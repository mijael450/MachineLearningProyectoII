package Market::MarketData;
use strict;
use warnings;
use Time::Piece;

# Temporalidades soportadas (en minutos). 'D' y 'W' se manejan con lógica especial.
our @SUPPORTED_TF = (1, 5, 15, 60, 120, 240, 'D', 'W');

# Minutos por temporalidad (para las especiales D=1440, W=10080)
my %TF_MINUTES = (
    1 => 1, 5 => 5, 15 => 15,
    60 => 60, 120 => 120, 240 => 240,
    'D' => 1440, 'W' => 10080,
);

sub new {
    my ($class) = @_;
    my $self = {
        data      => { 1 => [] },
        timeframe => 1,
    };
    bless $self, $class;
    return $self;
}

sub get_data { return $_[0]->{data}; }

# ─── Carga de datos ───────────────────────────────────────────────────────────

sub add_candle {
    my ($self, $candle) = @_;
    push @{$self->{data}{1}}, $candle;
}

# Carga un solo archivo CSV (1m). Llama a build_timeframes al final.
sub load_csv {
    my ($self, $file) = @_;
    open my $fh, '<', $file or die "No se puede abrir $file: $!";
    <$fh>; # saltar encabezado
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*$/;
        my ($time, $open, $high, $low, $close, $volume) = split /,/, $line;
        $time =~ s/\.\d+//;
        my $epoch = _to_epoch($time);
        $self->add_candle({
            time   => $time,
            epoch  => $epoch,
            open   => $open   + 0,
            high   => $high   + 0,
            low    => $low    + 0,
            close  => $close  + 0,
            volume => $volume + 0,
        });
    }
    close $fh;
    $self->build_timeframes();
}

# Carga múltiples CSVs en orden cronológico y construye todos los TF.
# Uso: $market->load_csv_files('2026_04.csv', '2026_05.csv', '2026_06_29.csv');
sub load_csv_files {
    my ($self, @files) = @_;

    # Vaciar datos previos de 1m para evitar duplicados
    $self->{data}{1} = [];

    my %by_epoch;
    for my $file (@files) {
        next unless defined $file && -f $file;
        print "  Cargando: $file\n";
        open my $fh, '<', $file or die "No se puede abrir $file: $!";
        <$fh>; # saltar encabezado
        while (my $line = <$fh>) {
            chomp $line;
            next if $line =~ /^\s*$/;
            my ($time, $open, $high, $low, $close, $volume) = split /,/, $line;
            $time =~ s/\.\d+//;
            my $epoch = _to_epoch($time);
            # La última fuente gana si dos CSV contienen el mismo minuto.
            $by_epoch{$epoch} = {
                time   => $time,
                epoch  => $epoch,
                open   => $open   + 0,
                high   => $high   + 0,
                low    => $low    + 0,
                close  => $close  + 0,
                volume => $volume + 0,
            };
        }
        close $fh;
    }

    # Ordenar y materializar una sola vela por timestamp.
    $self->{data}{1} = [ map { $by_epoch{$_} } sort { $a <=> $b } keys %by_epoch ];

    $self->build_timeframes();
    return $self;
}

# ─── Construcción de temporalidades ──────────────────────────────────────────

sub _to_epoch {
    my ($time) = @_;
    my $clean = $time;
    $clean =~ s/[-+]\d\d:\d\d$//;   # quitar zona horaria
    my $t = Time::Piece->strptime($clean, '%Y-%m-%dT%H:%M:%S');
    return $t->epoch;
}

# Devuelve el epoch del inicio del bucket para un TF dado.
# Para D y W se alinea al inicio del día/semana UTC.
sub _bucket_epoch {
    my ($epoch, $tf) = @_;
    my $minutes = $TF_MINUTES{$tf} // ($tf + 0);
    my $seconds = $minutes * 60;
    return int($epoch / $seconds) * $seconds;
}

# Construye (o reconstruye) el array de velas para un TF a partir de las velas 1m.
sub build_tf_candles {
    my ($self, $tf) = @_;
    # TF 1 es el array base; D y W son strings, nunca == 1 numéricamente
    return $self->{data}{1} if $tf eq '1' || ($tf =~ /^\d+$/ && $tf == 1);

    my @out;
    my $current;
    my $bucket = -1;

    for my $c (@{$self->{data}{1}}) {
        my $b = _bucket_epoch($c->{epoch}, $tf);
        if (!defined $current || $b != $bucket) {
            push @out, $current if defined $current;
            $bucket  = $b;
            $current = {
                time   => $c->{time},
                epoch  => $b,
                open   => $c->{open},
                high   => $c->{high},
                low    => $c->{low},
                close  => $c->{close},
                volume => $c->{volume},
            };
        } else {
            $current->{high}   = $c->{high}   if $c->{high}  > $current->{high};
            $current->{low}    = $c->{low}     if $c->{low}   < $current->{low};
            $current->{close}  = $c->{close};
            $current->{volume} += $c->{volume};
        }
    }
    push @out, $current if defined $current;

    $self->{data}{$tf} = \@out;
    return \@out;
}

# Construye TODAS las temporalidades soportadas de una vez.
sub build_timeframes {
    my ($self) = @_;
    for my $tf (@SUPPORTED_TF) {
        next if $tf eq '1' || ($tf =~ /^\d+$/ && $tf == 1);
        $self->build_tf_candles($tf);
    }
}

# ─── Gestión de temporalidad activa ──────────────────────────────────────────

sub set_timeframe {
    my ($self, $tf) = @_;
    $self->{timeframe} = $tf;
    # Construir bajo demanda si por alguna razón no existe aún
    $self->build_tf_candles($tf) unless exists $self->{data}{$tf};
}

sub get_timeframe { return $_[0]->{timeframe}; }

# Lista de TFs disponibles con datos (los que tienen al menos 1 vela)
sub available_timeframes {
    my ($self) = @_;
    return grep { exists $self->{data}{$_} && scalar @{$self->{data}{$_}} > 0 }
           @SUPPORTED_TF;
}

# ─── Acceso a datos ──────────────────────────────────────────────────────────

sub _active_array { return $_[0]->{data}{ $_[0]->{timeframe} }; }

sub get_slice {
    my ($self, $start, $end) = @_;
    my $a = $self->_active_array();
    $start = 0      if $start < 0;
    $end   = $#$a   if $end > $#$a;
    return []       if $end < $start;
    return [ @$a[$start .. $end] ];
}

# get_slice con límite explícito de replay (para el sistema Replay de la Fase 2)
sub get_slice_limited {
    my ($self, $start, $end, $limit) = @_;
    $end = $limit if defined $limit && $limit < $end;
    return $self->get_slice($start, $end);
}

# Acceso a los datos de un TF específico (sin cambiar el TF activo).
# Útil para que los indicadores lean TF superiores desde un TF menor.
sub get_tf_data {
    my ($self, $tf) = @_;
    return $self->{data}{$tf} // [];
}

sub get_tf_slice {
    my ($self, $tf, $start, $end) = @_;
    my $a = $self->get_tf_data($tf);
    $start = 0    if $start < 0;
    $end   = $#$a if $end > $#$a;
    return []     if $end < $start || !@$a;
    return [ @$a[$start .. $end] ];
}

# Binary search: índice del último elemento en $arr (ordenado por epoch)
# con epoch <= $target. Devuelve -1 si ninguno cumple.
sub _bsearch_epoch_le {
    my ($arr, $target) = @_;
    return -1 if !@$arr || $arr->[0]{epoch} > $target;
    my ($lo, $hi) = (0, $#$arr);
    while ($lo < $hi) {
        my $mid = int(($lo + $hi + 1) / 2);
        $arr->[$mid]{epoch} > $target ? ($hi = $mid - 1) : ($lo = $mid);
    }

    return $lo;
}

# get_tf_data_upto — versión de get_tf_data() que NUNCA filtra velas
# futuras a $cursor_epoch, ni siquiera dentro de la vela HTF que está
# "en formación" en ese instante.
#
# Motivo: build_tf_candles() agrega TODO el histórico 1m de una sola vez,
# así que la última vela de un TF superior (ej. la vela 4H que contiene al
# cursor de Replay) puede tener su high/low/close calculados con minutos
# que, en el instante del Replay, todavía no han "sucedido". Este método
# reconstruye esa última vela usando solo las velas de 1m con
# epoch <= $cursor_epoch — igual que se vería en un feed en vivo detenido
# exactamente en ese punto.
sub get_tf_data_upto {
    my ($self, $tf, $cursor_epoch) = @_;
    return $self->get_tf_data($tf) unless defined $cursor_epoch;

    # TF 1: filtrado directo por epoch, sin reconstrucción de buckets.
    if ($tf eq '1' || ($tf =~ /^\d+$/ && $tf == 1)) {
        my $arr = $self->{data}{1};
        my $idx = _bsearch_epoch_le($arr, $cursor_epoch);
        return [] if $idx < 0;
        return [ @$arr[0 .. $idx] ];
    }

    my $tf_arr = $self->get_tf_data($tf);
    return [] unless @$tf_arr;

    my $bidx = _bsearch_epoch_le($tf_arr, $cursor_epoch);
    return [] if $bidx < 0;

    my @out = @$tf_arr[0 .. $bidx];

    # ¿El último bucket devuelto sigue "en formación" en el instante del
    # cursor (todavía no llegó a bucket_start + duración)? Si es así, hay
    # que reconstruirlo solo con los 1m ya "sucedidos".
    my $minutes      = $TF_MINUTES{$tf} // ($tf + 0);
    my $bucket_start = $out[-1]{epoch};
    my $bucket_end   = $bucket_start + $minutes * 60;

    if ($cursor_epoch < $bucket_end - 1) {
        my $m1 = $self->{data}{1};
        my $lo = _bsearch_epoch_le($m1, $bucket_start - 1) + 1;  # primer 1m del bucket
        $lo = 0 if $lo < 0;
        my $hi = _bsearch_epoch_le($m1, $cursor_epoch);

        if ($hi >= $lo) {
            my $live;
            for my $c (@$m1[$lo .. $hi]) {
                if (!defined $live) {
                    $live = {
                        time => $c->{time}, epoch => $bucket_start,
                        open => $c->{open}, high => $c->{high},
                        low  => $c->{low},  close => $c->{close},
                        volume => $c->{volume},
                    };
                } else {
                    $live->{high}   = $c->{high}  if $c->{high} > $live->{high};
                    $live->{low}    = $c->{low}   if $c->{low}  < $live->{low};
                    $live->{close}  = $c->{close};
                    $live->{volume} += $c->{volume};
                }
            }
            $out[-1] = $live if $live;
        } else {
            # No hay ni una sola vela 1m del bucket todavía "sucedida":
            # el bucket no debería mostrarse en absoluto.
            pop @out;
        }
    }

    return \@out;
}

# get_tf_slice_upto — equivalente a get_tf_slice() pero apoyado en
# get_tf_data_upto() para respetar el límite de $cursor_epoch.
sub get_tf_slice_upto {
    my ($self, $tf, $start, $end, $cursor_epoch) = @_;
    my $a = $self->get_tf_data_upto($tf, $cursor_epoch);
    $start = 0    if $start < 0;
    $end   = $#$a if $end > $#$a;
    return []     if $end < $start || !@$a;
    return [ @$a[$start .. $end] ];
}

sub get_candle     { return $_[0]->_active_array()->[$_[1]]; }

# index_at_epoch — índice del último candle del TF ACTIVO con epoch <= $epoch.
# Se usa para reproyectar el cursor de Replay al cambiar de temporalidad
# (los índices de un TF no significan lo mismo en otro TF).
sub index_at_epoch {
    my ($self, $epoch) = @_;
    return _bsearch_epoch_le($self->_active_array(), $epoch);
}
sub size           { return scalar @{$_[0]->_active_array()}; }
sub last_index     { return $_[0]->size() - 1; }
sub last_candle    { return $_[0]->_active_array()->[-1]; }
sub get_timestamp  { return $_[0]->get_candle($_[1])->{time}; }

# ─── Actualización incremental (streaming / live) ────────────────────────────

sub merge_delta_row {
    my ($self, $row) = @_;
    my $last = $self->last_candle();
    if (defined $last && $last->{time} eq $row->{time}) {
        %$last = (%$last, %$row);
    } else {
        $self->add_candle($row);
    }
    $self->build_timeframes();
}

# ─── Anclajes de tiempo para el eje X ────────────────────────────────────────

sub compute_time_anchors {
    my ($self) = @_;
    my $arr = $self->_active_array();
    my @anchors;
    my $prev_day = '';

    for my $i (0 .. $#$arr) {
        my $time = $arr->[$i]{time};
        my ($date, $hh, $mm) = $time =~ /(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})/;
        next if !defined $date;
        if ($date ne $prev_day || $mm =~ /^(00|15|30|45)$/) {
            push @anchors, {
                index   => $i,
                date    => $date,
                hour    => "$hh:$mm",
                new_day => ($date ne $prev_day),
            };
            $prev_day = $date;
        }
    }
    return \@anchors;
}

# ─── Diagnóstico ─────────────────────────────────────────────────────────────

sub print_summary {
    my ($self) = @_;
    print "=== MarketData Summary ===\n";
    for my $tf (@SUPPORTED_TF) {
        my $arr = $self->{data}{$tf};
        next unless defined $arr && @$arr;
        my $n     = scalar @$arr;
        my $first = $arr->[0]{time}  // '?';
        my $last  = $arr->[-1]{time} // '?';
        printf "  TF %-4s : %6d velas   [%s → %s]\n", $tf, $n, $first, $last;
    }
    print "==========================\n";
}

1;
