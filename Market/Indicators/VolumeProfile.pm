package Market::Indicators::VolumeProfile;
use strict;
use warnings;
use POSIX qw(floor ceil);

# ═════════════════════════════════════════════════════════════════════════════
# Market::Indicators::VolumeProfile — Perfil de Volumen Anclado (AVP), fiel a
# TradingView. Cálculo puro (cero dibujo).
#
# El AVP calcula el volumen negociado en cada nivel de precio dentro del rango
# [vela Anchor .. última vela disponible]. MULTIPIVOT: mantiene una LISTA de
# perfiles, cada uno con su anchor y config, para mostrar varios AVP a la vez
# (igual patrón que Market::Indicators::VWAP).
#
# Fidelidad a TV:
#  · Resolución (regla de los 5000): se elige la temporalidad MÁS FINA cuyo
#    número de barras en el rango sea < 5000, recorriendo la secuencia de TFs
#    disponibles (1,5,15,60,120,240,'D'). Menos barras que eso ⇒ más detalle.
#  · Reparto de volumen UNIFORME por rango: el volumen de cada vela se reparte
#    entre las filas de precio que cubre su rango [low,high], en proporción al
#    solape. Se etiqueta como "up" si close>open, si no "down" (regla de TV
#    "creación en una sola barra": close>open ⇒ Volumen Máximo, si no Mínimo).
#  · Filas: "Número de filas" (row_size) con la regla de redondeo de TV para
#    ticks-por-fila (se elige round-up/round-down según cuál deja un total de
#    filas más cercano a row_size).
#  · Value Area (área de valor): % del volumen total alrededor del POC ⇒ VAH/VAL.
#
# Replay-safe: lee sólo vía $md->get_slice / $md->get_tf_slice; con un
# ReplayProxy ambos quedan acotados al cursor (get_tf_slice → get_tf_slice_upto),
# así ninguna barra futura entra al perfil.
# ═════════════════════════════════════════════════════════════════════════════

# Secuencia de resolución (TFs disponibles en este motor; TV usa 1,3,5,15,30,60,
# 240,1D — aquí no existen 3m/30m, se usa el subconjunto disponible).
my @RES_SEQUENCE = (1, 5, 15, 60, 120, 240, 'D');
my $MAX_BARS     = 5000;

sub new {
    my ($class, %a) = @_;
    my $self = {
        # profiles: [ { key, anchor_index, label, config, result } ]
        profiles => $a{profiles} // [],
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $_->{result} = undef for @{ $self->{profiles} };
}

# values() devuelve la lista de perfiles (con su result calculado) — la usa el
# overlay para dibujar cada AVP.
sub values  { return $_[0]->{profiles}; }
sub has_any { return scalar @{ $_[0]->{profiles} } ? 1 : 0; }

# Config por defecto (valores de las imágenes de configuración del usuario).
sub default_config {
    return {
        rows_layout    => 'rows',    # 'rows' = "Número de filas"
        row_size       => 1000,      # nº de filas objetivo
        volume_mode    => 'updown',  # total | updown | delta
        value_area_pct => 70,        # % de volumen del área de valor
        tick_size      => 0.25,      # NQ: movimiento mínimo de precio
    };
}

# Reemplaza la lista de perfiles. Cada spec: { key, anchor_index, label?,
# color?, config? }. El result se rellena en calculate_all().
sub set_profiles {
    my ($self, $specs) = @_;
    my @profiles;
    for my $s (@$specs) {
        my %cfg = (%{ default_config() }, %{ $s->{config} // {} });
        push @profiles, {
            key          => $s->{key},
            anchor_index => $s->{anchor_index},
            label        => $s->{label} // 'AVP',
            color        => $s->{color} // '#787b86',
            config       => \%cfg,
            result       => undef,
        };
    }
    $self->{profiles} = \@profiles;
}

sub calculate_all {
    my ($self, $md) = @_;
    my $last = $md->last_index();

    for my $prof (@{ $self->{profiles} }) {
        $prof->{result} = undef;
        my $anchor = $prof->{anchor_index};
        next unless defined $anchor;
        my $a = $anchor < 0 ? 0 : $anchor;
        next if $a > $last;   # el anchor aún no ocurrió (Replay)

        # Slice del TF activo [anchor..last] (ya acotado al cursor en Replay).
        my $slice = $md->get_slice($a, $last);
        next unless $slice && @$slice;
        my $anchor_epoch = $slice->[0]{epoch};
        my $last_epoch   = $slice->[-1]{epoch};

        # Barras a la resolución elegida (regla de los 5000). Fallback: el slice
        # del TF activo si no hay TF más fina disponible para el rango.
        my $bars = _pick_resolution_bars($md, $anchor_epoch, $last_epoch);
        $bars = $slice unless $bars && @$bars;

        $prof->{result} = compute_profile($bars, %{ $prof->{config} });
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _pick_resolution_bars — elige la TF más fina con < 5000 barras en el rango
# [anchor_epoch..last_epoch] y devuelve esas barras (arrayref de velas).
sub _pick_resolution_bars {
    my ($md, $anchor_epoch, $last_epoch) = @_;
    my $chosen;
    for my $tf (@RES_SEQUENCE) {
        # get_tf_slice queda acotado al cursor en Replay (get_tf_slice_upto).
        my $arr = $md->get_tf_slice($tf, 0, 1_000_000_000);
        next unless $arr && @$arr;
        my @in = grep { $_->{epoch} >= $anchor_epoch && $_->{epoch} <= $last_epoch } @$arr;
        next unless @in;
        if (@in < $MAX_BARS) { return \@in; }   # la más fina que cabe: listo
        $chosen = \@in;                          # recuerda la última (más gruesa)
    }
    # Ninguna baja de 5000: usar la más gruesa disponible (la última recordada).
    return $chosen;
}

# ─────────────────────────────────────────────────────────────────────────────
# compute_profile — núcleo reutilizable. Recibe un arrayref de velas y la config,
# devuelve el perfil completo. Lo usan calculate_all() y el AVWAP (POC real).
sub compute_profile {
    my ($candles, %cfg) = @_;
    return undef unless $candles && @$candles;

    my $tick    = $cfg{tick_size}      || 0.25;
    my $rows    = $cfg{row_size}       || 1000;
    my $va_pct  = $cfg{value_area_pct} || 70;

    # top/bottom del rango.
    my ($top, $bottom);
    for my $c (@$candles) {
        $top    = $c->{high} if !defined $top    || $c->{high} > $top;
        $bottom = $c->{low}  if !defined $bottom || $c->{low}  < $bottom;
    }
    return undef unless defined $top && defined $bottom;
    # Degenerado (todo el rango en un solo precio): una fila de un tick.
    $top = $bottom + $tick if $top - $bottom < $tick;

    my $span_price  = $top - $bottom;
    my $total_ticks = $span_price / $tick;

    # ── Filas: ticks-por-fila con la regla de redondeo de TV ─────────────────
    my $tpr;
    if ($cfg{rows_layout} && $cfg{rows_layout} eq 'ticks') {
        $tpr = $rows;                    # aquí row_size = ticks por fila
    } else {
        my $raw = $total_ticks / $rows;  # ticks por fila (float)
        if ($raw <= 1) {
            $tpr = 1;
        } else {
            my $down = floor($raw); $down = 1 if $down < 1;
            my $up   = ceil($raw);
            my $n_down = ceil($total_ticks / $down);
            my $n_up   = ceil($total_ticks / $up);
            $tpr = (abs($n_down - $rows) <= abs($n_up - $rows)) ? $down : $up;
        }
    }
    $tpr = 1 if $tpr < 1;

    my $row_h  = $tpr * $tick;                       # alto de fila en precio
    my $n_rows = ceil($span_price / $row_h);
    $n_rows = 1 if $n_rows < 1;

    my $row_of = sub {
        my ($p) = @_;
        my $r = int(($p - $bottom) / $row_h);
        $r = 0            if $r < 0;
        $r = $n_rows - 1  if $r > $n_rows - 1;
        return $r;
    };

    # ── Reparto de volumen uniforme por rango ────────────────────────────────
    my (@up, @dn);
    $up[$_] = 0, $dn[$_] = 0 for 0 .. $n_rows - 1;
    for my $c (@$candles) {
        my $vol = $c->{volume} // 0;
        next if $vol <= 0;
        my $lo = $c->{low};
        my $hi = $c->{high};
        my $is_up = ($c->{close} > $c->{open}) ? 1 : 0;

        if ($hi <= $lo) {                            # vela plana → una sola fila
            my $r = $row_of->($lo);
            $is_up ? ($up[$r] += $vol) : ($dn[$r] += $vol);
            next;
        }
        my $span = $hi - $lo;
        my $r0 = $row_of->($lo);
        my $r1 = $row_of->($hi);
        for my $r ($r0 .. $r1) {
            my $rlo = $bottom + $r * $row_h;
            my $rhi = $rlo + $row_h;
            my $ov  = (($hi < $rhi) ? $hi : $rhi) - (($lo > $rlo) ? $lo : $rlo);
            next if $ov <= 0;
            my $part = $vol * ($ov / $span);
            $is_up ? ($up[$r] += $part) : ($dn[$r] += $part);
        }
    }

    # ── Filas + POC + total ──────────────────────────────────────────────────
    my @rows_out;
    my ($poc_idx, $max_vol, $total_vol) = (0, -1, 0);
    for my $r (0 .. $n_rows - 1) {
        my $tot = $up[$r] + $dn[$r];
        $total_vol += $tot;
        if ($tot > $max_vol) { $max_vol = $tot; $poc_idx = $r; }
        push @rows_out, {
            price_lo => $bottom + $r * $row_h,
            price_hi => $bottom + ($r + 1) * $row_h,
            up       => $up[$r],
            down     => $dn[$r],
            total    => $tot,
            in_va    => 0,
        };
    }

    # ── Value Area: expandir desde el POC hasta cubrir va_pct% del volumen ────
    my $va_target = $total_vol * $va_pct / 100;
    my ($lo_idx, $hi_idx) = ($poc_idx, $poc_idx);
    my $acc = $rows_out[$poc_idx]{total};
    while ($acc < $va_target && ($lo_idx > 0 || $hi_idx < $n_rows - 1)) {
        my $above = ($hi_idx < $n_rows - 1) ? $rows_out[$hi_idx + 1]{total} : -1;
        my $below = ($lo_idx > 0)           ? $rows_out[$lo_idx - 1]{total} : -1;
        last if $above < 0 && $below < 0;
        if ($above >= $below) { $hi_idx++; $acc += $above; }
        else                  { $lo_idx--; $acc += $below; }
    }
    $rows_out[$_]{in_va} = 1 for $lo_idx .. $hi_idx;

    my $poc_row = $rows_out[$poc_idx];
    return {
        rows        => \@rows_out,
        poc_price   => ($poc_row->{price_lo} + $poc_row->{price_hi}) / 2,
        vah         => $rows_out[$hi_idx]{price_hi},
        val         => $rows_out[$lo_idx]{price_lo},
        total_vol   => $total_vol,
        max_row_vol => $max_vol,
        top         => $top,
        bottom      => $bottom,
        n_rows      => $n_rows,
    };
}

1;

