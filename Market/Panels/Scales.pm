package Market::Panels::Scales;
use strict;
use warnings;

sub new { bless {}, shift }

sub nice_step {
    my ($self, $range, $pixels) = @_;

    $pixels = 100 if !defined($pixels) || $pixels <= 0;
    return 1 if !defined($range) || $range <= 0;

    my $target = $range / ($pixels / 70);
    return 1 if !defined($target) || $target <= 0;

    my $pow = 10 ** int(log($target) / log(10));

    for my $m (1, 2, 5, 10) {
        my $s = $m * $pow;
        return $s if $s >= $target;
    }

    return 10 * $pow;
}

sub price_to_y {
    my ($self, $price, $min, $max, $top, $height) = @_;

    return $top if !defined($price) || !defined($min) || !defined($max);
    return $top + $height / 2 if $max == $min;

    if ($min > $max) {
        my $tmp = $min;
        $min = $max;
        $max = $tmp;
    }

    return $top + ($max - $price) * $height / ($max - $min);
}

sub y_to_price {
    my ($self, $y, $min, $max, $top, $height) = @_;

    return $min if !defined($y) || !defined($min) || !defined($max);
    return $min if $max == $min;

    if ($min > $max) {
        my $tmp = $min;
        $min = $max;
        $max = $tmp;
    }

    return $max - (($y - $top) / $height) * ($max - $min);
}

1;