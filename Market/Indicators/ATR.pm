package Market::Indicators::ATR;
use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = { period => $args{period} || 14, values => [] };
    bless $self, $class;
    return $self;
}

sub reset { $_[0]->{values} = []; }
sub values { return $_[0]->{values}; }

sub calculate_all {
    my ($self, $market_data) = @_;
    my $data = $market_data->get_slice(0, $market_data->last_index());
    my @tr;
    my @atr;
    my $p = $self->{period};

    for my $i (0 .. $#$data) {
        my $c = $data->[$i];
        my $tr;
        if ($i == 0) {
            $tr = $c->{high} - $c->{low};
        } else {
            my $prev_close = $data->[$i - 1]{close};
            my $a = $c->{high} - $c->{low};
            my $b = abs($c->{high} - $prev_close);
            my $d = abs($c->{low}  - $prev_close);
            $tr = _max($a, $b, $d);
        }
        push @tr, $tr;

        if ($i < $p - 1) {
            push @atr, undef;
        } elsif ($i == $p - 1) {
            my $sum = 0;
            $sum += $_ for @tr[0 .. $p - 1];
            push @atr, $sum / $p;
        } else {
            # RMA de Wilder: ATR actual = (ATR anterior*(periodo-1)+TR actual)/periodo
            push @atr, (($atr[-1] * ($p - 1)) + $tr) / $p;
        }
    }
    $self->{values} = \@atr;
}

sub _max {
    my $m = shift;
    for (@_) { $m = $_ if $_ > $m; }
    return $m;
}

1;
