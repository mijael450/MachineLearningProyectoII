package Market::Algorithms::MainSMC;

use strict;
use warnings;

# ============================================================
#  Market::Indicators::SMC_Structures
#
#  Detecta estructura de mercado SMC. No dibuja; solo calcula.
#
#  Produce:
#    pivots     : Swing Highs/Lows con label HH/HL/LH/LL y scope
#    structures : eventos BOS, CHoCH y MSS (solo por cierre de cuerpo)
#    fvgs       : Fair Value Gaps con estado active/mitigated/invalidated
#    fib_sets   : Fibonacci basico anclado al ultimo swing externo
#    premium_discount_zones : premium/equilibrium/discount por rango estructural
#
#  Reglas criticas:
#    - BOS valido: close[i] cruza el nivel estructural (no mecha)
#    - Cada nivel solo genera UN evento (hash de niveles rotos)
#    - CHoCH real: invalida major high/low y cambia tendencia
#    - FVG: desequilibrio de 3 velas (gap entre vela[i-2] y vela[i])
#    - reaction_zone se almacena como 0/1 (no referencia)
#    - Ningun calculo usa velas con index > max_visible_index
# ============================================================

use constant SWING_K             => 3;
use constant MXWLL_EXT_SENS      => 25;
use constant MXWLL_INT_SENS      => 3;
use constant FIB_RATIOS          => [0.236, 0.382, 0.5, 0.618, 0.786];
use constant FADE_RATE  => 0.03;
use constant INIT_OP    => 0.40;
use constant HR_OP      => 0.70;
use constant MIN_OP     => 0.05;

my $NEXT_ID = 1;
sub _new_id { 'SMC_' . sprintf('%04d', $NEXT_ID++) }

sub new  { bless {}, shift }
sub reset { $NEXT_ID = 1 }
sub get_values { [] }

sub compute_pivots {
    my ($class_or_self, %args) = @_;

    my $candles = $args{candles}           or die 'SMC::compute_pivots: falta candles';
    my $atr     = $args{atr_series}        // [];
    my $max_idx = $args{max_visible_index} // $#$candles;
    my $tf      = $args{timeframe}         // '1m';
    my $config  = $args{config}            // {};
    my $external_sens = $config->{externalStructureSensitivity} // MXWLL_EXT_SENS;
    my $internal_sens = $config->{internalStructureSensitivity}
                     // $config->{internalSwingLookback}
                     // MXWLL_INT_SENS;

    $NEXT_ID = 1;
    my ($pivots) = _build_pivots(
        $candles, $atr, $max_idx, $tf, $external_sens, $internal_sens,
    );
    return $pivots;
}

# ============================================================
#  Punto de entrada principal
# ============================================================

sub compute {
    my ($class_or_self, %args) = @_;

    my $candles   = $args{candles}           or die 'SMC::compute: falta candles';
    my $atr       = $args{atr_series}        // [];
    my $max_idx   = $args{max_visible_index} // $#$candles;
    my $tf        = $args{timeframe}         // '1m';
    my $liq_evts  = $args{liquidity_events}  // [];
    my $config    = $args{config}            // {};
    my $external_sens = $config->{externalStructureSensitivity} // MXWLL_EXT_SENS;
    my $internal_sens = $config->{internalStructureSensitivity}
                     // $config->{internalSwingLookback}
                     // MXWLL_INT_SENS;

    $NEXT_ID = 1;

    my ($pivots, $major_high, $major_low) = _build_pivots(
        $candles, $atr, $max_idx, $tf, $external_sens, $internal_sens,
    );
    my $structures = _build_structures($candles, $pivots, $max_idx, $tf, $liq_evts);
    my $trailing_extremes = _build_trailing_extremes(
        $candles, $pivots, $structures, $max_idx,
    );
    my $fvgs       = _build_fvgs(
        $candles, $atr, $max_idx, $tf, $liq_evts,
        $config->{fvgMinSizeAtrMultiplier} // 0,
    );
    my $fib_sets   = _build_fib_sets($candles, $pivots, $structures, $max_idx, $tf);
    my $pd_zones   = _build_premium_discount($pivots, $structures, $fib_sets, $max_idx, $tf);

    return {
        pivots                 => $pivots,
        structures             => $structures,
        trailing_extremes      => $trailing_extremes,
        fvgs                   => $fvgs,
        fib_sets               => $fib_sets,
        premium_discount_zones => $pd_zones,
        events                 => [ @$structures, @$fvgs, @$pd_zones ],
    };
}

# ============================================================
#  Pivots: deteccion, etiquetas HH/HL/LH/LL, scope
# ============================================================

sub _build_pivots {
    my ($candles, $atr_series, $max_idx, $tf, $external_sens, $internal_sens) = @_;
    $external_sens = _positive_int($external_sens, MXWLL_EXT_SENS);
    $internal_sens = _positive_int($internal_sens, MXWLL_INT_SENS);

    my @raw = (
        @{ _mxwll_pivots_for_length($candles, $atr_series, $max_idx, $tf, $external_sens, 'external') },
        @{ _mxwll_pivots_for_length($candles, $atr_series, $max_idx, $tf, $internal_sens, 'internal') },
    );

    @raw = sort {
        ($a->{confirmed_at} // 0) <=> ($b->{confirmed_at} // 0)
            || _scope_sort($a->{scope}) <=> _scope_sort($b->{scope})
            || ($a->{index} // 0) <=> ($b->{index} // 0)
            || (($a->{kind} // '') cmp ($b->{kind} // ''))
    } @raw;

    for my $p (@raw) {
        $p->{id}        = _new_id();
        $p->{timeframe} = $tf;
    }

    my @major_highs = grep { ($_->{scope}//'') eq 'external' && $_->{kind} eq 'high' } @raw;
    my @major_lows  = grep { ($_->{scope}//'') eq 'external' && $_->{kind} eq 'low'  } @raw;
    my $major_high = @major_highs ? $major_highs[-1] : undef;
    my $major_low  = @major_lows  ? $major_lows[-1]  : undef;

    return (\@raw, $major_high, $major_low);
}

sub _positive_int {
    my ($value, $fallback) = @_;
    return $fallback unless defined $value && $value =~ /^\d+$/ && $value > 0;
    return $value + 0;
}

sub _scope_sort {
    my ($scope) = @_;
    return ($scope // '') eq 'external' ? 0 : 1;
}

sub _mxwll_pivots_for_length {
    my ($candles, $atr_series, $max_idx, $tf, $length, $scope) = @_;

    my @out;
    my $intra_calc = 0;
    my $prev_upaxis = 0.0;
    my $prev_dnaxis = 0.0;
    my $rank = $scope eq 'external' ? 'major' : 'minor';

    for my $i (0 .. $max_idx) {
        last if $i > $#$candles;
        next unless $i > $length + 1;

        my $pivot_idx = $i - $length;
        next if $pivot_idx < 0;

        my $up = _max_high_between($candles, $pivot_idx + 1, $i);
        my $dn = _min_low_between($candles, $pivot_idx + 1, $i);
        next unless defined $up && defined $dn;

        my $pivot = $candles->[$pivot_idx];
        my $prev_intra_calc = $intra_calc;

        if (($pivot->{high} // 0) > $up) {
            $intra_calc = 0;
        }
        elsif (($pivot->{low} // 0) < $dn) {
            $intra_calc = 1;
        }

        if ($intra_calc == 0 && $prev_intra_calc != 0) {
            my $label = $scope eq 'external'
                ? (($pivot->{high} // 0) > $prev_upaxis ? 'HH' : 'LH')
                : undef;
            push @out, _mxwll_pivot(
                $candles, $atr_series, $tf, $scope, $rank, $length,
                'high', $pivot_idx, $i, $pivot->{high}, $label, $prev_upaxis,
            );
            $prev_upaxis = $pivot->{high} // $prev_upaxis;
        }

        if ($intra_calc == 1 && $prev_intra_calc != 1) {
            my $label = $scope eq 'external'
                ? (($pivot->{low} // 0) < $prev_dnaxis ? 'LL' : 'HL')
                : undef;
            push @out, _mxwll_pivot(
                $candles, $atr_series, $tf, $scope, $rank, $length,
                'low', $pivot_idx, $i, $pivot->{low}, $label, $prev_dnaxis,
            );
            $prev_dnaxis = $pivot->{low} // $prev_dnaxis;
        }
    }

    return \@out;
}

sub _mxwll_pivot {
    my ($candles, $atr_series, $tf, $scope, $rank, $length,
        $kind, $idx, $confirmed_at, $price, $label, $prev_axis_price) = @_;

    my %p = (
        kind              => $kind,
        index             => $idx,
        confirmed_at      => $confirmed_at,
        confirmed_time    => $candles->[$confirmed_at]{time},
        price             => $price,
        time              => $candles->[$idx]{time},
        atr               => $atr_series->[$idx],
        confirmation_atr  => $atr_series->[$confirmed_at],
        rank              => $rank,
        scope             => $scope,
        mxwll_sensitivity => $length,
        source_logic      => 'mxwll_calculatePivots',
    );

    if (defined $label) {
        $p{label} = $label;
        $p{label_scope} = 'external';
        $p{swing_label_valid} = 1;
        $p{swing_label_reason} = 'mxwll_external_pivot';
        $p{swing_label_prev_kind_price} = $prev_axis_price;
        $p{swing_label_delta} = abs(($price // 0) - ($prev_axis_price // 0));
    }
    else {
        $p{swing_label_valid} = 0;
        $p{swing_label_reason} = 'mxwll_internal_pivot';
    }

    return \%p;
}

sub _build_trailing_extremes {
    my ($candles, $pivots, $structures, $max_idx) = @_;
    return undef unless $candles && @$candles && $pivots && @$pivots;

    my @external = sort {
        ($a->{confirmed_at} // 0) <=> ($b->{confirmed_at} // 0)
            || ($a->{index} // 0) <=> ($b->{index} // 0)
    } grep {
        ($_->{scope} // '') eq 'external'
            && ($_->{confirmed_at} // 9_999_999) < $max_idx
    } @$pivots;

    my ($swing_high, $swing_low);
    for my $p (@external) {
        if (($p->{kind} // '') eq 'high') { $swing_high = $p }
        elsif (($p->{kind} // '') eq 'low') { $swing_low = $p }
    }
    return undef unless $swing_high && $swing_low;

    my ($top, $top_index, $top_time) =
        @{$swing_high}{qw(price index time)};
    my ($bottom, $bottom_index, $bottom_time) =
        @{$swing_low}{qw(price index time)};

    my $top_from = ($swing_high->{confirmed_at} // $swing_high->{index}) + 1;
    for my $i ($top_from .. $max_idx) {
        my $high = $candles->[$i]{high};
        next unless defined $high;
        if (!defined($top) || $high >= $top) {
            $top       = $high;
            $top_index = $i;
            $top_time  = $candles->[$i]{time};
        }
    }

    my $bottom_from = ($swing_low->{confirmed_at} // $swing_low->{index}) + 1;
    for my $i ($bottom_from .. $max_idx) {
        my $low = $candles->[$i]{low};
        next unless defined $low;
        if (!defined($bottom) || $low <= $bottom) {
            $bottom       = $low;
            $bottom_index = $i;
            $bottom_time  = $candles->[$i]{time};
        }
    }

    my ($bias, $bias_event, $bias_index) = ('neutral', undef, -1);
    for my $st (@{ $structures // [] }) {
        next unless ($st->{scope} // '') eq 'external';
        next unless ($st->{type} // '') eq 'BOS' || ($st->{type} // '') eq 'CHOCH';
        my $idx = $st->{confirmation_index} // $st->{break_index} // 9_999_999;
        next if $idx >= $max_idx || $idx < $bias_index;
        $bias       = $st->{direction} // $bias;
        $bias_event = $st;
        $bias_index = $idx;
    }

    return {
        top                       => $top,
        bottom                    => $bottom,
        last_top_index            => $top_index,
        last_top_time             => $top_time,
        last_bottom_index         => $bottom_index,
        last_bottom_time          => $bottom_time,
        structural_bias           => $bias,
        high_classification       => $bias eq 'bearish' ? 'strong_high' : 'weak_high',
        low_classification        => $bias eq 'bullish' ? 'strong_low' : 'weak_low',
        source_high_pivot_id      => $swing_high->{id},
        source_low_pivot_id       => $swing_low->{id},
        source_structure_event_id => $bias_event ? $bias_event->{id} : undef,
        status                    => 'active',
        source_logic              => 'smc_trailing_extremes',
    };
}

sub _rank_sequence {
    my ($pts, $kind) = @_;
    return unless @$pts;
    $pts->[0]{rank}  = 'major';
    return if @$pts == 1;

    for my $i (1 .. $#$pts) {
        my $prev = $pts->[$i-1];
        my $cur  = $pts->[$i];
        if ($kind eq 'high') {
            if ($cur->{price} > $prev->{price}) {
                $cur->{rank} = 'major';
            } else {
                $cur->{rank} = 'minor';
            }
        } else {
            if ($cur->{price} < $prev->{price}) {
                $cur->{rank} = 'major';
            } else {
                $cur->{rank} = 'minor';
            }
        }
    }
}

sub _label_significant_swings {
    my ($pts, $atr_multiplier, $min_bars, $impulse_override_multiplier) = @_;
    return unless $pts && @$pts;
    $atr_multiplier = 2.25 unless defined $atr_multiplier && $atr_multiplier > 0;
    $min_bars = 14 unless defined $min_bars && $min_bars >= 0;
    $impulse_override_multiplier = 1.15
        unless defined $impulse_override_multiplier && $impulse_override_multiplier > 0;

    for my $p (@$pts) {
        delete $p->{label};
        delete $p->{label_scope};
        $p->{swing_label_valid} = 0;
        $p->{swing_label_reason} = 'not_significant';
        $p->{swing_atr_multiplier} = $atr_multiplier;
        $p->{swing_label_min_bars} = $min_bars;
        $p->{swing_impulse_override_multiplier} = $impulse_override_multiplier;
    }

    my %last_by_kind;
    my $last_accepted;

    for my $cur (@$pts) {
        if (!$last_accepted) {
            _accept_swing_label(
                $cur, \%last_by_kind, $atr_multiplier, 'initial_anchor',
                undef, $impulse_override_multiplier,
            );
            $last_accepted = $cur;
            next;
        }

        my $atr = _swing_atr($cur);
        my $threshold = (defined $atr && $atr > 0) ? $atr * $atr_multiplier : undef;
        my $same_kind_ref = $last_by_kind{ $cur->{kind} };
        my $same_kind_delta = $same_kind_ref ? abs(($cur->{price} // 0) - ($same_kind_ref->{price} // 0)) : undef;
        my $leg_delta = abs(($cur->{price} // 0) - ($last_accepted->{price} // 0));
        my $bars_since_accepted = ($cur->{index} // 0) - ($last_accepted->{index} // 0);

        $cur->{swing_label_reference_price} = $same_kind_ref ? $same_kind_ref->{price} : undef;
        $cur->{swing_label_delta} = $same_kind_delta;
        $cur->{swing_leg_delta} = $leg_delta;
        $cur->{swing_label_threshold} = $threshold;
        $cur->{swing_label_min_bars} = $min_bars;
        $cur->{swing_bars_since_label} = $bars_since_accepted;
        $cur->{swing_impulse_override_multiplier} = $impulse_override_multiplier;
        my $is_impulse_override = defined $threshold
            && $leg_delta > ($threshold * $impulse_override_multiplier);
        $cur->{swing_impulse_override} = $is_impulse_override ? 1 : 0;

        if (!defined $threshold) {
            $cur->{swing_label_reason} = 'missing_atr';
            next;
        }

        if (($cur->{kind} // '') eq ($last_accepted->{kind} // '')) {
            if (_is_more_extreme($cur, $last_accepted) && $leg_delta > $threshold) {
                my $replacement_ref = defined $last_accepted->{swing_label_prev_kind_price}
                    ? { price => $last_accepted->{swing_label_prev_kind_price} }
                    : undef;
                _reject_swing_label($last_accepted, 'replaced_by_more_extreme_pivot');
                _accept_swing_label(
                    $cur, \%last_by_kind, $atr_multiplier, 'extended_extreme',
                    undef, $impulse_override_multiplier, $replacement_ref,
                );
                $last_accepted = $cur;
            }
            else {
                $cur->{swing_label_reason} = 'same_leg_not_more_extreme';
            }
            next;
        }

        if ($bars_since_accepted < $min_bars && !$is_impulse_override) {
            $cur->{swing_label_reason} = 'below_min_bars';
            next;
        }
        if ($same_kind_ref && $same_kind_delta <= $threshold) {
            $cur->{swing_label_reason} = 'below_same_kind_atr_threshold';
            next;
        }
        if ($leg_delta <= $threshold) {
            $cur->{swing_label_reason} = 'below_leg_atr_threshold';
            next;
        }

        _accept_swing_label(
            $cur, \%last_by_kind, $atr_multiplier,
            $is_impulse_override ? 'impulse_override' : 'atr_confirmed',
            undef, $impulse_override_multiplier,
        );
        $last_accepted = $cur;
    }
}

sub _accept_swing_label {
    my ($cur, $last_by_kind, $atr_multiplier, $reason, $forced_label,
        $impulse_override_multiplier, $label_ref) = @_;
    my $kind = $cur->{kind} // '';
    my $has_label_ref = @_ >= 7;
    my $ref = $has_label_ref ? $label_ref : $last_by_kind->{$kind};

    $cur->{label} = $forced_label // _swing_label_for($cur, $ref);
    $cur->{swing_label_prev_kind_price} = $ref ? $ref->{price} : undef;
    $cur->{label_scope} = 'external';
    $cur->{swing_label_valid} = 1;
    $cur->{swing_label_reason} = $reason;
    $cur->{swing_atr_multiplier} = $atr_multiplier;
    $cur->{swing_impulse_override_multiplier} = $impulse_override_multiplier
        if defined $impulse_override_multiplier;
    $last_by_kind->{$kind} = $cur;
}

sub _reject_swing_label {
    my ($p, $reason) = @_;
    delete $p->{label};
    delete $p->{label_scope};
    $p->{swing_label_valid} = 0;
    $p->{swing_label_reason} = $reason;
}

sub _swing_label_for {
    my ($cur, $ref) = @_;
    if (($cur->{kind} // '') eq 'high') {
        return (!$ref || $cur->{price} > $ref->{price}) ? 'HH' : 'LH';
    }
    return (!$ref || $cur->{price} < $ref->{price}) ? 'LL' : 'HL';
}

sub _is_more_extreme {
    my ($cur, $ref) = @_;
    return ($cur->{price} // 0) > ($ref->{price} // 0) if (($cur->{kind} // '') eq 'high');
    return ($cur->{price} // 0) < ($ref->{price} // 0);
}

sub _swing_atr {
    my ($cur) = @_;
    return $cur->{confirmation_atr} // $cur->{atr};
}

# ============================================================
#  BOS y CHoCH
#  Regla: cada nivel estructural solo genera UN evento.
#         Se usa %broken para evitar la cascada.
# ============================================================

sub _build_structures {
    my ($candles, $pivots, $max_idx, $tf, $liq_evts) = @_;

    my @confirmed = sort {
        ($a->{confirmed_at} // 0) <=> ($b->{confirmed_at} // 0)
            || _scope_sort($a->{scope}) <=> _scope_sort($b->{scope})
            || ($a->{index} // 0) <=> ($b->{index} // 0)
    } grep { ($_->{source_logic} // '') eq 'mxwll_calculatePivots' } @$pivots;

    return [] unless @confirmed;

    my %ctx = (
        external => { moving => 0, high => undef, low => undef, upside => 1, downside => 1 },
        internal => { moving => 0, high => undef, low => undef, upside => 1, downside => 1 },
    );
    my @out;
    my $ptr = 0;

    for my $i (1 .. $max_idx) {
        last if $i > $#$candles;
        my $c = $candles->[$i];

        # Igual que Mxwll: el pivot confirmado actualiza el eje activo y habilita
        # una unica ruptura para ese eje.
        while ($ptr <= $#confirmed && $confirmed[$ptr]{confirmed_at} <= $i) {
            my $p = $confirmed[$ptr];
            my $scope = $p->{scope} // 'internal';
            if (($p->{kind} // '') eq 'high') {
                $ctx{$scope}{high} = $p;
                $ctx{$scope}{upside} = 1;
            }
            else {
                $ctx{$scope}{low} = $p;
                $ctx{$scope}{downside} = 1;
            }
            $ptr++;
        }

        for my $scope (qw(external internal)) {
            my $hi = $ctx{$scope}{high};
            if ($hi && ($ctx{$scope}{upside} // 0) != 0 && _close_cross_over($candles, $i, $hi->{price})) {
                my $old_moving = $ctx{$scope}{moving} // 0;
                my $type = $old_moving < 0 ? 'CHOCH' : 'BOS';
                my $ev = _structure_event(
                    $type, 'bullish', $tf, $hi, $i, $c, $scope, $liq_evts, _moving_to_trend($old_moving),
                );
                push @out, $ev;
                push @out, _mss_event_from_choch($ev, _moving_to_trend($old_moving))
                    if $type eq 'CHOCH';
                $ctx{$scope}{upside} = 0;
                $ctx{$scope}{moving} = 1;
            }

            my $lo = $ctx{$scope}{low};
            if ($lo && ($ctx{$scope}{downside} // 0) != 0 && _close_cross_under($candles, $i, $lo->{price})) {
                my $old_moving = $ctx{$scope}{moving} // 0;
                my $type = $old_moving > 0 ? 'CHOCH' : 'BOS';
                my $ev = _structure_event(
                    $type, 'bearish', $tf, $lo, $i, $c, $scope, $liq_evts, _moving_to_trend($old_moving),
                );
                push @out, $ev;
                push @out, _mss_event_from_choch($ev, _moving_to_trend($old_moving))
                    if $type eq 'CHOCH';
                $ctx{$scope}{downside} = 0;
                $ctx{$scope}{moving} = -1;
            }
        }
    }

    return \@out;
}

sub _close_cross_over {
    my ($candles, $i, $level) = @_;
    return 0 unless $i > 0 && defined $level;
    my $prev = $candles->[$i - 1]{close};
    my $cur  = $candles->[$i]{close};
    return defined $prev && defined $cur && $cur > $level && $prev <= $level ? 1 : 0;
}

sub _close_cross_under {
    my ($candles, $i, $level) = @_;
    return 0 unless $i > 0 && defined $level;
    my $prev = $candles->[$i - 1]{close};
    my $cur  = $candles->[$i]{close};
    return defined $prev && defined $cur && $cur < $level && $prev >= $level ? 1 : 0;
}

sub _moving_to_trend {
    my ($moving) = @_;
    return 'bullish' if ($moving // 0) > 0;
    return 'bearish' if ($moving // 0) < 0;
    return 'unknown';
}

sub _structure_event {
    my ($type, $direction, $tf, $pivot, $i, $c, $scope, $liq_evts, $previous_trend) = @_;
    my $quality = _quality($c, $liq_evts, $i);
    my $display_type = $scope eq 'internal'
        ? ($type eq 'CHOCH' ? 'I-CHoCH' : 'I-BoS')
        : ($type eq 'CHOCH' ? 'CHoCH' : 'BoS');
    return {
        id             => _new_id(),
        type           => $type,
        display_type   => $display_type,
        direction      => $direction,
        timeframe      => $tf,
        pivot_id       => $pivot->{id},
        pivot_index    => $pivot->{index},
        pivot_time     => $pivot->{time},
        pivot_confirmed_at   => $pivot->{confirmed_at},
        pivot_confirmation_time => $pivot->{confirmed_time},
        break_index    => $i,
        break_time     => $c->{time},
        break_price    => $pivot->{price},
        close_price    => $c->{close},
        confirmation_index => $i,
        confirmation_time  => $c->{time},
        start_time     => $c->{time},
        price          => $pivot->{price},
        status         => 'confirmed',
        confirmed      => 1,
        break_mode     => 'close',
        scope          => $scope,
        previous_trend => $previous_trend // 'unknown',
        real_or_false  => $scope eq 'external' || $quality >= 0.65 ? 'real' : 'internal',
        quality_score  => $quality,
        liquidity_context => _near_liq($liq_evts, $i),
    };
}

sub _mss_event_from_choch {
    my ($choch, $previous_trend) = @_;
    return {
        %$choch,
        id                 => _new_id(),
        type               => 'MSS',
        display_type       => 'MSS',
        source_choch_id    => $choch->{id},
        previous_trend     => $previous_trend // $choch->{previous_trend} // 'unknown',
        quality_score      => (($choch->{quality_score} // 0.5) + 0.05 > 1)
                              ? 1 : (($choch->{quality_score} // 0.5) + 0.05),
        real_or_false      => ($choch->{scope} // '') eq 'external' ? 'real' : 'internal',
        liquidity_context  => $choch->{liquidity_context},
        status             => 'confirmed',
    };
}

sub _quality {
    my ($c, $liq_evts, $idx) = @_;
    my $body  = abs($c->{close} - $c->{open});
    my $range = $c->{high} - $c->{low};
    my $score = 0.5;
    $score += 0.2 if $range > 0 && ($body / $range) > 0.6;
    $score += 0.15 if _near_liq($liq_evts, $idx);
    return $score > 1 ? 1 : $score;
}

sub _near_liq {
    my ($liq_evts, $idx) = @_;
    return undef unless $liq_evts && @$liq_evts;
    my @near = grep {
        defined $_->{resolved_index} && abs($_->{resolved_index} - $idx) <= 5
    } @$liq_evts;
    return @near ? $near[-1]{id} : undef;
}

# ============================================================
#  FVG: Fair Value Gaps
#  reaction_zone se guarda como 0 o 1 (entero), no referencia,
#  para poder filtrarlo correctamente en Perl.
# ============================================================

sub _build_fvgs {
    my ($candles, $atr_series, $max_idx, $tf, $liq_evts, $min_size_atr_mult) = @_;
    $min_size_atr_mult //= 0;

    # Indice de swept_index de cada evento de liquidez
    my %liq_at;
    for my $ev (@{ $liq_evts // [] }) {
        my $si = $ev->{swept_index};
        next unless defined $si;
        $liq_at{$si} = $ev;
    }

    my @fvgs;

    for my $i (2 .. $max_idx) {
        last if $i > $#$candles;
        my $c0 = $candles->[$i-2];
        my $c2 = $candles->[$i];

        # Bullish FVG: low[i] > high[i-2]
        if ($c2->{low} > $c0->{high}) {
            my $gap_size = $c2->{low} - $c0->{high};
            next unless _fvg_size_allowed($gap_size, $atr_series, $i, $min_size_atr_mult);
            my $hr  = (exists $liq_at{$i-1} || exists $liq_at{$i-2}) ? 1 : 0;
            my $lev = $hr ? ($liq_at{$i-1} // $liq_at{$i-2}) : undef;
            push @fvgs, {
                id                        => _new_id(),
                timeframe                 => $tf,
                direction                 => 'bullish',
                start_index               => $i-2,
                middle_index              => $i-1,
                end_index                 => $i,
                start_time                => $c0->{time},
                middle_time               => $candles->[$i-1]{time},
                end_time                  => $c2->{time},
                gap_low                   => $c0->{high},
                gap_high                  => $c2->{low},
                status                    => 'active',
                reaction_zone             => $hr,
                source_liquidity_event_id => $lev ? $lev->{id} : undef,
                opacity                   => $hr ? HR_OP : INIT_OP,
                fade_start_index          => $i,
                fade_rate                 => FADE_RATE,
                formed_index              => $i,
                confirmation_index        => $i,
                confirmation_time         => $c2->{time},
                project_until_index       => $max_idx,
                project_until_time        => $candles->[$max_idx]{time},
            };
        }

        # Bearish FVG: high[i] < low[i-2]
        if ($c2->{high} < $c0->{low}) {
            my $gap_size = $c0->{low} - $c2->{high};
            next unless _fvg_size_allowed($gap_size, $atr_series, $i, $min_size_atr_mult);
            my $hr  = (exists $liq_at{$i-1} || exists $liq_at{$i-2}) ? 1 : 0;
            my $lev = $hr ? ($liq_at{$i-1} // $liq_at{$i-2}) : undef;
            push @fvgs, {
                id                        => _new_id(),
                timeframe                 => $tf,
                direction                 => 'bearish',
                start_index               => $i-2,
                middle_index              => $i-1,
                end_index                 => $i,
                start_time                => $c0->{time},
                middle_time               => $candles->[$i-1]{time},
                end_time                  => $c2->{time},
                gap_high                  => $c0->{low},
                gap_low                   => $c2->{high},
                status                    => 'active',
                reaction_zone             => $hr,
                source_liquidity_event_id => $lev ? $lev->{id} : undef,
                opacity                   => $hr ? HR_OP : INIT_OP,
                fade_start_index          => $i,
                fade_rate                 => FADE_RATE,
                formed_index              => $i,
                confirmation_index        => $i,
                confirmation_time         => $c2->{time},
                project_until_index       => $max_idx,
                project_until_time        => $candles->[$max_idx]{time},
            };
        }
    }

    _update_fvg_states(\@fvgs, $candles, $max_idx);
    return \@fvgs;
}

sub _fvg_size_allowed {
    my ($gap_size, $atr_series, $idx, $min_mult) = @_;
    return 1 unless ($min_mult // 0) > 0;
    my $atr = $atr_series && defined $atr_series->[$idx] ? $atr_series->[$idx] : undef;
    return 1 unless defined $atr && $atr > 0;
    return $gap_size >= $atr * $min_mult ? 1 : 0;
}

sub _update_fvg_states {
    my ($fvgs, $candles, $max_idx) = @_;
    for my $fvg (@$fvgs) {
        my $start_age = $fvg->{fade_start_index};
        my $resolved;
        for my $i ($fvg->{end_index}+1 .. $max_idx) {
            last if $i > $#$candles;
            my $c = $candles->[$i];

            # Fade: opacidad decrece con la edad
            my $age = $i - $start_age;
            my $op  = $fvg->{opacity} - $age * $fvg->{fade_rate};
            $fvg->{current_opacity} = $op < MIN_OP ? MIN_OP : $op;

            if ($fvg->{direction} eq 'bullish') {
                if ($c->{close} <= $fvg->{gap_low}) {
                    $resolved = [ invalidated => $i, $c->{time} ];
                    last;
                } elsif ($c->{low} <= $fvg->{gap_low}) {
                    $resolved = [ mitigated => $i, $c->{time} ];
                    last;
                }
            } else {
                if ($c->{close} >= $fvg->{gap_high}) {
                    $resolved = [ invalidated => $i, $c->{time} ];
                    last;
                } elsif ($c->{high} >= $fvg->{gap_high}) {
                    $resolved = [ mitigated => $i, $c->{time} ];
                    last;
                }
            }
        }
        if ($resolved) {
            my ($status, $idx, $time) = @$resolved;
            $fvg->{status} = $status;
            $fvg->{project_until_index} = $idx;
            $fvg->{project_until_time}  = $time;
            if ($status eq 'mitigated') {
                $fvg->{mitigation_index} = $idx;
                $fvg->{mitigation_time}  = $time;
            }
            else {
                $fvg->{invalidation_index} = $idx;
                $fvg->{invalidation_time}  = $time;
            }
        }
        else {
            $fvg->{status} = 'active';
            $fvg->{project_until_index} = $max_idx;
            $fvg->{project_until_time}  = $candles->[$max_idx]{time};
        }
        $fvg->{current_opacity} //= $fvg->{opacity};
    }
}

# ============================================================
#  Fibonacci basico
# ============================================================

sub _build_fib_sets {
    my ($candles, $pivots, $structures, $max_idx, $tf) = @_;

    my @ext_pivots = sort {
        ($a->{confirmed_at} // 0) <=> ($b->{confirmed_at} // 0)
            || ($a->{index} // 0) <=> ($b->{index} // 0)
    } grep {
        ($_->{scope}//'') eq 'external'
            && ($_->{source_logic}//'') eq 'mxwll_calculatePivots'
            && ($_->{confirmed_at} // 9_999_999) <= $max_idx
    } @$pivots;
    return [] unless @ext_pivots;

    my @highs = grep { $_->{kind} eq 'high' } @ext_pivots;
    my @lows  = grep { $_->{kind} eq 'low'  } @ext_pivots;
    return [] unless @highs && @lows;

    my $last = $ext_pivots[-1];
    my ($axis, $opposite);

    if (($last->{kind} // '') eq 'high') {
        $axis = _last_confirmed_before(\@lows, $last->{confirmed_at});
        return [] unless $axis;
        $opposite = _price_extreme_between($candles, 'low', $axis->{index}, $last->{confirmed_at});
        $opposite ||= $axis;
    }
    else {
        $axis = _last_confirmed_before(\@highs, $last->{confirmed_at});
        return [] unless $axis;
        $opposite = _price_extreme_between($candles, 'high', $axis->{index}, $last->{confirmed_at});
        $opposite ||= $axis;
    }

    my ($a, $b) = ($last, $opposite);
    ($a, $b) = ($b, $a) if ($b->{index} // 0) < ($a->{index} // 0);
    return [] unless defined $a->{price} && defined $b->{price};
    return [] if $a->{index} == $b->{index} || $a->{price} == $b->{price};

    my $direction = $b->{price} < $a->{price} ? 'bearish' : 'bullish';
    my $high = $a->{price} > $b->{price} ? $a->{price} : $b->{price};
    my $low  = $a->{price} < $b->{price} ? $a->{price} : $b->{price};
    my $range = $high - $low;
    return [] if $range <= 0;

    my @levels = map {
        my $price = $direction eq 'bullish'
            ? $high - $range * $_
            : $low  + $range * $_;
        {
            ratio => $_,
            price => $price,
        }
    } @{ FIB_RATIOS() };

    my $source_event = _structure_for_pivot($structures, $last->{id}, $max_idx);

    return [{
        id                 => _new_id(),
        timeframe          => $tf,
        anchor_start_index => $a->{index},
        anchor_end_index   => $b->{index},
        anchor_start_time  => $a->{time},
        anchor_end_time    => $b->{time},
        anchor_start_price => $a->{price},
        anchor_end_price   => $b->{price},
        anchor_high        => $high,
        anchor_low         => $low,
        source_event_id    => $source_event ? $source_event->{id} : undef,
        source_pivot_id    => $last->{id},
        source_pivot_kind  => $last->{kind},
        direction          => $direction,
        break_index        => $last->{confirmed_at},
        break_time         => $last->{confirmed_time},
        levels             => \@levels,
    }];
}

sub _build_premium_discount {
    my ($pivots, $structures, $fib_sets, $max_idx, $tf) = @_;
    my @out;
    my %seen;

    my @sets = @{ $fib_sets // [] };
    @sets = @sets > 8 ? @sets[-8 .. -1] : @sets;

    for my $fs (@sets) {
        my $high = $fs->{anchor_high};
        my $low  = $fs->{anchor_low};
        next unless defined $high && defined $low && $high > $low;
        my $key = join(':', $fs->{anchor_start_index}, $fs->{anchor_end_index}, $fs->{source_event_id} // '');
        next if $seen{$key}++;
        push @out, _pd_zone(
            $tf, $max_idx,
            start_index        => $fs->{anchor_start_index},
            start_time         => $fs->{anchor_start_time},
            confirmation_index => $fs->{break_index},
            confirmation_time  => $fs->{break_time},
            anchor_high        => $high,
            anchor_low         => $low,
            direction          => $fs->{direction},
            source_event_id    => $fs->{source_event_id},
            source_fib_id      => $fs->{id},
            source             => 'fibonacci_auto',
        );
    }

    # Fallback dinamico: Premium/Discount debe existir aunque no haya fib_set
    # en la ventana. Usa el ultimo rango estructural confirmado disponible.
    my @confirmed = grep { ($_->{confirmed_at} // 9_999_999) <= $max_idx } @{ $pivots // [] };
    my @highs = grep { $_->{kind} eq 'high' } @confirmed;
    my @lows  = grep { $_->{kind} eq 'low'  } @confirmed;
    if (@highs && @lows) {
        my $h = $highs[-1];
        my $l = $lows[-1];
        my ($a, $b) = ($h->{index} <= $l->{index}) ? ($h, $l) : ($l, $h);
        my $direction = $a->{kind} eq 'low' && $b->{kind} eq 'high' ? 'bullish' : 'bearish';
        my $key = join(':', $a->{index}, $b->{index}, 'current_range');
        if (!$seen{$key}++) {
            push @out, _pd_zone(
                $tf, $max_idx,
                start_index        => $a->{index},
                start_time         => $a->{time},
                confirmation_index => $b->{confirmed_at},
                confirmation_time  => $b->{confirmed_time},
                anchor_high        => $h->{price},
                anchor_low         => $l->{price},
                direction          => $direction,
                source_event_id    => undef,
                source_fib_id      => undef,
                source             => 'current_structure_range',
            );
        }
    }

    return \@out;
}

sub _pd_zone {
    my ($tf, $max_idx, %args) = @_;
    my $high = $args{anchor_high};
    my $low  = $args{anchor_low};
    return () unless defined $high && defined $low && $high > $low;
    my $eq = $low + (($high - $low) * 0.5);

    return {
        id                 => _new_id(),
        type               => 'premium_discount',
        timeframe          => $tf,
        source_event_id    => $args{source_event_id},
        source_fib_id      => $args{source_fib_id},
        source             => $args{source},
        direction          => $args{direction},
        start_index        => $args{start_index},
        start_time         => $args{start_time},
        confirmation_index => $args{confirmation_index},
        confirmation_time  => $args{confirmation_time},
        end_index          => $max_idx,
        project_until_index=> $max_idx,
        anchor_high        => $high,
        anchor_low         => $low,
        equilibrium_price  => $eq,
        premium_top        => $high,
        premium_bottom     => $eq,
        discount_top       => $eq,
        discount_bottom    => $low,
        status             => 'active',
    };
}

sub _max_high_between {
    my ($candles, $from, $to) = @_;
    return undef unless $candles && @$candles;
    $from = 0 if !defined($from) || $from < 0;
    $to = $#$candles if !defined($to) || $to > $#$candles;
    return undef if $from > $to;

    my $max;
    for my $i ($from .. $to) {
        next unless defined $candles->[$i]{high};
        $max = $candles->[$i]{high}
            if !defined $max || $candles->[$i]{high} > $max;
    }
    return $max;
}

sub _min_low_between {
    my ($candles, $from, $to) = @_;
    return undef unless $candles && @$candles;
    $from = 0 if !defined($from) || $from < 0;
    $to = $#$candles if !defined($to) || $to > $#$candles;
    return undef if $from > $to;

    my $min;
    for my $i ($from .. $to) {
        next unless defined $candles->[$i]{low};
        $min = $candles->[$i]{low}
            if !defined $min || $candles->[$i]{low} < $min;
    }
    return $min;
}

sub _price_extreme_between {
    my ($candles, $kind, $from, $to) = @_;
    return undef unless $candles && @$candles;
    $from = 0 if !defined($from) || $from < 0;
    $to = $#$candles if !defined($to) || $to > $#$candles;
    return undef if $from > $to;

    my ($best_idx, $best_price);
    for my $i ($from .. $to) {
        my $price = $kind eq 'high' ? $candles->[$i]{high} : $candles->[$i]{low};
        next unless defined $price;
        my $better = !defined $best_price
            || ($kind eq 'high' ? $price > $best_price : $price < $best_price);
        if ($better) {
            $best_idx = $i;
            $best_price = $price;
        }
    }
    return undef unless defined $best_idx;

    return {
        kind         => $kind,
        index        => $best_idx,
        time         => $candles->[$best_idx]{time},
        price        => $best_price,
        source_logic => 'mxwll_fib_extreme',
    };
}

sub _last_confirmed_before {
    my ($arr, $idx) = @_;
    my $last;
    for my $p (@$arr) {
        last if ($p->{confirmed_at} // 9_999_999) > $idx;
        $last = $p;
    }
    return $last;
}

sub _structure_for_pivot {
    my ($structures, $pivot_id, $max_idx) = @_;
    return undef unless defined $pivot_id;
    my $last;
    for my $st (@{ $structures // [] }) {
        next unless ($st->{pivot_id} // '') eq $pivot_id;
        next if ($st->{type} // '') eq 'MSS';
        next if ($st->{break_index} // 9_999_999) > $max_idx;
        $last = $st;
    }
    return $last;
}

sub _last_before {
    my ($arr, $idx) = @_;
    my $last;
    for my $p (@$arr) {
        last if ($p->{index} // 9_999_999) > $idx;
        $last = $p;
    }
    return $last;
}

1;

