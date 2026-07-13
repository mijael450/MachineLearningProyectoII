package Market::Panels::ATRPanel;
use strict;
use warnings;
use lib ".";
use Market::Panels::Scales;

sub new { bless { scale => Market::Panels::Scales->new() }, shift }

sub draw {
    my ($self, $canvas, $atr, $x_of, $state) = @_;
    my $top = $state->{atr_top};
    my $h = $state->{atr_h};
    my $left = $state->{left};
    my $right = $state->{right};
    my $w = $state->{w};
    my $scale_w = $state->{scale_w};

    my ($min, $max);
    my $atr_auto = exists $state->{auto_atr} ? $state->{auto_atr} : $state->{auto_y};
    if ((!$atr_auto || $state->{lock_y}) && defined $state->{atr_min} && defined $state->{atr_max}) {
        $min = $state->{atr_min};
        $max = $state->{atr_max};
    } else {
        ($min, $max) = _range_atr($atr);
        my $pad = ($max - $min) * 0.10 || 1;
        $min -= $pad;
        $max += $pad;
        $state->{atr_min} = $min;
        $state->{atr_max} = $max;
    }

    my $step = $self->{scale}->nice_step($max - $min, $h);
    my $first = int($min / $step) * $step;
    my $count = 0;
    for (my $p = $first; $p <= $max + $step; $p += $step) {
        next if $p < $min;
        last if ++$count > 30;
        my $y = $self->{scale}->price_to_y($p, $min, $max, $top, $h);
        next if $y < $top + 14;
        next if $y > $top + $h - 14;
        $canvas->createLine($left, $y, $right, $y, -fill => '#1e222d', -tags => 'grid');
        $canvas->createText($w - $scale_w + 5, $y, -anchor => 'w', -text => sprintf('%.2f', $p), -fill => '#787b86', -tags => 'scale');
    }

    # Optimización: si hay más puntos ATR que píxeles útiles, conservar un solo
    # punto por píxel. Visualmente no se pierde información perceptible y Tk dibuja
    # muchos menos segmentos.
    my @pts = _atr_points_reduced($atr, $x_of, $self->{scale}, $min, $max, $top, $h, $left, $right);
    $canvas->createLine(@pts, -fill => '#e05c5c', -width => 1.4, -tags => 'atr') if @pts >= 4;

    my $value;
    if (defined $state->{mouse_index}) {
        my $idx = $state->{mouse_index} - ($state->{start_index} // 0);
        if ($idx >= 0 && $idx <= $#$atr && defined $atr->[$idx]) {
            $value = $atr->[$idx];
        }
    }
    $value = _last_defined($atr) if !defined $value;

    my $label = defined $value ? sprintf('ATR 14 RMA   %.2f', $value) : 'ATR 14 RMA';
    $canvas->createText($left + 8, $top + 16, -anchor => 'w', -text => $label, -fill => '#e05c5c', -tags => 'overlay');
}

sub _atr_points_reduced {
    my ($atr, $x_of, $scale, $min, $max, $top, $h, $left, $right) = @_;
    my @pts;
    my %bucket;

    my $count = scalar(@$atr);
    my $plot_w = $right - $left;
    my $reduce = ($count > $plot_w * 1.5) ? 1 : 0;

    for my $i (0 .. $#$atr) {
        next if !defined $atr->[$i];
        my $x = $x_of->($i);
        next if $x < $left || $x > $right;
        my $y = $scale->price_to_y($atr->[$i], $min, $max, $top, $h);
        $y = _clip_y($y, $top, $top + $h);

        if ($reduce) {
            my $b = int($x + 0.5);
            $bucket{$b} = $y; # último valor visible del píxel
        } else {
            push @pts, ($x, $y);
        }
    }

    if ($reduce) {
        for my $b (sort { $a <=> $b } keys %bucket) {
            push @pts, ($b, $bucket{$b});
        }
    }
    return @pts;
}

sub _clip_y {
    my ($y, $top, $bottom) = @_;
    return $top if $y < $top;
    return $bottom if $y > $bottom;
    return $y;
}

sub _range_atr_visible {
    my ($atr, $start, $end) = @_;
    my ($min, $max);
    $start = 0 if !defined($start) || $start < 0;
    $end = $#$atr if !defined($end) || $end > $#$atr;
    for my $i ($start .. $end) {
        next if !defined $atr->[$i];
        $min = $atr->[$i] if !defined($min) || $atr->[$i] < $min;
        $max = $atr->[$i] if !defined($max) || $atr->[$i] > $max;
    }
    $min = 0 if !defined $min;
    $max = 1 if !defined $max;
    return ($min, $max);
}

sub _range_atr {
    my ($atr) = @_;
    my ($min, $max);
    for my $v (@$atr) {
        next if !defined $v;
        $min = $v if !defined($min) || $v < $min;
        $max = $v if !defined($max) || $v > $max;
    }
    return ($min || 0, $max || 1);
}

sub _last_defined {
    my ($arr) = @_;
    for (my $i = $#$arr; $i >= 0; $i--) { return $arr->[$i] if defined $arr->[$i]; }
    return undef;
}

1;
