package Market::Overlays::VolumeProfile;
use strict;
use warnings;
use lib '.';
use Market::Panels::Scales;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Overlays::VolumeProfile — dibujo del Perfil de Volumen Anclado (AVP).
#
# Dibuja cada perfil calculado por Market::Indicators::VolumeProfile (cero
# cálculo aquí):
#   · Histograma horizontal anclado a la DERECHA (Colocación = Derecha), con
#     ancho máximo = 30% del recuadro (desde el anchor hasta el borde derecho).
#     La fila más votada (POC) ocupa el ancho máximo; el resto, proporcional.
#   · Modo Volumen: updown (up cyan / down rosa apilados) | total | delta.
#   · Filas dentro del Área de Valor a color pleno; fuera, atenuadas.
#   · Líneas POC / VAH / VAL + etiquetas en la escala de precios.
#
# Replay-safe: el result ya viene acotado al cursor; aquí sólo se renderiza.
# ═════════════════════════════════════════════════════════════════════════════

my %COL = (
    up_va  => '#22d3ee', up_out  => '#0e7490',
    dn_va  => '#ec4899', dn_out  => '#9d174b',
    tot_va => '#5b9cff', tot_out => '#2a4a7a',
    poc    => '#e53935',
    va     => '#b58a3c',
);

# 30% del recuadro (Ancho % del recuadro = 30).
my $WIDTH_FRAC = 0.30;

sub new {
    my ($class, %args) = @_;
    my $self = {
        scale   => Market::Panels::Scales->new(),
        mode    => 'updown',                       # updown | total | delta
        visible => { poc => 1, vah => 1, val => 1, va => 1 },
    };
    bless $self, $class;
    return $self;
}

sub set_visible { $_[0]->{visible}{$_[1]} = $_[2] ? 1 : 0; }
sub is_visible  { return $_[0]->{visible}{$_[1]} // 0; }
sub set_mode    { $_[0]->{mode} = $_[1]; }
sub mode        { return $_[0]->{mode}; }

# ─────────────────────────────────────────────────────────────────────────────
sub draw {
    my ($self, $canvas, $vp, $x_of, $state) = @_;
    return unless defined $vp && $vp->has_any;
    return unless defined $state->{price_min} && defined $state->{price_max};

    for my $prof (@{ $vp->values() }) {
        next unless $prof->{result};
        $self->_draw_profile($canvas, $prof, $x_of, $state);
    }
}

sub draw_result {
    my ($self, $canvas, $result, $x_of, $state) = @_;
    return unless $result;
    $self->_draw_profile($canvas, {
        key => 'visible_range',
        anchor_index => $state->{start_index},
        result => $result,
    }, $x_of, $state);
}

sub _draw_profile {
    my ($self, $c, $prof, $x_of, $state) = @_;
    my $res   = $prof->{result};
    my $rows  = $res->{rows};
    return unless $rows && @$rows;

    my $min   = $state->{price_min};
    my $max   = $state->{price_max};
    my $top   = $state->{top};
    my $h     = $state->{price_h};
    my $left  = $state->{left};
    my $right = $state->{right};
    my $w     = $state->{w};
    my $start = $state->{start_index};
    my $scale = $self->{scale};

    my $y_of = sub { $scale->price_to_y($_[0], $min, $max, $top, $h) };

    # Identificar si se trata de uno de los perfiles automáticos
# implementados para BOS, CHoCH o contingencia.
my $profile_key = $prof->{key} // '';

my $is_auto_profile =
       $profile_key =~ /^avp_auto_/
    || $profile_key eq 'avp_contingency';

# Posición gráfica del evento que originó el perfil.
my $anchor_x = $x_of->(
    $prof->{anchor_index} - $start
);

# Mantener el anchor dentro del panel visible.
my $box_left = $anchor_x;
$box_left = $left  if $box_left < $left;
$box_left = $right if $box_left > $right;

my $box_w = $right - $box_left;

# En perfiles manuales se conserva el comportamiento original:
# si prácticamente no existe espacio desde el anchor hasta el borde,
# no hay recuadro válido para dibujar.
#
# En perfiles automáticos NO se abandona el dibujo, porque sus niveles
# POC, VAH y VAL deben mantenerse visibles en toda la temporalidad.
return if !$is_auto_profile && $box_w < 4;

# Para BOS, CHoCH y contingencia, el histograma puede utilizar como
# referencia el ancho completo del panel visible. De esta manera,
# aunque el evento esté cerca del borde derecho, el perfil no desaparece.
my $profile_draw_width = $is_auto_profile
    ? ($right - $left)
    : $box_w;

$profile_draw_width = 4
    if $profile_draw_width < 4;

my $max_width =
    $WIDTH_FRAC * $profile_draw_width;

    my $mode    = $self->{mode};
    my $max_vol = $res->{max_row_vol} || 1;

    # En modo delta el ancho se escala por el |delta| máximo.
    my $max_delta = 1;
    if ($mode eq 'delta') {
        for my $r (@$rows) {
            my $d = abs($r->{up} - $r->{down});
            $max_delta = $d if $d > $max_delta;
        }
    }

    # ── Barras del histograma ────────────────────────────────────────────────
    for my $r (@$rows) {
        next if $r->{total} <= 0;
        my $y_hi = $y_of->($r->{price_hi});   # y del precio superior (más arriba)
        my $y_lo = $y_of->($r->{price_lo});
        # Fuera del panel de precio visible: saltar.
        next if $y_lo < $top - 1 || $y_hi > $top + $h + 1;
        my $bh = $y_lo - $y_hi;
        $bh = 1 if $bh < 1;
        my $in_va = $r->{in_va};

        if ($mode eq 'total') {
            my $bw = ($r->{total} / $max_vol) * $max_width;
            next if $bw < 0.5;
            _rect($c, $right - $bw, $y_hi, $right, $y_hi + $bh,
                  $in_va ? $COL{tot_va} : $COL{tot_out});
        }
        elsif ($mode eq 'delta') {
            my $d  = $r->{up} - $r->{down};
            my $bw = (abs($d) / $max_delta) * $max_width;
            next if $bw < 0.5;
            my $col = $d >= 0
                ? ($in_va ? $COL{up_va} : $COL{up_out})
                : ($in_va ? $COL{dn_va} : $COL{dn_out});
            _rect($c, $right - $bw, $y_hi, $right, $y_hi + $bh, $col);
        }
        else {   # updown: up y down apilados (up junto al eje)
            my $w_up = ($r->{up}   / $max_vol) * $max_width;
            my $w_dn = ($r->{down} / $max_vol) * $max_width;
            my $x_up0 = $right - $w_up;
            if ($w_up >= 0.5) {
                _rect($c, $x_up0, $y_hi, $right, $y_hi + $bh,
                      $in_va ? $COL{up_va} : $COL{up_out});
            }
            if ($w_dn >= 0.5) {
                _rect($c, $x_up0 - $w_dn, $y_hi, $x_up0, $y_hi + $bh,
                      $in_va ? $COL{dn_va} : $COL{dn_out});
            }
        }
    }

    # ── Líneas POC / VAH / VAL + etiquetas en la escala de precios ────────────

# Los perfiles automáticos mantienen sus niveles en todo el ancho
# de la temporalidad visible.
#
# Los perfiles manuales conservan el inicio desde su anchor.
my $level_x0 = $is_auto_profile
    ? $left
    : $box_left;

if ($self->{visible}{poc}) {
    $self->_level_line(
        $c,
        $level_x0,
        $right,
        $w,
        $y_of->($res->{poc_price}),
        $res->{poc_price},
        $COL{poc},
        2,
        0
    );
}

if ($self->{visible}{vah}) {
    $self->_level_line(
        $c,
        $level_x0,
        $right,
        $w,
        $y_of->($res->{vah}),
        $res->{vah},
        $COL{va},
        1,
        1
    );
}

if ($self->{visible}{val}) {
    $self->_level_line(
        $c,
        $level_x0,
        $right,
        $w,
        $y_of->($res->{val}),
        $res->{val},
        $COL{va},
        1,
        1
    );
}

    # Etiqueta del perfil junto al anchor.
    if ($box_left < $right - 20) {
        $c->createText($box_left + 2, $top + 8, -anchor => 'w',
            -text => $prof->{label}, -fill => $prof->{color},
            -font => ['Arial', 7, 'bold'], -tags => 'avp');
    }
}

# Línea horizontal a lo ancho del recuadro + etiqueta de precio en el eje Y.
sub _level_line {
    my ($self, $c, $x0, $x1, $w, $y, $price, $color, $width, $dash) = @_;
    my @opt = (-fill => $color, -width => $width, -tags => 'avp');
    push @opt, (-dash => [4, 3]) if $dash;
    $c->createLine($x0, $y, $x1, $y, @opt);

    my $label = sprintf('%.2f', $price);
    my $lw    = length($label) * 6 + 8;
    my $lx    = $x1 + ($w - $x1) / 2;
    $lx = $x1 + $lw / 2 + 1 if $lx - $lw / 2 < $x1;
    $c->createRectangle($lx - $lw/2, $y - 7, $lx + $lw/2, $y + 7,
        -fill => $color, -outline => $color, -tags => 'avp');
    $c->createText($lx, $y, -text => $label, -fill => '#ffffff',
        -font => ['Arial', 7, 'bold'], -tags => 'avp');
}

sub _rect {
    my ($c, $x0, $y0, $x1, $y1, $color) = @_;
    $c->createRectangle($x0, $y0, $x1, $y1,
        -fill => $color, -outline => '', -tags => 'avp');
}

1;
