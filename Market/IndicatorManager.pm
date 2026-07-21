package Market::IndicatorManager;
use strict;
use warnings;
use Market::ReplayProxy;

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
    # Orden determinista: los módulos compuestos consumen resultados previos.
    my @order = qw(ATR SMC_Structures Liquidity ZigZagMTF ZigZagVolume);
    my %done;
    # Los indicadores de estructura son costosos y el PDF limita su cálculo a
    # velas visibles + contexto. En datasets grandes analizamos las últimas
    # 4,000 velas; WindowProxy mantiene índices globales y acceso MTF seguro.
    my $analysis_data = $market_data;
    if (!$market_data->can('base_index') && $market_data->size > 6000) {
        $analysis_data = Market::WindowProxy->new(
            $market_data, $market_data->last_index, 4000,
        );
    }
    for my $name (@order, sort keys %{$self->{indicators}}) {
        next if $done{$name}++;
        next unless $self->{indicators}{$name};
        my $source = $name eq 'ATR' ? $market_data : $analysis_data;
        $self->{indicators}{$name}->calculate_all($source);
    }
    my $smc=$self->{indicators}{SMC_Structures}; my $liq=$self->{indicators}{Liquidity};
    $smc->apply_liquidity_context($liq) if $smc && $liq && $smc->can('apply_liquidity_context');
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
