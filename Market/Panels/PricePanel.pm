package Market::Panels::PricePanel;
use strict;
use warnings;
use lib ".";
use Market::Panels::Scales;

sub new {
    my ($class) = @_;
    bless { scale => Market::Panels::Scales->new() }, $class;
}

sub draw {
    my ($self, $canvas, $data, $x_of, $state) = @_;
    my $left = $state->{left};
    my $right = $state->{right};
    my $top = $state->{top};
    my $height = $state->{price_h};
    my $bar_w = $state->{bar_w};
    my $scale_w = $state->{scale_w};
    my $w = $state->{w};

    my ($min, $max);
    if ((!$state->{auto_y} || $state->{lock_y}) && defined $state->{price_min} && defined $state->{price_max}) {
        $min = $state->{price_min};
        $max = $state->{price_max};
    } else {
        ($min, $max) = _range_price($data);
        $min = $state->{overlay_price_min}
            if defined($state->{overlay_price_min}) && $state->{overlay_price_min} < $min;
        $max = $state->{overlay_price_max}
            if defined($state->{overlay_price_max}) && $state->{overlay_price_max} > $max;
        my $pad = ($max - $min) * 0.08 || 1;
        $min -= $pad;
        $max += $pad;
        $state->{price_min} = $min;
        $state->{price_max} = $max;
    }

    _grid_price($canvas, $self->{scale}, $min, $max, $top, $height, $left, $right, $w, $scale_w);

    # Optimización: si hay más velas visibles que píxeles útiles, se agrupan varias
    # velas en una sola vela visual por columna/píxel. Esto evita crear miles de
    # rectángulos y líneas cuando el timeframe es 1m/5m y se aleja mucho el zoom.
    my $visible_count = scalar(@$data);
    my $plot_w = $right - $left;
    my $use_grouping = ($visible_count > $plot_w * 1.15 || $bar_w <= 1.2) ? 1 : 0;
    my @items = $use_grouping
        ? _build_pixel_groups($data, $x_of, $left, $right)
        : _build_direct_items($data, $x_of, $left, $right, $bar_w);

    my $bottom = $top + $height;
    for my $item (@items) {
        my $c = $item->{c};
        my $x = $item->{x};
        next if $x < $left - 2 || $x > $right + 2;

        my $yo = $self->{scale}->price_to_y($c->{open},  $min, $max, $top, $height);
        my $yh = $self->{scale}->price_to_y($c->{high},  $min, $max, $top, $height);
        my $yl = $self->{scale}->price_to_y($c->{low},   $min, $max, $top, $height);
        my $yc = $self->{scale}->price_to_y($c->{close}, $min, $max, $top, $height);
        my $color = ($c->{close} >= $c->{open}) ? '#089981' : '#f23645';

        $yo = _clip_y($yo, $top, $bottom);
        $yh = _clip_y($yh, $top, $bottom);
        $yl = _clip_y($yl, $top, $bottom);
        $yc = _clip_y($yc, $top, $bottom);

        my $body_top = $yo < $yc ? $yo : $yc;
        my $body_bot = $yo > $yc ? $yo : $yc;
        $body_bot = $body_top + 1 if $body_bot - $body_top < 1;

        my $draw_w = $use_grouping ? 1.0 : $bar_w;
        $draw_w = 1 if $draw_w < 1;
        my $x_left  = $x - $draw_w / 2;
        my $x_right = $x + $draw_w / 2;

        $x_left  = $left  + 1 if $x_left  < $left + 1;
        $x_right = $right - 3 if $x_right > $right - 3;
        next if $x_right <= $x_left;

        my $wick_x = int(($x_left + $x_right) / 2);
        my $outline = ($bar_w >= 2 && !$use_grouping)
            ? (($c->{close} >= $c->{open}) ? '#0ecfa0' : '#ff4d5e')
            : $color;

        $canvas->createRectangle($x_left, $body_top, $x_right, $body_bot,
            -fill => $color, -outline => $outline, -tags => 'data');

        if ($yh < $body_top) {
            $canvas->createLine($wick_x, $yh, $wick_x, $body_top, -fill => $color, -tags => 'data');
        }
        if ($yl > $body_bot) {
            $canvas->createLine($wick_x, $body_bot, $wick_x, $yl, -fill => $color, -tags => 'data');
        }
    }

    _draw_volume_items($canvas, \@items, $state);
    _header($canvas, $data, $state);
    _draw_last_price_line($canvas, $self->{scale}, $state, $min, $max, $top, $height, $left, $right, $w, $scale_w);
}

sub _build_direct_items {
    my ($data, $x_of, $left, $right, $bar_w) = @_;
    my @items;
    for my $i (0 .. $#$data) {
        my $x = $x_of->($i);
        next if $x < $left - $bar_w || $x > $right + $bar_w;
        push @items, { x => $x, c => $data->[$i] };
    }
    return @items;
}

sub _build_pixel_groups {
    my ($data, $x_of, $left, $right) = @_;
    my @groups;
    for my $i (0 .. $#$data) {
        my $x = $x_of->($i);
        next if $x < $left - 2 || $x > $right + 2;
        my $bucket = int($x + 0.5);
        $bucket = int($left) if $bucket < $left;
        $bucket = int($right) if $bucket > $right;
        my $c = $data->[$i];
        if (!$groups[$bucket]) {
            $groups[$bucket] = {
                x => $bucket,
                c => {
                    open => $c->{open}, high => $c->{high}, low => $c->{low},
                    close => $c->{close}, volume => $c->{volume} || 0,
                },
            };
        } else {
            my $g = $groups[$bucket]{c};
            $g->{high} = $c->{high} if $c->{high} > $g->{high};
            $g->{low}  = $c->{low}  if $c->{low}  < $g->{low};
            $g->{close} = $c->{close};
            $g->{volume} += $c->{volume} || 0;
        }
    }
    return grep { defined $_ } @groups;
}

sub _clip_y {
    my ($y, $top, $bottom) = @_;
    return $top if $y < $top;
    return $bottom if $y > $bottom;
    return $y;
}

sub _range_price {
    my ($data) = @_;
    my ($min, $max);
    for my $c (@$data) {
        $min = $c->{low}  if !defined($min) || $c->{low}  < $min;
        $max = $c->{high} if !defined($max) || $c->{high} > $max;
    }
    return ($min || 0, $max || 1);
}

sub _grid_price {
    my ($canvas, $scale, $min, $max, $top, $height, $left, $right, $w, $scale_w) = @_;
    my $step = $scale->nice_step($max - $min, $height);

    $step = 0.25 if $step < 0.25;
    $step = int($step / 0.25 + 0.999999) * 0.25;
    my $first = int($min / $step) * $step;
    my $count = 0;
    for (my $p = $first; $p <= $max + $step; $p += $step) {
        next if $p < $min;
        last if ++$count > 40; # seguridad: nunca saturar Tk con demasiados textos
        my $y = $scale->price_to_y($p, $min, $max, $top, $height);
        $canvas->createLine($left, $y, $right, $y, -fill => '#1e222d', -tags => 'grid');
        $canvas->createText($w - $scale_w + 5, $y, -anchor => 'w', -text => sprintf('%.2f', $p), -fill => '#787b86', -tags => 'scale');
    }
    $canvas->createLine($right, $top, $right, $top + $height, -fill => '#2a2e39', -tags => 'scale');
}

sub _draw_volume_items {
    my ($canvas, $items, $state) = @_;
    my $top = $state->{top} + $state->{price_h} - $state->{vol_h};
    my $h = $state->{vol_h};
    my $bar_w = $state->{bar_w};
    my $maxv = 1;
    for my $it (@$items) { $maxv = $it->{c}{volume} if ($it->{c}{volume} || 0) > $maxv; }
    my $draw_w = $bar_w < 1.2 ? 1 : $bar_w;
    for my $it (@$items) {
        my $c = $it->{c};
        my $x = $it->{x};
        my $vh = (($c->{volume} || 0) / $maxv) * $h;
        my $color = ($c->{close} >= $c->{open}) ? '#1a3f3a' : '#3f1a1e';
        $canvas->createRectangle($x - $draw_w/2, $top + $h - $vh, $x + $draw_w/2, $top + $h,
            -fill => $color, -outline => $color, -tags => 'volume');
    }
    my $lastv = @$items ? $items->[-1]{c}{volume} : 0;
    $canvas->createText($state->{left} + 8, $top + 15, -anchor => 'w', -text => 'Vol. ' . _fmt_k($lastv), -fill => '#787b86', -tags => 'overlay');
}

sub _fmt_k {
    my ($v) = @_;
    return sprintf('%.2f K', $v / 1000) if $v >= 1000;
    return $v;
}

sub _header {
    my ($canvas, $data, $state) = @_;
    return if !@$data;
    # Conservado para no cambiar funcionalidad: el header OHLC lo maneja el crosshair.
}

sub _draw_last_price_line {
    my ($canvas, $scale, $state, $min, $max, $top, $height, $left, $right, $w, $scale_w) = @_;

    my $last = $state->{last_candle};
    return if !defined $last;

    my $close = $last->{close};
    my $open  = $last->{open};
    my $color = ($close >= $open) ? '#089981' : '#f23645';

    my $y = $scale->price_to_y($close, $min, $max, $top, $height);
    my $price_bottom = $top + $height - $state->{vol_h};
    return if $y < $top || $y > $price_bottom;

    $canvas->createLine($left, $y, $right, $y,
        -fill  => $color,
        -dash  => [3, 3],
        -width => 1,
        -tags  => 'overlay'
    );

    my $label = sprintf('%.2f', $close);
    $canvas->createRectangle($right + 2, $y - 9, $w - $scale_w + 88, $y + 9,
        -fill => $color, -outline => $color, -tags => 'overlay');
    $canvas->createText($right + 6, $y,
        -anchor => 'w', -text => $label, -fill => '#ffffff',
        -font => ['Arial', 8, 'bold'], -tags => 'overlay');
}

1;
