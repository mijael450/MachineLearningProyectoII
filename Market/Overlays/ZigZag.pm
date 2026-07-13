package Market::Overlays::ZigZag;
use strict;
use warnings;
use lib '.';
use Market::Panels::Scales;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Overlays::ZigZag
#
# Responsabilidad EXCLUSIVA: dibujar en el canvas lo que calcularon
# Market::Indicators::ZigZagMTF y Market::Indicators::ZigZagVolume.
# No calcula nada — separación estricta Indicators vs Overlays (Tabla 1).
#
# Dibuja:
#   ZZMTF (dirección interna):
#     - Segmentos confirmados : línea sólida verde (up) / roja (down), grosor 2
#     - Segmento tentativo    : mismos colores, línea punteada [4,2], grosor 1
#     - Etiquetas HH/HL/LH/LL : sobre cada pivote, arriba si high / abajo si low
#
#   ZigZag Volume (dirección externa):
#     - Segmentos confirmados : línea sólida azul (#2962ff), grosor 2
#     - Segmento tentativo    : azul punteado [4,2], grosor 1
#     (sin etiquetas — solo los segmentos, como en el PDF pág.5)
#
# Compatible con Replay: ChartEngine llama a draw() con $start/$end ya
# recortados al cursor, y los indicadores devuelven solo elementos en ese
# rango, igual que SMC_Structures y Liquidity.
# ═════════════════════════════════════════════════════════════════════════════

# Colores (PDF pág. 4 / pág. 5)
my $COLOR_UP    = '#26a69a';   # verde  — ZZMTF alcista
my $COLOR_DOWN  = '#ef5350';   # rojo   — ZZMTF bajista
my $COLOR_EXT   = '#2962ff';   # azul   — ZZVolume (dirección externa)
my $COLOR_LABEL = '#2962ff';   # azul   — etiquetas HH/HL/LH/LL (PDF: text color)

sub new {
    my ($class, %args) = @_;
    my $self = {
        scale   => Market::Panels::Scales->new(),
        visible => {
            zzmtf    => 0,   # dirección interna  (verde/rojo)
            zzvolume => 0,   # dirección externa  (azul)
        },
    };
    bless $self, $class;
    return $self;
}

sub set_visible {
    my ($self, $key, $value) = @_;
    $self->{visible}{$key} = $value ? 1 : 0;
}

sub is_visible {
    my ($self, $key) = @_;
    return $self->{visible}{$key} // 0;
}

# ─────────────────────────────────────────────────────────────────────────────
# draw — punto de entrada, llamado desde ChartEngine::draw()
#
# $zzmtf   : objeto Market::Indicators::ZigZagMTF   (puede ser undef)
# $zzv     : objeto Market::Indicators::ZigZagVolume (puede ser undef)
# $x_of    : closure  índice_local -> coordenada_X
# $state   : hashref de contexto (igual que usa PricePanel/ATRPanel)
# ─────────────────────────────────────────────────────────────────────────────
sub draw {
    my ($self, $canvas, $zzmtf, $zzv, $x_of, $state) = @_;

    my $start = $state->{start_index};
    my $end   = $state->{end_index};
    my $min   = $state->{price_min};
    my $max   = $state->{price_max};
    my $top   = $state->{top};
    my $h     = $state->{price_h};   # igual que PricePanel — incluye el área de volumen

    return unless defined $min && defined $max;

    # ZZVolume debajo (capa de fondo) para que ZZMTF quede encima
    $self->_draw_zzvolume($canvas, $zzv,   $x_of, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{zzvolume} && defined $zzv;

    $self->_draw_zzmtf($canvas,   $zzmtf, $x_of, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{zzmtf}   && defined $zzmtf;
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_zzmtf — segmentos y etiquetas de la dirección INTERNA
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_zzmtf {
    my ($self, $canvas, $ind, $x_of, $start, $end, $min, $max, $top, $h) = @_;

    # Segmentos confirmados
    # _seg_coords interpola los puntos cuando el from/to cae fuera de la ventana
    # visible, para que la línea entre/salga por el borde con el precio correcto.
    my $segs = $ind->segments_in_range($start, $end);
    for my $s (@$segs) {
        my ($x1,$y1,$x2,$y2) = _seg_coords($s->{from}, $s->{to},
                                            $x_of, $start, $end,
                                            $self->{scale}, $min, $max, $top, $h);
        next unless defined $x1;
        next if _both_outside($y1, $y2, $top, $h);

        my $color = ($s->{dir} eq 'up') ? $COLOR_UP : $COLOR_DOWN;
        $canvas->createLine($x1, $y1, $x2, $y2,
            -fill  => $color,
            -width => 2,
            -tags  => 'zz_mtf',
        );
    }

    # Segmento tentativo (punteado, grosor 1 — aún no confirmado)
    my $tent = $ind->tentative_segment();
    if (defined $tent
        && $tent->{from}{index} <= $end
        && $tent->{to}{index}   >= $start) {

        my ($x1,$y1,$x2,$y2) = _seg_coords($tent->{from}, $tent->{to},
                                            $x_of, $start, $end,
                                            $self->{scale}, $min, $max, $top, $h);
        if (defined $x1 && !_both_outside($y1, $y2, $top, $h)) {
            my $color = ($tent->{dir} eq 'up') ? $COLOR_UP : $COLOR_DOWN;
            $canvas->createLine($x1, $y1, $x2, $y2,
                -fill  => $color,
                -width => 1,
                -dash  => [4, 2],
                -tags  => 'zz_mtf',
            );
        }
    }

}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_zzvolume — segmentos de la dirección EXTERNA (azul)
# Solo líneas, sin etiquetas (PDF pág. 5)
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_zzvolume {
    my ($self, $canvas, $ind, $x_of, $start, $end, $min, $max, $top, $h) = @_;

    # Segmentos confirmados
    my $segs = $ind->segments_in_range($start, $end);
    for my $s (@$segs) {
        my ($x1,$y1,$x2,$y2) = _seg_coords($s->{from}, $s->{to},
                                            $x_of, $start, $end,
                                            $self->{scale}, $min, $max, $top, $h);
        next unless defined $x1;
        next if _both_outside($y1, $y2, $top, $h);
        $canvas->createLine($x1, $y1, $x2, $y2,
            -fill  => $COLOR_EXT,
            -width => 2,
            -tags  => 'zz_vol',
        );
    }

    # Segmento tentativo (punteado)
    my $tent = $ind->tentative_segment();
    if (defined $tent
        && $tent->{from}{index} <= $end
        && $tent->{to}{index}   >= $start) {

        my ($x1,$y1,$x2,$y2) = _seg_coords($tent->{from}, $tent->{to},
                                            $x_of, $start, $end,
                                            $self->{scale}, $min, $max, $top, $h);
        if (defined $x1 && !_both_outside($y1, $y2, $top, $h)) {
            $canvas->createLine($x1, $y1, $x2, $y2,
                -fill  => $COLOR_EXT,
                -width => 1,
                -dash  => [4, 2],
                -tags  => 'zz_vol',
            );
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _seg_coords — calcula (x1,y1,x2,y2) para un segmento, interpolando los
# extremos que caen fuera de la ventana visible [start..end].
#
# Sin esto, cuando from.index < start o to.index > end, la línea entraría/
# saldría del borde del canvas visualmente en el lugar equivocado (Tk la
# recorta en el borde del widget, no en el precio correcto). La interpolación
# lineal garantiza que la línea entre/salga exactamente en el precio correcto
# al borde de la ventana, igual que TradingView.
# ─────────────────────────────────────────────────────────────────────────────
sub _seg_coords {
    my ($from, $to, $x_of, $start, $end, $scale, $min, $max, $top, $h) = @_;

    my $fi = $from->{index};
    my $ti = $to->{index};
    my $fp = $from->{price};
    my $tp = $to->{price};

    # Interpolación lineal: si from o to caen fuera de [start,end],
    # calcular el precio en el borde visible.
    if ($fi < $start) {
        # Interpolar el precio en start
        my $ratio = ($start - $fi) / ($ti - $fi);
        $fp = $fp + ($tp - $fp) * $ratio;
        $fi = $start;
    }
    if ($ti > $end) {
        my $ratio = ($ti - $end) / ($ti - $fi);
        $tp = $tp - ($tp - $fp) * $ratio;
        $ti = $end;
    }
    return () if $fi > $ti;

    my $x1 = $x_of->($fi - $start);
    my $y1 = $scale->price_to_y($fp, $min, $max, $top, $h);
    my $x2 = $x_of->($ti - $start);
    my $y2 = $scale->price_to_y($tp, $min, $max, $top, $h);
    return ($x1, $y1, $x2, $y2);
}

# ─────────────────────────────────────────────────────────────────────────────
# _both_outside — true si los dos extremos están fuera del panel visible.
# ─────────────────────────────────────────────────────────────────────────────
sub _both_outside {
    my ($y1, $y2, $top, $h) = @_;
    my $bot = $top + $h;
    return (($y1 < $top && $y2 < $top) || ($y1 > $bot && $y2 > $bot));
}

1;
