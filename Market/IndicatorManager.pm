package Market::IndicatorManager;
use strict;
use warnings;

sub new {
    my ($class) = @_;
    my $self = { indicators => {} };
    bless $self, $class;
    return $self;
}

sub register {
    my ($self, $name, $indicator) = @_;
    $self->{indicators}{$name} = $indicator;
}

sub update_last {
    my ($self, $market_data) = @_;
    for my $name (keys %{$self->{indicators}}) {
        $self->{indicators}{$name}->calculate_all($market_data);
    }
}

sub get {
    my ($self, $name) = @_;
    return $self->{indicators}{$name}->values();
}

# Acceso al OBJETO indicador completo (no solo a values()).
# Necesario para indicadores como SMC_Structures que exponen métodos propios
# de consulta (swing_at, swings_in_range, last_swing_high_before, etc.)
# que no encajan en el contrato simple de get()/slice_array() pensado
# originalmente para arrays indexados por vela como ATR.
# No modifica get() ni slice_array(): es estrictamente aditivo.
sub get_indicator {
    my ($self, $name) = @_;
    return $self->{indicators}{$name};
}

sub slice_array {
    my ($self, $name, $start, $end) = @_;
    my $arr = $self->get($name);
    $start = 0 if $start < 0;
    $end = $#$arr if $end > $#$arr;
    return [] if $end < $start;
    return [ @$arr[$start .. $end] ];
}

sub reset_all {
    my ($self) = @_;
    $_->reset() for values %{$self->{indicators}};
}

1;
