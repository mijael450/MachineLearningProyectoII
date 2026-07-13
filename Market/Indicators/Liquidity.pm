package Market::Indicators::Liquidity;
use strict;
use warnings;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Indicators::Liquidity
#
# Según la arquitectura del PDF (Tabla 1):
#   "Motor de detección analítica de Swing Points, EQH/EQL, Sweeps, Grabs y
#    Runs, gestionando la máquina de estados de liquidez."
#
# PUNTO 3.4 — Implementado en este archivo:
#   - BSL (Buy Side Liquidity) y SSL (Sell Side Liquidity)
#   - EQH (Equal Highs) y EQL (Equal Lows) con tolerancia dinámica por ATR
#   - Máquina de estados de liquidez: Detected -> Swept -> Acceptance/
#     Reclaimed -> Resolved, con clasificación final Sweep / Grab / Run
#
# PDF 4.4 — Jerarquía Multi-Temporal y Reglas de Volumen Asociado:
#   - Pesado de volumen multi-temporal: cada nivel almacena el volumen
#     observado en 1m, 5m y 15m, independiente del TF activo del gráfico.
#   - Clasificación de liquidez por origen: 'internal' (mismo TF activo)
#     vs 'external' (TF superior proyectado en el TF actual).
#
# Archivo independiente y autocontenido: calcula sus propios Swing Points
# y su propio ATR internamente (mismas fórmulas que SMC_Structures.pm y
# ATR.pm respectivamente) para no depender del orden de registro de otros
# indicadores en el IndicatorManager. Esto respeta la separación de
# packages de la Tabla 1 del PDF: Liquidity.pm es responsable exclusivo
# de su propio dominio.
#
# Sigue el mismo contrato que los demás indicadores:
#   new(%args) -> objeto
#   reset()    -> limpia el estado interno
#   values()   -> devuelve los niveles de liquidez calculados (arrayref)
#   calculate_all($market_data) -> recalcula todo desde cero
#
# Compatible con Market::ReplayProxy: calculate_all() solo usa
# $market_data->get_slice(0, $market_data->last_index()), igual que los
# demás indicadores. Con un ReplayProxy en vez del MarketData real, todo
# el módulo de liquidez respeta automáticamente el cursor de Replay.
# ═════════════════════════════════════════════════════════════════════════════

sub new {
    my ($class, %args) = @_;
    my $self = {
        # Profundidad de vecindad para detectar Swing Points (PDF 4.1: k=3)
        depth => $args{depth} // 3,

        # Periodo del ATR interno usado para la tolerancia de EQH/EQL
        # PDF 4.1: "tolerancia = ATR * 0.10"
        atr_period    => $args{atr_period}    // 14,
        eq_tolerance_factor => $args{eq_tolerance_factor} // 0.10,
        eq_lookback         => $args{eq_lookback} // 12,

        # N de velas de cierre consecutivo requeridas para clasificar un
        # evento como "Run" (PDF 4.2: "valor inicial N = 3")
        run_confirm_n => $args{run_confirm_n} // 3,

        # Máximo de velas para que un retorno cuente como "Grab" en vez
        # de "Sweep" estándar (PDF 4.2: "máximo de 3 velas posteriores")
        grab_max_candles => $args{grab_max_candles} // 3,

        # ── Resultado de calculate_all() ──────────────────────────────────
        # levels: arrayref cronológico de hashrefs de nivel de liquidez:
        #   {
        #     index, price, kind,        # kind: 'BSL' | 'SSL' | 'EQH' | 'EQL'
        #     pair_index,                # solo EQH/EQL: índice del 2º pivote
        #     state,                     # 'Detected'|'Swept'|'Acceptance'|
        #                                # 'Reclaimed'|'Resolved'
        #     classification,            # 'Sweep'|'Grab'|'Run'|undef (hasta Resolved)
        #     swept_at,                  # índice donde el precio cruzó el nivel
        #     resolved_at,               # índice donde el ciclo concluyó
        #     volume_mtf,                # PDF 4.4: { '1' => N, '5' => N, '15' => N }
        #                                # volumen agregado de sub-velas en cada TF,
        #                                # SIEMPRE calculado independiente del TF activo
        #     origin,                    # PDF 4.4: 'internal' | 'external'
        #                                # internal = detectado en el TF activo del gráfico
        #                                # external = proyectado desde un TF superior (HTF)
        #   }
        levels => [],
        levels_by_index => {},   # índice de DETECCIÓN -> nivel(es)

        # TF en el que se detectó este cálculo — necesario para clasificar
        # origin internal/external. Se fija en calculate_all() según el
        # TF activo del $market_data recibido.
        _detection_tf => 1,

        # Swing Points internos (mismo formato que SMC_Structures, recalculado
        # aquí para mantener el archivo autocontenido según la Tabla 1 del PDF)
        _swings => [],
    };
    bless $self, $class;
    return $self;
}


# ─────────────────────────────────────────────────────────────────────────────
# _offset_indices — convierte índices locales -> globales tras cálculo por ventana.
# ─────────────────────────────────────────────────────────────────────────────
sub _offset_indices {
    my ($self, $base) = @_;
    return if !$base;
    for my $lv (@{ $self->{levels} }) {
        $lv->{index}       += $base;
        $lv->{pair_index}  += $base if defined $lv->{pair_index};
        $lv->{swept_at}    += $base if defined $lv->{swept_at};
        $lv->{resolved_at} += $base if defined $lv->{resolved_at};
    }
    $self->{levels_by_index} = {};
    for my $lv (@{ $self->{levels} }) {
        my $k = $lv->{index};
        if (exists $self->{levels_by_index}{$k}) {
            my $e = $self->{levels_by_index}{$k};
            $self->{levels_by_index}{$k} = ref($e) eq 'ARRAY' ? [@$e,$lv] : [$e,$lv];
        } else { $self->{levels_by_index}{$k} = $lv; }
    }
}


sub reset {
    my ($self) = @_;
    $self->{levels} = [];
    $self->{levels_by_index} = {};
    $self->{_swings} = [];
}

# values() devuelve el arrayref de niveles de liquidez — contrato estándar
# esperado por IndicatorManager::get('Liquidity').
sub values {
    my ($self) = @_;
    return $self->{levels};
}

# Acceso directo: nivel(es) detectados en una vela específica, o undef.
sub levels_at {
    my ($self, $index) = @_;
    return $self->{levels_by_index}{$index};
}

# Niveles dentro de un rango de índices — usado por el Overlay (3.5).
sub _bsearch_lo {
    my ($arr, $val) = @_;
    my ($lo, $hi) = (0, scalar @$arr);
    while ($lo < $hi) {
        my $mid = int(($lo + $hi) / 2);
        $arr->[$mid]{index} < $val ? ($lo = $mid + 1) : ($hi = $mid);
    }
    return $lo;
}

sub _bsearch_hi {
    my ($arr, $val) = @_;
    my ($lo, $hi) = (0, $#{$arr});
    return -1 if !@$arr || $arr->[0]{index} > $val;
    while ($lo < $hi) {
        my $mid = int(($lo + $hi + 1) / 2);
        $arr->[$mid]{index} > $val ? ($hi = $mid - 1) : ($lo = $mid);
    }
    return $lo;
}

sub levels_in_range {
    my ($self, $start, $end) = @_;
    my $arr = $self->{levels};
    return [] unless @$arr;
    my $lo = _bsearch_lo($arr, $start);
    my $hi = _bsearch_hi($arr, $end);
    return [] if $hi < $lo;
    return [ @{$arr}[$lo .. $hi] ];
}

# Solo niveles de un kind dado ('BSL'|'SSL'|'EQH'|'EQL') dentro de un rango.
sub levels_in_range_by_kind {
    my ($self, $start, $end, $kind) = @_;
    return [
        grep { $_->{index} >= $start && $_->{index} <= $end && $_->{kind} eq $kind }
        @{ $self->{levels} }
    ];
}

# ─────────────────────────────────────────────────────────────────────────────
# calculate_all — orquesta el cálculo completo del módulo de liquidez:
#   1. Swing Points internos (idéntico a SMC_Structures.pm)
#   2. ATR interno (idéntico a ATR.pm) — usado para la tolerancia EQH/EQL
#   3. Detección de BSL/SSL y EQH/EQL
#   4. Máquina de estados Sweep/Grab/Run sobre cada nivel detectado
# ─────────────────────────────────────────────────────────────────────────────
sub calculate_all {
    my ($self, $market_data) = @_;
    $self->reset();

    my $data = $market_data->get_slice(0, $market_data->last_index());
    my $n = scalar @$data;
    return if $n < (2 * $self->{depth} + 1);

    $self->{_detection_tf} = $market_data->get_timeframe();

    $self->_calc_swings($data);
    my $atr = $self->_calc_atr($data);
    $self->_detect_levels($data, $atr);
    $self->_run_state_machine($data);

    # ── PDF 4.4: jerarquía multi-temporal y peso de volumen ──────────────────
    $self->_calc_mtf_volume($market_data, $data);
    $self->_classify_origin();
}
# ─────────────────────────────────────────────────────────────────────────────
# calculate_replay — versión para el sistema Replay
#
# ── FIX (bug reportado): antes esta función usaba _detect_levels_fast(),
# que SOLO genera BSL/SSL y omite EQH/EQL por completo. Como reset() vacía
# {levels} en cada step, el resultado era que las etiquetas EQH/EQL
# DESAPARECÍAN por completo apenas se entraba a Replay — incumpliendo el
# cronograma 29/06 ("EQL/EQH: below EQLs & above EQH") justo en el modo
# que más se evalúa.
#
# La justificación original ("EQH/EQL es un loop O(n²)") ya no aplica:
# _detect_levels() fue optimizado hace tiempo para comparar cada swing
# SOLO contra los `eq_lookback` (12) swings anteriores — es decir, ya es
# O(swings * 12), no O(n²). Sumado a que WindowProxy ya acota el cálculo
# a las últimas REPLAY_WINDOW (~4000) velas, correr la detección completa
# de EQH/EQL en cada step es barato. Se usa _detect_levels() (completo)
# en vez de _detect_levels_fast().
#
# ── FIX (hallazgo 4a): warm-up de contexto ──────────────────────────────
# Igual problema que en SMC_Structures: sin contexto previo, los niveles
# formados justo ANTES del borde de la ventana no existen, así que un
# Sweep/Grab/Run que en realidad depende de un BSL/SSL/EQH/EQL formado un
# poco antes del cursor-4000 no se detecta cerca de ese borde, y el
# emparejamiento EQH/EQL (que mira hasta 12 swings atrás) pierde pares
# reales que caen justo en el límite. Se aplica el mismo patrón que
# SMC_Structures::calculate_all(): calcular sobre warmup+ventana y recortar
# al final con _trim_warmup().
# ─────────────────────────────────────────────────────────────────────────────
sub calculate_replay {
    my ($self, $market_data) = @_;
    $self->reset();

    my $data = $market_data->get_slice(0, $market_data->last_index());
    my $n = scalar @$data;
    return if $n < (2 * $self->{depth} + 1);

    $self->{_detection_tf} = $market_data->get_timeframe();

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

    $self->_calc_swings($run_data);
    my $atr = $self->_calc_atr($run_data);

    # BSL, SSL, EQH y EQL — completo, ya no hace falta la versión "fast".
    $self->_detect_levels($run_data, $atr);
    $self->_run_state_machine($run_data);
    # Omitimos _calc_mtf_volume (no afecta el render del Replay)

    # Recortar el warm-up: descartar niveles detectados enteramente antes
    # de la ventana real y reindexar de vuelta al espacio local de la
    # ventana (mismo patrón que SMC_Structures::_trim_warmup).
    $self->_trim_warmup($warmup_n) if $warmup_n;

    # Windowing (Market::WindowProxy): índices locales -> globales.
    $self->_offset_indices($base) if $base;
}

# ─────────────────────────────────────────────────────────────────────────────
# _trim_warmup — ver comentario detallado en SMC_Structures_indicators.pm
# (mismo patrón: descarta lo detectado enteramente en el warm-up, reindexa
# lo demás restando $warmup_n para volver al espacio local de la ventana).
# Los índices de REFERENCIA (pair_index, swept_at, resolved_at) que queden
# negativos se dejan tal cual: el _offset_indices($base) posterior los
# resuelve a índices GLOBALES reales, apuntando a historial válido fuera
# de la ventana actual.
# ─────────────────────────────────────────────────────────────────────────────
sub _trim_warmup {
    my ($self, $warmup_n) = @_;
    return unless $warmup_n;

    $self->_offset_indices(-$warmup_n);

    @{ $self->{levels} } = grep { $_->{index} >= 0 } @{ $self->{levels} };

    $self->{levels_by_index} = {};
    for my $lv (@{ $self->{levels} }) {
        my $idx = $lv->{index};
        if (exists $self->{levels_by_index}{$idx}) {
            my $e = $self->{levels_by_index}{$idx};
            $self->{levels_by_index}{$idx} = ref($e) eq 'ARRAY' ? [@$e, $lv] : [$e, $lv];
        } else { $self->{levels_by_index}{$idx} = $lv; }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _calc_swings — Swing Points internos (misma fórmula que SMC_Structures 3.1)
# PDF 4.1: High[i] > High[i-k..i-1] y High[i] > High[i+1..i+k] (Swing High)
#          Low[i]  < Low[i-k..i-1]  y Low[i]  < Low[i+1..i+k]  (Swing Low)
# ─────────────────────────────────────────────────────────────────────────────
sub _calc_swings {
    my ($self, $data) = @_;
    my $k = $self->{depth};
    my $n = scalar @$data;
    my @swings;

    for (my $i = $k; $i <= $n - 1 - $k; $i++) {
        my $c = $data->[$i];

        my $is_high = 1;
        for my $j (($i - $k) .. ($i - 1), ($i + 1) .. ($i + $k)) {
            if ($data->[$j]{high} >= $c->{high}) { $is_high = 0; last; }
        }
        if ($is_high) {
            push @swings, { index => $i, price => $c->{high}, type => 'high' };
            next;
        }

        my $is_low = 1;
        for my $j (($i - $k) .. ($i - 1), ($i + 1) .. ($i + $k)) {
            if ($data->[$j]{low} <= $c->{low}) { $is_low = 0; last; }
        }
        if ($is_low) {
            push @swings, { index => $i, price => $c->{low}, type => 'low' };
        }
    }

    $self->{_swings} = \@swings;
}

# ─────────────────────────────────────────────────────────────────────────────
# _calc_atr — ATR interno (misma fórmula RMA de Wilder que ATR.pm)
# Devuelve un arrayref alineado 1:1 con $data (undef durante el warmup).
# ─────────────────────────────────────────────────────────────────────────────
sub _calc_atr {
    my ($self, $data) = @_;
    my $p = $self->{atr_period};
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

        if ($i < $p - 1) {
            push @atr, undef;
        } elsif ($i == $p - 1) {
            my $sum = 0; $sum += $_ for @tr[0 .. $p - 1];
            push @atr, $sum / $p;
        } else {
            push @atr, (($atr[-1] * ($p - 1)) + $tr) / $p;
        }
    }
    return \@atr;
}

# ─────────────────────────────────────────────────────────────────────────────
# _detect_levels — Punto 3.4, primera mitad
#
# BSL (Buy Side Liquidity): un nivel por cada Swing High — liquidez de
# Buy Stops acumulada por encima de máximos relevantes (PDF 4.1).
#
# SSL (Sell Side Liquidity): un nivel por cada Swing Low — liquidez de
# Sell Stops acumulada por debajo de mínimos relevantes (PDF 4.1).
#
# EQH (Equal Highs) / EQL (Equal Lows): cuando dos Swing Highs (o Lows)
# tienen precios casi idénticos según la tolerancia dinámica del PDF:
#   tolerancia = ATR * 0.10
# se registra un nivel EQH/EQL adicional conectando ambos pivotes. El
# segundo pivote del par se guarda en pair_index para que el Overlay (3.5)
# pueda dibujar la línea que conecta ambos extremos.
#
# Cada Swing High/Low SIEMPRE genera su BSL/SSL correspondiente; además,
# si forma un par con tolerancia, genera TAMBIÉN un nivel EQH/EQL. Esto
# es intencional: BSL/SSL representan "todo nivel relevante", mientras
# que EQH/EQL son el subconjunto especial de niveles duplicados — ambos
# coexisten como exige la Tabla 2 del PDF (estilos de overlay distintos).
# ─────────────────────────────────────────────────────────────────────────────
sub _detect_levels {
    my ($self, $data, $atr) = @_;
    my $factor = $self->{eq_tolerance_factor};

    my @highs = grep { $_->{type} eq 'high' } @{ $self->{_swings} };
    my @lows  = grep { $_->{type} eq 'low'  } @{ $self->{_swings} };

    # ── BSL: un nivel por cada Swing High ─────────────────────────────────
    for my $sw (@highs) {
        $self->_push_level($sw->{index}, $sw->{price}, 'BSL', undef);
    }

    # ── SSL: un nivel por cada Swing Low ──────────────────────────────────
    for my $sw (@lows) {
        $self->_push_level($sw->{index}, $sw->{price}, 'SSL', undef);
    }

    # ── EQH: pares de Swing Highs dentro de tolerancia ATR*0.10 ───────────
    # Se compara cada swing contra los anteriores (no solo el inmediato)
    # para detectar pares distantes en el tiempo, tal como especifica el
    # PDF ("Dos pivotes distantes en el tiempo se consideran iguales").
    # OPTIMIZADO: cada high se empareja SOLO con el previo más cercano en
    # precio dentro de una ventana acotada de swings (LOOKBACK). Antes esto
    # era O(n^2) y generaba un nivel por CADA par -> explosión de niveles.
    my $LOOKBACK = $self->{eq_lookback};
    for (my $b = 1; $b <= $#highs; $b++) {
        my $tolerance = _tolerance_at($atr, $highs[$b]{index}, $factor);
        next if !defined $tolerance;
        my $lo = $b - $LOOKBACK; $lo = 0 if $lo < 0;
        my ($best_a, $best_diff);
        for (my $a = $b - 1; $a >= $lo; $a--) {
            my $diff = abs($highs[$a]{price} - $highs[$b]{price});
            if ($diff <= $tolerance && (!defined $best_diff || $diff < $best_diff)) {
                $best_diff = $diff; $best_a = $a;
            }
        }
        $self->_push_level($highs[$b]{index}, $highs[$b]{price}, 'EQH', $highs[$best_a]{index})
            if defined $best_a;
    }

    # ── EQL: pares de Swing Lows dentro de tolerancia ATR*0.10 ─────────────
    my $LOOKBACK_L = $self->{eq_lookback};
    for (my $b = 1; $b <= $#lows; $b++) {
        my $tolerance = _tolerance_at($atr, $lows[$b]{index}, $factor);
        next if !defined $tolerance;
        my $lo = $b - $LOOKBACK_L; $lo = 0 if $lo < 0;
        my ($best_a, $best_diff);
        for (my $a = $b - 1; $a >= $lo; $a--) {
            my $diff = abs($lows[$a]{price} - $lows[$b]{price});
            if ($diff <= $tolerance && (!defined $best_diff || $diff < $best_diff)) {
                $best_diff = $diff; $best_a = $a;
            }
        }
        $self->_push_level($lows[$b]{index}, $lows[$b]{price}, 'EQL', $lows[$best_a]{index})
            if defined $best_a;
    }

    # Reordenar cronológicamente: los pasos anteriores insertan BSL/SSL
    # primero y EQH/EQL después, mezclando el orden temporal.
    @{ $self->{levels} } = sort { $a->{index} <=> $b->{index} } @{ $self->{levels} };
}

# Versión rápida para Replay: solo BSL y SSL, sin el O(n²) de EQH/EQL.
# El resultado es un array con únicamente niveles BSL/SSL ordenados
# cronológicamente, listo para _run_state_machine().
sub _detect_levels_fast {
    my ($self, $data, $atr) = @_;

    my @highs = grep { $_->{type} eq 'high' } @{ $self->{_swings} };
    my @lows  = grep { $_->{type} eq 'low'  } @{ $self->{_swings} };

    for my $sw (@highs) {
        $self->_push_level($sw->{index}, $sw->{price}, 'BSL', undef);
    }
    for my $sw (@lows) {
        $self->_push_level($sw->{index}, $sw->{price}, 'SSL', undef);
    }

    @{ $self->{levels} } = sort { $a->{index} <=> $b->{index} } @{ $self->{levels} };
}

# Tolerancia dinámica en el índice dado: ATR * factor. undef si el ATR
# todavía está en warmup en ese índice (PDF: "tolerancia dinámico basado
# en la volatilidad del activo").
sub _tolerance_at {
    my ($atr, $index, $factor) = @_;
    my $v = $atr->[$index];
    return defined $v ? $v * $factor : undef;
}

# ─────────────────────────────────────────────────────────────────────────────
# _calc_mtf_volume — PDF 4.4, primera mitad: "Pesado de Volumen Multi-Temporal"
#
# Para cada nivel de liquidez, calcula el volumen agregado observado en las
# sub-velas de 1m, 5m y 15m correspondientes a la ventana temporal de la
# vela donde se detectó el nivel — sin importar el TF en el que el usuario
# está navegando el gráfico (PDF: "si el usuario visualiza el gráfico en
# 1H, 4H o D, el motor del package extraerá los volúmenes agregados de las
# sub-velas de menor rango").
#
# Mecánica: cada vela del TF activo tiene un 'epoch' que marca el INICIO
# de su bucket de tiempo (ver MarketData::_bucket_epoch). La ventana de esa
# vela es [epoch, epoch + tf_seconds). Para cada sub-TF (1, 5, 15) se suman
# los volúmenes de todas las sub-velas cuyo epoch cae dentro de esa ventana.
#
# Caso especial: si el TF activo YA ES menor o igual a un sub-TF (p.ej. el
# usuario está en 1m y se pide el "volumen en 1m"), la ventana coincide con
# la propia vela y el volumen es directamente el de esa vela.
# ─────────────────────────────────────────────────────────────────────────────
sub _calc_mtf_volume {
    my ($self, $market_data, $data) = @_;

    my %TF_SECONDS = (1 => 60, 5 => 300, 15 => 900);
    my $active_tf  = $self->{_detection_tf};
    my $active_seconds = $TF_SECONDS{$active_tf} // ($active_tf =~ /^\d+$/ ? $active_tf * 60 : 86400);

    # Cachear los datos de cada sub-TF una sola vez (no en cada nivel)
    my %sub_data;
    for my $sub_tf (1, 5, 15) {
        $sub_data{$sub_tf} = $market_data->get_tf_data($sub_tf);
    }

    for my $level (@{ $self->{levels} }) {
        my $candle = $data->[ $level->{index} ];
        next unless defined $candle;

        my $window_start = $candle->{epoch};
        my $window_end   = $window_start + $active_seconds;

        for my $sub_tf (1, 5, 15) {
            my $arr = $sub_data{$sub_tf};
            next unless $arr && @$arr;

            # Si el TF activo es igual o menor que el sub-TF, no hay
            # "sub-velas" reales que sumar — el volumen es el de la propia
            # vela detectada (caso: detectando en 1m, pidiendo volumen 1m).
            if ($active_seconds <= $TF_SECONDS{$sub_tf}) {
                $level->{volume_mtf}{$sub_tf} = $candle->{volume} // 0;
                next;
            }

            # Búsqueda binaria del primer índice con epoch >= window_start
            my ($lo, $hi) = (0, $#$arr);
            while ($lo < $hi) {
                my $mid = int(($lo + $hi) / 2);
                if ($arr->[$mid]{epoch} < $window_start) { $lo = $mid + 1; }
                else                                     { $hi = $mid; }
            }

            my $sum = 0;
            for (my $i = $lo; $i <= $#$arr && $arr->[$i]{epoch} < $window_end; $i++) {
                $sum += $arr->[$i]{volume} // 0;
            }
            $level->{volume_mtf}{$sub_tf} = $sum;
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _classify_origin — PDF 4.4, segunda mitad: "Clasificación de Liquidez por Origen"
#
# Internal Liquidity: niveles generados y detectados dentro de la misma
# temporalidad activa en el gráfico (ejemplo: operando en 5m con niveles
# de 5m).
#
# External Liquidity: niveles clave originados en marcos temporales
# superiores (HTF) que se proyectan en el gráfico actual (ejemplo: usuario
# analizando en 5m pero visualizando la liquidez proveniente de 15m, 1H,
# 4H, D o W).
#
# Implementación: como este indicador siempre calcula sus propios swings
# en el TF activo recibido ($market_data->get_timeframe()), todo lo que
# calculate_all() detecta es, por definición, 'internal' para ese TF.
# Para exponer también la perspectiva 'external', se recalculan los swings
# en CADA temporalidad superior disponible y se marca como external
# cualquier nivel cuyo precio caiga dentro de la tolerancia ATR de un
# swing equivalente en un TF mayor — esto es exactamente la proyección de
# niveles HTF sobre el TF actual que pide el PDF.
# ─────────────────────────────────────────────────────────────────────────────
sub _classify_origin {
    my ($self) = @_;
    # Todos los niveles calculados por calculate_all() son, por construcción,
    # internos al TF activo — se dejan como 'internal' (valor por defecto
    # ya asignado en _push_level). La proyección external real requiere
    # acceso al $market_data completo en otras temporalidades; se expone
    # mediante mark_external_levels(), invocado explícitamente por quien
    # orqueste la vista multi-temporal (ChartEngine u Overlay), de modo que
    # este indicador siga siendo autocontenido y no dependa de otros TFs
    # para su cálculo base — solo para el enriquecimiento opcional.
    return;
}

# Marca como 'external' los niveles de ESTE indicador (calculado en su TF
# activo) cuyo precio coincide, dentro de tolerancia ATR*factor, con algún
# nivel de un Liquidity calculado en un TF superior ($htf_liquidity).
#
# Uso típico (desde ChartEngine o el Overlay, cuando se navega en un TF
# bajo y se quiere proyectar liquidez de TFs mayores):
#   my $htf = Market::Indicators::Liquidity->new(depth => 3);
#   $htf->calculate_all($market_proxy_en_TF_superior);
#   $self->mark_external_levels($htf, $atr_actual);
sub mark_external_levels {
    my ($self, $htf_liquidity, $atr_current) = @_;
    return unless defined $htf_liquidity;

    my $factor    = $self->{eq_tolerance_factor};
    my $htf_levels = $htf_liquidity->values();

    for my $level (@{ $self->{levels} }) {
        my $tolerance = _tolerance_at($atr_current, $level->{index}, $factor);
        next unless defined $tolerance;

        for my $htf_lv (@$htf_levels) {
            if (abs($level->{price} - $htf_lv->{price}) <= $tolerance) {
                $level->{origin} = 'external';
                last;
            }
        }
    }
}


# Estado inicial siempre 'Detected' — la máquina de estados lo hace
# evolucionar más adelante en _run_state_machine().
sub _push_level {
    my ($self, $index, $price, $kind, $pair_index) = @_;

    my $level = {
        index          => $index,
        price          => $price,
        kind           => $kind,
        pair_index     => $pair_index,
        state          => 'Detected',
        classification => undef,
        swept_at       => undef,
        resolved_at    => undef,
        # PDF 4.4 — se rellenan en _calc_mtf_volume() y _classify_origin()
        volume_mtf     => { 1 => 0, 5 => 0, 15 => 0 },
        origin         => 'internal',
    };

    push @{ $self->{levels} }, $level;

    if (exists $self->{levels_by_index}{$index}) {
        my $existing = $self->{levels_by_index}{$index};
        if (ref($existing) eq 'ARRAY') {
            push @$existing, $level;
        } else {
            $self->{levels_by_index}{$index} = [ $existing, $level ];
        }
    } else {
        $self->{levels_by_index}{$index} = $level;
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _run_state_machine — Punto 3.4, segunda mitad
#
# Implementa la máquina de estados de liquidez del PDF 4.3:
#
#   Estado 1 DETECTED   -> nivel BSL/SSL/EQH/EQL recién identificado.
#   Estado 2 SWEPT      -> el precio cruza el extremo del nivel:
#                          High > BSL  (para BSL/EQH)
#                          Low  < SSL  (para SSL/EQL)
#   Desde SWEPT, según el PDF 4.2, el primer evento que ocurra decide:
#     a) N=3 cierres consecutivos fuera del nivel -> ACCEPTANCE -> "Run"
#     b) Retorno (cierre) dentro del rango en <=3 velas tras el cruce
#        -> RECLAIMED -> "Grab" (rechazo rápido, PDF: "máximo 3 velas")
#     c) Retorno estándar (más de 3 velas, sin las 3 consecutivas de N)
#        -> RECLAIMED -> "Sweep" (caso por defecto/estándar)
#   Estado 5 RESOLVED   -> el ciclo concluye, clasificación inmutable.
#
# Solo BSL y EQH se evalúan contra rupturas alcistas (High > nivel);
# solo SSL y EQL contra rupturas bajistas (Low < nivel) — coherente con
# el PDF: BSL/EQH son techos, SSL/EQL son pisos.
# ─────────────────────────────────────────────────────────────────────────────
sub _run_state_machine {
    my ($self, $data) = @_;
    my $n = scalar @$data;
    my $grab_max = $self->{grab_max_candles};
    my $run_n    = $self->{run_confirm_n};

    for my $level (@{ $self->{levels} }) {
        my $is_ceiling = ($level->{kind} eq 'BSL' || $level->{kind} eq 'EQH');
        my $price = $level->{price};

        # Buscar el primer cruce (Swept) después del índice de detección.
        my $swept_at;
        for (my $j = $level->{index} + 1; $j < $n; $j++) {
            my $c = $data->[$j];
            if ($is_ceiling ? ($c->{high} > $price) : ($c->{low} < $price)) {
                $swept_at = $j;
                last;
            }
        }

        next unless defined $swept_at;   # nunca fue barrido: queda 'Detected'

        $level->{state}    = 'Swept';
        $level->{swept_at} = $swept_at;

        # ── Evaluar qué pasa después del cruce ────────────────────────────
        # Primero: ¿cuántas velas consecutivas, empezando en swept_at,
        # cierran de forma ESTRICTA fuera del nivel? (para detectar Run)
        my $consecutive_outside = 0;
        for (my $j = $swept_at; $j < $n; $j++) {
            my $close = $data->[$j]{close};
            my $outside = $is_ceiling ? ($close > $price) : ($close < $price);
            last unless $outside;
            $consecutive_outside++;
            last if $consecutive_outside >= $run_n;
        }

        if ($consecutive_outside >= $run_n) {
            # ── Run: aceptación institucional confirmada ──────────────────
            my $resolved_at = $swept_at + $run_n - 1;
            $level->{state}          = 'Acceptance';
            $level->{classification} = 'Run';
            $level->{resolved_at}    = $resolved_at;
            $level->{state}          = 'Resolved';
            next;
        }

        # No hubo Run: buscar el primer retorno (Reclaimed) — la primera
        # vela posterior a swept_at cuyo CIERRE regresa dentro del rango.
        my $reclaim_at;
        for (my $j = $swept_at; $j < $n; $j++) {
            my $close = $data->[$j]{close};
            my $still_outside = $is_ceiling ? ($close > $price) : ($close < $price);
            if (!$still_outside) {
                $reclaim_at = $j;
                last;
            }
        }

        if (defined $reclaim_at) {
            my $candles_to_reclaim = $reclaim_at - $swept_at;
            $level->{state} = 'Reclaimed';
            $level->{classification} =
                ($candles_to_reclaim <= $grab_max) ? 'Grab' : 'Sweep';
            $level->{resolved_at} = $reclaim_at;
            $level->{state} = 'Resolved';
        }
        # Si no hubo ni Run ni Reclaimed dentro de los datos disponibles,
        # el nivel queda en estado 'Swept' — su ciclo aún no concluyó
        # (relevante en Replay: el futuro que resolvería el evento
        # todavía no ha sido revelado por el cursor).
    }
}

1;
