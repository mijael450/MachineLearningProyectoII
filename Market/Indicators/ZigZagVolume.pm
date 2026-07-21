package Market::Indicators::ZigZagVolume;
use strict;
use warnings;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Indicators::ZigZagVolume
#
# "ZigZag Volume Profile [ChartPrime]" — indicador de DIRECCIÓN EXTERNA del
# precio (PDF "Indicadores zigzag", pág. 4 y 5).
#
# Objetivo: detectar solo los swings más significativos del mercado usando el
# volumen como filtro de ruido. A más volumen en la vela, más "peso" tiene ese
# movimiento para confirmar un nuevo swing.
#
# Config interna (PDF pág. 4, panel "ZigZag Volume Profile [ChartPrime]"):
#   Amount of ZigZag Volume Profiles to display : 15
#   Swing Channel → Display : off   Length : 150   Width : 1
#   Volume Profile → Display : off  Bins : 10      Bins Width : 5
#   POC → Display : off   Width : 1   Color : rojo
#   Zigzag line color : azul (#2962ff) — dirección externa (PDF pág. 5)
#
# Algoritmo (equivalente a ChartPrime con los parámetros del PDF):
#   1. ATR(14) propio (no depende del indicador ATR externo — independencia).
#   2. Volumen medio de las últimas 'length' velas (ventana móvil).
#   3. Threshold de confirmación por vela:
#        min_move(i) = ATR(i) * (volume(i) / avg_volume)^0.5
#      Con volumen alto el threshold BAJA (movimiento significativo con menos
#      desplazamiento), con volumen bajo SUBE. Raíz cuadrada para suavizar.
#   4. Pivot High / Low: mínimo 'depth' velas a cada lado + el movimiento desde
#      el último pivot contrario debe superar min_move * depth.
#   5. Alternancia estricta: en rachas del mismo tipo conserva el extremo.
#   6. Último segmento TENTATIVO hasta que el precio confirme la nueva dirección
#      alejándose al menos min_move del último pivot confirmado.
#
# Separación Indicators vs Overlays: este archivo SOLO calcula. El overlay
# (Market::Overlays::ZigZag) dibuja los segmentos en color azul.
# ═════════════════════════════════════════════════════════════════════════════

sub new {
    my ($class, %a) = @_;
    my $self = {
        # ── Config interna (default = PDF pág. 4) ──────────────────────────
        length     => $a{length}     // 150,   # ventana de volumen medio
        depth      => $a{depth}      // 5,     # velas de contexto a cada lado
        max_pivots => $a{max_pivots} // 15,    # "Amount of ZigZag Volume Profiles"
        atr_period => $a{atr_period} // 14,    # ATR para threshold dinámico
        color      => $a{color}      // '#2962ff',  # azul (dirección externa)
        # parámetros del Swing Channel / Volume Profile — almacenados por
        # completitud del PDF pero no se renderizan (Display: off)
        channel_length => $a{channel_length} // 150,
        channel_width  => $a{channel_width}  // 1,
        bins           => $a{bins}           // 10,
        bins_width     => $a{bins_width}     // 5,
        poc_width      => $a{poc_width}      // 1,

        # ── Resultados ─────────────────────────────────────────────────────
        pivots    => [],    # [{index, price, type=>'high'/'low', confirmed}]
        segments  => [],    # [{from,to,dir,confirmed}]
        tentative => undef, # {from,to,dir}  último tramo sin confirmar
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my $s = shift;
    $s->{pivots}    = [];
    $s->{segments}  = [];
    $s->{tentative} = undef;
}

sub values { return $_[0]->{segments}; }   # contrato IndicatorManager

# ─────────────────────────────────────────────────────────────────────────────
sub calculate_all {
    my ($self, $md) = @_;
    $self->reset;

    my $data  = $md->get_slice(0, $md->last_index());
    my $n     = scalar @$data;
    my $dep   = $self->{depth};
    my $vol_w = $self->{length};
    my $atrp  = $self->{atr_period};

    return unless $n >= 2 * $dep + 2;

    # ── Paso 1: ATR(14) sobre los datos recibidos ─────────────────────────
    my @atr = _calc_atr($data, $atrp);

    # ── Paso 2: volumen medio móvil de las últimas vol_w velas ───────────
    my @avg_vol = _calc_avg_vol($data, $vol_w);

    # ── Paso 3: threshold dinámico por vela ──────────────────────────────
    # min_move(i) = ATR(i) * sqrt(vol(i) / avg_vol(i))
    # Si avg_vol == 0 (inicio), usamos 1 para evitar división por cero.
    my @min_move;
    for my $i (0 .. $n - 1) {
        my $a   = $atr[$i]     // ($data->[$i]{high} - $data->[$i]{low});
        my $avg = $avg_vol[$i] || 1;
        my $vw  = $data->[$i]{volume} / $avg;
        $vw  = 0.25 if $vw  < 0.25;   # clamping: evitar pivotes extremadamente
        $vw  = 4.0  if $vw  > 4.0;    # fáciles/difíciles por picos de volumen
        $min_move[$i] = $a * sqrt($vw);
    }

    # ── Paso 4: detección de pivotes con threshold de volumen ─────────────
    my @cand;
    for my $i ($dep .. $n - 1 - $dep) {
        my ($is_h, $is_l) = (1, 1);

        # Ventana high/low: el candidato debe ser extremo local
        for my $k (1 .. $dep) {
            $is_h = 0 unless $data->[$i]{high} >= $data->[$i - $k]{high}
                          && $data->[$i]{high} >= $data->[$i + $k]{high};
            $is_l = 0 unless $data->[$i]{low}  <= $data->[$i - $k]{low}
                          && $data->[$i]{low}  <= $data->[$i + $k]{low};
        }
        push @cand, { idx => $i, price => $data->[$i]{high}, type => 'high' } if $is_h;
        push @cand, { idx => $i, price => $data->[$i]{low},  type => 'low'  } if $is_l;
    }
    @cand = sort { $a->{idx} <=> $b->{idx} } @cand;

    # ── Paso 5: filtro de movimiento mínimo + alternancia estricta ────────
    my @piv;
    for my $c (@cand) {
        if (!@piv) { push @piv, $c; next; }

        my $last = $piv[-1];
        if ($last->{type} eq $c->{type}) {
            # misma dirección: conservar el extremo
            if ($c->{type} eq 'high') { $piv[-1] = $c if $c->{price} > $last->{price}; }
            else                      { $piv[-1] = $c if $c->{price} < $last->{price}; }
        } else {
            # dirección opuesta: verificar que el movimiento supere el threshold
            my $move    = abs($c->{price} - $last->{price});
            my $thresh  = $min_move[$c->{idx}] * $dep;
            push @piv, $c if $move >= $thresh;
        }
    }

    return unless @piv;

    # ── Paso 6: confirmación ─────────────────────────────────────────────
    # Un pivot está confirmado si tiene 'dep' velas cerradas a su derecha.
    my $last_i = $n - 1;
    for my $p (@piv) {
        $p->{confirmed} = ($p->{idx} + $dep <= $last_i) ? 1 : 0;
    }

    # Recortar a max_pivots más recientes (PDF: "Amount of Profiles to display")
    if (@piv > $self->{max_pivots}) {
        @piv = @piv[ -$self->{max_pivots} .. -1 ];
    }

    # ── Paso 7: construir pivots (índices locales) y segmentos ────────────
    my @proj;
    for my $p (@piv) {
        push @proj, {
            index     => $p->{idx},
            price     => $p->{price},
            type      => $p->{type},
            confirmed => $p->{confirmed},
        };
    }
    $self->{pivots} = \@proj;

    my @seg;
    for (my $i = 0; $i < $#proj; $i++) {
        my ($a, $b) = ($proj[$i], $proj[$i + 1]);
        push @seg, {
            from      => { index => $a->{index}, price => $a->{price} },
            to        => { index => $b->{index}, price => $b->{price} },
            dir       => ($b->{price} >= $a->{price}) ? 'up' : 'down',
            confirmed => ($a->{confirmed} && $b->{confirmed}) ? 1 : 0,
        };
    }
    $self->{segments} = \@seg;

    # ── Paso 8: tramo tentativo del último pivot confirmado al precio actual
    my ($last_conf) = grep { $_->{confirmed} } reverse @proj;
    if ($last_conf) {
        my $cur_price = $data->[-1]{close};
        my $cur_index = $n - 1;
        $self->{tentative} = {
            from => { index => $last_conf->{index}, price => $last_conf->{price} },
            to   => { index => $cur_index,          price => $cur_price },
            dir  => ($cur_price >= $last_conf->{price}) ? 'up' : 'down',
        };
    }

    # ── Windowing (Replay): índices locales -> globales ───────────────────
    my $base = $md->can('base_index') ? $md->base_index : 0;
    $self->_offset_indices($base) if $base;
}

# ─────────────────────────────────────────────────────────────────────────────
# _calc_atr — ATR(period) de Wilder sobre el slice de datos. Idéntico al
# indicador Market::Indicators::ATR pero acotado a los datos recibidos (no
# depende del objeto ATR externo — independencia entre indicadores).
# ─────────────────────────────────────────────────────────────────────────────
sub _calc_atr {
    my ($data, $p) = @_;
    my @atr;
    my @tr;
    for my $i (0 .. $#$data) {
        my $c = $data->[$i];
        my $tr;
        if ($i == 0) {
            $tr = $c->{high} - $c->{low};
        } else {
            my $pc = $data->[$i - 1]{close};
            my $a  = $c->{high} - $c->{low};
            my $b  = abs($c->{high} - $pc);
            my $d  = abs($c->{low}  - $pc);
            $tr = $a > $b ? $a : $b; $tr = $d if $d > $tr;
        }
        push @tr, $tr;
        if ($i < $p - 1) {
            push @atr, undef;
        } elsif ($i == $p - 1) {
            my $s = 0; $s += $_ for @tr[0 .. $p - 1]; push @atr, $s / $p;
        } else {
            push @atr, (($atr[-1] * ($p - 1)) + $tr) / $p;
        }
    }
    return @atr;
}

# ─────────────────────────────────────────────────────────────────────────────
# _calc_avg_vol — media móvil simple del volumen con ventana 'w'.
# ─────────────────────────────────────────────────────────────────────────────
sub _calc_avg_vol {
    my ($data, $w) = @_;
    my @avg;
    my $sum = 0;
    for my $i (0 .. $#$data) {
        $sum += $data->[$i]{volume};
        $sum -= $data->[$i - $w]{volume} if $i >= $w;
        my $cnt = ($i < $w) ? ($i + 1) : $w;
        push @avg, $sum / $cnt;
    }
    return @avg;
}

# ─────────────────────────────────────────────────────────────────────────────
# _offset_indices — índices locales -> globales tras cálculo por ventana.
# Mismo patrón que SMC_Structures, Liquidity y ZigZagMTF.
# ─────────────────────────────────────────────────────────────────────────────
sub _offset_indices {
    my ($self, $base) = @_;
    return if !$base;

    $_->{index} += $base for @{ $self->{pivots} };

    for my $s (@{ $self->{segments} }) {
        $s->{from}{index} += $base;
        $s->{to}{index}   += $base;
    }
    if (my $t = $self->{tentative}) {
        $t->{from}{index} += $base;
        $t->{to}{index}   += $base;
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Consultas para el Overlay — índices globales, baratas (filtran arrays ya
# calculados en el rango visible).
# ─────────────────────────────────────────────────────────────────────────────
sub segments_in_range {
    my ($self, $start, $end) = @_;
    return [ grep { $_->{from}{index} <= $end && $_->{to}{index} >= $start }
             @{ $self->{segments} } ];
}

sub pivots_in_range {
    my ($self, $start, $end) = @_;
    return [ grep { $_->{index} >= $start && $_->{index} <= $end }
             @{ $self->{pivots} } ];
}

sub tentative_segment { return $_[0]->{tentative}; }

sub latest_confirmed_segment_before {
    my ($self, $end) = @_;
    my @segments = grep { $_->{confirmed} && $_->{to}{index} <= $end }
                   @{ $self->{segments} };
    return @segments ? $segments[-1] : undef;
}

1;
