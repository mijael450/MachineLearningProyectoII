package Market::Overlays::Liquidity;
use strict;
use warnings;
use lib '.';
use Market::Panels::Scales;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Overlays::Liquidity
#
# Según la arquitectura del PDF (Tabla 1):
#   "Gestión del dibujado de líneas de liquidez, velas de liquidez, etiquetas
#    dinámicas y control de visibilidad interactivo que se desarrollan con
#    el replay."
#
# Responsabilidad EXCLUSIVA de este archivo: renderizar lo que
# Market::Indicators::Liquidity ya calculó. Cero lógica de detección aquí.
#
# PUNTO 3.5 — Implementa la Tabla 2 del PDF al pie de la letra:
#
#   Elemento  Estilo                          Color   Etiqueta
#   BSL       Horizontal discontinua/punteada Rojo    "BSL"
#   SSL       Horizontal discontinua/punteada Verde   "SSL"
#   EQH       Línea que conecta ambos máximos Config. "EQH"
#   EQL       Línea que conecta ambos mínimos Config. "EQL"
#   Sweep Up  Marcador/línea de quiebre        Rojo    "SWEEP ↑" (ASCII: "SWEEP UP")
#   Sweep Dn  Marcador/línea de quiebre        Verde   "SWEEP ↓" (ASCII: "SWEEP DOWN")
#   Liq.Grab  Destacado de rechazo rápido      Naranja "LQ GRAB"
#   Liq.Run   Extensión de ruptura de nivel    Azul    "LQ RUN"
#
# Control de visibilidad individual desde el menú "Overlays" del
# ChartEngine (3.5-B), igual patrón que Overlays::SMC_Structures.
#
# Compatible con Replay: igual que el resto del sistema — el ChartEngine
# siempre llama con $start/$end ya acotados por _replay_limit().
# ═════════════════════════════════════════════════════════════════════════════

# Colores EXACTOS de la Tabla 2 del PDF
my $COLOR_BSL   = '#f23645';   # Rojo
my $COLOR_SSL   = '#089981';   # Verde
my $COLOR_EQH   = '#9c8a5c';   # Configurable — tono neutro dorado por defecto
my $COLOR_EQL   = '#9c8a5c';
my $COLOR_SWEEP_UP   = '#f23645';   # Rojo (Tabla 2: Sweep Up)
my $COLOR_SWEEP_DOWN = '#089981';   # Verde (Tabla 2: Sweep Down)
my $COLOR_GRAB  = '#f59e0b';   # Naranja
my $COLOR_RUN   = '#2962ff';   # Azul

sub new {
    my ($class, %args) = @_;
    my $self = {
        scale => Market::Panels::Scales->new(),
        # Todos desactivados al arrancar — el usuario activa desde el menú.
        visible => {
            bsl   => 0,
            ssl   => 0,
            eqh   => 0,
            eql   => 0,
            sweep => 0,
            grab  => 0,
            run   => 0,
        },
    };
    bless $self, $class;
    return $self;
}

sub set_visible {
    my ($self, $key, $value) = @_;
    $self->{visible}{$key} = $value ? 1 : 0;
}

sub is_visible {
    my ($self, $key) = @_;
    return $self->{visible}{$key};
}

# ─────────────────────────────────────────────────────────────────────────────
# draw — punto de entrada principal, llamado desde ChartEngine::draw()
#
# $liq    : objeto Market::Indicators::Liquidity ya calculado
# $x_of   : closure índice local -> coordenada X
# $state  : hashref de contexto (price_min, price_max, top, price_h, etc.)
# ─────────────────────────────────────────────────────────────────────────────
sub draw {
    my ($self, $canvas, $liq, $x_of, $state) = @_;
    return unless defined $liq;

    my $start = $state->{start_index};
    my $end   = $state->{end_index};
    my $min   = $state->{price_min};
    my $max   = $state->{price_max};
    my $top   = $state->{top};
    my $h     = $state->{price_h} - ($state->{vol_h} // 0);
    my $right = $state->{right};

    return unless defined $min && defined $max;

    my $levels = $liq->levels_in_range($start, $end);

    for my $lv (@$levels) {
        if ($lv->{kind} eq 'BSL') {
            $self->_draw_bsl_ssl($canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h, $right)
                if $self->{visible}{bsl};
        } elsif ($lv->{kind} eq 'SSL') {
            $self->_draw_bsl_ssl($canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h, $right)
                if $self->{visible}{ssl};
        } elsif ($lv->{kind} eq 'EQH') {
            $self->_draw_eq($canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h)
                if $self->{visible}{eqh};
        } elsif ($lv->{kind} eq 'EQL') {
            $self->_draw_eq($canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h)
                if $self->{visible}{eql};
        }

        # Marcadores de resolución (Sweep/Grab/Run) — independientes del
        # kind del nivel, se dibujan sobre la vela donde se resolvió.
        next unless $lv->{state} eq 'Resolved' && defined $lv->{classification};

        if ($lv->{classification} eq 'Sweep' && $self->{visible}{sweep}) {
            $self->_draw_sweep_marker($canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h);
        } elsif ($lv->{classification} eq 'Grab' && $self->{visible}{grab}) {
            $self->_draw_grab_marker($canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h);
        } elsif ($lv->{classification} eq 'Run' && $self->{visible}{run}) {
            $self->_draw_run_marker($canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h);
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_bsl_ssl — línea horizontal discontinua/punteada (Tabla 2).
# BSL en rojo, SSL en verde. Se extiende desde el índice de detección
# hasta donde el nivel sigue "vivo" (swept_at si fue barrido, o el borde
# visible si nunca se barrió).
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_bsl_ssl {
    my ($self, $canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h, $right) = @_;

    my $is_bsl = ($lv->{kind} eq 'BSL');
    my $color  = $is_bsl ? $COLOR_BSL : $COLOR_SSL;
    my $label  = $is_bsl ? 'BSL' : 'SSL';

    my $x1_local = $lv->{index} - $start;
    my $x1 = $x_of->($x1_local);

    my $end_index = defined $lv->{swept_at} ? $lv->{swept_at} : $end;
    $end_index = $end if $end_index > $end;
    my $x2_local = $end_index - $start;
    my $x2 = $x_of->($x2_local);

    return if $x2 < $x1;

    my $y = $self->{scale}->price_to_y($lv->{price}, $min, $max, $top, $h);
    return if $y < $top || $y > $top + $h;

    $canvas->createLine($x1, $y, $x2, $y,
        -fill  => $color,
        -width => 1,
        -dash  => [4, 3],
        -tags  => 'liq_level',
    );
    $canvas->createText($x2 + 4, $y,
        -anchor => 'w',
        -text   => $label,
        -fill   => $color,
        -font   => ['Arial', 7, 'bold'],
        -tags   => 'liq_level',
    );
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_eq — EQH/EQL: línea que conecta ambos pivotes "iguales" (Tabla 2).
# pair_index es el primer pivote del par; lv->{index} es el segundo.
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_eq {
    my ($self, $canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h) = @_;
    return unless defined $lv->{pair_index};

    my $pair_local = $lv->{pair_index} - $start;
    my $cur_local  = $lv->{index} - $start;
    return if $lv->{pair_index} < $start && $lv->{index} < $start;   # ambos fuera

    my $x1 = $x_of->($pair_local);
    my $x2 = $x_of->($cur_local);
    my $y  = $self->{scale}->price_to_y($lv->{price}, $min, $max, $top, $h);
    return if $y < $top || $y > $top + $h;

    my $color = ($lv->{kind} eq 'EQH') ? $COLOR_EQH : $COLOR_EQL;

    $canvas->createLine($x1, $y, $x2, $y,
        -fill  => $color,
        -width => 1,
        -tags  => 'liq_eq',
    );
    $canvas->createText($x2 + 4, $y,
        -anchor => 'w',
        -text   => $lv->{kind},
        -fill   => $color,
        -font   => ['Arial', 7, 'bold'],
        -tags   => 'liq_eq',
    );
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_sweep_marker — Tabla 2: "Marcador / Línea de quiebre".
# Sweep Up (BSL/EQH barridos) = rojo "SWEEP UP".
# Sweep Down (SSL/EQL barridos) = verde "SWEEP DOWN".
# (Tabla 2 usa flechas Unicode ↑/↓; se usan equivalentes ASCII por la
# limitación de fuentes en Tk/Perl ya resuelta en el toolbar del ChartEngine).
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_sweep_marker {
    my ($self, $canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h) = @_;
    my $is_ceiling = ($lv->{kind} eq 'BSL' || $lv->{kind} eq 'EQH');

    my $sx_local = $lv->{swept_at} - $start;
    return if $lv->{swept_at} < $start || $lv->{swept_at} > $end;
    my $x = $x_of->($sx_local);
    my $y = $self->{scale}->price_to_y($lv->{price}, $min, $max, $top, $h);
    return if $y < $top || $y > $top + $h;

    my $color = $is_ceiling ? $COLOR_SWEEP_UP : $COLOR_SWEEP_DOWN;
    my $label = $is_ceiling ? 'SWEEP UP' : 'SWEEP DOWN';
    my $arrow_dy = $is_ceiling ? -8 : 8;

    # Marcador de quiebre: pequeña "X" sobre el punto de cruce
    $canvas->createLine($x - 5, $y - 5, $x + 5, $y + 5, -fill => $color, -width => 2, -tags => 'liq_sweep');
    $canvas->createLine($x - 5, $y + 5, $x + 5, $y - 5, -fill => $color, -width => 2, -tags => 'liq_sweep');

    $canvas->createText($x, $y + $arrow_dy * 2,
        -text => $label,
        -fill => $color,
        -font => ['Arial', 7, 'bold'],
        -tags => 'liq_sweep',
    );
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_grab_marker — Tabla 2: "Destacado de rechazo rápido", Naranja, "LQ GRAB".
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_grab_marker {
    my ($self, $canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h) = @_;
    return if $lv->{resolved_at} < $start || $lv->{resolved_at} > $end;

    my $x_local = $lv->{resolved_at} - $start;
    my $x = $x_of->($x_local);
    my $y = $self->{scale}->price_to_y($lv->{price}, $min, $max, $top, $h);
    return if $y < $top || $y > $top + $h;

    # Destacado: círculo relleno naranja sobre la vela de rechazo
    $canvas->createOval($x - 5, $y - 5, $x + 5, $y + 5,
        -fill    => $COLOR_GRAB,
        -outline => $COLOR_GRAB,
        -tags    => 'liq_grab',
    );
    $canvas->createText($x, $y - 14,
        -text => 'LQ GRAB',
        -fill => $COLOR_GRAB,
        -font => ['Arial', 7, 'bold'],
        -tags => 'liq_grab',
    );
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_run_marker — Tabla 2: "Extensión de ruptura de nivel", Azul, "LQ RUN".
# Se dibuja como una línea extendida desde el nivel barrido hasta el punto
# de aceptación confirmada (resolved_at), representando la "extensión" de
# la ruptura tal como describe la Tabla 2.
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_run_marker {
    my ($self, $canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h) = @_;

    my $sx = defined $lv->{swept_at} ? $lv->{swept_at} : $lv->{index};
    $sx = $start if $sx < $start;
    my $ex = $lv->{resolved_at};
    return if $ex < $start || $sx > $end;
    $ex = $end if $ex > $end;

    my $x1 = $x_of->($sx - $start);
    my $x2 = $x_of->($ex - $start);
    my $y  = $self->{scale}->price_to_y($lv->{price}, $min, $max, $top, $h);
    return if $y < $top || $y > $top + $h;

    $canvas->createLine($x1, $y, $x2, $y,
        -fill  => $COLOR_RUN,
        -width => 2,
        -tags  => 'liq_run',
    );
    $canvas->createText($x2 + 4, $y,
        -anchor => 'w',
        -text   => 'LQ RUN',
        -fill   => $COLOR_RUN,
        -font   => ['Arial', 7, 'bold'],
        -tags   => 'liq_run',
    );
}

1;
