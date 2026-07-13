package Market::Indicators::SMC_Structures;
use strict;
use warnings;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Indicators::SMC_Structures
#
# Cálculo algorítmico subyacente de estructuras de Smart Money Concepts.
# Según la arquitectura del PDF (Tabla 1):
#   "Cálculo algorítmico subyacente de BOS, CHoCH, FVG, niveles de Fibonacci
#    y su integración nativa con los vectores de liquidez."
#
# PUNTO 3.1 — Swing Points y máquina de estados HH/HL/LH/LL
# PUNTO 3.2 — BOS y CHoCH internal/external
# PUNTO 3.3 — FVG (Fair Value Gap) con mitigación y desvanecimiento
#
# Piezas del cronograma 29/06 (Tabla 4 del PDF) implementadas en este archivo:
#   - Order Blocks (OB): última vela opuesta antes de un BOS
#   - Support/Resistance: niveles horizontales de reacción repetida del precio
#   - Trendlines/Channels: líneas conectando swings consecutivos del mismo tipo
#   - "Near daily candle's body & wick": proximidad del precio actual a la
#     vela diaria más reciente
#
# Sigue el mismo contrato que Market::Indicators::ATR para integrarse
# sin cambios en IndicatorManager:
#   new(%args) -> objeto
#   reset()    -> limpia el estado interno
#   values()   -> devuelve los datos calculados (arrayref)
#   calculate_all($market_data) -> recalcula todo desde cero
#
# Compatible con Market::ReplayProxy: calculate_all() solo usa
# $market_data->get_slice(0, $market_data->last_index()), exactamente
# igual que ATR.pm. Cuando se le pase un ReplayProxy en lugar del
# MarketData real, automáticamente respeta el límite del cursor de Replay
# sin ningún cambio adicional en este archivo.
# ═════════════════════════════════════════════════════════════════════════════

sub new {
    my ($class, %args) = @_;
    my $self = {
        # Profundidad de vecindad para detectar un swing INTERNO (estructura
        # menor). PDF 4.1: "valor inicial recomendado k = 3"
        depth => $args{depth} // 5,   # LuxAlgo default para 1m: 5

        # ── FIX (retroalimentación del profesor: "limpiar HH/HL/LH/LL",
        # "OB debe ser más externo", "corregir trendlines") ────────────────
        # Profundidad de vecindad para la estructura EXTERNA/MAYOR — una
        # detección de swings genuinamente más gruesa, independiente de la
        # interna, igual que LuxAlgo real (Internal Structure length=5 vs
        # Swing Structure length=50, ver ScriptSMCSTRUCTURES.txt). Antes
        # "external" era solo "el swing anterior al más reciente" del MISMO
        # set de swings k=5 — no reducía el ruido en absoluto. Ahora es una
        # segunda pasada de detección con k mucho mayor.
        major_depth => $args{major_depth} // 50,   # LuxAlgo "Swing Length" default: 50

        # Resultado del último calculate_all():
        #   swings: arrayref de hashrefs { index, price, type, label }
        #     type  => 'high' | 'low'           (Swing High o Swing Low)
        #     label => 'HH' | 'HL' | 'LH' | 'LL' (clasificación de tendencia)
        swings => [],

        # major_swings: mismo formato que swings, pero con major_depth.
        # Es la base real de: etiquetas HH/HL/LH/LL "limpias" que dibuja el
        # Overlay, BOS/CHoCH de scope 'external', Order Blocks (que ya solo
        # se generan desde 'external'), Trendlines y Fibonacci.
        major_swings => [],
        major_swings_by_index => {},

        # Índice de vela -> swing en ese índice (acceso O(1) para overlays)
        # Solo las velas que SON un swing point tienen entrada aquí.
        swings_by_index => {},

        # ── 3.2: eventos BOS y CHoCH ─────────────────────────────────────────
        # events: arrayref cronológico de hashrefs:
        #   { index, type, direction, scope, level_price, level_index }
        #     type      => 'BOS' | 'CHoCH'
        #     direction => 'up' | 'down'        (dirección de la ruptura)
        #     scope     => 'internal' | 'external'
        #     level_price => precio del swing roto
        #     level_index => índice de vela del swing roto
        events => [],

        # Índice de vela -> evento(s) confirmados en esa vela (puede haber
        # como máximo un BOS y un CHoCH en la misma vela, raro pero posible).
        events_by_index => {},

        # ── 3.3: Fair Value Gaps ──────────────────────────────────────────────
        # fvgs: arrayref cronológico de hashrefs:
        #   { index, direction, top, bottom, mitigated_at }
        #     index        => índice de la vela "central" (i) que formó el gap
        #     direction    => 'up' (alcista) | 'down' (bajista)
        #     top, bottom  => límites de precio del gap (top siempre > bottom)
        #     mitigated_at => índice de la vela donde el precio volvió a entrar
        #                     al rango del gap, o undef si sigue activo
        fvgs => [],

        # Índice de la vela de FORMACIÓN -> fvg (acceso O(1) para overlays)
        fvgs_by_index => {},

        # ── Order Blocks ────────────────────────────────────────────────────
        # order_blocks: arrayref cronológico de hashrefs:
        #   { index, direction, top, bottom, bos_index, mitigated_at }
        #     index        => índice de la vela OB (última opuesta antes del BOS)
        #     direction    => 'bullish' | 'bearish'
        #     top, bottom  => rango de precio del OB (high/low de esa vela)
        #     bos_index    => índice del BOS que originó este OB
        #     mitigated_at => índice donde el precio volvió a tocar el OB, o undef
        order_blocks => [],
        order_blocks_by_index => {},

        # ── Support / Resistance ────────────────────────────────────────────
        # support_resistance: arrayref de hashrefs:
        #   { price, kind, touches, first_index, last_index }
        #     kind    => 'support' | 'resistance'
        #     touches => arrayref de índices donde el precio reaccionó en este nivel
        support_resistance => [],

        # ── Trendlines / Channels ───────────────────────────────────────────
        # trendlines: arrayref de hashrefs:
        #   { kind, point1, point2, slope, intercept }
        #     kind   => 'support' (conecta Swing Lows) | 'resistance' (Swing Highs)
        #     point1, point2 => { index, price } — los dos swings que definen la línea
        #     slope, intercept => y = slope*x + intercept, para extender la línea
        trendlines => [],

        # ── Near daily candle's body & wick ─────────────────────────────────
        # daily_proximity: hashref con la referencia de la vela diaria más
        # reciente y la posición del precio actual respecto a su cuerpo/mecha.
        daily_proximity => undef,

        # ── Fibonacci Retracement levels (Fase 3) ───────────────────────────
        # fibonacci: arrayref cronológico de hashrefs, uno por cada "pierna"
        # entre dos swings consecutivos (ya alternados high/low por el
        # zigzag de calculate_all):
        #   { from => {index,price}, to => {index,price}, direction,
        #     levels => [ {ratio, price}, ... ] }
        #     from/to    => los dos swings que delimitan la pierna (from es
        #                   el más antiguo cronológicamente, to el más nuevo)
        #     direction  => 'up' (to > from) | 'down' (to < from)
        #     levels     => niveles estándar 0/0.236/0.382/0.5/0.618/0.786/1,
        #                   anclados con ratio=0 en el extremo MÁS RECIENTE
        #                   (to) y ratio=1 en el extremo anterior (from) —
        #                   convención estándar de retroceso.
        fibonacci => [],
    };
    bless $self, $class;
    return $self;
}


# ─────────────────────────────────────────────────────────────────────────────
# _offset_indices — suma $base a todos los índices (locales -> globales) tras un
# cálculo por ventana (Market::WindowProxy). NO toca daily_proximity->{daily_index}
# porque ese es un índice del array 'D', no del 1m. Reconstruye los hashes *_by_index.
# ─────────────────────────────────────────────────────────────────────────────
sub _offset_indices {
    my ($self, $base) = @_;
    return if !$base;

    for my $sw (@{ $self->{swings} }) { $sw->{index} += $base; }
    for my $sw (@{ $self->{major_swings} }) { $sw->{index} += $base; }
    for my $ev (@{ $self->{events} }) {
        $ev->{index}       += $base;
        $ev->{level_index} += $base if defined $ev->{level_index};
    }
    for my $f (@{ $self->{fvgs} }) {
        $f->{index}        += $base;
        $f->{mitigated_at} += $base if defined $f->{mitigated_at};
    }
    for my $ob (@{ $self->{order_blocks} }) {
        $ob->{index}        += $base;
        $ob->{bos_index}    += $base if defined $ob->{bos_index};
        $ob->{mitigated_at} += $base if defined $ob->{mitigated_at};
    }
    for my $lvl (@{ $self->{support_resistance} }) {
        $lvl->{first_index} += $base;
        $lvl->{last_index}  += $base;
        $_ += $base for @{ $lvl->{touches} };
    }
    for my $tl (@{ $self->{trendlines} }) {
        $tl->{point1}{index} += $base;
        $tl->{point2}{index} += $base;
        # slope/intercept se recalculan en índices globales:
        my ($p1,$p2) = ($tl->{point1}, $tl->{point2});
        my $dx = $p2->{index} - $p1->{index};
        if ($dx != 0) {
            $tl->{slope}     = ($p2->{price} - $p1->{price}) / $dx;
            $tl->{intercept} = $p1->{price} - $tl->{slope} * $p1->{index};
        }
    }
    for my $fib (@{ $self->{fibonacci} }) {
        $fib->{from}{index} += $base;
        $fib->{to}{index}   += $base;
    }

    # Reconstruir los índices O(1) por vela
    $self->{swings_by_index} = {};
    $self->{swings_by_index}{ $_->{index} } = $_ for @{ $self->{swings} };
    $self->{major_swings_by_index} = {};
    $self->{major_swings_by_index}{ $_->{index} } = $_ for @{ $self->{major_swings} };
    $self->{events_by_index} = {};
    for my $ev (@{ $self->{events} }) {
        my $k = $ev->{index};
        if (exists $self->{events_by_index}{$k}) {
            my $e = $self->{events_by_index}{$k};
            $self->{events_by_index}{$k} = ref($e) eq 'ARRAY' ? [@$e,$ev] : [$e,$ev];
        } else { $self->{events_by_index}{$k} = $ev; }
    }
    $self->{fvgs_by_index} = {};
    $self->{fvgs_by_index}{ $_->{index} } = $_ for @{ $self->{fvgs} };
    $self->{order_blocks_by_index} = {};
    $self->{order_blocks_by_index}{ $_->{index} } = $_ for @{ $self->{order_blocks} };
}


sub reset {
    my ($self) = @_;
    $self->{swings} = [];
    $self->{swings_by_index} = {};
    $self->{major_swings} = [];
    $self->{major_swings_by_index} = {};
    $self->{events} = [];
    $self->{events_by_index} = {};
    $self->{fvgs} = [];
    $self->{fvgs_by_index} = {};
    $self->{order_blocks} = [];
    $self->{order_blocks_by_index} = {};
    $self->{support_resistance} = [];
    $self->{trendlines} = [];
    $self->{daily_proximity} = undef;
    $self->{fibonacci} = [];
    # NOTA: reset() NO toca _fvg_global / _fvg_last_global_index a propósito
    # — ese es el estado persistente que hace posible la actualización
    # incremental de FVG (spec del profesor: "no debe recalcular todo el
    # historial... únicamente debe analizar la nueva vela cerrada"). reset()
    # se llama en CADA calculate_all() (todos los demás indicadores sí se
    # recalculan siempre desde cero), así que si _fvg_global se limpiara
    # aquí, la incrementalidad de FVG quedaría anulada en la práctica.
}

# ─────────────────────────────────────────────────────────────────────────────
# invalidate_fvg_cache — fuerza un recálculo COMPLETO de FVG en la próxima
# llamada a calculate_all(). Necesario en los momentos donde el "índice
# global" deja de tener el mismo significado (cambio de temporalidad: el
# índice 500 en 1m no es la misma vela que el índice 500 en 15m), donde la
# heurística automática de _sync_fvg() (comparar contra el último índice
# procesado) no es fiable. Debe llamarse explícitamente desde ChartEngine
# justo después de cambiar de TF.
# ─────────────────────────────────────────────────────────────────────────────
sub invalidate_fvg_cache {
    my ($self) = @_;
    $self->{_fvg_global} = [];
    $self->{_fvg_last_global_index} = undef;
}

# values() devuelve el arrayref de swings — es el contrato esperado por
# IndicatorManager::get('SMC_Structures') y slice_array().
sub values {
    my ($self) = @_;
    return $self->{swings};
}

# Acceso directo: swing en un índice de vela específico, o undef si esa
# vela no es un swing point. Usado por el Overlay para no iterar todo el
# array de swings en cada redibujo.
sub swing_at {
    my ($self, $index) = @_;
    return $self->{swings_by_index}{$index};
}

# values_major_swings() / major_swing_at() — equivalentes a values()/swing_at()
# pero para la estructura EXTERNA (major_swings, k=major_depth). Es la fuente
# que usa el Overlay para dibujar las etiquetas HH/HL/LH/LL "limpias".
sub values_major_swings {
    my ($self) = @_;
    return $self->{major_swings};
}

sub major_swing_at {
    my ($self, $index) = @_;
    return $self->{major_swings_by_index}{$index};
}

# Devuelve el evento (BOS/CHoCH) confirmado en una vela específica, o undef.
# Si hay más de uno en la misma vela (raro), devuelve un arrayref.
sub events_at {
    my ($self, $index) = @_;
    return $self->{events_by_index}{$index};
}

# values_events() devuelve el arrayref cronológico de todos los eventos.
sub values_events {
    my ($self) = @_;
    return $self->{events};
}

# Devuelve el FVG formado en una vela específica (índice de formación), o undef.
sub fvg_at {
    my ($self, $index) = @_;
    return $self->{fvgs_by_index}{$index};
}

# values_fvgs() devuelve el arrayref cronológico de todos los FVG.
sub values_fvgs {
    my ($self) = @_;
    return $self->{fvgs};
}

# Devuelve el Order Block formado en una vela específica, o undef.
sub order_block_at {
    my ($self, $index) = @_;
    return $self->{order_blocks_by_index}{$index};
}

sub values_order_blocks {
    my ($self) = @_;
    return $self->{order_blocks};
}

sub values_support_resistance {
    my ($self) = @_;
    return $self->{support_resistance};
}

sub values_trendlines {
    my ($self) = @_;
    return $self->{trendlines};
}

sub daily_proximity {
    my ($self) = @_;
    return $self->{daily_proximity};
}

sub values_fibonacci {
    my ($self) = @_;
    return $self->{fibonacci};
}

# ─────────────────────────────────────────────────────────────────────────────
# _detect_swings_at_depth — Fases A+B (candidatos + zigzag con alternancia
# estricta), parametrizado por profundidad $k. Reutilizado para generar tanto
# la estructura interna (k pequeño) como la externa/mayor (k grande) —
# exactamente el mismo algoritmo, solo cambia la vecindad de comparación.
# Devuelve el zigzag SIN etiquetar (sin HH/HL/LH/LL todavía).
# ─────────────────────────────────────────────────────────────────────────────
sub _detect_swings_at_depth {
    my ($self, $run_data, $rn, $k) = @_;

    # Fase A: candidatos extremo local
    my @cand;
    for (my $i = $k; $i <= $rn - 1 - $k; $i++) {
        my $c = $run_data->[$i];

        my $is_high = 1;
        for my $j (($i - $k) .. ($i - 1), ($i + 1) .. ($i + $k)) {
            if ($run_data->[$j]{high} >= $c->{high}) { $is_high = 0; last; }
        }
        if ($is_high) {
            push @cand, { index => $i, price => $c->{high}, type => 'high' };
            next;
        }

        my $is_low = 1;
        for my $j (($i - $k) .. ($i - 1), ($i + 1) .. ($i + $k)) {
            if ($run_data->[$j]{low} <= $c->{low}) { $is_low = 0; last; }
        }
        if ($is_low) {
            push @cand, { index => $i, price => $c->{low}, type => 'low' };
        }
    }

    # Fase B: zigzag con alternancia estricta — en rachas del mismo tipo
    # conservar solo el extremo más pronunciado. Produce high/low/high/...
    my @zz;
    for my $c (@cand) {
        if (!@zz) { push @zz, $c; next; }
        my $last = $zz[-1];
        if ($last->{type} eq $c->{type}) {
            if ($c->{type} eq 'high') {
                $zz[-1] = $c if $c->{price} > $last->{price};
            } else {
                $zz[-1] = $c if $c->{price} < $last->{price};
            }
        } else {
            push @zz, $c;
        }
    }
    return \@zz;
}

# ─────────────────────────────────────────────────────────────────────────────
# _label_and_store_swings — Fase C: etiqueta HH/HL/LH/LL comparando cada
# swing con el anterior del MISMO array de zigzag (self-contenido: la
# estructura interna y la externa mantienen su propia clasificación de
# tendencia, no se mezclan entre sí). Escribe en $target_arr/$target_idx.
# ─────────────────────────────────────────────────────────────────────────────
sub _label_and_store_swings {
    my ($self, $zz, $target_arr, $target_idx) = @_;
    my $last_high;
    my $last_low;

    for my $sw (@$zz) {
        my $label;
        if ($sw->{type} eq 'high') {
            $label = defined $last_high
                   ? ($sw->{price} > $last_high->{price} ? 'HH' : 'LH')
                   : 'HH';
            $last_high = $sw;
        } else {
            $label = defined $last_low
                   ? ($sw->{price} > $last_low->{price} ? 'HL' : 'LL')
                   : 'LL';
            $last_low = $sw;
        }

        my $entry = {
            index => $sw->{index},
            price => $sw->{price},
            type  => $sw->{type},
            label => $label,
        };
        push @$target_arr, $entry;
        $target_idx->{ $sw->{index} } = $entry;
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# calculate_all — recalcula todos los Swing Points y su clasificación
# HH/HL/LH/LL desde cero, sobre los datos visibles en $market_data.
#
# IMPORTANTE: usa get_slice(0, last_index()) igual que ATR.pm. Esto es lo
# que permite que el ReplayProxy (Fase 2) limite automáticamente los datos
# sin que este archivo necesite saber nada sobre el modo Replay.
# ─────────────────────────────────────────────────────────────────────────────
sub calculate_all {
    my ($self, $market_data) = @_;
    $self->reset();

    my $data = $market_data->get_slice(0, $market_data->last_index());
    my $k = $self->{depth};
    my $n = scalar @$data;

    return if $n < (2 * $k + 1);   # no hay suficientes velas para un swing

    # ── FIX (hallazgo 4a): warm-up de contexto para WindowProxy ─────────────
    #
    # Cuando $market_data es un WindowProxy (Replay), $data solo contiene la
    # ventana visible (ej. últimas 4000 velas). Antes, TODO el cálculo corría
    # exclusivamente sobre esa ventana, así que el estado de tendencia
    # ($last_high/$last_low en Fase C, y $trend{internal/external} en
    # _detect_bos_choch) se REINICIABA en cada llamada — el primer swing high
    # de la ventana siempre salía 'HH', el primer low siempre 'LL', y el
    # primer BOS/CHoCH del borde de la ventana siempre se clasificaba como
    # BOS (trend='unknown'), sin importar el contexto real anterior.
    #
    # Fix: si hay base_index() > 0 (estamos en una ventana), pedimos velas
    # de warm-up ANTES del inicio de la ventana (mismo patrón que ya usa
    # ZigZagMTF::calculate_all) y corremos TODO el cálculo sobre el array
    # combinado (warmup + ventana). Al final, _trim_warmup() descarta lo que
    # ocurrió enteramente en el warm-up y reindexa lo demás de vuelta al
    # espacio local de la ventana — el resultado final tiene exactamente el
    # mismo "shape" que antes, pero con la clasificación de tendencia correcta
    # heredada del historial real, no reiniciada en el borde de la ventana.
    my $base = (ref($market_data) && $market_data->can('base_index'))
             ? $market_data->base_index : 0;
    my $warmup_n = 0;
    my $run_data = $data;
    if ($base > 0 && $market_data->can('get_warmup_slice')) {
        my $WARMUP = $self->{warmup_candles} // 500;
        my $wu = $market_data->get_warmup_slice($WARMUP);
        if ($wu && @$wu) {
            $warmup_n = scalar @$wu;
            $run_data = [ @$wu, @$data ];
        }
    }
    my $rn = scalar @$run_data;

    # ── Paso 1 + 2: Swing Points con alternancia forzada (estilo LuxAlgo) ──────
    #
    # ── FIX (retroalimentación del profesor: "limpiar HH/HL/LH/LL", "OB debe
    # ser más externo", "corregir trendlines") ─────────────────────────────
    # Se corre la MISMA detección dos veces con profundidades distintas,
    # igual que LuxAlgo real (Internal Structure k=5, Swing Structure k=50):
    #   - {swings}       (k = depth,       interno — estructura menor)
    #   - {major_swings} (k = major_depth, externo — estructura mayor)
    # Antes solo existía una detección (k=5) y "external" era un truco
    # ("el swing anterior al más reciente" del MISMO set) — no reducía el
    # ruido. Ahora major_swings es una segunda pasada independiente sobre
    # una vecindad mucho más ancha, produciendo ~10x menos puntos — la base
    # real de las etiquetas HH/HL/LH/LL "limpias", BOS/CHoCH externo, Order
    # Blocks, Trendlines y Fibonacci.
    my @zz_internal = @{ $self->_detect_swings_at_depth($run_data, $rn, $k) };
    $self->_label_and_store_swings(\@zz_internal, $self->{swings}, $self->{swings_by_index});

    my $mk = $self->{major_depth};
    if ($rn >= (2 * $mk + 1)) {
        my @zz_major = @{ $self->_detect_swings_at_depth($run_data, $rn, $mk) };
        $self->_label_and_store_swings(\@zz_major, $self->{major_swings}, $self->{major_swings_by_index});
    }

    # ── Paso 3: detección de BOS y CHoCH (sobre $run_data: el estado de
    #    tendencia interno/externo también hereda contexto del warm-up).
    #    Internal usa {swings} (k=5), external usa {major_swings} (k=50) —
    #    dos pasadas independientes, cada una con su propio pivote/tendencia.
    $self->_detect_bos_choch($run_data);

    # ── Paso 4: Fair Value Gaps — INCREMENTAL (spec del profesor: "no debe
    #    recalcular todo el historial... únicamente debe analizar la nueva
    #    vela cerrada"). Ver _sync_fvg() para el detalle del mecanismo.
    $self->_sync_fvg($market_data, $run_data, $warmup_n, $base);

    # ── Paso 5: Order Blocks (última vela opuesta antes de cada BOS externo) ─
    $self->_detect_order_blocks($run_data);

    # ── Paso 6: Support / Resistance (niveles con reacción repetida) ────────
    $self->_detect_support_resistance($run_data);

    # ── Paso 7: Trendlines / Channels — ahora sobre major_swings (estructura
    #    externa), no sobre el set denso interno. Reduce ~10x el número de
    #    líneas y las ancla a swings realmente significativos.
    $self->_detect_trendlines();

    # ── Paso 7.5: Fibonacci Retracement levels — también sobre major_swings,
    #    mismo criterio que Trendlines (mismo tipo de ruido, misma solución).
    $self->_detect_fibonacci();

    # ── Paso 8: proximidad a la vela diaria más reciente ─────────────────────
    # Usa $data (la ventana real, no $run_data) — "vela actual" siempre debe
    # ser la última visible, que es la misma en ambos arrays de todos modos.
    $self->_calc_daily_proximity($market_data, $data);

    # ── Recortar el warm-up: descartar lo que ocurrió enteramente antes de
    #    la ventana real y reindexar de vuelta al espacio LOCAL de la
    #    ventana (mismo espacio que tenían los índices al calcular
    #    directamente sobre $data, antes de este fix).
    $self->_trim_warmup($warmup_n) if $warmup_n;

    # Ordenar trendlines por point1.index para habilitar búsqueda binaria
    @{ $self->{trendlines} } = sort { $a->{point1}{index} <=> $b->{point1}{index} }
                                @{ $self->{trendlines} };

    # Índice de buckets para FVG y OB (O(1) lookup en draw)
    $self->_build_bucket_index();

    # Windowing (Market::WindowProxy): convertir índices locales -> globales.
    $self->_offset_indices($base) if $base;
}

# ─────────────────────────────────────────────────────────────────────────────
# _trim_warmup — descarta las entradas cuyo evento "ocurrió" enteramente
# dentro del warm-up (antes del inicio real de la ventana) y reindexa todo
# lo demás restando $warmup_n, para volver al espacio de índices LOCAL de
# la ventana (el mismo que tenían antes de este fix, cuando se calculaba
# directo sobre $data sin warm-up).
#
# Reutiliza _offset_indices() para el desplazamiento (funciona con números
# negativos igual que con positivos) y luego filtra por el campo "índice
# primario" de cada colección. Los índices de REFERENCIA que queden
# negativos tras el desplazamiento (ej. el level_index de un BOS cuyo pivote
# roto vive en el warm-up, o un touch de Support/Resistance anterior a la
# ventana) se dejan tal cual a propósito: el _offset_indices($base) final
# del llamador los vuelve a convertir en índices GLOBALES reales y válidos
# (apuntan a velas de historial real, solo que fuera de la ventana actual).
# ─────────────────────────────────────────────────────────────────────────────
sub _trim_warmup {
    my ($self, $warmup_n) = @_;
    return unless $warmup_n;

    $self->_offset_indices(-$warmup_n);

    @{ $self->{swings} }             = grep { $_->{index} >= 0 } @{ $self->{swings} };
    @{ $self->{major_swings} }       = grep { $_->{index} >= 0 } @{ $self->{major_swings} };
    @{ $self->{events} }             = grep { $_->{index} >= 0 } @{ $self->{events} };
    @{ $self->{fvgs} }               = grep { $_->{index} >= 0 } @{ $self->{fvgs} };
    @{ $self->{order_blocks} }       = grep { $_->{index} >= 0 } @{ $self->{order_blocks} };
    @{ $self->{support_resistance} } = grep { $_->{last_index} >= 0 } @{ $self->{support_resistance} };
    @{ $self->{trendlines} }         = grep { $_->{point2}{index} >= 0 } @{ $self->{trendlines} };
    @{ $self->{fibonacci} }          = grep { $_->{to}{index} >= 0 } @{ $self->{fibonacci} };

    # Reconstruir los índices O(1) por vela con los arrays ya filtrados
    # (los que había armado _offset_indices arriba incluían lo descartado).
    $self->{swings_by_index} = {};
    $self->{swings_by_index}{ $_->{index} } = $_ for @{ $self->{swings} };

    $self->{major_swings_by_index} = {};
    $self->{major_swings_by_index}{ $_->{index} } = $_ for @{ $self->{major_swings} };

    $self->{events_by_index} = {};
    for my $ev (@{ $self->{events} }) {
        my $idx = $ev->{index};
        if (exists $self->{events_by_index}{$idx}) {
            my $e = $self->{events_by_index}{$idx};
            $self->{events_by_index}{$idx} = ref($e) eq 'ARRAY' ? [@$e, $ev] : [$e, $ev];
        } else { $self->{events_by_index}{$idx} = $ev; }
    }

    $self->{fvgs_by_index} = {};
    $self->{fvgs_by_index}{ $_->{index} } = $_ for @{ $self->{fvgs} };

    $self->{order_blocks_by_index} = {};
    $self->{order_blocks_by_index}{ $_->{index} } = $_ for @{ $self->{order_blocks} };
}

# ─────────────────────────────────────────────────────────────────────────────
# _build_bucket_index — asigna cada FVG y OB a todos los buckets que solapa.
# Un FVG/OB vive desde {index} hasta {mitigated_at} (o ∞). Se añade al bucket
# de su {index} y al de su fin, para que fvgs_in_range los encuentre aunque
# el rango visible caiga en el medio de su "vida".
# ─────────────────────────────────────────────────────────────────────────────
sub _build_bucket_index {
    my ($self) = @_;
    my $B = 1000;
    $self->{_bucket_size} = $B;

    my (%fvg_idx, %ob_idx);
    for my $fvg (@{ $self->{fvgs} }) {
        my $b0 = int($fvg->{index} / $B);
        my $b1 = defined $fvg->{mitigated_at}
               ? int($fvg->{mitigated_at} / $B)
               : $b0 + 200;   # activos: cubrimos 200k velas hacia adelante
        $b1 = $b0 + 200 if $b1 - $b0 > 200;
        push @{ $fvg_idx{$_} }, $fvg for $b0 .. $b1;
    }
    for my $ob (@{ $self->{order_blocks} }) {
        my $b0 = int($ob->{index} / $B);
        my $b1 = defined $ob->{mitigated_at}
               ? int($ob->{mitigated_at} / $B)
               : $b0 + 200;
        $b1 = $b0 + 200 if $b1 - $b0 > 200;
        push @{ $ob_idx{$_} }, $ob for $b0 .. $b1;
    }
    $self->{_fvg_bucket_idx} = \%fvg_idx;
    $self->{_ob_bucket_idx}  = \%ob_idx;
}

# ─────────────────────────────────────────────────────────────────────────────
# _detect_bos_choch — Punto 3.2
#
# Recorre las velas cronológicamente. En cada vela comprueba si el CUERPO
# rompe el último Swing High o Swing Low relevante. La clasificación sigue
# la relación estructural del PDF (sección 5):
#
#   BOS (Break of Structure)   — confirma la tendencia vigente:
#     · Alcista: cuerpo > último HH  (la estructura de máximos sigue creciendo)
#     · Bajista: cuerpo < último LL  (la estructura de mínimos sigue cayendo)
#
#   CHoCH (Change of Character) — señala una reversión de tendencia:
#     · Alcista a bajista: cuerpo < último HL (rompe el último mínimo creciente)
#     · Bajista a alcista: cuerpo > último LH (rompe el último máximo decreciente)
#
# ── FIX (retroalimentación del profesor: "OB debe ser más externo",
# "limpiar HH/HL/LH/LL", "corregir trendlines") ─────────────────────────────
# ANTES: 'internal' y 'external' venían del MISMO set de swings k=5 — external
# era literalmente "el swing anterior al más reciente" (un truco de desfase,
# no una estructura distinta). Eso no reducía nada de ruido: verificado que
# 419 de 905 Order Blocks salían de "external" con ese esquema, casi tan
# denso como internal.
#
# AHORA: 'internal' y 'external' son dos DETECCIONES INDEPENDIENTES:
#   · internal -> corre sobre {swings}       (k = depth,       ej. 5)
#   · external -> corre sobre {major_swings} (k = major_depth, ej. 50)
# Igual que LuxAlgo real (Internal Structure vs Swing Structure, dos pivotes
# de longitud distinta — ver ScriptSMCSTRUCTURES.txt). Cada pasada mantiene
# su propio pivote activo y su propia tendencia — no se mezclan entre sí.
#
# Una vez resuelto un evento, el nivel roto se considera "consumido" y no
# vuelve a generar el mismo tipo de evento hasta que aparezca un nuevo swing
# del tipo correspondiente — así se evita spamear el mismo BOS en cada vela
# que sigue cerrando por encima de un nivel ya roto.
# ─────────────────────────────────────────────────────────────────────────────
sub _detect_bos_choch {
    my ($self, $data) = @_;

    $self->_detect_bos_choch_pass($data, $self->{swings},       'internal');
    $self->_detect_bos_choch_pass($data, $self->{major_swings}, 'external');

    # Las dos pasadas se calcularon por separado (internal primero, external
    # después) — reordenar cronológicamente y reconstruir events_by_index
    # para que events_in_range() (búsqueda binaria) siga funcionando.
    @{ $self->{events} } = sort { $a->{index} <=> $b->{index} } @{ $self->{events} };
    $self->{events_by_index} = {};
    for my $ev (@{ $self->{events} }) {
        my $k = $ev->{index};
        if (exists $self->{events_by_index}{$k}) {
            my $e = $self->{events_by_index}{$k};
            $self->{events_by_index}{$k} = ref($e) eq 'ARRAY' ? [@$e, $ev] : [$e, $ev];
        } else { $self->{events_by_index}{$k} = $ev; }
    }
}

# _detect_bos_choch_pass — UNA pasada de detección BOS/CHoCH sobre UN solo
# set de swings ($swings_arr), con su propio pivote y tendencia (sin
# lentes/desfases). Genera eventos con scope=$scope.
sub _detect_bos_choch_pass {
    my ($self, $data, $swings_arr, $scope) = @_;

    my @highs = grep { $_->{type} eq 'high' } @$swings_arr;
    my @lows  = grep { $_->{type} eq 'low'  } @$swings_arr;

    my $hi_ptr = 0;
    my $lo_ptr = 0;
    my ($ph, $pl);     # pivote activo high/low de ESTE scope únicamente
    my $trend = 'unknown';
    my ($prev_body_high, $prev_body_low);

    for (my $i = 0; $i < scalar(@$data); $i++) {

        while ($hi_ptr <= $#highs && $highs[$hi_ptr]{index} <= $i) {
            $ph = { price => $highs[$hi_ptr]{price}, index => $highs[$hi_ptr]{index}, crossed => 0 };
            $hi_ptr++;
        }
        while ($lo_ptr <= $#lows && $lows[$lo_ptr]{index} <= $i) {
            $pl = { price => $lows[$lo_ptr]{price}, index => $lows[$lo_ptr]{index}, crossed => 0 };
            $lo_ptr++;
        }

        # Cuerpo de la vela actual (mechas excluidas) — criterio pedido:
        # "el BOS debe romper con el cuerpo".
        my $body_high = $data->[$i]{close} > $data->[$i]{open}
                      ? $data->[$i]{close} : $data->[$i]{open};
        my $body_low  = $data->[$i]{close} < $data->[$i]{open}
                      ? $data->[$i]{close} : $data->[$i]{open};

        # Cruce alcista real: el cuerpo anterior NO rompía el nivel, el
        # cuerpo actual sí (evita "romper" un nivel que ya venía roto).
        my $crossed_up = defined($ph) && !$ph->{crossed}
            && (!defined($prev_body_high) || $prev_body_high <= $ph->{price})
            && $body_high > $ph->{price};

        my $crossed_down = defined($pl) && !$pl->{crossed}
            && (!defined($prev_body_low) || $prev_body_low >= $pl->{price})
            && $body_low < $pl->{price};

        if ($crossed_up) {
            my $tag = ($trend eq 'down') ? 'CHoCH' : 'BOS';
            $self->_push_event($i, $tag, 'up', $scope, $ph->{price}, $ph->{index});
            $ph->{crossed} = 1;
            $trend = 'up';
        }

        if ($crossed_down) {
            my $tag = ($trend eq 'up') ? 'CHoCH' : 'BOS';
            $self->_push_event($i, $tag, 'down', $scope, $pl->{price}, $pl->{index});
            $pl->{crossed} = 1;
            $trend = 'down';
        }

        $prev_body_high = $body_high;
        $prev_body_low  = $body_low;
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# FVG (Fair Value Gap) — sistema completo
#
# Patrón estándar ICT/TradingView de 3 velas: un FVG alcista existe cuando
# High[2] < Low[0] (usando la convención índice-0=vela más nueva del spec
# del profesor), o en términos de este código: el máximo de la vela más
# antigua del trío ($prev) es menor que el mínimo de la más nueva ($next).
# Bajista: análogo invertido. La detección SOLO puede confirmarse cuando
# la tercera vela del trío ya cerró — en este motor eso ya está garantizado
# porque el array de velas de la TF activa nunca contiene una vela en
# formación (ver ChartEngine::_replay_limit / MarketData::build_tf_candles).
#
# ── Cada FVG es un objeto independiente (spec del profesor) ────────────────
# Campos: direction, top/bottom (límites VIGENTES, pueden recortarse por
# mitigación parcial), orig_top/orig_bottom (límites originales de
# formación), state ('active'|'mitigated', explícito), created_at /
# created_epoch (fecha real de la vela de origen), g_index (vela de origen,
# en índice GLOBAL) y g_mitigated_at (vela donde se mitigó del todo, o
# undef). Múltiples FVG conviven en @{ $self->{_fvg_global} } sin
# interferirse entre sí — cada uno es un hashref independiente.
#
# ── Mitigación parcial vs completa (spec del profesor) ──────────────────────
# _apply_fvg_mitigation() compara cada vela nueva contra la zona VIGENTE:
#   - Sin solape: no pasa nada.
#   - Cobertura total en una vela: mitigación completa (state='mitigated').
#   - Invade solo un borde: ese borde se recorta, el FVG sigue 'active' y
#     más chico (igual que el indicador nativo de TradingView) — solo pasa
#     a 'mitigated' cuando el remanente se consume por completo.
#   - Toque aislado sin romper ningún borde (gap directo al centro, caso
#     raro): se ignora, no hay borde no-ambiguo que recortar.
#
# ── Incrementalidad (spec del profesor: "no debe recalcular todo el
# historial... únicamente debe analizar la nueva vela cerrada") ────────────
# _sync_fvg() es el único punto de entrada, llamado desde calculate_all()
# en cada paso (incluido cada step de Replay). Mantiene el estado en
# $self->{_fvg_global}, indexado en términos GLOBALES (no se ve afectado
# por el desplazamiento de la ventana de WindowProxy) y persistente entre
# llamadas — reset() NO lo toca a propósito (ver comentario en reset()).
#
#   - Si el cursor avanzó desde la última llamada (caso normal de Replay:
#     step, play, fast-forward): SOLO se procesan las velas nuevas —
#     _fvg_incremental_scan() revisa mitigación de los FVG activos
#     existentes contra las velas nuevas, y busca FVG nuevos únicamente en
#     los tríos cuyo centro cae en el tramo recién cerrado. Costo O(velas
#     nuevas + FVG activos), NO O(todo el historial).
#   - Si el cursor retrocedió (replay rebobinado) o no hay estado previo
#     (primera vez, o justo después de invalidate_fvg_cache()): se hace un
#     _fvg_full_scan() del array disponible — el mismo costo que antes,
#     pero solo en este caso excepcional, no en cada step.
#   - invalidate_fvg_cache() se llama explícitamente desde ChartEngine al
#     cambiar de temporalidad, porque ahí el "índice global" dejaría de
#     significar la misma vela y la heurística de avance no es fiable.
#
# Al final, _sync_fvg() publica el resultado en el formato LOCAL clásico
# ($self->{fvgs}, $self->{fvgs_by_index}) para que el resto del pipeline
# (bucket index, _offset_indices($base) final de calculate_all, overlay)
# no necesite saber nada de este mecanismo interno.
# ─────────────────────────────────────────────────────────────────────────────
sub _sync_fvg {
    my ($self, $market_data, $run_data, $warmup_n, $base) = @_;
    my $rn = scalar @$run_data;

    $self->{fvgs} = [];
    $self->{fvgs_by_index} = {};
    return if $rn < 3;

    my $run_base_global = $base - $warmup_n;    # índice GLOBAL de run_data[0]
    my $cur_global_last  = $run_base_global + $rn - 1;
    my $prev_last        = $self->{_fvg_last_global_index};

    my $need_full_scan =
           !defined($prev_last)
        || $cur_global_last < $prev_last                 # replay rebobinado
        || ($prev_last - $run_base_global) >= $rn;        # fuera del array actual (defensivo)

    if ($need_full_scan) {
        $self->_fvg_full_scan($run_data, $run_base_global);
    } else {
        $self->_fvg_incremental_scan($run_data, $run_base_global, $prev_last, $cur_global_last);
    }
    $self->{_fvg_last_global_index} = $cur_global_last;

    # Publicar en espacio LOCAL de ventana (index = g_index - base), igual
    # convención que _detect_fvg() producía antes de este cambio — el
    # _offset_indices($base) final de calculate_all() se encarga de
    # convertir a GLOBAL una sola vez, igual que para todos los demás tipos.
    my $win_end_global = $base + ($rn - $warmup_n) - 1;   # = base + n - 1
    for my $fvg (@{ $self->{_fvg_global} }) {
        next if $fvg->{g_index} > $win_end_global;
        next if $fvg->{g_index} < $base;   # nacido en warmup: fuera de la ventana publicada
        my $local_index = $fvg->{g_index} - $base;
        my $local = {
            index        => $local_index,
            direction    => $fvg->{direction},
            top          => $fvg->{top},
            bottom       => $fvg->{bottom},
            orig_top     => $fvg->{orig_top},
            orig_bottom  => $fvg->{orig_bottom},
            state        => $fvg->{state},
            created_at   => $fvg->{created_at},
            created_epoch=> $fvg->{created_epoch},
            mitigated_at => defined $fvg->{g_mitigated_at} ? ($fvg->{g_mitigated_at} - $base) : undef,
        };
        push @{ $self->{fvgs} }, $local;
        $self->{fvgs_by_index}{$local_index} = $local;
    }
    @{ $self->{fvgs} } = sort { $a->{index} <=> $b->{index} } @{ $self->{fvgs} };
}

# _fvg_full_scan — recorre TODO $run_data (caso excepcional: primera vez,
# replay rebobinado, o justo después de invalidate_fvg_cache()). Reconstruye
# $self->{_fvg_global} desde cero, en índices GLOBALES.
sub _fvg_full_scan {
    my ($self, $run_data, $run_base_global) = @_;
    $self->{_fvg_global} = [];

    my $rn = scalar @$run_data;
    return if $rn < 3;

    my $atr_arr   = $self->_calc_atr_simple($run_data, 14);
    my $min_ratio = $self->{fvg_min_atr_ratio} // 0.15;

    for (my $i = 1; $i < $rn - 1; $i++) {
        my $fvg = $self->_try_form_fvg($run_data, $i, $atr_arr, $min_ratio, $run_base_global);
        next unless $fvg;
        for (my $j = $i + 2; $j < $rn; $j++) {
            last if $self->_apply_fvg_mitigation($fvg, $run_data->[$j], $j + $run_base_global);
        }
        push @{ $self->{_fvg_global} }, $fvg;
    }
}

# _fvg_incremental_scan — SOLO procesa lo nuevo desde $prev_last_global:
#   1) Mitigación de los FVG YA existentes (activos) contra las velas nuevas.
#   2) Detección de FVG NUEVOS, cuyo centro cae en el tramo recién cerrado.
# Nunca vuelve a tocar velas/FVGs anteriores a $prev_last_global.
sub _fvg_incremental_scan {
    my ($self, $run_data, $run_base_global, $prev_last_global, $cur_last_global) = @_;
    my $rn = scalar @$run_data;

    # 1) Actualizar mitigación de los FVG activos existentes.
    my $new_start_local = ($prev_last_global + 1) - $run_base_global;
    $new_start_local = 0 if $new_start_local < 0;

    for my $fvg (@{ $self->{_fvg_global} }) {
        next unless $fvg->{state} eq 'active';
        for (my $k = $new_start_local; $k < $rn; $k++) {
            my $g = $k + $run_base_global;
            next if $g <= $prev_last_global;   # ya procesada en una llamada anterior
            last if $self->_apply_fvg_mitigation($fvg, $run_data->[$k], $g);
        }
    }

    # 2) Detectar FVG nuevos: el trío centrado en $g solo puede confirmarse
    # cuando su tercera vela ($g+1) ya cerró. Los centros nuevos a revisar
    # son los que antes no se podían confirmar (el anterior "cur_last") y
    # ahora sí, hasta el nuevo penúltimo índice disponible.
    my $atr_arr;   # perezoso: solo se calcula si aparece al menos un trío nuevo
    my $min_ratio = $self->{fvg_min_atr_ratio} // 0.15;

    for (my $g = $prev_last_global; $g <= $cur_last_global - 1; $g++) {
        my $i = $g - $run_base_global;
        next if $i < 1 || $i > $rn - 2;
        $atr_arr //= $self->_calc_atr_simple($run_data, 14);
        my $fvg = $self->_try_form_fvg($run_data, $i, $atr_arr, $min_ratio, $run_base_global);
        next unless $fvg;
        for (my $k = $i + 2; $k < $rn; $k++) {
            last if $self->_apply_fvg_mitigation($fvg, $run_data->[$k], $k + $run_base_global);
        }
        push @{ $self->{_fvg_global} }, $fvg;
    }
}

# _try_form_fvg — evalúa si el trío centrado en el índice LOCAL $i (dentro
# de $run_data) forma un FVG válido (patrón de 3 velas + filtro de tamaño
# mínimo por ATR). Devuelve el hashref del FVG (en términos GLOBALES vía
# $run_base_global) o undef si no aplica.
sub _try_form_fvg {
    my ($self, $run_data, $i, $atr_arr, $min_ratio, $run_base_global) = @_;
    my $prev = $run_data->[$i - 1];
    my $next = $run_data->[$i + 1];
    my $origin_candle = $run_data->[$i];

    my $fvg;
    if ($next->{low} > $prev->{high}) {
        $fvg = {
            g_index       => $i + $run_base_global,
            direction     => 'up',
            top           => $next->{low},
            bottom        => $prev->{high},
            orig_top      => $next->{low},
            orig_bottom   => $prev->{high},
            state         => 'active',
            created_at    => $origin_candle->{time},
            created_epoch => $origin_candle->{epoch},
            g_mitigated_at=> undef,
        };
    } elsif ($next->{high} < $prev->{low}) {
        $fvg = {
            g_index       => $i + $run_base_global,
            direction     => 'down',
            top           => $prev->{low},
            bottom        => $next->{high},
            orig_top      => $prev->{low},
            orig_bottom   => $next->{high},
            state         => 'active',
            created_at    => $origin_candle->{time},
            created_epoch => $origin_candle->{epoch},
            g_mitigated_at=> undef,
        };
    }
    return undef unless $fvg;

    my $atr_here = $atr_arr->[$i];
    if (defined $atr_here && $atr_here > 0) {
        my $gap_size = $fvg->{top} - $fvg->{bottom};
        return undef if $gap_size < ($min_ratio * $atr_here);
    }
    return $fvg;
}

# ─────────────────────────────────────────────────────────────────────────────
# _apply_fvg_mitigation — spec del profesor: "Cuando el precio solo toque una
# parte del FVG, este debe permanecer activo y continuar extendiéndose.
# Cuando la zona sea completamente mitigada... el sistema debe permitir
# configurar si el rectángulo desaparece o simplemente deja de extenderse."
#
# Compara la vela $c contra la zona VIGENTE del FVG ($fvg->{bottom}..{top},
# que puede ya venir recortada de toques parciales previos) y decide:
#
#   - Sin solape -> no pasa nada, el FVG sigue igual.
#   - La vela cubre TODA la zona vigente de una sola vez -> mitigación
#     completa: state='mitigated', g_mitigated_at=$g.
#   - La vela invade solo desde un borde (arriba o abajo) sin llegar al
#     otro -> RECORTE: ese borde se mueve hasta donde llegó la vela, el
#     FVG sigue 'active' con una zona más chica (igual que el indicador
#     nativo de FVG de TradingView).
#   - La vela queda enteramente DENTRO de la zona sin tocar ningún borde
#     (gap directo al medio, caso raro) -> se ignora; no hay borde que
#     recortar de forma no ambigua.
#
# $g es el índice GLOBAL de la vela evaluada. Devuelve 1 si el FVG quedó
# completamente mitigado en esta vela (el bucle llamador debe detenerse),
# 0 en cualquier otro caso (incluyendo recorte parcial, que sigue
# evaluándose en velas futuras).
# ─────────────────────────────────────────────────────────────────────────────
sub _apply_fvg_mitigation {
    my ($self, $fvg, $c, $g) = @_;
    my ($bottom, $top) = ($fvg->{bottom}, $fvg->{top});

    return 0 if $c->{high} < $bottom || $c->{low} > $top;   # sin solape

    if ($c->{low} <= $bottom && $c->{high} >= $top) {
        $fvg->{state}         = 'mitigated';
        $fvg->{g_mitigated_at}= $g;
        return 1;
    }
    elsif ($c->{low} <= $bottom) {
        $fvg->{bottom} = $c->{high};
    }
    elsif ($c->{high} >= $top) {
        $fvg->{top} = $c->{low};
    }
    else {
        return 0;
    }

    if ($fvg->{top} - $fvg->{bottom} <= 0) {
        $fvg->{state}         = 'mitigated';
        $fvg->{g_mitigated_at}= $g;
        return 1;
    }
    return 0;
}


# Liquidity_indicators::_calc_atr). Se duplica aquí en vez de compartir
# código entre packages para no crear un acoplamiento nuevo entre
# SMC_Structures y Liquidity — ambos son consumidores independientes del
# mismo cálculo estándar.
sub _calc_atr_simple {
    my ($self, $data, $period) = @_;
    my (@tr, @atr);

    for my $i (0 .. $#$data) {
        my $c = $data->[$i];
        my $tr;
        if ($i == 0) {
            $tr = $c->{high} - $c->{low};
        } else {
            my $pc = $data->[$i - 1]{close};
            my $a = $c->{high} - $c->{low};
            my $b = abs($c->{high} - $pc);
            my $d = abs($c->{low}  - $pc);
            $tr = $a > $b ? ($a > $d ? $a : $d) : ($b > $d ? $b : $d);
        }
        push @tr, $tr;

        if ($i < $period - 1) {
            push @atr, undef;
        } elsif ($i == $period - 1) {
            my $sum = 0; $sum += $_ for @tr[0 .. $period - 1];
            push @atr, $sum / $period;
        } else {
            push @atr, ($atr[-1] * ($period - 1) + $tr) / $period;
        }
    }
    return \@atr;
}

# ─────────────────────────────────────────────────────────────────────────────
# _detect_order_blocks — "OB: Inside Order Blocks" (cronograma 29/06)
#
# Un Order Block es la última vela de dirección OPUESTA a un movimiento
# impulsivo, justo antes de que ese movimiento confirme un BOS. Representa
# la zona donde "smart money" habría acumulado posiciones antes de mover
# el precio — definición estándar ICT/LuxAlgo:
#
#   OB alcista (bullish): para un BOS alcista (direction='up'), es la
#   última vela BAJISTA (close < open) en el rango [level_index, event_index)
#   del evento BOS. Su rango de precio es [low, high] de esa vela.
#
#   OB bajista (bearish): para un BOS bajista (direction='down'), es la
#   última vela ALCISTA (close > open) en ese mismo rango.
#
# Mitigación: el OB se considera mitigado en la primera vela posterior al
# BOS cuyo rango vuelve a tocar el rango de precio del OB — el precio
# "regresó a recoger" esa liquidez.
#
# Solo se generan Order Blocks a partir de eventos BOS (no CHoCH), ya que
# el OB representa el origen de una continuación de tendencia confirmada.
#
# ── FIX (retroalimentación del profesor): "OB tiene que ser más externo,
# no tanto interno... los externos hay que plotear, los internos no porque
# se vería muy ruidoso." ──────────────────────────────────────────────────
# Antes se generaba un OB por CADA BOS, sin importar su scope (internal o
# external) — verificado empíricamente: de 905 Order Blocks totales, 486
# venían de BOS internos y 419 de externos, es decir, más de la mitad del
# ruido visual de OB era estructura interna que el profesor pidió ocultar.
# Ahora solo se generan Order Blocks desde eventos BOS de scope 'external'
# (estructura mayor) — la estructura interna deja de producir OB en
# absoluto, tal como se pidió.
# ─────────────────────────────────────────────────────────────────────────────
sub _detect_order_blocks {
    my ($self, $data) = @_;
    my $n = scalar @$data;

    for my $ev (@{ $self->{events} }) {
        next unless $ev->{type} eq 'BOS';
        next unless $ev->{scope} eq 'external';   # FIX: solo estructura externa

        my $is_bullish_bos = ($ev->{direction} eq 'up');
        my $search_start    = $ev->{level_index};
        my $search_end      = $ev->{index};
        next if $search_end <= $search_start;

        # Buscar hacia atrás desde el evento la última vela de dirección opuesta
        my $ob_index;
        for (my $j = $search_end - 1; $j >= $search_start; $j--) {
            my $c = $data->[$j];
            my $is_opposite = $is_bullish_bos
                ? ($c->{close} < $c->{open})    # vela bajista para OB alcista
                : ($c->{close} > $c->{open});   # vela alcista para OB bajista
            if ($is_opposite) {
                $ob_index = $j;
                last;
            }
        }
        next unless defined $ob_index;

        my $ob_candle = $data->[$ob_index];
        my $ob = {
            index        => $ob_index,
            direction    => $is_bullish_bos ? 'bullish' : 'bearish',
            top          => $ob_candle->{high},
            bottom       => $ob_candle->{low},
            bos_index    => $ev->{index},
            mitigated_at => undef,
        };

        # Buscar mitigación: primera vela posterior al BOS que vuelve a
        # tocar el rango del Order Block.
        for (my $j = $ev->{index} + 1; $j < $n; $j++) {
            my $c = $data->[$j];
            if ($c->{low} <= $ob->{top} && $c->{high} >= $ob->{bottom}) {
                $ob->{mitigated_at} = $j;
                last;
            }
        }

        push @{ $self->{order_blocks} }, $ob;
        $self->{order_blocks_by_index}{$ob_index} = $ob;
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# _detect_support_resistance — "Support/Resistence: below support or above
# resistance levels" (cronograma 29/06)
#
# Agrupa los Swing Highs en niveles de Resistencia y los Swing Lows en
# niveles de Soporte: cuando varios swings del mismo tipo caen dentro de
# una tolerancia de precio entre sí (misma idea de EQH/EQL pero acumulando
# TODOS los toques, no solo pares), se consolidan en un único nivel con
# la lista de índices donde el precio reaccionó ahí.
#
# Solo se reportan niveles con 2 o más toques — un solo swing aislado no
# es un nivel de "soporte/resistencia", es solo un Swing Point normal.
#
# Tolerancia: se usa un porcentaje fijo simple (0.15% del precio del
# primer toque) para no depender del ATR de Liquidity.pm — este archivo
# se mantiene autocontenido según la Tabla 1 del PDF.
# ─────────────────────────────────────────────────────────────────────────────
sub _detect_support_resistance {
    my ($self, $data) = @_;
    my $tolerance_pct = 0.0015;   # 0.15%

    for my $kind_info (
        { type => 'high', kind => 'resistance' },
        { type => 'low',  kind => 'support' },
    ) {
        # OPTIMIZADO: en vez de O(n^2) comparando todos los pares, ordenamos
        # los pivotes por precio y agrupamos clústeres contiguos dentro de
        # tolerancia. O(n log n). Produce los mismos niveles de S/R.
        my @pivots = sort { $a->{price} <=> $b->{price} }
                     grep { $_->{type} eq $kind_info->{type} } @{ $self->{swings} };
        my $i = 0;
        while ($i <= $#pivots) {
            my $base_price = $pivots[$i]{price};
            my $tolerance  = $base_price * $tolerance_pct;
            my @touches    = ($pivots[$i]{index});
            my $sum_price  = $base_price;
            my $count      = 1;
            my $j = $i + 1;
            while ($j <= $#pivots
                   && abs($pivots[$j]{price} - $base_price) <= $tolerance) {
                push @touches, $pivots[$j]{index};
                $sum_price += $pivots[$j]{price};
                $count++;
                $j++;
            }
            if ($count >= 2) {
                @touches = sort { $a <=> $b } @touches;
                push @{ $self->{support_resistance} }, {
                    price       => $sum_price / $count,
                    kind        => $kind_info->{kind},
                    touches     => \@touches,
                    first_index => $touches[0],
                    last_index  => $touches[-1],
                };
            }
            $i = $j;
        }
    }

    # Ordenar cronológicamente por el primer toque, para consistencia visual.
    @{ $self->{support_resistance} } =
        sort { $a->{first_index} <=> $b->{first_index} } @{ $self->{support_resistance} };
}

# ─────────────────────────────────────────────────────────────────────────────
# _detect_trendlines — "Trendlines/Channels: below or above" (cronograma 29/06)
#
# Conecta SWINGS MAYORES (major_swings, estructura externa) CONSECUTIVOS del
# mismo tipo con una línea recta:
#   - Línea de resistencia: conecta cada par de Swing Highs mayores consecutivos.
#   - Línea de soporte: conecta cada par de Swing Lows mayores consecutivos.
#
# ── FIX (retroalimentación del profesor: "corregir trendlines porque no
# coincide") ─────────────────────────────────────────────────────────────
# Antes se usaba {swings} (interno, k=5) — con 2,581 swings en el histórico
# de prueba, salían 2,579 trendlines: una maraña ilegible que no representa
# ninguna estructura real (confirmado visualmente). Ahora usa {major_swings}
# (k=50) — reduce a ~10% el número de líneas y las ancla a extremos
# realmente significativos, no a cualquier zigzag menor.
#
# Cada trendline se expresa como y = slope*x + intercept (en términos de
# índice de vela como x y precio como y) para que el Overlay pueda
# extender la línea más allá del segundo punto y dibujar el canal completo.
# ─────────────────────────────────────────────────────────────────────────────
sub _detect_trendlines {
    my ($self) = @_;

    for my $type ('high', 'low') {
        my @pivots = grep { $_->{type} eq $type } @{ $self->{major_swings} };
        next if @pivots < 2;

        for (my $i = 0; $i < $#pivots; $i++) {
            my $p1 = $pivots[$i];
            my $p2 = $pivots[$i + 1];

            my $dx = $p2->{index} - $p1->{index};
            next if $dx == 0;

            my $slope     = ($p2->{price} - $p1->{price}) / $dx;
            my $intercept = $p1->{price} - $slope * $p1->{index};

            push @{ $self->{trendlines} }, {
                kind      => ($type eq 'high') ? 'resistance' : 'support',
                point1    => { index => $p1->{index}, price => $p1->{price} },
                point2    => { index => $p2->{index}, price => $p2->{price} },
                slope     => $slope,
                intercept => $intercept,
            };
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _detect_fibonacci — Fibonacci Retracement levels (Fase 3, cronograma 29/06:
# "niveles de Fibonacci" — Tabla 1 y Tabla 4 del PDF).
#
# El PDF no fija una regla de anclaje específica para Fibonacci (a diferencia
# de BOS/CHoCH/EQH-EQL, que sí tienen fórmulas explícitas en 4.1/4.2). Se usa
# la convención estándar de la industria: anclar cada pierna a dos swings
# MAYORES consecutivos de la secuencia ya alternada (misma fuente que
# Trendlines, major_swings[i] -> major_swings[i+1] — mismo fix de ruido que
# ahí, ver comentario de _detect_trendlines), generando una serie histórica
# de piernas para que el Overlay pueda mostrar la más reciente o cualquiera
# que intersecte el rango visible.
#
# Convención: ratio=0 en el extremo MÁS RECIENTE (to) y ratio=1 en el
# extremo anterior (from) — así "38.2%", "61.8%", etc. representan el
# retroceso desde el movimiento más nuevo hacia el más viejo, tal como se
# usa en TradingView/LuxAlgo.
# ─────────────────────────────────────────────────────────────────────────────
my @FIB_RATIOS = (0, 0.236, 0.382, 0.5, 0.618, 0.786, 1);

sub _detect_fibonacci {
    my ($self) = @_;
    my $swings = $self->{major_swings};
    return if @$swings < 2;

    for (my $i = 0; $i < $#$swings; $i++) {
        my $from = $swings->[$i];
        my $to   = $swings->[$i + 1];
        next if $to->{index} == $from->{index};

        my $range     = $to->{price} - $from->{price};
        my $direction = ($range >= 0) ? 'up' : 'down';

        my @levels = map {
            { ratio => $_, price => $to->{price} - $_ * $range }
        } @FIB_RATIOS;

        push @{ $self->{fibonacci} }, {
            from      => { index => $from->{index}, price => $from->{price} },
            to        => { index => $to->{index},   price => $to->{price} },
            direction => $direction,
            levels    => \@levels,
        };
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _calc_daily_proximity — "near daily candle's body & wick" (cronograma 29/06)
#
# Calcula la posición del PRECIO ACTUAL (cierre de la última vela visible)
# respecto al cuerpo y la mecha de la vela DIARIA más reciente. Útil como
# referencia visual de "qué tan cerca está el precio de zonas relevantes
# del día" — exactamente lo que TradingView/LuxAlgo muestran con niveles
# "Previous Day High/Low" combinados con el cuerpo de la vela.
#
# Requiere acceso al MarketData completo (no solo al slice del TF activo)
# para leer la temporalidad 'D' independientemente de en qué TF esté
# navegando el usuario — mismo patrón que el volumen multi-temporal del
# PDF 4.4 en Liquidity.pm.
#
# Resultado almacenado en daily_proximity:
#   {
#     daily_index,        # índice de la vela diaria de referencia
#     body_top, body_bottom,    # max/min de open y close de esa vela diaria
#     wick_top, wick_bottom,    # high/low de esa vela diaria
#     current_price,       # close de la última vela visible en el TF activo
#     zone,                 # 'above_wick' | 'in_upper_wick' | 'in_body' |
#                            # 'in_lower_wick' | 'below_wick'
#     distance_to_body,     # distancia en precio al cuerpo más cercano
#   }
# ─────────────────────────────────────────────────────────────────────────────
sub _calc_daily_proximity {
    my ($self, $market_data, $data) = @_;
    return unless @$data;

    my $daily = eval { $market_data->get_tf_data('D') };
    return unless $daily && @$daily;

    my $current_price = $data->[-1]{close};
    my $current_epoch = $data->[-1]{epoch};

    # Encontrar la vela diaria más reciente cuyo epoch sea <= la vela actual
    my $ref_candle;
    my $ref_index;
    for my $i (0 .. $#$daily) {
        if ($daily->[$i]{epoch} <= $current_epoch) {
            $ref_candle = $daily->[$i];
            $ref_index  = $i;
        } else {
            last;
        }
    }
    return unless defined $ref_candle;

    my $body_top    = $ref_candle->{open} > $ref_candle->{close} ? $ref_candle->{open}  : $ref_candle->{close};
    my $body_bottom = $ref_candle->{open} > $ref_candle->{close} ? $ref_candle->{close} : $ref_candle->{open};
    my $wick_top    = $ref_candle->{high};
    my $wick_bottom = $ref_candle->{low};

    my $zone;
    my $distance_to_body;

    if ($current_price > $wick_top) {
        $zone = 'above_wick';
        $distance_to_body = $current_price - $body_top;
    } elsif ($current_price > $body_top) {
        $zone = 'in_upper_wick';
        $distance_to_body = $current_price - $body_top;
    } elsif ($current_price >= $body_bottom) {
        $zone = 'in_body';
        $distance_to_body = 0;
    } elsif ($current_price >= $wick_bottom) {
        $zone = 'in_lower_wick';
        $distance_to_body = $body_bottom - $current_price;
    } else {
        $zone = 'below_wick';
        $distance_to_body = $body_bottom - $current_price;
    }

    $self->{daily_proximity} = {
        daily_index       => $ref_index,
        body_top          => $body_top,
        body_bottom       => $body_bottom,
        wick_top          => $wick_top,
        wick_bottom       => $wick_bottom,
        current_price     => $current_price,
        zone              => $zone,
        distance_to_body  => $distance_to_body,
    };
}

# Helper interno: registra un evento BOS/CHoCH en las dos estructuras de
# almacenamiento (lista cronológica + índice por vela).
sub _push_event {
    my ($self, $index, $type, $direction, $scope, $level_price, $level_index) = @_;

    my $event = {
        index       => $index,
        type        => $type,
        direction   => $direction,
        scope       => $scope,
        level_price => $level_price,
        level_index => $level_index,
    };

    push @{ $self->{events} }, $event;

    if (exists $self->{events_by_index}{$index}) {
        # Ya hay un evento en esta vela: convertir a arrayref si hace falta
        my $existing = $self->{events_by_index}{$index};
        if (ref($existing) eq 'ARRAY') {
            push @$existing, $event;
        } else {
            $self->{events_by_index}{$index} = [ $existing, $event ];
        }
    } else {
        $self->{events_by_index}{$index} = $event;
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Helpers de consulta — usados por overlays y por 3.2 (BOS/CHoCH) más adelante
# ─────────────────────────────────────────────────────────────────────────────

# Devuelve el último Swing High registrado antes (o en) un índice dado.
# undef si no hay ninguno. Útil para BOS/CHoCH: "¿cuál es el último SH
# relevante para comparar con el precio actual?"
sub last_swing_high_before {
    my ($self, $index) = @_;
    my $found;
    for my $sw (@{ $self->{swings} }) {
        last if $sw->{index} > $index;
        $found = $sw if $sw->{type} eq 'high';
    }
    return $found;
}

# Equivalente para Swing Low.
sub last_swing_low_before {
    my ($self, $index) = @_;
    my $found;
    for my $sw (@{ $self->{swings} }) {
        last if $sw->{index} > $index;
        $found = $sw if $sw->{type} eq 'low';
    }
    return $found;
}

# Devuelve todos los swings dentro de un rango de índices [start, end].
# Usado por el Overlay para no iterar swings fuera de la ventana visible.
# ─────────────────────────────────────────────────────────────────────────────
# *_in_range OPTIMIZADOS — búsqueda binaria O(log n + k) en lugar de
# grep O(n). Los arrays {swings}, {events}, {trendlines} están ordenados
# por {index}; usamos _bsearch_lo/_bsearch_hi para acotar el slice.
# ─────────────────────────────────────────────────────────────────────────────

sub _bsearch_lo {
    # primer índice en el array donde $arr->[$i]{index} >= $val
    my ($arr, $val) = @_;
    my ($lo, $hi) = (0, scalar @$arr);
    while ($lo < $hi) {
        my $mid = int(($lo + $hi) / 2);
        $arr->[$mid]{index} < $val ? ($lo = $mid + 1) : ($hi = $mid);
    }
    return $lo;
}

sub _bsearch_hi {
    # último índice en el array donde $arr->[$i]{index} <= $val  (retorna -1 si ninguno)
    my ($arr, $val) = @_;
    my ($lo, $hi) = (0, $#{$arr});
    return -1 if !@$arr || $arr->[0]{index} > $val;
    while ($lo < $hi) {
        my $mid = int(($lo + $hi + 1) / 2);
        $arr->[$mid]{index} > $val ? ($hi = $mid - 1) : ($lo = $mid);
    }
    return $lo;
}

sub swings_in_range {
    my ($self, $start, $end) = @_;
    my $arr = $self->{swings};
    return [] unless @$arr;
    my $lo = _bsearch_lo($arr, $start);
    my $hi = _bsearch_hi($arr, $end);
    return [] if $hi < $lo;
    return [ @{$arr}[$lo .. $hi] ];
}

# Equivalente a swings_in_range pero para la estructura EXTERNA (major_swings).
# Es lo que usa el Overlay para dibujar las etiquetas HH/HL/LH/LL "limpias".
sub major_swings_in_range {
    my ($self, $start, $end) = @_;
    my $arr = $self->{major_swings};
    return [] unless @$arr;
    my $lo = _bsearch_lo($arr, $start);
    my $hi = _bsearch_hi($arr, $end);
    return [] if $hi < $lo;
    return [ @{$arr}[$lo .. $hi] ];
}

# Equivalente a swings_in_range pero para eventos BOS/CHoCH.
# Usado por el Overlay (3.5) para dibujar solo los eventos visibles.
sub events_in_range {
    my ($self, $start, $end) = @_;
    my $arr = $self->{events};
    return [] unless @$arr;
    my $lo = _bsearch_lo($arr, $start);
    my $hi = _bsearch_hi($arr, $end);
    return [] if $hi < $lo;
    return [ @{$arr}[$lo .. $hi] ];
}

# Devuelve solo los eventos de un tipo dado ('BOS' o 'CHoCH') dentro de un rango.
sub events_in_range_by_type {
    my ($self, $start, $end, $type) = @_;
    return [
        grep { $_->{index} >= $start && $_->{index} <= $end && $_->{type} eq $type }
        @{ $self->{events} }
    ];
}

# Devuelve los FVG cuyo rango de "vida visual" intersecta [start, end].
# Un FVG sigue siendo relevante para dibujar mientras no ha sido mitigado,
# o si la mitigación ocurrió dentro o después del rango visible — así el
# Overlay puede mostrar el rectángulo hasta el punto exacto de mitigación.
sub fvgs_in_range {
    my ($self, $start, $end) = @_;
    # Usar índice de buckets si está disponible (O(k) en vez de O(n))
    if (my $idx = $self->{_fvg_bucket_idx}) {
        my $B = $self->{_bucket_size};
        my $b0 = int($start / $B);
        my $b1 = int($end   / $B);
        my %seen;
        my @cand;
        for my $b ($b0 .. $b1) {
            for my $fvg (@{ $idx->{$b} // [] }) {
                next if $seen{$fvg}++;
                push @cand, $fvg
                    if $fvg->{index} <= $end
                    && (!defined $fvg->{mitigated_at} || $fvg->{mitigated_at} >= $start);
            }
        }
        return \@cand;
    }
    return [
        grep {
            $_->{index} <= $end
            && (!defined $_->{mitigated_at} || $_->{mitigated_at} >= $start)
        } @{ $self->{fvgs} }
    ];
}

# Devuelve solo los FVG todavía activos (sin mitigar) hasta un índice dado.
# Útil para el Overlay cuando solo interesa "lo que sigue siendo zona de
# reacción válida" en el momento actual del gráfico (incluye Replay).
sub active_fvgs_at {
    my ($self, $index) = @_;
    return [
        grep {
            $_->{index} <= $index
            && (!defined $_->{mitigated_at} || $_->{mitigated_at} > $index)
        } @{ $self->{fvgs} }
    ];
}

# Order Blocks dentro de un rango — su "vida visual" intersecta [start,end]
# igual criterio que fvgs_in_range: relevante mientras no mitigado, o si
# la mitigación ocurrió dentro/después del rango visible.
sub order_blocks_in_range {
    my ($self, $start, $end) = @_;
    if (my $idx = $self->{_ob_bucket_idx}) {
        my $B = $self->{_bucket_size};
        my $b0 = int($start / $B);
        my $b1 = int($end   / $B);
        my %seen; my @cand;
        for my $b ($b0 .. $b1) {
            for my $ob (@{ $idx->{$b} // [] }) {
                next if $seen{$ob}++;
                push @cand, $ob
                    if $ob->{index} <= $end
                    && (!defined $ob->{mitigated_at} || $ob->{mitigated_at} >= $start);
            }
        }
        return \@cand;
    }
    return [
        grep {
            $_->{index} <= $end
            && (!defined $_->{mitigated_at} || $_->{mitigated_at} >= $start)
        } @{ $self->{order_blocks} }
    ];
}

# Niveles de Support/Resistance cuyo primer toque cae dentro de [start,end]
# o cuyo último toque sigue siendo posterior a start (nivel "vivo" en la
# ventana visible).
sub support_resistance_in_range {
    my ($self, $start, $end) = @_;
    return [
        grep { $_->{first_index} <= $end && $_->{last_index} >= $start }
        @{ $self->{support_resistance} }
    ];
}

# Trendlines cuyo segmento [point1.index, point2.index] intersecta el
# rango visible [start,end].
sub trendlines_in_range {
    my ($self, $start, $end) = @_;
    my $arr = $self->{trendlines};
    return [] unless @$arr;
    # Trendlines ordenados por point1.index. Encontrar el último con p1 <= end.
    my ($lo2, $hi2) = (0, $#{$arr});
    return [] if $arr->[0]{point1}{index} > $end;
    while ($lo2 < $hi2) {
        my $mid = int(($lo2 + $hi2 + 1) / 2);
        $arr->[$mid]{point1}{index} > $end ? ($hi2 = $mid - 1) : ($lo2 = $mid);
    }
    # De esos, filtrar por point2.index >= start (pocos elementos pasan este test)
    return [ grep { $_->{point2}{index} >= $start } @{$arr}[0 .. $lo2] ];
}

# ─────────────────────────────────────────────────────────────────────────────
# latest_trendlines_before — FIX (retroalimentación del profesor: "corregir
# trendlines porque no coincide"). trendlines_in_range() devuelve TODO lo que
# geométricamente intersecta [start,end] — con zoom muy alejado (miles de
# velas en 1m), eso incluye docenas de canales históricos distintos, cada
# uno extendido hasta el borde derecho: el resultado es la maraña de líneas
# reportada (confirmado con capturas: ~60-100 líneas cruzadas en 1m).
#
# La solución no es filtrar por geometría sino por VIGENCIA: como un canal
# de TradingView, solo interesan los $n canales MÁS RECIENTES de cada tipo
# (resistencia/soporte) hasta el cursor/borde derecho $end — sin importar
# cuánta historia haya en pantalla. Reduce a un puñado de líneas siempre,
# sea cual sea el nivel de zoom.
# ─────────────────────────────────────────────────────────────────────────────
sub latest_trendlines_before {
    my ($self, $end, $n) = @_;
    $n //= 2;
    my (%by_kind);
    for my $tl (@{ $self->{trendlines} }) {
        next if $tl->{point2}{index} > $end;
        push @{ $by_kind{ $tl->{kind} } }, $tl;
    }
    my @result;
    for my $kind (keys %by_kind) {
        my @sorted = sort { $a->{point2}{index} <=> $b->{point2}{index} } @{ $by_kind{$kind} };
        my $from = @sorted > $n ? (@sorted - $n) : 0;
        push @result, @sorted[$from .. $#sorted];
    }
    return \@result;
}

# Fibonacci: mismo patron que trendlines_in_range -- ordenado cronologicamente
# por construccion (se generan en el mismo orden que swings), asi que basta
# con filtrar por interseccion de [from.index, to.index] con [start,end].
sub fibonacci_in_range {
    my ($self, $start, $end) = @_;
    return [
        grep { $_->{from}{index} <= $end && $_->{to}{index} >= $start }
        @{ $self->{fibonacci} }
    ];
}

1;
