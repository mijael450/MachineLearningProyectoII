package Market::Indicators::ZigZagMTF;
use strict;
use warnings;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Indicators::ZigZagMTF
#
# "ZigZag Multi Time Frame with Fibonacci Retracement [ZZMTF]" — indicador de
# DIRECCIÓN INTERNA del precio (PDF "Indicadores zigzag", pág. 4 y 5).
#
# Objetivo: limpiar el ruido de las etiquetas HH/HL/LH/LL en baja temporalidad.
# En vez de detectar swings sobre el 1m (ruidoso), detecta el zigzag sobre una
# temporalidad de referencia superior (30m por defecto) y lo PROYECTA sobre el
# gráfico de 1m. El resultado es una dirección interna limpia.
#
# Config interna (PDF pág. 4, panel "ZZMTF"):
#   ZigZag Resolution : 30 min     ZigZag Period : 2      Show Zig Zag : on
#   Show Fibonacci Ratios : off     Colorful Fibonacci : off
#   Text Color : azul   Line Color : verde   Zigzag Line Colors : verde/rojo
#   Label Location : Left   Enable Level 0.236/0.382/0.5/0.618/0.786 : off
#
# NO calcula nada de otros indicadores ni modifica MarketData. Construye la
# temporalidad de 30m bajo demanda con build_tf_candles (idempotente y barato)
# y solo cuando el objeto lo soporta (MarketData real); en Replay recibe un
# WindowProxy y la lee ya construida.
#
# Comportamiento en Replay (PDF pág. 5): el ÚLTIMO segmento es TENTATIVO — el
# zigzag "espera" a que se consoliden velas del TF de referencia antes de
# confirmar la dirección. Al confirmarse un pivote, el segmento anterior queda
# fijo. Esto emerge de forma natural: solo se detectan pivotes con 'period'
# velas cerradas a cada lado, así que el tramo hasta el precio actual queda
# tentativo hasta que el TF superior cierra suficientes velas.
#
# Separación Indicators vs Overlays (Tabla 1): este archivo SOLO calcula; el
# dibujo lo hace Market::Overlays::ZigZag.
# ═════════════════════════════════════════════════════════════════════════════

sub new {
    my ($class, %a) = @_;
    my $self = {
        # ── Config interna (default = PDF pág. 4) ──────────────────────────
        resolution     => $a{resolution}     // 30,   # ZigZag Resolution (min)
        period         => $a{period}         // 2,    # ZigZag Period (depth)
        show_zigzag    => $a{show_zigzag}    // 1,
        show_fib       => $a{show_fib}       // 0,     # Show Fibonacci Ratios
        colorful_fib   => $a{colorful_fib}   // 0,     # Colorful Fibonacci Levels
        text_color     => $a{text_color}     // '#2962ff',  # azul
        line_color     => $a{line_color}     // '#26a69a',  # verde
        up_color       => $a{up_color}       // '#26a69a',  # alcista  (verde)
        down_color     => $a{down_color}     // '#ef5350',  # bajista  (rojo)
        label_location => $a{label_location} // 'left',
        fib_enabled    => $a{fib_enabled}    // {       # Enable Level *: todos off
            '0.236' => 0, '0.382' => 0, '0.500' => 0, '0.618' => 0, '0.786' => 0,
        },

        # ── Resultados ─────────────────────────────────────────────────────
        pivots    => [],    # [{index, price, label, type, confirmed}]
        segments  => [],    # [{from,to,dir,confirmed}]  index/price en from/to
        tentative => undef, # {from,to,dir}  último tramo aún sin confirmar
        fib       => undef, # {from,to,levels=>[{level,price}]}
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my $s = shift;
    $s->{pivots}    = [];
    $s->{segments}  = [];
    $s->{tentative} = undef;
    $s->{fib}       = undef;
}

sub values { return $_[0]->{segments}; }   # contrato mínimo del IndicatorManager


# ─────────────────────────────────────────────────────────────────────────────
# calculate_all — motor principal ATR-based sobre la temporalidad activa
#
# La "resolution" (15/30/60) controla la sensibilidad del umbral de reversión:
#   15min → factor ~2.5  (más pivotes, más denso)
#   30min → factor ~3.0  (densidad media, ~20 velas/pivote — igual que TV)
#   60min → factor ~5.0  (menos pivotes, visión más amplia)
#
# El zigzag NO usa velas del TF superior. Calcula sobre la temporalidad activa
# (1m) con un threshold = factor * ATR(14). Esto reproduce exactamente el
# comportamiento visual de ChartPrime ZZMTF en TradingView.
#
# Comportamiento tentativo en Replay (PDF pág.5): el último pivote queda
# "no confirmado" hasta que el precio revierte suficiente desde su extremo
# en las velas SIGUIENTES al extremo. En replay, como no hay velas futuras,
# el tramo entre el último extremo y el precio actual se dibuja punteado.
# ─────────────────────────────────────────────────────────────────────────────
sub calculate_all {
    my ($self, $md) = @_;
    $self->reset;

    my $data = $md->get_slice(0, $md->last_index());
    my $n    = scalar @$data;
    return unless $n >= 20;

    # ── Paso 1: ATR(14) sobre los datos recibidos ─────────────────────────
    my @atr = _calc_atr_zz($data, 14);

    # ── Paso 2: factor de reversión según resolution (PDF pág.4) ──────────
    # Mapeo lineal: resolution → factor.  15→2.5  30→3.0  60→5.0
    my $res    = $self->{resolution};
    my $factor = $res <= 15 ? 2.5
               : $res <= 30 ? 3.0
               : $res <= 60 ? 5.0
               :              3.0 + ($res - 30) / 15;

    # ── Paso 3: ZigZag ATR-based sobre 1m ────────────────────────────────
    # Si estamos en WindowProxy, prepend un warm-up de velas previas para
    # que el algoritmo sepa la dirección de entrada. El warm-up NO modifica
    # $data ni @atr ya calculados — corremos _zigzag_atr sobre el array
    # combinado y luego filtramos los pivotes que caen en la ventana real.
    my $base     = $md->can('base_index') ? $md->base_index : 0;
    my $warmup_n = 0;
    my $run_data = $data;    # array sobre el que se ejecuta el zigzag
    my @run_atr  = @atr;

    if ($base > 0 && $md->can('get_warmup_slice')) {
        my $wu = $md->get_warmup_slice(300);
        if ($wu && @$wu) {
            $warmup_n = scalar @$wu;
            $run_data = [@$wu, @$data];
            @run_atr  = _calc_atr_zz($run_data, 14);
        }
    }

    my ($piv_ref, $unconfirmed_ext, $unconfirmed_idx, $unconfirmed_type)
        = _zigzag_atr($run_data, \@run_atr, $factor);

    # Filtrar y reajustar: solo pivotes dentro de la ventana real
    @$piv_ref = grep { $_->{index} >= $warmup_n } @$piv_ref;
    $_->{index} -= $warmup_n for @$piv_ref;
    if (defined $unconfirmed_idx) {
        $unconfirmed_idx -= $warmup_n;
        undef $unconfirmed_idx if $unconfirmed_idx < 0;
    }

    return unless @$piv_ref;

    # ── Paso 4: etiquetas HH/HL/LH/LL ────────────────────────────────────
    $self->_label($piv_ref);

    # Todos los pivotes detectados están confirmados (tienen velas a ambos lados
    # que causaron la reversión). El extremo en formación (unconfirmed) es el
    # tramo tentativo.
    $_->{confirmed} = 1 for @$piv_ref;
    $self->{pivots} = $piv_ref;

    # ── Paso 5: segmentos ─────────────────────────────────────────────────
    my @seg;
    for (my $i = 0; $i < $#$piv_ref; $i++) {
        my ($a, $b) = ($piv_ref->[$i], $piv_ref->[$i + 1]);
        push @seg, {
            from      => { index => $a->{index}, price => $a->{price} },
            to        => { index => $b->{index}, price => $b->{price} },
            dir       => ($b->{price} >= $a->{price}) ? 'up' : 'down',
            confirmed => 1,
        };
    }
    $self->{segments} = \@seg;

    # ── Paso 6: tramo tentativo — del último pivote al extremo en formación
    # $unconfirmed_ext / $unconfirmed_idx es el extremo actual del segmento
    # en curso (máximo si subiendo, mínimo si bajando). Aún no es un pivote
    # porque no hubo suficiente reversión. En replay el cursor lo trunca al
    # precio actual, que es exactamente lo que muestra TV: la línea punteada
    # siguiendo al precio hasta que cambia de dirección.
    my $last_piv = $piv_ref->[-1];
    if (defined $unconfirmed_idx && $unconfirmed_idx > $last_piv->{index}) {
        # Usar high/low REAL de la vela del extremo en formación
        my $tent_c     = $data->[$unconfirmed_idx];
        my $tent_price = defined($tent_c)
                       ? (($unconfirmed_type eq 'high') ? $tent_c->{high} : $tent_c->{low})
                       : $unconfirmed_ext;
        $self->{tentative} = {
            from => { index => $last_piv->{index},   price => $last_piv->{price} },
            to   => { index => $unconfirmed_idx,      price => $tent_price        },
            dir  => ($unconfirmed_type eq 'high') ? 'up' : 'down',
        };
    }

    # ── Paso 7: Fibonacci del último leg (off por default, PDF pág.4) ─────
    if (@$piv_ref >= 2) {
        my ($p1, $p2) = ($piv_ref->[-2], $piv_ref->[-1]);
        my $range = $p2->{price} - $p1->{price};
        if ($range != 0) {
            my @lv;
            for my $l (0, 0.236, 0.382, 0.5, 0.618, 0.786, 1) {
                push @lv, { level => $l, price => $p2->{price} - $range * $l };
            }
            $self->{fib} = { from => $p1, to => $p2, levels => \@lv };
        }
    }

    # ── Paso 8: Windowing (Replay) — índices locales -> globales ──────────
    $self->_offset_indices($base) if $base;
}

# ─────────────────────────────────────────────────────────────────────────────
# _zigzag_atr — núcleo del zigzag ATR-based sobre la temporalidad activa.
#
# Algoritmo de reversión clásico:
#   - Mantenemos el extremo actual (máximo si tendencia alcista, mínimo si bajista).
#   - Cuando el precio revierte >= factor*ATR desde ese extremo, se confirma el
#     pivote anterior y se inicia el segmento contrario.
#   - Devuelve también el extremo en formación (tramo tentativo).
# ─────────────────────────────────────────────────────────────────────────────
sub _zigzag_atr {
    my ($data, $atr, $factor) = @_;
    my $n = scalar @$data;
    return ([], undef, undef, undef) unless $n >= 2;

    my @piv;
    # Inicialización: la primera vela determina la dirección inicial.
    # Usamos el close de la primera vela como extremo de referencia.
    # dir=+1: buscando máximo (asumimos que venimos de un mínimo).
    # dir=-1: buscando mínimo (asumimos que venimos de un máximo).
    # Elegimos la dirección según si el close de la primera vela está
    # más cerca del high o del low del rango de la primera vela.
    my $first_range = $data->[0]{high} - $data->[0]{low};
    my $init_dir = ($first_range > 0 &&
                    ($data->[0]{close} - $data->[0]{low}) > $first_range * 0.5)
                 ? 1 : -1;

    my $dir       = $init_dir;
    my $ext_price = ($dir > 0) ? $data->[0]{low} : $data->[0]{high};
    my $ext_idx   = 0;
    my $ext_type  = ($dir > 0) ? 'low' : 'high';

    for my $i (1 .. $n - 1) {
        my $a   = $atr->[$i] // ($data->[$i]{high} - $data->[$i]{low} || 1);
        my $thr = $factor * $a;
        my $hi  = $data->[$i]{high};
        my $lo  = $data->[$i]{low};

        if ($dir > 0) {
            # Buscando máximo
            if ($hi >= $ext_price) {
                $ext_price = $hi;
                $ext_idx   = $i;
                $ext_type  = 'high';
            } elsif ($ext_price - $lo >= $thr) {
                # Reversión bajista: confirmar el máximo como pivote
                # Usar el high REAL de la vela del pivote (no $ext_price que puede
                # diferir si la misma vela actualizó el extremo y causó reversión).
                # Esto garantiza que el segmento siempre toca la mecha exacta de la vela.
                my $piv_price = $data->[$ext_idx]{high};
                push @piv, { index => $ext_idx, price => $piv_price, type => 'high' }
                    unless @piv && $ext_idx == $piv[-1]{index};
                $dir       = -1;
                $ext_price = $lo;
                $ext_idx   = $i;
                $ext_type  = 'low';
            }
        } else {
            # Buscando mínimo
            if ($lo <= $ext_price) {
                $ext_price = $lo;
                $ext_idx   = $i;
                $ext_type  = 'low';
            } elsif ($hi - $ext_price >= $thr) {
                # Reversión alcista: confirmar el mínimo como pivote
                my $piv_price_l = $data->[$ext_idx]{low};
                push @piv, { index => $ext_idx, price => $piv_price_l, type => 'low' }
                    unless @piv && $ext_idx == $piv[-1]{index};
                $dir       = 1;
                $ext_price = $hi;
                $ext_idx   = $i;
                $ext_type  = 'high';
            }
        }
    }

    return (\@piv, $ext_price, $ext_idx, $ext_type);
}

# ─────────────────────────────────────────────────────────────────────────────
# _calc_atr_zz — ATR(14) de Wilder. Encapsulado aquí para no depender del
# indicador ATR externo (independencia entre indicadores).
# ─────────────────────────────────────────────────────────────────────────────
sub _calc_atr_zz {
    my ($data, $p) = @_;
    my (@atr, @tr);
    for my $i (0 .. $#$data) {
        my $c = $data->[$i];
        my $tr = $i == 0 ? $c->{high} - $c->{low}
               : do { my $pc = $data->[$i-1]{close};
                      my $a  = $c->{high} - $c->{low};
                      my $b  = abs($c->{high} - $pc);
                      my $d  = abs($c->{low}  - $pc);
                      $a > $b ? ($a > $d ? $a : $d) : ($b > $d ? $b : $d) };
        push @tr, $tr;
        if    ($i < $p - 1)  { push @atr, undef; }
        elsif ($i == $p - 1) { my $s=0; $s+=$_ for @tr; push @atr, $s/$p; }
        else                  { push @atr, (($atr[-1]*($p-1))+$tr)/$p; }
    }
    return @atr;
}

# ─────────────────────────────────────────────────────────────────────────────
# _label — asigna HH/HL/LH/LL comparando cada pivote con el previo del mismo tipo.
# ─────────────────────────────────────────────────────────────────────────────
sub _label {
    my ($self, $piv) = @_;
    my ($last_high, $last_low);
    for my $p (@$piv) {
        if ($p->{type} eq 'high') {
            $p->{label} = defined $last_high ? ($p->{price} > $last_high ? 'HH' : 'LH') : 'HH';
            $last_high = $p->{price};
        } else {
            $p->{label} = defined $last_low ? ($p->{price} < $last_low ? 'LL' : 'HL') : 'LL';
            $last_low = $p->{price};
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _project — mapea cada pivote del TF de referencia al índice 1m equivalente.
# Dentro del bucket busca la vela 1m con el extremo real (high/low) para que el
# zigzag toque el precio correcto; si el bucket cae fuera de la ventana 1m,
# usa búsqueda binaria por epoch.
# ─────────────────────────────────────────────────────────────────────────────
sub _project {
    my ($self, $piv, $closed, $ltf, $sec) = @_;
    my $n = scalar @$ltf;
    my $first_e = $ltf->[0]{epoch};
    my $last_e  = $ltf->[-1]{epoch};

    my @out;
    my $prev_idx = -1;   # para garantizar avance monótono (un zigzag no retrocede)
    for my $p (@$piv) {
        my $E = $closed->[$p->{idx}]{epoch};
        my $idx1m;
        if ($E + $sec <= $first_e || $E > $last_e) {
            $idx1m = _bsearch_epoch($ltf, $E);
        } else {
            # Primera vela 1m del bucket: primer índice con epoch >= E
            # (bsearch da epoch <= E; avanzamos si cayó en el bucket anterior,
            #  cosa que ocurre cuando faltan los primeros minutos del bucket).
            my $lo = _bsearch_epoch($ltf, $E);
            $lo++ while $lo < $n - 1 && $ltf->[$lo]{epoch} < $E;

            my $best = $lo;
            my $found = 0;
            for (my $j = $lo; $j < $n && $ltf->[$j]{epoch} < $E + $sec; $j++) {
                next if $ltf->[$j]{epoch} < $E;   # seguridad ante gaps
                if (!$found) { $best = $j; $found = 1; next; }
                if ($p->{type} eq 'high') {
                    $best = $j if $ltf->[$j]{high} > $ltf->[$best]{high};
                } else {
                    $best = $j if $ltf->[$j]{low} < $ltf->[$best]{low};
                }
            }
            $idx1m = $best;
        }

        # Monotonicidad: el zigzag debe avanzar en el tiempo. Si por gaps un
        # pivote proyecta a un índice <= al anterior, lo empujamos hacia adelante.
        $idx1m = $prev_idx + 1 if $idx1m <= $prev_idx;
        $idx1m = $n - 1 if $idx1m > $n - 1;
        $prev_idx = $idx1m;

        push @out, {
            index     => $idx1m,
            price     => $p->{price},
            label     => $p->{label},
            type      => $p->{type},
            confirmed => $p->{confirmed},
        };
    }
    return \@out;
}

# Índice local de la vela 1m con epoch <= $E más grande (clamp a [0, n-1]).
sub _bsearch_epoch {
    my ($ltf, $E) = @_;
    my ($lo, $hi) = (0, $#$ltf);
    return 0 if $E <= $ltf->[0]{epoch};
    return $hi if $E >= $ltf->[$hi]{epoch};
    while ($lo < $hi) {
        my $mid = int(($lo + $hi + 1) / 2);
        if ($ltf->[$mid]{epoch} <= $E) { $lo = $mid; } else { $hi = $mid - 1; }
    }
    return $lo;
}

# ─────────────────────────────────────────────────────────────────────────────
# _offset_indices — convierte índices 1m locales -> globales tras cálculo por
# ventana (WindowProxy en Replay). Mismo patrón que SMC_Structures/Liquidity.
# fib->{from,to} son referencias a objetos de {pivots}, ya offseteados en el
# bucle de pivots; NO se vuelven a offsetear.
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
# Consultas usadas por el Overlay (índices globales). Baratas: filtran arrays
# ya calculados por el rango visible.
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
sub fib_levels        { return $_[0]->{fib}; }

1;
