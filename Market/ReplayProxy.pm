package Market::ReplayProxy;
use strict;
use warnings;

# ─────────────────────────────────────────────────────────────────────────────
# Market::ReplayProxy — Proxy de solo lectura sobre MarketData
#
# Propósito: durante el Replay, los indicadores (ATR, SMC, Liquidity) deben
# calcular SOLO con los datos hasta replay_cursor, nunca con velas futuras.
# El problema es que calculate_all() en ATR.pm llama:
#   $market_data->get_slice(0, $market_data->last_index())
# y last_index() siempre devuelve el total real.
#
# Este proxy envuelve el MarketData real y sobreescribe last_index() y size()
# para que devuelvan el límite del cursor, sin copiar ni modificar los datos.
# Todos los demás métodos delegan al market real.
#
# Uso en _replay_recalc_indicators():
#   my $proxy = Market::ReplayProxy->new($self->{market}, $self->{replay_cursor});
#   $self->{indicators}->update_last($proxy);
# ─────────────────────────────────────────────────────────────────────────────

sub new {
    my ($class, $market, $cursor) = @_;
    return bless {
        _market => $market,
        _cursor => $cursor,
    }, $class;
}

# ── Métodos sobreescritos — devuelven el límite del cursor ───────────────────

sub last_index {
    my ($self) = @_;
    my $real_last = $self->{_market}->last_index();
    return $self->{_cursor} < $real_last ? $self->{_cursor} : $real_last;
}

sub size {
    my ($self) = @_;
    return $self->last_index() + 1;
}

sub last_candle {
    my ($self) = @_;
    return $self->{_market}->get_candle($self->last_index());
}

# get_slice respeta el límite del cursor
sub get_slice {
    my ($self, $start, $end) = @_;
    my $limit = $self->last_index();
    $end = $limit if $end > $limit;
    return $self->{_market}->get_slice($start, $end);
}

# ── Delegación completa al market real ──────────────────────────────────────
# Todos los métodos no sobreescritos se delegan automáticamente.

sub get_candle      { $_[0]->{_market}->get_candle($_[1]); }

# ── FIX (bug #1): get_tf_data/get_tf_slice ya NO delegan directo al market
# real sin acotar. Antes, un indicador que pidiera contexto de un TF
# superior (ej. proyectar niveles 4H sobre una ventana 1m, como exige el
# PDF punto 3) recibía velas de esa temporalidad más allá del cursor de
# Replay — filtración de velas futuras "por la puerta de atrás" del TF
# activo. Ahora se acotan por el epoch de la última vela visible
# ($self->last_index(), ya recortado por el cursor), usando
# get_tf_data_upto()/get_tf_slice_upto() de MarketData, que además
# reconstruyen la vela HTF "en formación" usando solo los minutos ya
# transcurridos hasta ese instante (no toda la vela precalculada).
sub _cursor_epoch {
    my ($self) = @_;
    my $c = $self->{_market}->get_candle($self->last_index());
    return defined $c ? $c->{epoch} : undef;
}

sub get_tf_data {
    my ($self, $tf) = @_;
    return $self->{_market}->get_tf_data_upto($tf, $self->_cursor_epoch());
}

sub get_tf_slice {
    my ($self, $tf, $start, $end) = @_;
    return $self->{_market}->get_tf_slice_upto($tf, $start, $end, $self->_cursor_epoch());
}

sub get_timeframe   { $_[0]->{_market}->get_timeframe(); }
sub get_timestamp   { $_[0]->{_market}->get_timestamp($_[1]); }
sub get_data        { $_[0]->{_market}->get_data(); }
sub available_timeframes { $_[0]->{_market}->available_timeframes(); }
sub build_tf_candles  { $_[0]->{_market}->build_tf_candles($_[1]); }
# get_warmup_slice: velas previas al inicio de la ventana (para warm-up de ZZ)
sub get_warmup_slice  { return []; }  # ReplayProxy: ya tiene toda la historia en get_slice


# ═════════════════════════════════════════════════════════════════════════════
# Market::WindowProxy — como ReplayProxy pero SOLO expone una VENTANA de las
# últimas $window velas hasta $cursor. Permite recalcular indicadores en O(W)
# en lugar de O(cursor) durante el replay, respetando la directiva del PDF:
# "cálculos limitados a las velas visibles + una ventana de contexto".
#
# El índice local 0 corresponde al índice global base_index(). Los indicadores
# calculan con índices locales y luego llaman a _offset_indices(base) para
# convertirlos a globales, de modo que los overlays (que usan índices globales)
# funcionan sin cambios.
# ═════════════════════════════════════════════════════════════════════════════
package Market::WindowProxy;
use strict;
use warnings;

sub new {
    my ($class, $market, $cursor, $window) = @_;
    my $real_last = $market->last_index();
    $cursor = $real_last if $cursor > $real_last;
    my $base = $cursor - $window + 1;
    $base = 0 if $base < 0;
    return bless { _market=>$market, _cursor=>$cursor, _base=>$base }, $class;
}

sub base_index { return $_[0]->{_base}; }
sub last_index { return $_[0]->{_cursor} - $_[0]->{_base}; }   # último índice LOCAL
sub size       { return $_[0]->last_index() + 1; }

# get_slice recibe índices LOCALES y devuelve las velas reales de la ventana.
sub get_slice {
    my ($self, $a, $b) = @_;
    my $base   = $self->{_base};
    my $cursor = $self->{_cursor};
    my $ga = $base + ($a // 0);
    my $gb = $base + ($b // $self->last_index());
    $ga = $base   if $ga < $base;
    $gb = $cursor if $gb > $cursor;
    return $self->{_market}->get_slice($ga, $gb);
}

sub get_candle  { return $_[0]->{_market}->get_candle($_[0]->{_base} + $_[1]); }
sub last_candle { return $_[0]->{_market}->get_candle($_[0]->{_cursor}); }

# ── FIX (bug #1): mismo problema que en ReplayProxy — get_tf_data/
# get_tf_slice delegaban sin acotar al cursor. Se corrige igual, acotando
# por el epoch de la vela en $self->{_cursor} (índice global del cursor
# de replay/ventana) vía get_tf_data_upto()/get_tf_slice_upto().
sub _cursor_epoch {
    my ($self) = @_;
    my $c = $self->{_market}->get_candle($self->{_cursor});
    return defined $c ? $c->{epoch} : undef;
}

sub get_tf_data {
    my ($self, $tf) = @_;
    return $self->{_market}->get_tf_data_upto($tf, $self->_cursor_epoch());
}

sub get_tf_slice {
    my ($self, $tf, $start, $end) = @_;
    return $self->{_market}->get_tf_slice_upto($tf, $start, $end, $self->_cursor_epoch());
}

# Delegación (timeframe activo no depende de la ventana 1m).
sub get_timeframe        { $_[0]->{_market}->get_timeframe(); }
sub get_timestamp        { $_[0]->{_market}->get_timestamp($_[0]->{_base} + $_[1]); }
sub get_data             { $_[0]->{_market}->get_data(); }
sub available_timeframes { $_[0]->{_market}->available_timeframes(); }
sub build_tf_candles  { $_[0]->{_market}->build_tf_candles($_[1]); }
# get_warmup_slice: velas previas a base_index para warm-up del ZigZag
sub get_warmup_slice {
    my ($self, $n) = @_;
    my $base = $self->{_base};
    return [] unless $base > 0;
    my $start = $base > $n ? $base - $n : 0;
    return $self->{_market}->get_slice($start, $base - 1);
}


1;
