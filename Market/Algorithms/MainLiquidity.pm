package Market::Algorithms::MainLiquidity;

use strict;
use warnings;
use List::Util qw(max min);

# ============================================================
#  Market::Indicators::Liquidity
#
#  Detecta niveles de liquidez y los modela con una maquina
#  de estados determinista. No dibuja; solo calcula y exporta.
#
#  Niveles detectados:
#    BSL  Buy Side Liquidity  (encima de Swing Highs / EQH)
#    SSL  Sell Side Liquidity (debajo de Swing Lows  / EQL)
#    EQH  Equal Highs  (tolerancia = ATR * 0.10)
#    EQL  Equal Lows
#
#  Maquina de estados por nivel:
#    DETECTED -> SWEPT -> ACCEPTANCE -> RESOLVED (RUN)
#                      -> RECLAIMED  -> RESOLVED (GRAB o SWEEP)
#
#  Clasificacion final del evento:
#    SWEEP : precio cruzo y regreso sin aceptacion
#    GRAB  : retorno rapido (<=3 velas)
#    RUN   : >= N cierres consecutivos fuera del nivel
#
#  Regla de Replay:
#    Ningun calculo usa velas con index > max_visible_index.
# ============================================================

# N de cierres consecutivos para clasificar como RUN
use constant RUN_BARS   => 3;
# Ventana de velas para clasificar GRAB vs SWEEP
use constant GRAB_BARS  => 3;
# Parametro k para Swing High/Low (confirmacion requiere i+k velas)
use constant SWING_K    => 3;
# Tolerancia legacy como multiplicador de ATR
use constant EQ_FACTOR  => 0.10;
# Parametros conservadores para agrupar EQH/EQL.
use constant EQ_MATCH_FACTOR => 0.10;
use constant EQ_MINIMUM_TICK_DISTANCE => 2;
use constant EQ_MIN_PIVOT_GAP => 4;
use constant EQ_MAX_PIVOT_GAP => 0;       # 0 = sin limite duro
use constant EQ_SWEEP_BUFFER_ATR_FACTOR => 0.02;
use constant LIQUIDITY_MARGIN_ATR_FACTOR => 0.02;
use constant LIQUIDITY_MINIMUM_MARGIN_TICKS => 2;
use constant LIQUIDITY_SWEEP_BUFFER_TICKS => 1;

my $NEXT_ID = 1;
sub _new_id { return 'LQ_' . sprintf('%04d', $NEXT_ID++) }

# ============================================================
sub new {
    my ($class) = @_;
    bless {
        levels => [],   # ArrayRef de LiquidityLevel
        events => [],   # ArrayRef de LiquidityEvent
    }, $class;
}

# ============================================================
#  Interface compatible con IndicatorManager
# ============================================================

sub update_last {
    my ($self, $market, $atr_series, $max_visible_index, $timeframe, $ext_levels) = @_;

    # Atr_series: arrayref paralelo a candles (undef durante warm-up)
    # ext_levels: niveles externos (HTF) opcionales para marcar scope=external

    my $idx = $self->{_last_processed} // -1;
    $idx++;

    return if $idx > $max_visible_index;
    return if $idx >= $market->size;

    my $candle = $market->get_candle($idx);
    my $atr    = defined $atr_series ? $atr_series->[$idx] : undef;

    $self->{_last_processed} = $idx;

    # 1. Confirmar nuevos Swing High/Low si ya hay suficientes velas
    $self->_detect_swing_points($market, $idx, $atr, $max_visible_index, $timeframe);

    # 2. Avanzar maquina de estados de niveles existentes
    $self->_advance_states($candle, $idx, $max_visible_index);

    return;
}

sub reset {
    my ($self) = @_;
    $self->{levels}          = [];
    $self->{events}          = [];
    $self->{_last_processed} = undef;
    $self->{_swings}         = [];
    $self->{_liquidity_by_source_pivot} = {};
    $self->{_volume_source_indexes} = {};
    $NEXT_ID = 1;
    return;
}

sub get_values { return [] }   # compatibilidad con IndicatorManager (no aplica)

# ============================================================
#  Calculo completo para un slice de velas (modo batch)
#  Retorna { levels => [...], events => [...] }
# ============================================================

sub compute {
    my ($class_or_self, %args) = @_;

    my $candles           = $args{candles}           or die 'Liquidity::compute: falta candles';
    my $atr_series        = $args{atr_series}        // [];
    my $max_visible_index = $args{max_visible_index} // $#$candles;
    my $timeframe         = $args{timeframe}         // '1m';
    my $ext_levels        = $args{ext_levels}        // [];  # niveles HTF para marcar external
    my $volume_sources    = $args{volume_sources}    // {};  # { '1m'=>[...], '5m'=>[...], '15m'=>[...] }
    my $volume_until_time = $args{volume_until_time};         # corte replay-safe opcional
    my $config            = $args{config}            // {};

    my $self = ref($class_or_self) ? $class_or_self : $class_or_self->new;
    $self->reset;

    my $VOL_WIN = 14;
    my @vol_avg;
    my $vol_sum = 0;
    for my $i (0 .. $#$candles) {
        $vol_sum += ($candles->[$i]{volume} // 0);
        $vol_sum -= ($candles->[$i - $VOL_WIN]{volume} // 0) if $i >= $VOL_WIN;
        my $cnt = $i + 1 < $VOL_WIN ? $i + 1 : $VOL_WIN;
        $vol_avg[$i] = $cnt > 0 ? $vol_sum / $cnt : 1;
    }
    $self->{_vol_avg}           = \@vol_avg;
    $self->{_candles}           = $candles;
    $self->{_atr_series}        = $atr_series;
    $self->{_timeframe}         = $timeframe;
    $self->{_volume_sources}    = $volume_sources;
    $self->{_volume_source_indexes} = _prepare_volume_source_indexes($volume_sources);
    $self->{_volume_until_time} = $volume_until_time;
    $self->{_equal_level_threshold} =
        _positive_number($args{equal_level_threshold}
            // $config->{equalLevelThreshold}
            // $config->{equalHighLowAtrTolerance}
            // EQ_MATCH_FACTOR);
    $self->{_minimum_tick} =
        _positive_number($args{minimum_tick} // $config->{minimumTick})
        // _infer_minimum_tick($candles);
    $self->{_minimum_tick_distance} =
        _positive_number($args{minimum_tick_distance}
            // $config->{minimumTickDistance}
            // EQ_MINIMUM_TICK_DISTANCE)
        // EQ_MINIMUM_TICK_DISTANCE;
    $self->{_minimum_bars_between_pivots} =
        _positive_int_value($args{minimum_bars_between_pivots}
            // $config->{minimumBarsBetweenPivots}
            // EQ_MIN_PIVOT_GAP,
            EQ_MIN_PIVOT_GAP);
    $self->{_maximum_bars_between_pivots} =
        _positive_int_value($args{maximum_bars_between_pivots}
            // $config->{maximumBarsBetweenPivots}
            // EQ_MAX_PIVOT_GAP,
            EQ_MAX_PIVOT_GAP);
    $self->{_sweep_buffer_atr_factor} =
        _positive_number($args{sweep_buffer_atr_factor}
            // $config->{sweepBufferAtrFactor}
            // EQ_SWEEP_BUFFER_ATR_FACTOR)
        // EQ_SWEEP_BUFFER_ATR_FACTOR;
    $self->{_sweep_buffer_ticks} =
        _positive_number($args{sweep_buffer_ticks}
            // $config->{sweepBufferTicks}
            // LIQUIDITY_SWEEP_BUFFER_TICKS)
        // LIQUIDITY_SWEEP_BUFFER_TICKS;
    $self->{_liquidity_margin_atr_factor} =
        _positive_number($args{liquidity_margin_factor}
            // $config->{liquidityMarginFactor}
            // LIQUIDITY_MARGIN_ATR_FACTOR)
        // LIQUIDITY_MARGIN_ATR_FACTOR;
    $self->{_minimum_margin_ticks} =
        _positive_number($args{minimum_margin_ticks}
            // $config->{minimumMarginTicks}
            // LIQUIDITY_MINIMUM_MARGIN_TICKS)
        // LIQUIDITY_MINIMUM_MARGIN_TICKS;

    # Fase 1: los pivotes estructurales confirmados son la fuente primaria
    # para BSL/SSL y EQH/EQL. El detector local queda solo como fallback legacy
    # para tests/rutas que aun no entregan structure_pivots.
    my $provided_structure_pivots = defined($args{structure_pivots}) || defined($args{pivots});
    my @structure_swings = _normalize_structure_pivots(
        $args{structure_pivots} // $args{pivots},
        $candles,
        $max_visible_index,
        $args{show_internal_liquidity} // $config->{showInternalLiquidity} // 0,
    );
    my @swings = $provided_structure_pivots
        ? @structure_swings
        : _find_swing_points($candles, $max_visible_index);
    $self->_create_levels_from_swings(\@swings, $candles, $atr_series, $timeframe, $ext_levels, \@swings);
    $self->_absorb_equal_levels_into_liquidity($candles, $atr_series, $timeframe, $ext_levels);

    # Fase 2: avanzar maquina de estados solo sobre niveles vivos.
    my @levels_by_start = sort { $a->{start_index} <=> $b->{start_index} } @{ $self->{levels} };
    my @active_levels;
    my $next_level = 0;
    for my $i (0 .. $max_visible_index) {
        last if $i > $#$candles;
        while ($next_level <= $#levels_by_start
            && $levels_by_start[$next_level]{start_index} <= $i) {
            push @active_levels, $levels_by_start[$next_level++];
        }
        my $c = $candles->[$i];
        $self->_advance_state_list($c, $i, \@active_levels);
        @active_levels = grep { $_->{active} } @active_levels if @active_levels;
    }

    return {
        levels => $self->{levels},
        events => $self->{events},
    };
}

# ============================================================
#  Deteccion de Swing Highs y Swing Lows
# ============================================================

sub _find_swing_points {
    my ($candles, $max_idx) = @_;
    my @swings;
    my $k = SWING_K;

    for my $i ($k .. $max_idx) {
        last if $i + $k > $max_idx;  # necesitamos k velas a la derecha

        # Swing High: high[i] es maximo local en ventana [i-k, i+k]
        my $is_sh = 1;
        for my $j (1 .. $k) {
            if ($candles->[$i-$j]{high} >= $candles->[$i]{high}
             || $candles->[$i+$j]{high} >= $candles->[$i]{high}) {
                $is_sh = 0; last;
            }
        }
        if ($is_sh) {
            push @swings, {
                kind              => 'high',
                index             => $i,
                price             => $candles->[$i]{high},
                time              => $candles->[$i]{time},
                confirmed_at      => $i + $k,
                confirmed_time    => $candles->[$i + $k]{time},
                broke_structure   => 0,
                strength          => 'unknown',
            };
        }

        # Swing Low: low[i] es minimo local en ventana [i-k, i+k]
        my $is_sl = 1;
        for my $j (1 .. $k) {
            if ($candles->[$i-$j]{low} <= $candles->[$i]{low}
             || $candles->[$i+$j]{low} <= $candles->[$i]{low}) {
                $is_sl = 0; last;
            }
        }
        if ($is_sl) {
            push @swings, {
                kind              => 'low',
                index             => $i,
                price             => $candles->[$i]{low},
                time              => $candles->[$i]{time},
                confirmed_at      => $i + $k,
                confirmed_time    => $candles->[$i + $k]{time},
                broke_structure   => 0,
                strength          => 'unknown',
            };
        }
    }

    return sort { $a->{index} <=> $b->{index} } @swings;
}

# ============================================================
#  Creacion de niveles BSL/SSL/EQH/EQL desde swings
# ============================================================

sub _create_levels_from_swings {
    my ($self, $swings, $candles, $atr_series, $timeframe, $ext_levels, $equal_swings) = @_;

    my @highs = grep { $_->{kind} eq 'high' } @$swings;
    my @lows  = grep { $_->{kind} eq 'low'  } @$swings;
    my @equal_source = $equal_swings && @$equal_swings ? @$equal_swings : @$swings;
    my @equal_highs = grep { $_->{kind} eq 'high' } @equal_source;
    my @equal_lows  = grep { $_->{kind} eq 'low'  } @equal_source;

    # --- BSL: encima de cada Swing High ---
    for my $sh (@highs) {
        $self->_create_individual_liquidity_level(
            'BSL', $sh, $candles, $atr_series, $timeframe, $ext_levels,
        );
    }

    # --- SSL: debajo de cada Swing Low ---
    for my $sl (@lows) {
        $self->_create_individual_liquidity_level(
            'SSL', $sl, $candles, $atr_series, $timeframe, $ext_levels,
        );
    }

    for my $scope (_ordered_equal_scopes(\@equal_highs)) {
        my @scoped = grep { ($_->{scope} // 'legacy') eq $scope } @equal_highs;
        _create_equal_levels($self, \@scoped, 'EQH', $candles, $atr_series, $timeframe, $ext_levels);
    }
    for my $scope (_ordered_equal_scopes(\@equal_lows)) {
        my @scoped = grep { ($_->{scope} // 'legacy') eq $scope } @equal_lows;
        _create_equal_levels($self, \@scoped, 'EQL', $candles, $atr_series, $timeframe, $ext_levels);
    }

    return;
}

sub _create_individual_liquidity_level {
    my ($self, $side, $pivot, $candles, $atr_series, $timeframe, $ext_levels) = @_;
    return unless $pivot && defined $pivot->{index} && defined $pivot->{price};
    return unless defined $pivot->{confirmed_at};

    my $pivot_id = _pivot_id($pivot);
    $self->{_liquidity_by_source_pivot}{$side} ||= {};
    return if $self->{_liquidity_by_source_pivot}{$side}{$pivot_id};

    my $margin = _liquidity_margin_for_index($self, $atr_series, $pivot->{index});
    my $buffer = _sweep_buffer_for_index($self, $atr_series, $pivot->{index});
    my $base   = $pivot->{price} + 0;
    my ($zone_bottom, $zone_top, $outer) = $side eq 'BSL'
        ? ($base, $base + $margin, $base + $margin)
        : ($base - $margin, $base, $base - $margin);
    my $confirmed_at = $pivot->{confirmed_at} + 0;
    my $confirmed_time = $pivot->{confirmed_time}
        // ($candles && $confirmed_at <= $#$candles ? $candles->[$confirmed_at]{time} : undef);
    my $scope = $pivot->{scope} // _scope($base, $ext_levels);

    my $level = {
        id                    => _new_id(),
        type                  => $side,
        side                  => $side,
        sourceType            => $side eq 'BSL' ? 'SWING_HIGH' : 'SWING_LOW',
        source_type           => $side eq 'BSL' ? 'SWING_HIGH' : 'SWING_LOW',
        sourcePivotIds        => [$pivot_id],
        source_pivot_ids      => [$pivot_id],
        origin                => 'swing',
        timeframe             => $timeframe,
        price                 => $base,
        basePrice             => $base,
        base_price            => $base,
        outerPrice            => $outer,
        outer_price           => $outer,
        zoneTop               => $zone_top,
        zoneBottom            => $zone_bottom,
        zone_top              => $zone_top,
        zone_bottom           => $zone_bottom,
        liquidityMargin       => $margin,
        liquidity_margin      => $margin,
        start_index           => $confirmed_at,
        start_time            => $confirmed_time,
        createdAtIndex        => $confirmed_at,
        created_at_index      => $confirmed_at,
        createdAt             => $confirmed_at,
        created_at            => $confirmed_at,
        createdTime           => $confirmed_time,
        created_time          => $confirmed_time,
        confirmedAtIndex      => $confirmed_at,
        confirmed_at_index    => $confirmed_at,
        confirmedAt           => $confirmed_at,
        confirmed_at          => $confirmed_at,
        confirmedTime         => $confirmed_time,
        confirmed_time        => $confirmed_time,
        firstPivotIndex       => $pivot->{index},
        lastPivotIndex        => $pivot->{index},
        firstPivotTime        => $pivot->{time},
        lastPivotTime         => $pivot->{time},
        firstPivotPrice       => $base,
        lastPivotPrice        => $base,
        first_pivot_index     => $pivot->{index},
        last_pivot_index      => $pivot->{index},
        first_pivot_time      => $pivot->{time},
        last_pivot_time       => $pivot->{time},
        first_pivot_price     => $base,
        last_pivot_price      => $base,
        pivot_time            => $pivot->{time},
        pivot_index           => $pivot->{index},
        end_index             => undef,
        end_time              => undef,
        resolvedAtIndex       => undef,
        resolved_at_index     => undef,
        resolvedAt            => undef,
        resolved_at           => undef,
        status                => 'ACTIVE',
        state                 => 'DETECTED',
        active                => 1,
        strength              => 1,
        touchCount            => 0,
        touch_count           => 0,
        sweepIndex            => undef,
        sweep_index           => undef,
        breakIndex            => undef,
        break_index           => undef,
        renderObjectIds       => [],
        render_object_ids     => [],
        pivots                => [$pivot],
        tolerance             => $margin,
        minimum_tick          => $self->{_minimum_tick} // 0.01,
        sweep_buffer          => $buffer,
        internal_or_external  => $scope eq 'external' ? 'external' : 'internal',
        structure_scope       => $scope,
        volume_weights        => _vol_weight($self, $candles, $pivot->{index}),
        _sweep_index          => undef,
        _consecutive_out      => 0,
        _sweep_candidate      => undef,
    };

    push @{ $self->{levels} }, $level;
    $self->{_liquidity_by_source_pivot}{$side}{$pivot_id} = $level;
    return $level;
}

sub _create_equal_levels {
    my ($self, $points, $type, $candles, $atr_series, $timeframe, $ext_levels) = @_;
    return unless @$points >= 2;
    $self->{_atr_series} = $atr_series if defined $atr_series;

    my @sorted = sort {
        ($a->{confirmed_at} // $a->{index} // 0) <=> ($b->{confirmed_at} // $b->{index} // 0)
            || ($a->{index} // 0) <=> ($b->{index} // 0)
    } @$points;

    my @clusters;
    my $min_gap = $self->{_minimum_bars_between_pivots} // EQ_MIN_PIVOT_GAP;
    my $max_gap = $self->{_maximum_bars_between_pivots} // EQ_MAX_PIVOT_GAP;

    PIVOT:
    for my $cur (@sorted) {
        next unless defined $cur->{index} && defined $cur->{price};
        my $cur_confirm = $cur->{confirmed_at} // $cur->{index};
        my $cur_tol = _equal_tolerance_for_pivot($self, $atr_series, $cur->{index});

        for my $cluster (@clusters) {
            next unless $cluster->{_match_active};
            my $from = ($cluster->{_last_match_check_index} // $cluster->{created_at} // $cluster->{firstPivotIndex}) + 1;
            my $to   = ($cur->{index} // $cur_confirm) - 1;
            if (_equal_cluster_consumed_between($type, $candles, $cluster, $from, $to)) {
                $cluster->{_match_active} = 0;
            }
            else {
                $cluster->{_last_match_check_index} = $to if defined $to && $to >= $from;
            }
        }

        my ($best_cluster, $best_score);
        for my $cluster (@clusters) {
            next unless $cluster->{_match_active};
            next if _cluster_contains_pivot($cluster, $cur);

            my $bars_from_last = ($cur->{index} // 0) - ($cluster->{lastPivotIndex} // 0);
            next if $bars_from_last < $min_gap;
            next if $max_gap > 0 && $bars_from_last > $max_gap;

            my $tol = max($cur_tol, $cluster->{tolerance} // 0);
            my $dist = abs(($cur->{price} // 0) - ($cluster->{referenceLevel} // $cluster->{reference_level} // 0));
            next if $dist > $tol;
            next unless _pivot_fits_cluster($cur, $cluster, $tol);

            my $score = $dist - ((@{ $cluster->{memberPivots} // [] } >= 2) ? 0.000_001 : 0);
            if (!defined $best_score || $score < $best_score) {
                $best_score = $score;
                $best_cluster = $cluster;
            }
        }

        if ($best_cluster) {
            _append_pivot_to_equal_cluster($self, $best_cluster, $cur, $cur_tol, $candles, $timeframe, $ext_levels);
            next PIVOT;
        }

        push @clusters, _new_equal_seed_cluster($self, $type, $cur, $cur_tol, $atr_series);
    }
}

sub _new_equal_seed_cluster {
    my ($self, $type, $pivot, $tol, $atr_series) = @_;
    my $price = $pivot->{price} + 0;
    my $atr = _atr_at($atr_series, $pivot->{index}) // 0;
    my $minimum_tick = $self->{_minimum_tick} // 0.01;
    my $sweep_buffer = _sweep_buffer_for_index($self, $atr_series, $pivot->{index});
    my $liquidity_margin = _liquidity_margin_for_index($self, $atr_series, $pivot->{index});
    return {
        type                    => $type,
        scope                   => $pivot->{scope} // 'legacy',
        memberPivots            => [$pivot],
        member_pivots           => [$pivot],
        pivots                  => [$pivot],
        tolerance               => $tol + 0,
        referenceLevel          => $price,
        reference_level         => $price,
        firstPivotIndex         => $pivot->{index},
        lastPivotIndex          => $pivot->{index},
        firstPivotTime          => $pivot->{time},
        lastPivotTime           => $pivot->{time},
        firstPivotPrice         => $price,
        lastPivotPrice          => $price,
        first_pivot_index       => $pivot->{index},
        last_pivot_index        => $pivot->{index},
        first_pivot_time        => $pivot->{time},
        last_pivot_time         => $pivot->{time},
        first_pivot_price       => $price,
        last_pivot_price        => $price,
        upper_price             => $price,
        lower_price             => $price,
        minimum_tick            => $minimum_tick,
        sweep_buffer            => $sweep_buffer,
        liquidity_margin        => $liquidity_margin,
        _match_active           => 1,
        _last_match_check_index => $pivot->{confirmed_at} // $pivot->{index},
    };
}

sub _append_pivot_to_equal_cluster {
    my ($self, $cluster, $pivot, $pivot_tol, $candles, $timeframe, $ext_levels) = @_;

    push @{ $cluster->{memberPivots} }, $pivot;
    $cluster->{member_pivots} = $cluster->{memberPivots};
    $cluster->{pivots}        = $cluster->{memberPivots};
    $cluster->{tolerance}     = max($cluster->{tolerance} // 0, $pivot_tol // 0);
    $cluster->{lastPivotIndex} = $pivot->{index};
    $cluster->{lastPivotTime}  = $pivot->{time};
    $cluster->{lastPivotPrice} = $pivot->{price} + 0;
    $cluster->{last_pivot_index} = $cluster->{lastPivotIndex};
    $cluster->{last_pivot_time}  = $cluster->{lastPivotTime};
    $cluster->{last_pivot_price} = $cluster->{lastPivotPrice};
    $cluster->{sweep_buffer} = max(
        $cluster->{sweep_buffer} // 0,
        _sweep_buffer_for_index($self, $self->{_atr_series} // [], $pivot->{index}),
    );
    $cluster->{liquidity_margin} = max(
        $cluster->{liquidity_margin} // 0,
        _liquidity_margin_for_index($self, $self->{_atr_series} // [], $pivot->{index}),
    );
    _refresh_equal_cluster_prices($cluster);

    if (!$cluster->{level}) {
        my $created_at = $pivot->{confirmed_at} // $pivot->{index};
        my $created_time = $pivot->{confirmed_time}
            // ($candles && defined $created_at && $created_at <= $#$candles ? $candles->[$created_at]{time} : undef);

        my $level = {
            id                 => _new_id(),
            type               => $cluster->{type},
            origin             => 'equal_level',
            timeframe          => $timeframe,
            price              => $cluster->{referenceLevel},
            referenceLevel     => $cluster->{referenceLevel},
            reference_level    => $cluster->{referenceLevel},
            start_index        => $created_at,
            start_time         => $created_time,
            createdAt          => $created_at,
            created_at         => $created_at,
            createdTime        => $created_time,
            created_time       => $created_time,
            pivot_time         => $pivot->{time},
            end_index          => undef,
            end_time           => undef,
            resolvedAt         => undef,
            resolved_at        => undef,
            status             => 'ACTIVE',
            state              => 'DETECTED',
            active             => 1,
            internal_or_external => $cluster->{scope} eq 'external'
                                    ? 'external'
                                    : $cluster->{scope} eq 'internal'
                                    ? 'internal'
                                    : _scope($cluster->{referenceLevel}, $ext_levels),
            structure_scope     => $cluster->{scope},
            volume_weights     => _vol_weight($self, $candles, $pivot->{index}),
            _sweep_index       => undef,
            _consecutive_out   => 0,
            _sweep_candidate   => undef,
        };
        $cluster->{level} = $level;
        _sync_equal_level_fields($level, $cluster);
        push @{ $self->{levels} }, $level;
        return;
    }

    _sync_equal_level_fields($cluster->{level}, $cluster);
}

sub _refresh_equal_cluster_prices {
    my ($cluster) = @_;
    my @prices = map { $_->{price} + 0 } @{ $cluster->{memberPivots} // [] };
    return unless @prices;
    my $sum = 0;
    $sum += $_ for @prices;
    my $ref = $sum / scalar(@prices);
    $cluster->{referenceLevel} = $ref;
    $cluster->{reference_level} = $ref;
    $cluster->{upper_price} = max(@prices);
    $cluster->{lower_price} = min(@prices);
}

sub _sync_equal_level_fields {
    my ($level, $cluster) = @_;
    my $members = $cluster->{memberPivots} // [];
    return unless @$members >= 2;

    $level->{pivots}       = [ @$members ];
    $level->{memberPivots} = [ @$members ];
    $level->{member_pivots}= [ @$members ];
    $level->{referenceLevel} = $cluster->{referenceLevel} + 0;
    $level->{reference_level}= $cluster->{referenceLevel} + 0;
    $level->{tolerance}    = $cluster->{tolerance} + 0;
    $level->{firstPivotIndex} = $cluster->{firstPivotIndex};
    $level->{lastPivotIndex}  = $cluster->{lastPivotIndex};
    $level->{firstPivotTime}  = $cluster->{firstPivotTime};
    $level->{lastPivotTime}   = $cluster->{lastPivotTime};
    $level->{firstPivotPrice} = $cluster->{firstPivotPrice};
    $level->{lastPivotPrice}  = $cluster->{lastPivotPrice};
    $level->{first_pivot_index} = $cluster->{firstPivotIndex};
    $level->{last_pivot_index}  = $cluster->{lastPivotIndex};
    $level->{first_pivot_time}  = $cluster->{firstPivotTime};
    $level->{last_pivot_time}   = $cluster->{lastPivotTime};
    $level->{first_pivot_price} = $cluster->{firstPivotPrice};
    $level->{last_pivot_price}  = $cluster->{lastPivotPrice};
    $level->{upper_price} = $cluster->{upper_price};
    $level->{lower_price} = $cluster->{lower_price};
    $level->{minimum_tick} = $cluster->{minimum_tick};
    $level->{sweep_buffer} = $cluster->{sweep_buffer};
    $level->{liquidityMargin} = $cluster->{liquidity_margin};
    $level->{liquidity_margin} = $cluster->{liquidity_margin};
    $level->{structure_scope} = $cluster->{scope};

    my $is_eqh = ($cluster->{type} // '') eq 'EQH';
    my $base = $is_eqh ? $cluster->{upper_price} : $cluster->{lower_price};
    my $margin = $cluster->{liquidity_margin} // 0;
    my ($zone_bottom, $zone_top, $outer) = $is_eqh
        ? ($base, $base + $margin, $base + $margin)
        : ($base - $margin, $base, $base - $margin);
    $level->{side} = $is_eqh ? 'BSL' : 'SSL';
    $level->{sourceType} = $is_eqh ? 'EQUAL_HIGHS' : 'EQUAL_LOWS';
    $level->{source_type} = $level->{sourceType};
    $level->{sourcePivotIds} = [ map { _pivot_id($_) } @$members ];
    $level->{source_pivot_ids} = [ @{ $level->{sourcePivotIds} } ];
    $level->{basePrice} = $base + 0;
    $level->{base_price} = $base + 0;
    $level->{outerPrice} = $outer + 0;
    $level->{outer_price} = $outer + 0;
    $level->{zoneTop} = $zone_top + 0;
    $level->{zoneBottom} = $zone_bottom + 0;
    $level->{zone_top} = $zone_top + 0;
    $level->{zone_bottom} = $zone_bottom + 0;
    $level->{price} = $base + 0;
    $level->{strength} = scalar @$members;
    $level->{touchCount} //= 0;
    $level->{touch_count} //= $level->{touchCount};
}

sub _absorb_equal_levels_into_liquidity {
    my ($self, $candles, $atr_series, $timeframe, $ext_levels) = @_;
    return unless $self->{levels} && @{ $self->{levels} };

    my %remove;
    for my $eq (grep { ($_->{type} // '') eq 'EQH' || ($_->{type} // '') eq 'EQL' } @{ $self->{levels} }) {
        my $is_eqh = ($eq->{type} // '') eq 'EQH';
        my $side = $is_eqh ? 'BSL' : 'SSL';
        my $source_type = $is_eqh ? 'EQUAL_HIGHS' : 'EQUAL_LOWS';
        my $members = $eq->{memberPivots} // $eq->{member_pivots} // $eq->{pivots} // [];
        next unless $members && @$members >= 2;

        my @pivot_ids = map { _pivot_id($_) } @$members;
        my @existing = grep { defined $_ } map {
            $self->{_liquidity_by_source_pivot}{$side}{$_}
        } @pivot_ids;

        my $primary = @existing
            ? (sort {
                ($a->{firstPivotIndex} // $a->{pivot_index} // 0)
                    <=> ($b->{firstPivotIndex} // $b->{pivot_index} // 0)
                || ($a->{createdAtIndex} // $a->{start_index} // 0)
                    <=> ($b->{createdAtIndex} // $b->{start_index} // 0)
            } @existing)[0]
            : _liquidity_level_from_equal_cluster($self, $side, $members->[0], $candles, $atr_series, $timeframe, $ext_levels);
        next unless $primary;

        for my $lv (@existing) {
            next if ($lv->{id} // '') eq ($primary->{id} // '');
            $remove{ $lv->{id} } = 1;
        }

        my $base = $is_eqh
            ? max(map { $_->{price} + 0 } @$members)
            : min(map { $_->{price} + 0 } @$members);
        my $margin = max(
            $eq->{liquidityMargin} // $eq->{liquidity_margin} // 0,
            map { _liquidity_margin_for_index($self, $atr_series, $_->{index}) } @$members,
        );
        my $buffer = max(
            $eq->{sweep_buffer} // 0,
            map { _sweep_buffer_for_index($self, $atr_series, $_->{index}) } @$members,
        );
        my ($zone_bottom, $zone_top, $outer) = $is_eqh
            ? ($base, $base + $margin, $base + $margin)
            : ($base - $margin, $base, $base - $margin);

        my @sorted = sort { ($a->{index} // 0) <=> ($b->{index} // 0) } @$members;
        my $first = $sorted[0];
        my $last  = $sorted[-1];
        my $first_confirm = min(map { $_->{confirmed_at} // $_->{index} // 0 } @$members);
        my $cluster_confirm = $eq->{createdAt} // $eq->{created_at} // $eq->{start_index};

        $primary->{origin} = 'equal_liquidity';
        $primary->{side} = $side;
        $primary->{sourceType} = $source_type;
        $primary->{source_type} = $source_type;
        $primary->{sourceEqualLevelId} = $eq->{id};
        $primary->{source_equal_level_id} = $eq->{id};
        $primary->{sourcePivotIds} = [ @pivot_ids ];
        $primary->{source_pivot_ids} = [ @pivot_ids ];
        $primary->{pivots} = [ @$members ];
        $primary->{memberPivots} = [ @$members ];
        $primary->{member_pivots} = [ @$members ];
        $primary->{price} = $base + 0;
        $primary->{basePrice} = $base + 0;
        $primary->{base_price} = $base + 0;
        $primary->{outerPrice} = $outer + 0;
        $primary->{outer_price} = $outer + 0;
        $primary->{zoneTop} = $zone_top + 0;
        $primary->{zoneBottom} = $zone_bottom + 0;
        $primary->{zone_top} = $zone_top + 0;
        $primary->{zone_bottom} = $zone_bottom + 0;
        $primary->{liquidityMargin} = $margin + 0;
        $primary->{liquidity_margin} = $margin + 0;
        $primary->{tolerance} = max($primary->{tolerance} // 0, $eq->{tolerance} // 0);
        $primary->{sweep_buffer} = $buffer + 0;
        $primary->{strength} = scalar @$members;
        $primary->{firstPivotIndex} = $first->{index};
        $primary->{lastPivotIndex} = $last->{index};
        $primary->{firstPivotTime} = $first->{time};
        $primary->{lastPivotTime} = $last->{time};
        $primary->{firstPivotPrice} = $first->{price};
        $primary->{lastPivotPrice} = $last->{price};
        $primary->{first_pivot_index} = $first->{index};
        $primary->{last_pivot_index} = $last->{index};
        $primary->{first_pivot_time} = $first->{time};
        $primary->{last_pivot_time} = $last->{time};
        $primary->{first_pivot_price} = $first->{price};
        $primary->{last_pivot_price} = $last->{price};
        $primary->{createdAtIndex} = $primary->{createdAtIndex} // $first_confirm;
        $primary->{created_at_index} = $primary->{createdAtIndex};
        $primary->{confirmedAtIndex} = $cluster_confirm;
        $primary->{confirmed_at_index} = $cluster_confirm;
        $primary->{confirmedAt} = $cluster_confirm;
        $primary->{confirmed_at} = $cluster_confirm;
        $primary->{internal_or_external} = ($eq->{internal_or_external} // $primary->{internal_or_external});
        $primary->{structure_scope} = ($eq->{structure_scope} // $primary->{structure_scope});

        for my $pid (@pivot_ids) {
            $self->{_liquidity_by_source_pivot}{$side}{$pid} = $primary;
        }
    }

    if (%remove) {
        $self->{levels} = [ grep { !$remove{ $_->{id} // '' } } @{ $self->{levels} } ];
    }
    return;
}

sub _liquidity_level_from_equal_cluster {
    my ($self, $side, $pivot, $candles, $atr_series, $timeframe, $ext_levels) = @_;
    return unless $pivot;
    return $self->_create_individual_liquidity_level(
        $side, $pivot, $candles, $atr_series, $timeframe, $ext_levels,
    );
}

sub _cluster_contains_pivot {
    my ($cluster, $pivot) = @_;
    for my $p (@{ $cluster->{memberPivots} // [] }) {
        return 1 if defined $p->{index} && defined $pivot->{index}
                 && $p->{index} == $pivot->{index};
    }
    return 0;
}

sub _ordered_equal_scopes {
    my ($points) = @_;
    my %seen;
    $seen{ $_->{scope} // 'legacy' } = 1 for @{ $points // [] };
    my @preferred = grep { $seen{$_} } qw(external internal legacy);
    my @rest = sort grep { $_ ne 'external' && $_ ne 'internal' && $_ ne 'legacy' } keys %seen;
    return (@preferred, @rest);
}

sub _pivot_fits_cluster {
    my ($pivot, $cluster, $tol) = @_;
    for my $member (@{ $cluster->{memberPivots} // [] }) {
        return 0 if abs(($pivot->{price} // 0) - ($member->{price} // 0)) > $tol;
    }
    return 1;
}

sub _equal_cluster_consumed_between {
    my ($type, $candles, $cluster, $from, $to) = @_;
    return 0 unless $candles && @$candles && defined $from && defined $to;
    $from = 0 if $from < 0;
    $to = $#$candles if $to > $#$candles;
    return 0 if $from > $to;

    my $buffer = _sweep_buffer_for_level($cluster);
    my $boundary = _trigger_boundary_price($cluster);
    for my $i ($from .. $to) {
        my $c = $candles->[$i];
        next unless $c;
        return 1 if $type eq 'EQH' && ($c->{high} // 0) > $boundary + $buffer;
        return 1 if $type eq 'EQL' && ($c->{low}  // 0) < $boundary - $buffer;
    }
    return 0;
}

# ============================================================
#  Maquina de estados: avance por vela
# ============================================================

sub _advance_states {
    my ($self, $candle, $idx, $max_visible_index) = @_;
    $self->_advance_state_list($candle, $idx, $self->{levels});
}

sub _advance_state_list {
    my ($self, $candle, $idx, $levels) = @_;

    for my $lv (@$levels) {
        next unless $lv->{active};
        next if $idx < $lv->{start_index};   # nivel no existe aun

        my $base   = _trigger_boundary_price($lv);
        my $outer  = _outer_boundary_price($lv);
        my $buffer = _sweep_buffer_for_level($lv);
        my $is_bsl = ($lv->{type} eq 'BSL' || $lv->{type} eq 'EQH');
        my $eps    = ($lv->{minimum_tick} // 0.000_000_01) / 10;

        my $touched = $is_bsl
            ? (($candle->{high} // 0) >= $base - $eps)
            : (($candle->{low}  // 0) <= $base + $eps);
        if ($touched) {
            $lv->{touchCount} = ($lv->{touchCount} // 0) + 1;
            $lv->{touch_count} = $lv->{touchCount};
        }

        my $close_broken = $is_bsl
            ? (($candle->{close} // 0) > $outer + $eps)
            : (($candle->{close} // 0) < $outer - $eps);
        my $wick_swept = $is_bsl
            ? ((($candle->{high} // 0) > $outer + $eps)
                || (($candle->{high} // 0) > $base + $buffer + $eps))
            : ((($candle->{low} // 0) < $outer - $eps)
                || (($candle->{low} // 0) < $base - $buffer - $eps));
        my $close_reclaimed = $is_bsl
            ? (($candle->{close} // 0) <= $base + $eps)
            : (($candle->{close} // 0) >= $base - $eps);

        if ($close_broken) {
            $lv->{_sweep_candidate} = {
                swept_index => $idx,
                swept_price => $is_bsl ? $candle->{high} : $candle->{low},
                close_price => $candle->{close},
            };
            _resolve_level($self, $lv, 'BROKEN', 'RUN', $idx, $candle);
            next;
        }

        if ($wick_swept && $close_reclaimed) {
            $lv->{_sweep_candidate} = {
                swept_index => $idx,
                swept_price => $is_bsl ? $candle->{high} : $candle->{low},
                close_price => $candle->{close},
            };
            _resolve_level($self, $lv, 'SWEPT', 'SWEEP', $idx, $candle);
            next;
        }
    }
}

sub _resolve_level {
    my ($self, $lv, $status, $classification, $idx, $candle) = @_;
    $lv->{state}       = 'RESOLVED';
    $lv->{status}      = $status;
    $lv->{active}      = 0;
    $lv->{end_index}   = $idx;
    $lv->{end_time}    = $candle->{time};
    $lv->{resolvedAtIndex} = $idx;
    $lv->{resolved_at_index} = $idx;
    $lv->{resolvedAt}  = $idx;
    $lv->{resolved_at} = $idx;
    $lv->{resolvedTime} = $candle->{time};
    $lv->{resolved_time} = $candle->{time};
    if ($status eq 'BROKEN') {
        $lv->{breakIndex} = $idx;
        $lv->{break_index} = $idx;
    }
    else {
        $lv->{sweepIndex} = $idx;
        $lv->{sweep_index} = $idx;
        $lv->{_sweep_index} = $idx;
    }
    $self->_emit_event($lv, $classification, $idx, $candle);
}

sub _emit_event {
    my ($self, $lv, $classification, $resolved_idx, $candle) = @_;

    my $sc = $lv->{_sweep_candidate} // {};

    # Efecto proyectado segun clasificacion
    my $effect = $classification eq 'RUN'   ? 'BOS_WEIGHT'
               : $classification eq 'GRAB'  ? 'REVERSAL_ALERT'
               :                              'CHOCH_WEIGHT';   # SWEEP

    # Volume weight del sweep: candle donde ocurrio el barrido
    my $sweep_idx = $sc->{swept_index} // $resolved_idx;
    my $sweep_vw  = _vol_weight($self, $self->{_candles}, $sweep_idx);
    my $sweep_candle = (defined $sweep_idx && $self->{_candles} && $sweep_idx <= $#{ $self->{_candles} })
        ? $self->{_candles}[$sweep_idx]
        : undef;
    my $sweep_time = (defined $sweep_idx && $self->{_candles} && $sweep_idx <= $#{ $self->{_candles} })
        ? $self->{_candles}[$sweep_idx]{time}
        : undef;

    push @{ $self->{events} }, {
        id                 => _new_id(),
        level_id           => $lv->{id},
        timeframe          => $lv->{timeframe},
        direction          => ($lv->{type} eq 'BSL' || $lv->{type} eq 'EQH') ? 'up' : 'down',
        swept_index        => $sc->{swept_index},
        swept_time         => $sweep_time,
        swept_price        => $sc->{swept_price},
        swept_candle_high  => $sweep_candle ? $sweep_candle->{high} : undef,
        swept_candle_low   => $sweep_candle ? $sweep_candle->{low}  : undef,
        swept_candle_open  => $sweep_candle ? $sweep_candle->{open} : undef,
        swept_candle_close => $sweep_candle ? $sweep_candle->{close}: undef,
        close_price        => $sc->{close_price},
        state_path         => ['DETECTED', 'SWEPT',
                               ($classification eq 'RUN' ? 'ACCEPTANCE' : 'RECLAIMED'),
                               'RESOLVED'],
        classification     => $classification,
        resolved_index     => $resolved_idx,
        resolved_time      => $candle->{time},
        resolved_candle_high => $candle->{high},
        resolved_candle_low  => $candle->{low},
        confirmation_bars  => ($resolved_idx - ($sc->{swept_index} // $resolved_idx)),
        related_fvg_ids    => [],
        projected_effect   => $effect,
        internal_or_external => $lv->{internal_or_external},
        volume_weights     => {
            at_level => $lv->{volume_weights},
            at_sweep => $sweep_vw,
        },
    };
}

# ============================================================
#  Helpers
# ============================================================

sub _positive_number {
    my ($value) = @_;
    return undef unless defined $value;
    return undef unless "$value" =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$/i;
    $value += 0;
    return $value > 0 ? $value : undef;
}

sub _positive_int_value {
    my ($value, $fallback) = @_;
    return $fallback unless defined $value && "$value" =~ /^\d+$/;
    return $value + 0;
}

sub _infer_minimum_tick {
    my ($candles) = @_;
    return 0.01 unless $candles && @$candles;

    my %seen;
    for my $c (@$candles) {
        for my $field (qw(open high low close)) {
            next unless defined $c->{$field};
            my $v = sprintf('%.8f', $c->{$field} + 0);
            $v =~ s/0+$//;
            $v =~ s/\.$//;
            $seen{$v + 0} = 1;
        }
    }

    my @prices = sort { $a <=> $b } keys %seen;
    my $best;
    for my $i (1 .. $#prices) {
        my $diff = $prices[$i] - $prices[$i - 1];
        next if $diff <= 0.000_000_01;
        $best = $diff if !defined($best) || $diff < $best;
    }
    return defined $best && $best > 0 ? $best : 0.01;
}

sub _normalize_structure_pivots {
    my ($pivots, $candles, $max_idx, $include_internal) = @_;
    return () unless $pivots && ref($pivots) eq 'ARRAY' && @$pivots;

    my @candidates = grep {
        (($_->{kind} // '') eq 'high' || ($_->{kind} // '') eq 'low')
            && defined $_->{index}
            && defined($_->{confirmed_at})
            && $_->{confirmed_at} <= $max_idx
            && $_->{index} <= $max_idx
            && ($include_internal || (($_->{scope} // 'external') eq 'external'))
    } @$pivots;

    my @out;
    my %seen;
    for my $p (@candidates) {
        my $idx = $p->{index};
        next if !$candles || $idx < 0 || $idx > $#$candles;
        my $kind = $p->{kind};
        my $price = $kind eq 'high' ? $candles->[$idx]{high} : $candles->[$idx]{low};
        my $key = join(':', $kind, $idx, $p->{confirmed_at}, $p->{scope} // 'external');
        next if $seen{$key}++;
        push @out, {
            %$p,
            id             => $p->{id} // join('_', 'PIVOT', uc($kind), $idx, $p->{confirmed_at}),
            kind           => $kind,
            index          => $idx + 0,
            price          => $price + 0,
            time           => $p->{time} // $candles->[$idx]{time},
            confirmed_at   => $p->{confirmed_at} + 0,
            confirmed_time => $p->{confirmed_time}
                               // ($candles->[$p->{confirmed_at}] ? $candles->[$p->{confirmed_at}]{time} : undef),
        };
    }

    return sort {
        ($a->{confirmed_at} // 0) <=> ($b->{confirmed_at} // 0)
            || ($a->{index} // 0) <=> ($b->{index} // 0)
    } @out;
}

sub _atr_at {
    my ($atr_series, $idx) = @_;
    return undef unless defined $atr_series && defined $atr_series->[$idx];
    return $atr_series->[$idx];
}

sub _equal_tolerance_for_pivot {
    my ($self, $atr_series, $idx) = @_;
    my $atr = _atr_at($atr_series, $idx) // 0;
    my $threshold = $self->{_equal_level_threshold} // EQ_MATCH_FACTOR;
    my $tick = $self->{_minimum_tick} // 0.01;
    my $tick_distance = $self->{_minimum_tick_distance} // EQ_MINIMUM_TICK_DISTANCE;
    return max($tick * $tick_distance, $atr * $threshold);
}

sub _liquidity_margin_for_index {
    my ($self, $atr_series, $idx) = @_;
    my $atr = _atr_at($atr_series, $idx) // 0;
    my $tick = $self->{_minimum_tick} // 0.01;
    my $ticks = $self->{_minimum_margin_ticks} // LIQUIDITY_MINIMUM_MARGIN_TICKS;
    my $factor = $self->{_liquidity_margin_atr_factor} // LIQUIDITY_MARGIN_ATR_FACTOR;
    return max($tick * $ticks, $atr * $factor);
}

sub _sweep_buffer_for_index {
    my ($self, $atr_series, $idx) = @_;
    my $atr = _atr_at($atr_series, $idx) // 0;
    my $tick = $self->{_minimum_tick} // 0.01;
    my $ticks = $self->{_sweep_buffer_ticks} // LIQUIDITY_SWEEP_BUFFER_TICKS;
    my $factor = $self->{_sweep_buffer_atr_factor} // EQ_SWEEP_BUFFER_ATR_FACTOR;
    return max($tick * $ticks, $atr * $factor);
}

sub _pivot_id {
    my ($pivot) = @_;
    return $pivot->{id} if defined $pivot->{id} && $pivot->{id} ne '';
    return join(':',
        $pivot->{kind} // 'pivot',
        defined $pivot->{index} ? $pivot->{index} : 'NA',
        defined $pivot->{confirmed_at} ? $pivot->{confirmed_at} : 'NA',
        defined $pivot->{price} ? sprintf('%.8f', $pivot->{price} + 0) : 'NA',
    );
}

sub _trigger_boundary_price {
    my ($lv) = @_;
    my $type = $lv->{type} // '';
    return $lv->{basePrice} if defined $lv->{basePrice};
    return $lv->{base_price} if defined $lv->{base_price};
    return $lv->{upper_price} if $type eq 'EQH' && defined $lv->{upper_price};
    return $lv->{lower_price} if $type eq 'EQL' && defined $lv->{lower_price};
    return $lv->{price} // $lv->{referenceLevel} // $lv->{reference_level} // 0;
}

sub _outer_boundary_price {
    my ($lv) = @_;
    return $lv->{outerPrice} if defined $lv->{outerPrice};
    return $lv->{outer_price} if defined $lv->{outer_price};
    my $base = _trigger_boundary_price($lv);
    my $buffer = _sweep_buffer_for_level($lv);
    return (($lv->{type} // '') eq 'BSL' || ($lv->{type} // '') eq 'EQH')
        ? $base + $buffer
        : $base - $buffer;
}

sub _sweep_buffer_for_level {
    my ($lv) = @_;
    return $lv->{sweep_buffer} + 0 if defined $lv->{sweep_buffer};
    return $lv->{minimum_tick} + 0 if defined $lv->{minimum_tick};
    return 0;
}


# Retorna hash de pesado de volumen. Mantiene los campos legacy
# vol_at/vol_avg/vol_ratio, pero agrega persistencia multi-temporal
# obligatoria para 1m, 5m y 15m: m1, m5, m15, score, estimated.
sub _vol_weight {
    my ($self, $candles, $idx) = @_;
    return _empty_vol_weight()
        unless defined $candles && defined $idx && $idx <= $#$candles;

    my $vol_avg = $self->{_vol_avg} // [];
    my $vol_at  = $candles->[$idx]{volume} // 0;
    my $avg     = $vol_avg->[$idx] || 1;

    my $legacy = {
        vol_at    => $vol_at + 0,
        vol_avg   => sprintf("%.2f", $avg) + 0,
        vol_ratio => sprintf("%.2f", $vol_at / $avg) + 0,
    };

    my $start_time = $candles->[$idx]{time};
    my $end_time   = _add_minutes_iso($start_time, _tf_minutes($self->{_timeframe} // '1m'));
    if (defined $self->{_volume_until_time} && $self->{_volume_until_time} lt $end_time) {
        $end_time = $self->{_volume_until_time};
    }

    my $sources = $self->{_volume_sources} // {};
    my $source_indexes = $self->{_volume_source_indexes} // {};
    my $m1  = _source_volume_weight($sources->{'1m'},  $start_time, $end_time, $source_indexes->{'1m'});
    my $m5  = _source_volume_weight($sources->{'5m'},  $start_time, $end_time, $source_indexes->{'5m'});
    my $m15 = _source_volume_weight($sources->{'15m'}, $start_time, $end_time, $source_indexes->{'15m'});

    # Score compacto 0..1 para priorizar eventos con participacion relativa alta.
    # Se basa en ratios frente al promedio local de cada fuente disponible.
    my @ratios = grep { defined $_ } map { $_->{ratio} } ($m1, $m5, $m15);
    my $ratio_avg = @ratios ? _sum(@ratios) / scalar(@ratios) : ($legacy->{vol_ratio} // 0);
    my $score = $ratio_avg <= 0 ? 0 : $ratio_avg / 3.0;
    $score = 1 if $score > 1;

    my $estimated = ($m1->{estimated} || $m5->{estimated} || $m15->{estimated}) ? 1 : 0;

    return {
        %$legacy,
        m1        => $m1,
        m5        => $m5,
        m15       => $m15,
        score     => sprintf("%.3f", $score) + 0,
        estimated => $estimated,
    };
}

sub _empty_vol_weight {
    my $empty = { volume => 0, avg => 0, ratio => 0, candles => 0, estimated => 1 };
    return {
        vol_at    => 0,
        vol_avg   => 0,
        vol_ratio => 0,
        m1        => { %$empty },
        m5        => { %$empty },
        m15       => { %$empty },
        score     => 0,
        estimated => 1,
    };
}

sub _prepare_volume_source_indexes {
    my ($sources) = @_;
    return {} unless $sources;

    my %indexes;
    for my $tf (qw(1m 5m 15m)) {
        my $source = $sources->{$tf};
        next unless $source && @$source;
        $indexes{$tf} = _prepare_volume_source_index($source);
    }
    return \%indexes;
}

sub _prepare_volume_source_index {
    my ($source) = @_;
    my (@times, @prefix);
    $prefix[0] = 0;

    for my $i (0 .. $#$source) {
        my $c = $source->[$i];
        $times[$i] = $c->{time} // '';
        $prefix[$i + 1] = $prefix[$i] + ($c->{volume} // 0);
    }

    return {
        source => $source,
        times  => \@times,
        prefix => \@prefix,
    };
}

sub _source_volume_weight {
    my ($source, $start_time, $end_time, $source_index) = @_;
    return { volume => 0, avg => 0, ratio => 0, candles => 0, estimated => 1 }
        unless $source && @$source && defined $start_time && defined $end_time;

    return _source_volume_weight_indexed($source_index, $start_time, $end_time)
        if $source_index && $source_index->{times} && @{ $source_index->{times} };

    my ($sum, $cnt) = (0, 0);
    for my $c (@$source) {
        my $t = $c->{time};
        next unless defined $t;
        next if $t lt $start_time;
        last if $t ge $end_time;
        $sum += $c->{volume} // 0;
        $cnt++;
    }

    my $estimated = 0;
    if ($cnt == 0) {
        # Si el TF fuente es mayor que la ventana activa, usar la vela fuente
        # contenedora como aproximacion marcada. Esto mantiene estructura m1/m5/m15.
        my $container = _containing_candle($source, $start_time);
        if ($container) {
            $sum = $container->{volume} // 0;
            $cnt = 1;
            $estimated = 1;
        }
    }

    my $avg = _avg_volume_near($source, $start_time, 14) || 1;
    my $ratio = $avg > 0 ? $sum / $avg : 0;

    return {
        volume    => sprintf("%.2f", $sum) + 0,
        avg       => sprintf("%.2f", $avg) + 0,
        ratio     => sprintf("%.3f", $ratio) + 0,
        candles   => $cnt + 0,
        estimated => $estimated ? 1 : 0,
    };
}

sub _source_volume_weight_indexed {
    my ($idx, $start_time, $end_time) = @_;
    my $source = $idx->{source};
    my $times  = $idx->{times};
    my $prefix = $idx->{prefix};
    return { volume => 0, avg => 0, ratio => 0, candles => 0, estimated => 1 }
        unless $source && @$source && $times && @$times && $prefix;

    my $from = _lower_bound_time($times, $start_time);
    my $to   = _lower_bound_time($times, $end_time);
    my $cnt  = $to - $from;
    my $sum  = $prefix->[$to] - $prefix->[$from];

    my $estimated = 0;
    if ($cnt == 0) {
        my $pos = _upper_bound_time($times, $start_time) - 1;
        if ($pos >= 0) {
            $sum = $source->[$pos]{volume} // 0;
            $cnt = 1;
            $estimated = 1;
        }
    }

    my $avg = _avg_volume_near_indexed($idx, $start_time, 14) || 1;
    my $ratio = $avg > 0 ? $sum / $avg : 0;

    return {
        volume    => sprintf("%.2f", $sum) + 0,
        avg       => sprintf("%.2f", $avg) + 0,
        ratio     => sprintf("%.3f", $ratio) + 0,
        candles   => $cnt + 0,
        estimated => $estimated ? 1 : 0,
    };
}

sub _avg_volume_near_indexed {
    my ($idx, $time, $win) = @_;
    my $times  = $idx->{times};
    my $prefix = $idx->{prefix};
    return 0 unless $times && @$times && $prefix;

    my $pos = _upper_bound_time($times, $time) - 1;
    $pos = 0 if $pos < 0;
    my $from = $pos >= ($win - 1) ? $pos - $win + 1 : 0;
    my $cnt = $pos - $from + 1;
    my $sum = $prefix->[$pos + 1] - $prefix->[$from];
    return $cnt ? $sum / $cnt : 0;
}

sub _lower_bound_time {
    my ($times, $target) = @_;
    my ($lo, $hi) = (0, scalar @$times);
    while ($lo < $hi) {
        my $mid = int(($lo + $hi) / 2);
        if (($times->[$mid] // '') lt $target) {
            $lo = $mid + 1;
        }
        else {
            $hi = $mid;
        }
    }
    return $lo;
}

sub _upper_bound_time {
    my ($times, $target) = @_;
    my ($lo, $hi) = (0, scalar @$times);
    while ($lo < $hi) {
        my $mid = int(($lo + $hi) / 2);
        if (($times->[$mid] // '') le $target) {
            $lo = $mid + 1;
        }
        else {
            $hi = $mid;
        }
    }
    return $lo;
}

sub _containing_candle {
    my ($source, $time) = @_;
    my $last;
    for my $c (@$source) {
        my $t = $c->{time};
        next unless defined $t;
        last if $t gt $time;
        $last = $c;
    }
    return $last;
}

sub _avg_volume_near {
    my ($source, $time, $win) = @_;
    return 0 unless $source && @$source;
    my $pos = 0;
    for my $i (0 .. $#$source) {
        last if ($source->[$i]{time} // '') gt $time;
        $pos = $i;
    }
    my $from = $pos >= ($win - 1) ? $pos - $win + 1 : 0;
    my ($sum, $cnt) = (0, 0);
    for my $i ($from .. $pos) {
        $sum += $source->[$i]{volume} // 0;
        $cnt++;
    }
    return $cnt ? $sum / $cnt : 0;
}

sub _tf_minutes {
    my ($tf) = @_;
    return 1     if $tf eq '1m';
    return 5     if $tf eq '5m';
    return 15    if $tf eq '15m';
    return 60    if $tf eq '1h';
    return 120   if $tf eq '2h';
    return 240   if $tf eq '4h';
    return 1440  if $tf eq 'D';
    return 10080 if $tf eq 'W';
    return 1;
}

sub _add_minutes_iso {
    my ($iso, $minutes) = @_;
    return $iso unless defined $iso && $iso =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/;
    my ($Y, $Mo, $D, $h, $mi) = ($1+0, $2+0, $3+0, $4+0, $5+0);
    require Time::Local;
    my $epoch = Time::Local::timegm(0, $mi, $h, $D, $Mo - 1, $Y - 1900);
    $epoch += ($minutes || 1) * 60;
    my @g = gmtime($epoch);
    return sprintf("%04d-%02d-%02dT%02d:%02d:00", $g[5]+1900, $g[4]+1, $g[3], $g[2], $g[1]);
}

sub _sum {
    my $s = 0;
    $s += $_ for @_;
    return $s;
}

# Determina si un precio pertenece a liquidez interna o externa
# ext_levels: arrayref de { price, type } de TFs superiores
sub _scope {
    my ($price, $ext_levels) = @_;
    return 'internal' unless $ext_levels && @$ext_levels;
    for my $el (@$ext_levels) {
        return 'external' if abs($price - $el->{price}) < ($el->{tolerance} // 0.001);
    }
    return 'internal';
}

# Detecta swing points incrementalmente (modo update_last)
sub _detect_swing_points {
    my ($self, $market, $idx, $atr, $max_visible_index, $timeframe) = @_;
    my $k = SWING_K;
    return if $idx < $k || $idx + $k > $max_visible_index;

    my $pivot_idx = $idx - $k;
    my $c = $market->get_candle($pivot_idx);

    my $is_sh = 1;
    for my $j (1..$k) {
        my $prev = $market->get_candle($pivot_idx - $j);
        my $next = $market->get_candle($pivot_idx + $j);
        if ($prev->{high} >= $c->{high} || $next->{high} >= $c->{high}) {
            $is_sh = 0; last;
        }
    }
    if ($is_sh) {
        push @{ $self->{_swings} }, {
            kind         => 'high',
            index        => $pivot_idx,
            price        => $c->{high},
            time         => $c->{time},
            confirmed_at => $idx,
            confirmed_time => $market->get_candle($idx)->{time},
        };
        push @{ $self->{levels} }, {
            id                   => _new_id(),
            type                 => 'BSL',
            origin               => 'swing',
            timeframe            => $timeframe,
            price                => $c->{high},
            start_index          => $idx,
            start_time           => $market->get_candle($idx)->{time},
            pivot_time           => $c->{time},
            end_index            => undef,
            end_time             => undef,
            tolerance            => ($atr // 0) * EQ_FACTOR,
            state                => 'DETECTED',
            active               => 1,
            internal_or_external => 'internal',
            volume_weights       => { estimated => \1 },
            _sweep_index         => undef,
            _consecutive_out     => 0,
            _sweep_candidate     => undef,
        };
    }

    my $is_sl = 1;
    for my $j (1..$k) {
        my $prev = $market->get_candle($pivot_idx - $j);
        my $next = $market->get_candle($pivot_idx + $j);
        if ($prev->{low} <= $c->{low} || $next->{low} <= $c->{low}) {
            $is_sl = 0; last;
        }
    }
    if ($is_sl) {
        push @{ $self->{_swings} }, {
            kind         => 'low',
            index        => $pivot_idx,
            price        => $c->{low},
            time         => $c->{time},
            confirmed_at => $idx,
            confirmed_time => $market->get_candle($idx)->{time},
        };
        push @{ $self->{levels} }, {
            id                   => _new_id(),
            type                 => 'SSL',
            origin               => 'swing',
            timeframe            => $timeframe,
            price                => $c->{low},
            start_index          => $idx,
            start_time           => $market->get_candle($idx)->{time},
            pivot_time           => $c->{time},
            end_index            => undef,
            end_time             => undef,
            tolerance            => ($atr // 0) * EQ_FACTOR,
            state                => 'DETECTED',
            active               => 1,
            internal_or_external => 'internal',
            volume_weights       => { estimated => \1 },
            _sweep_index         => undef,
            _consecutive_out     => 0,
            _sweep_candidate     => undef,
        };
    }
}

1;

