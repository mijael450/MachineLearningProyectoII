package Market::Overlays::SMC_Structures;
use strict;
use warnings;
use lib '.';
use Market::Panels::Scales;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Overlays::SMC_Structures
#
# Según la arquitectura del PDF (Tabla 1):
#   "Renderizado gráfico en el Canvas de Perl/Tk de las estructuras de
#    mercado unificadas."
#
# Responsabilidad EXCLUSIVA de este archivo: dibujar en el canvas lo que
# Market::Indicators::SMC_Structures ya calculó. No calcula nada — toda la
# lógica de detección vive en el Indicator (separación estricta Indicators
# vs Overlays que exige la Tabla 1).
#
# PUNTO 3.5 — Dibuja:
#   - Etiquetas HH / HL / LH / LL sobre cada Swing Point
#   - Marcadores BOS / CHoCH con distinción internal (sólido) / external (punteado)
#   - Rectángulos FVG con desvanecimiento progresivo de opacidad
#   - Niveles de Fibonacci Retracement entre el último Swing High y Low relevantes
#
# Convención de uso (idéntica a Market::Panels::PricePanel):
#   $overlay->draw($canvas, $smc_indicator, $x_of, $state)
# donde $state es el mismo hashref de contexto que ya usa PricePanel/ATRPanel,
# con price_min/price_max ya resueltos por el momento en que se llama.
#
# Compatible con Replay: el ChartEngine siempre llama a este overlay con
# $start/$end ya recortados por _replay_limit(), así que basta con pedir
# swings/eventos/fvgs "in_range(start,end)" — nunca se dibuja nada fuera
# de ese rango, sea cual sea el origen del límite (normal o replay).
# ═════════════════════════════════════════════════════════════════════════════

# Colores según convención SMC estándar (igual familia visual que TradingView/LuxAlgo)
my %SWING_COLOR = (
    HH => '#26a69a',  # verde — continuación alcista
    HL => '#26a69a',
    LH => '#ef5350',  # rojo — continuación bajista
    LL => '#ef5350',
);

my %EVENT_COLOR = (
    up   => '#26a69a',
    down => '#ef5350',
);

my %FVG_COLOR = (
    up   => '#26a69a',
    down => '#ef5350',
);

# Número de velas tras las cuales un FVG llega a opacidad mínima (visual).
# El indicador no sabe nada de esto — es puramente decisión del overlay.
my $FVG_FADE_WINDOW = 50;

sub new {
    my ($class, %args) = @_;
    my $self = {
        scale => Market::Panels::Scales->new(),

        # Spec del profesor: "el sistema debe permitir configurar si el
        # rectángulo desaparece o simplemente deja de extenderse" al
        # mitigarse un FVG. 'hide' (default) | 'freeze'. Ver _draw_fvgs().
        fvg_on_mitigate => $args{fvg_on_mitigate} // 'hide',

        # Visibilidad individual — todos desactivados al arrancar.
        # El usuario activa los que necesita desde el menú Overlays.
        # Esto evita dibujar miles de elementos en el primer frame y
        # mejora significativamente el tiempo de arranque y el draw().
        visible => {
            swings => 0,
            bos_internal => 0,
            bos_external => 0,
            choch_internal => 0,
            choch_external => 0,
            fvg    => 0,
            fib    => 0,
            ob_internal => 0,
            ob_external => 0,
            sr     => 0,   # Support / Resistance
            trend  => 0,   # Trendlines / Channels
            daily  => 0,   # Near daily candle's body & wick (Fase 4)
        },
    };
    bless $self, $class;
    return $self;
}

# Toggle de visibilidad individual — usado por los checkbuttons del menú.
sub set_visible {
    my ($self, $key, $value) = @_;
    $self->{visible}{$key} = $value ? 1 : 0;
}

sub is_visible {
    my ($self, $key) = @_;
    return $self->{visible}{$key};
}

sub set_external_zigzag { $_[0]->{external_zigzag} = $_[1]; }

# ─────────────────────────────────────────────────────────────────────────────
# draw — punto de entrada principal, llamado desde ChartEngine::draw()
#
# $smc    : objeto Market::Indicators::SMC_Structures ya calculado
# $x_of   : closure índice local -> coordenada X (misma que usa PricePanel)
# $state  : hashref de contexto (price_min, price_max, top, price_h, etc.)
# ─────────────────────────────────────────────────────────────────────────────
sub draw {
    my ($self, $canvas, $smc, $x_of, $state) = @_;
    return unless defined $smc;

    my $start = $state->{start_index};
    my $end   = $state->{end_index};
    my $min   = $state->{price_min};
    my $max   = $state->{price_max};
    my $top   = $state->{top};
    my $h     = $state->{price_h};   # FIX: igual que PricePanel — incluye zona de volumen

    return unless defined $min && defined $max;

    $self->_draw_fvgs($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{fvg};

    $self->_draw_swings($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{swings};

    $self->_draw_events($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{bos_internal} || $self->{visible}{bos_external}
        || $self->{visible}{choch_internal} || $self->{visible}{choch_external};

    $self->_draw_fibonacci($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{fib};

    $self->_draw_order_blocks($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h, 'internal')
        if $self->{visible}{ob_internal};
    $self->_draw_order_blocks($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h, 'external')
        if $self->{visible}{ob_external};

    $self->_draw_support_resistance($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{sr};

    $self->_draw_trendlines($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{trend};

    $self->_draw_daily_proximity($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{daily};
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_swings — etiquetas HH/HL/LH/LL sobre cada Swing Point visible.
# Se dibujan primero los FVG (capa de fondo) para que las etiquetas queden
# siempre legibles encima.
#
# ── FIX (retroalimentación del profesor: "limpiar HH, LH, HL, LL") ────────
# Antes se dibujaban TODOS los swings internos (k=5) — verificado: 2,581
# etiquetas en el histórico de prueba, ilegibles al alejar el zoom (ver
# capturas de referencia). Ahora se dibujan los major_swings (k=50,
# estructura externa/mayor) — reduce la densidad ~10x, mismo criterio ya
# aplicado a Order Blocks, Trendlines y Fibonacci.
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_swings {
    my ($self, $canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h) = @_;

    # Estilo LuxAlgo SMC (imágenes 3, 4, 5 de referencia):
    #   - Pequeña línea vertical desde la punta de la mecha (5px)
    #   - Etiqueta del label (HH/HL/LH/LL) justo encima/debajo de esa línea
    #   - Colores: verde para HH/HL (alcista), rojo/cyan para LH/LL (bajista)
    #   - Solo sobre la mecha: high para swing highs, low para swing lows
    my $swings = $smc->major_swings_in_range($start, $end);
    for my $sw (@$swings) {
        my $x = $x_of->($sw->{index} - $start);
        my $y = $self->{scale}->price_to_y($sw->{price}, $min, $max, $top, $h);
        next if $y < $top || $y > $top + $h;

        my $color = $SWING_COLOR{ $sw->{label} } // '#787b86';
        my $is_high = ($sw->{type} eq 'high');

        # Pequeña línea vertical: desde la punta de la mecha hacia afuera (5px)
        my $line_y1 = $is_high ? ($y - 5) : ($y + 5);
        my $line_y2 = $is_high ? ($y - 1) : ($y + 1);
        $canvas->createLine($x, $line_y1, $x, $line_y2,
            -fill  => $color,
            -width => 1,
            -tags  => 'smc_swing',
        );

        # Etiqueta: 8px más allá de la línea (encima para highs, debajo para lows)
        my $label_y = $is_high ? ($y - 14) : ($y + 14);
        $canvas->createText($x, $label_y,
            -text   => $sw->{label},
            -anchor => 'center',
            -fill   => $color,
            -font   => ['Arial', 7, 'bold'],
            -tags   => 'smc_swing',
        );
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_events — marcadores BOS y CHoCH.
# internal: línea sólida corta + etiqueta. external: línea punteada + etiqueta
# con sufijo, distinción visual exigida por la jerarquía multi-temporal del PDF.
#
# ── FIX (retroalimentación del profesor: "se mezcla BOS con LL,LH. BOS
# encima de la vela.") ──────────────────────────────────────────────────
# Causa encontrada: el label del swing (HH/LH/HL/LL, en _draw_swings) se
# dibuja a precio_swing±14px, y el label de BOS/CHoCH se dibujaba a
# precio_del_MISMO_nivel±9px — ambos anclados prácticamente al mismo precio,
# apenas 5px de diferencia, así que se superponían. Además el label se
# ubicaba en el punto medio del segmento nivel→ruptura; con niveles
# recién formados (lo más común dada la densidad anterior), ese punto medio
# caía casi encima de la vela que rompe.
# Fix: (a) separación de Y mucho mayor (±20px en vez de ±9px) para que no
# choque con el label del swing: (b) el label se ancla cerca del BORDE
# DERECHO del segmento (la vela de ruptura + un pequeño margen), no en el
# centro — es el patrón estándar de TradingView/LuxAlgo.
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_events {
    my ($self, $canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h) = @_;

    # Colores: alcista=verde, bajista=rojo. CHoCH más saturado.
    my %BOS_COLOR   = (up => '#26a69a', down => '#ef5350');
    my %CHOCH_COLOR = (up => '#26a69a', down => '#ef5350');
    my $right = $state->{right} // $x_of->($end - $start);

    # ── Agrupar eventos por vela para detectar CHoCH+BOS simultáneos ────────
    # Cuando CHoCH y BOS ocurren en la misma vela con el mismo nivel y
    # dirección, se muestran con la etiqueta "CHoCH BOS" en la misma línea
    # (comportamiento de TradingView / LuxAlgo, imagen 6 de referencia).
    my %by_candle;
    my $events = $smc->events_in_range($start, $end);
    for my $ev (@$events) {
        push @{ $by_candle{ $ev->{index} } }, $ev;
    }

    for my $idx (sort { $a <=> $b } keys %by_candle) {
        my @evs = @{ $by_candle{$idx} };

        # Filtrar por visibilidad
        @evs = grep {
            my $scope = ($_->{scope} // 'internal') eq 'external' ? 'external' : 'internal';
            ($_->{type} eq 'BOS'   && $self->{visible}{"bos_$scope"}) ||
            ($_->{type} eq 'CHoCH' && $self->{visible}{"choch_$scope"})
        } @evs;
        next unless @evs;

        # Agrupar por nivel+dirección para fusionar CHoCH+BOS del mismo nivel
        my %groups;
        for my $ev (@evs) {
            my $key = sprintf("%.2f_%s", $ev->{level_price}, $ev->{direction});
            push @{ $groups{$key} }, $ev;
        }

        for my $key (keys %groups) {
            my @grp = @{ $groups{$key} };
            my $ev  = $grp[0];   # tomar el primero como referencia

            # Determinar si hay CHoCH en este grupo
            my $has_choch = grep { $_->{type} eq 'CHoCH' } @grp;
            my $has_bos   = grep { $_->{type} eq 'BOS'   } @grp;

            my $color = ($ev->{direction} eq 'up')
                      ? $BOS_COLOR{up} : $BOS_COLOR{down};

            # Etiqueta: "CHoCH", "BOS", o "CHoCH BOS" si coexisten
            my $label = $has_choch && $has_bos ? 'CHoCH  BOS'
                      : $has_choch             ? 'CHoCH'
                      :                          'BOS';

            # ── Línea horizontal ─────────────────────────────────────────────
            # Estilo: sólido para externo (estructura mayor), dashed para interno
            my $is_ext = ($ev->{scope} eq 'external');
            my $y = $self->{scale}->price_to_y($ev->{level_price}, $min, $max, $top, $h);
            next if $y < $top || $y > $top + $h;

            # X inicio: el swing roto (level_index)
            my $x1 = ($ev->{level_index} >= $start)
                   ? $x_of->($ev->{level_index} - $start)
                   : $x_of->(0);

            # X fin: la vela que confirma la ruptura
            my $x2 = ($ev->{index} <= $end)
                   ? $x_of->($ev->{index} - $start)
                   : $right;

            my @line_args = (
                -fill  => $color,
                -width => $is_ext ? 2 : 1,
                -tags  => 'smc_event',
            );
            push @line_args, (-dash => [4, 3]) unless $is_ext;

            $canvas->createLine($x1, $y, $x2, $y, @line_args);

            # ── Etiqueta cerca del borde derecho (vela de ruptura) ────────────
            # Antes: label_x = punto medio del segmento -> quedaba encima de
            # la vela cuando el nivel era reciente. Ahora: cerca de x2 con un
            # pequeño margen hacia la izquierda, y separación de Y mayor
            # (±20px) para no chocar con la etiqueta HH/LH del swing (±14px).
            my $label_x = $x2 - 12;
            my $label_y = ($ev->{direction} eq 'up') ? ($y - 20) : ($y + 20);
            $canvas->createText($label_x, $label_y,
                -text   => $label,
                -fill   => $color,
                -anchor => 'center',
                -font   => ['Arial', 7, ($has_choch ? 'bold italic' : 'bold')],
                -tags   => 'smc_event',
            );
        }
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# _draw_fvgs — STUB TEMPORAL (Fase 0: parche de emergencia)
#
# Antes de este stub, activar el checkbox "FVG" del menú causaba:
#   Can't locate object method "_draw_fvgs" via package
#   "Market::Overlays::SMC_Structures"
# porque draw() (línea ~112) llama a este método pero nunca se implementó.
#
# Este stub NO dibuja nada todavía — solo evita el crash de Tk. El indicador
# (Market::Indicators::SMC_Structures::_detect_fvg) ya calcula los datos
# correctamente (top, bottom, direction, mitigated_at); lo que falta es
# escribir el renderizado real con el desvanecimiento progresivo (Fase 2
# del plan acordado). Hasta entonces, activar "FVG" en el menú es seguro
# mostrará simplemente nada en el canvas.
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# _draw_fvgs — Punto 3.3 / cronograma 29/06: "FVG con el desvanecimiento
# progresivo en el tiempo" (Fase 2 del plan).
#
# El Indicator (_detect_fvg) ya expone todo lo necesario vía fvgs_in_range():
#   { index, direction ('up'|'down'), top, bottom, mitigated_at }
# Este overlay SOLO decide cómo se ve — ninguna lógica de detección aquí.
#
# Rectángulo: desde la vela de formación (index) hasta mitigated_at (si ya
# fue mitigado) o hasta el borde visible/cursor de replay ($end) si sigue
# activo — mismo patrón que _draw_order_blocks.
#
# Desvanecimiento progresivo: Tk no soporta alpha real, así que se simula
# con 4 escalones de -stipple (más denso = recién formado, más disperso =
# viejo). La "edad" se mide en velas desde la formación hasta el punto de
# referencia visible (mitigated_at si ya se mitigó, o $end si sigue activo
# — así el desvanecimiento avanza también durante el Replay, no solo con
# el tiempo real). Pasado 1.5x la ventana de fade, se deja de dibujar para
# no saturar el canvas de rectángulos ya irrelevantes.
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# _draw_fvgs — Punto 3.3 / cronograma 29/06: "FVG con el desvanecimiento
# progresivo en el tiempo" (Fase 2 del plan).
#
# El Indicator (_detect_fvg) ya expone todo lo necesario vía fvgs_in_range():
#   { index, direction ('up'|'down'), top, bottom, mitigated_at }
# Este overlay SOLO decide cómo se ve — ninguna lógica de detección aquí.
#
# ── FIX (retroalimentación del profesor: "todo FVG consumido debe
# desaparecer") ────────────────────────────────────────────────────────
# ANTES: un FVG mitigado seguía dibujándose (desvanecido) hasta 75 velas
# después de mitigarse (`$FVG_FADE_WINDOW * 1.5`) — con el 99.5% de los
# FVGs mitigándose eventualmente en 1m, esto llenaba el canvas de
# rectángulos "fantasma" ya irrelevantes en todo momento.
# AHORA: en cuanto `mitigated_at` está definido, el FVG deja de dibujarse
# por completo — sin ventana de fade posterior. El desvanecimiento
# progresivo (que sí pide el cronograma) queda solo para los FVG AÚN
# ACTIVOS (no mitigados), que se desvanecen con la edad desde su formación
# hasta el cursor/borde visible, con el mismo tope de $FVG_FADE_WINDOW*1.5
# para no dejar cajas activas muy viejas indefinidamente.
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# _draw_fvgs — Punto 3.3 / cronograma 29/06: "FVG con el desvanecimiento
# progresivo en el tiempo" (Fase 2 del plan).
#
# El Indicator (_detect_fvg) ya expone todo lo necesario vía fvgs_in_range():
#   { index, direction ('up'|'down'), top, bottom, mitigated_at }
# Este overlay SOLO decide cómo se ve — ninguna lógica de detección aquí.
#
# ── FIX 1 (retroalimentación del profesor: "todo FVG consumido debe
# desaparecer") ────────────────────────────────────────────────────────
# En cuanto `mitigated_at` está definido, el FVG deja de dibujarse por
# completo — sin ventana de fade posterior.
#
# ── FIX 2 (reportado tras el fix anterior: "los FVG solo aparecen al
# final del gráfico, eso no debería pasar") ────────────────────────────
# La versión anterior de este fix, sin querer, heredó un tope de edad
# (`$FVG_FADE_WINDOW * 1.5` = 75 velas) que ANTES servía para dejar de
# dibujar un FVG YA MITIGADO tras un rato — pero se aplicaba también a los
# FVG que NUNCA se mitigan. Eso contradice la definición misma de un FVG:
# es una zona de desequilibrio a la que el precio puede volver en
# cualquier momento futuro, no algo que expira solo por el paso del
# tiempo. Con el fade window aplicado a los activos, cualquier FVG sin
# rellenar de más de 75 velas de antigüedad desaparecía del todo — por
# eso solo se veían los formados recientemente cerca del cursor.
#
# Ahora: un FVG activo (sin mitigar) SIEMPRE se dibuja mientras intersecte
# el rango visible, sin importar su edad — solo cambia qué tan disperso
# (desvanecido) se ve el patrón -stipple. _fvg_fade_stipple() ya clampa
# correctamente en el patrón más disperso ('gray12') para edades grandes,
# así que no hace falta ningún tope adicional aquí.
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# _draw_fvgs — Punto 3.3 / cronograma 29/06: "FVG con el desvanecimiento
# progresivo en el tiempo" (Fase 2 del plan).
#
# El Indicator (_detect_fvg) ya expone todo lo necesario vía fvgs_in_range():
#   { index, direction ('up'|'down'), top, bottom, state, mitigated_at, ... }
# Este overlay SOLO decide cómo se ve — ninguna lógica de detección aquí.
#
# ── FIX 1 (retroalimentación del profesor: "todo FVG consumido debe
# desaparecer") ────────────────────────────────────────────────────────
# En cuanto el FVG queda 'mitigated', deja de dibujarse por completo —
# sin ventana de fade posterior. (Comportamiento por defecto: 'hide'.)
#
# ── FIX 2 (reportado tras el fix anterior: "los FVG solo aparecen al
# final del gráfico") ──────────────────────────────────────────────────
# Un FVG activo (sin mitigar) SIEMPRE se dibuja mientras intersecte el
# rango visible, sin importar su edad — solo cambia qué tan disperso
# (desvanecido) se ve el patrón -stipple, nunca su visibilidad.
#
# ── FIX 3 (spec del profesor: "el sistema debe permitir configurar si el
# rectángulo desaparece o simplemente deja de extenderse") ─────────────
# Nuevo parámetro del constructor: $self->{fvg_on_mitigate}, 'hide'
# (default, comportamiento del FIX 1) o 'freeze' — en 'freeze', un FVG
# mitigado se sigue dibujando pero congelado: su borde derecho queda fijo
# en mitigated_at (ya no se extiende con el cursor) y su zona de precio
# queda en el estado final que tenía justo al mitigarse (puede ser más
# angosta que la original si hubo recortes parciales antes del cierre
# completo). Se dibuja con el stipple más disperso (histórico, no activo).
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_fvgs {
    my ($self, $canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h) = @_;
    my $on_mitigate = $self->{fvg_on_mitigate} // 'hide';

    for my $fvg (@{ $smc->recent_fvgs_in_range($start, $end, 3) }) {
        my $is_mitigated = defined $fvg->{mitigated_at};

        next if $is_mitigated && $on_mitigate eq 'hide';   # consumido -> desaparece

        my $i1 = $fvg->{index};
        my $i2;
        my $stipple;

        if ($is_mitigated) {
            # 'freeze': congelado en su último estado, sin seguir extendiéndose.
            $i2      = $fvg->{mitigated_at};
            $stipple = 'gray12';   # histórico: siempre el más disperso
        } else {
            # Activo: se extiende hasta el borde visible/cursor, y el fade
            # progresa con la edad desde la formación (sin tope de tiempo).
            $i2 = $end;
            my $age = $end - $i1;
            $stipple = _fvg_fade_stipple($age, $FVG_FADE_WINDOW);
        }

        $i1 = $start if $i1 < $start;
        $i2 = $end   if $i2 > $end;
        next if $i2 < $i1;

        my $x1 = $x_of->($i1 - $start);
        my $x2 = !$is_mitigated
            ? ($state->{right} // $x_of->($i2 - $start))
            : $x_of->($i2 - $start);
        my $y_top = $self->{scale}->price_to_y($fvg->{top},    $min, $max, $top, $h);
        my $y_bot = $self->{scale}->price_to_y($fvg->{bottom}, $min, $max, $top, $h);
        next if $y_bot < $top || $y_top > $top + $h;

        my $color = $FVG_COLOR{ $fvg->{direction} } // '#787b86';

        $canvas->createRectangle($x1, $y_top, $x2, $y_bot,
            -fill    => $color,
            -stipple => $stipple,
            -outline => '',
            -tags    => 'smc_fvg',
        );
        if ($fvg->{high_reaction}) {
            $canvas->createText($x1 + 4, ($y_top+$y_bot)/2,
                -anchor=>'w', -text=>'ZONA ALTA REACCION', -fill=>'#f59e0b',
                -font=>['Arial',7,'bold'], -tags=>'smc_fvg');
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _fvg_fade_stipple — traduce "edad en velas" a un patrón -stipple de Tk.
# Tk no tiene alpha real; los stipples más densos (gray50) se ven más
# sólidos/opacos y los más dispersos (gray12) se ven más tenues/transparentes.
# Recién formado -> denso. Con el tiempo -> cada vez más disperso.
# ─────────────────────────────────────────────────────────────────────────────
sub _fvg_fade_stipple {
    my ($age, $window) = @_;
    my $ratio = $window > 0 ? ($age / $window) : 1;

    return 'gray50' if $ratio < 0.33;   # recién formado: más opaco
    return 'gray25' if $ratio < 0.66;   # medio de vida
    return 'gray12';                    # cerca de desaparecer: más transparente
}

sub _draw_fibonacci {
    my ($self, $canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h) = @_;
    my $zz = $self->{external_zigzag};
    return unless $zz;
    my $segment = $zz->latest_confirmed_segment_before($end);
    return unless $segment;
    my ($from, $to) = ($segment->{from}, $segment->{to});
    my $range = $to->{price} - $from->{price};
    my @ratios = (0, 0.236, 0.382, 0.5, 0.618, 0.786, 1);
    my $leg = {
        from => $from,
        to => $to,
        levels => [ map {
            { ratio => $_, price => $to->{price} - $range * $_ }
        } @ratios ],
    };

    my $right = $state->{right} // $x_of->($end - $start);
    my $fi = $leg->{from}{index} < $start ? $start : $leg->{from}{index};
    my $x1 = $x_of->($fi - $start);

    # Colores: 0/100% en gris neutro (extremos del rango), 50%/61.8% (Fib
    # "golden ratio") destacados, el resto en un tono intermedio.
    my %ratio_color = (
        '0.000' => '#787b86',
        '1.000' => '#787b86',
        '0.500' => '#f0b90b',
        '0.618' => '#f0b90b',
    );

    for my $lvl (@{ $leg->{levels} }) {
        my $y = $self->{scale}->price_to_y($lvl->{price}, $min, $max, $top, $h);
        next if $y < $top || $y > $top + $h;

        my $key   = sprintf('%.3f', $lvl->{ratio});
        my $color = $ratio_color{$key} // '#5b9cff';

        $canvas->createLine($x1, $y, $right, $y,
            -fill  => $color,
            -width => 1,
            -dash  => [3, 2],
            -tags  => 'smc_fib',
        );
        $canvas->createText($right - 4, $y - 7,
            -anchor => 'e',
            -text   => sprintf('%.1f%%', $lvl->{ratio} * 100),
            -fill   => $color,
            -font   => ['Arial', 7, 'bold'],
            -tags   => 'smc_fib',
        );
    }
}

sub _draw_order_blocks {
    my ($self, $canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h, $scope) = @_;

    for my $ob (@{ $smc->order_blocks_in_range($start, $end) }) {
        next if defined($scope) && ($ob->{scope} // 'external') ne $scope;
        my $i1 = $ob->{index};
        my $i2 = defined $ob->{mitigated_at} ? $ob->{mitigated_at} : $end;
        $i1 = $start if $i1 < $start;
        $i2 = $end   if $i2 > $end;

        my $x1 = $x_of->($i1 - $start);
        my $x2 = defined $ob->{mitigated_at}
            ? $x_of->($i2 - $start)
            : ($state->{right} // $x_of->($i2 - $start));
        my $y_top = $self->{scale}->price_to_y($ob->{top},    $min, $max, $top, $h);
        my $y_bot = $self->{scale}->price_to_y($ob->{bottom}, $min, $max, $top, $h);

        # Recorte vertical: si el bloque queda totalmente fuera del panel, saltar.
        next if $y_bot < $top || $y_top > $top + $h;

        my $color = ($ob->{direction} eq 'bullish') ? '#26a69a' : '#ef5350';

        $canvas->createRectangle($x1, $y_top, $x2, $y_bot,
            -fill    => $color,
            -stipple => 'gray12',        # semitransparencia (Tk no tiene alpha real)
            -outline => $color,
            -width   => 1,
            -tags    => 'smc_ob',
        );
        $canvas->createText($x1 + 3, $y_top + 7,
            -anchor => 'w',
            -text   => 'OB',
            -fill   => $color,
            -font   => ['Arial', 7, 'bold'],
            -tags   => 'smc_ob',
        );
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_support_resistance — "Support/Resistence: below support or above
# resistance levels" (cronograma 29/06)
#
# Cada nivel se dibuja como una línea horizontal punteada extendida desde su
# primer toque hasta el borde derecho visible. Resistencia = rojo con etiqueta
# "R"; Soporte = verde con etiqueta "S".
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_support_resistance {
    my ($self, $canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h) = @_;

    my $right = $state->{right} // $x_of->($end - $start);

    for my $lvl (@{ $smc->support_resistance_in_range($start, $end) }) {
        my $y = $self->{scale}->price_to_y($lvl->{price}, $min, $max, $top, $h);
        next if $y < $top || $y > $top + $h;

        my $is_res = ($lvl->{kind} eq 'resistance');
        my $color  = $is_res ? '#ef5350' : '#26a69a';

        my $fi = $lvl->{first_index} < $start ? $start : $lvl->{first_index};
        my $x1 = $x_of->($fi - $start);

        $canvas->createLine($x1, $y, $right, $y,
            -fill  => $color,
            -dash  => [2, 2],
            -width => 1,
            -tags  => 'smc_sr',
        );
        # En Tk, Y crece hacia abajo: resistencia arriba, soporte debajo.
        $canvas->createText($x1 + 4, $y + ($is_res ? -7 : 7),
            -anchor => 'w',
            -text   => $is_res ? 'R' : 'S',
            -fill   => $color,
            -font   => ['Arial', 7, 'bold'],
            -tags   => 'smc_sr',
        );
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_trendlines — "Trendlines/Channels: below or above" (cronograma 29/06)
#
# Cada trendline conecta dos swings mayores consecutivos del mismo tipo. Se
# dibuja el segmento y se EXTIENDE hacia adelante usando slope/intercept
# hasta el borde visible. Resistencia (highs) = rojo; Soporte (lows) = verde.
#
# ── FIX (retroalimentación del profesor: "corregir trendlines porque no
# coincide") ─────────────────────────────────────────────────────────────
# Antes se usaba trendlines_in_range($start,$end): con zoom muy alejado en
# 1m (miles de velas visibles), docenas de canales HISTÓRICOS distintos
# intersectan ese rango tan ancho, y cada uno se extiende hasta el borde
# derecho -> maraña de líneas cruzadas (confirmado con capturas). Ahora se
# usa latest_trendlines_before($end, 2): solo los 2 canales MÁS RECIENTES
# por tipo (resistencia/soporte) hasta el cursor, sin importar el zoom —
# como una herramienta de canal real, no "todo lo que cabe en pantalla".
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_trendlines {
    my ($self, $canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h) = @_;

    my $tl = $smc->latest_channel_before($end, $start);
    return unless $tl;
    for my $which (qw(base parallel)) {
        my $i1 = $tl->{point1}{index};
        my $i2 = $end;                       # extender el canal hacia adelante
        next if $i1 > $end;                  # canal fuera de rango (no debería pasar)
        $i1 = $start if $i1 < $start;

        my $line_intercept = $which eq 'parallel'
            ? $tl->{parallel_intercept} : $tl->{intercept};
        my $p1 = $tl->{slope} * $i1 + $line_intercept;
        my $p2 = $tl->{slope} * $i2 + $line_intercept;

        my $x1 = $x_of->($i1 - $start);
        my $x2 = $x_of->($i2 - $start);
        my $y1 = $self->{scale}->price_to_y($p1, $min, $max, $top, $h);
        my $y2 = $self->{scale}->price_to_y($p2, $min, $max, $top, $h);

        next if ($y1 < $top && $y2 < $top) || ($y1 > $top + $h && $y2 > $top + $h);

        my $color = ($tl->{kind} eq 'resistance') ? '#ef5350' : '#26a69a';

        $canvas->createLine($x1, $y1, $x2, $y2,
            -fill  => $color,
            -width => 1,
            -tags  => 'smc_trend',
        );
        $canvas->createText($x2-4,$y2+(($tl->{kind} eq 'resistance')?-7:7),
            -anchor=>'e',-text=>($tl->{kind} eq 'resistance'?'CHANNEL ABOVE':'CHANNEL BELOW'),
            -fill=>$color,-font=>['Arial',7,'bold'],-tags=>'smc_trend');
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_daily_proximity — cronograma 29/06: "Near daily candle's body & wick"
# (Fase 4 del plan).
#
# El Indicator (_calc_daily_proximity) ya expone daily_proximity() con:
#   { daily_index, body_top, body_bottom, wick_top, wick_bottom,
#     current_price, zone, distance_to_body }
# No es un dato "por vela" del TF activo — es una referencia de la vela
# DIARIA más reciente, igual que "Previous Day High/Low" en TradingView, así
# que se dibuja como líneas horizontales de referencia que cruzan todo el
# ancho visible, no ancladas a un índice de vela concreto.
#
# Cuerpo (body_top/body_bottom) en trazo sólido más grueso; mecha
# (wick_top/wick_bottom) en trazo punteado más fino — para diferenciar
# visualmente cuerpo vs mecha tal como pide la Tabla 4.
# ─────────────────────────────────────────────────────────────────────────────
my $COLOR_DAILY_BODY = '#5b9cff';
my $COLOR_DAILY_WICK = '#5b9cff';

sub _draw_daily_proximity {
    my ($self, $canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h) = @_;

    my $dp = $smc->daily_proximity();
    return unless defined $dp;

    my $left  = $state->{left}  // $x_of->(0);
    my $right = $state->{right} // $x_of->($end - $start);

    # ── Mecha (wick_top / wick_bottom): punteado fino ───────────────────────
    for my $pair (
        [ $dp->{wick_top},    'PDH wick' ],
        [ $dp->{wick_bottom}, 'PDL wick' ],
    ) {
        my ($price, $label) = @$pair;
        my $y = $self->{scale}->price_to_y($price, $min, $max, $top, $h);
        next if $y < $top || $y > $top + $h;

        $canvas->createLine($left, $y, $right, $y,
            -fill  => $COLOR_DAILY_WICK,
            -width => 1,
            -dash  => [2, 3],
            -tags  => 'smc_daily',
        );
        $canvas->createText($right - 4, $y - 7,
            -anchor => 'e',
            -text   => $label,
            -fill   => $COLOR_DAILY_WICK,
            -font   => ['Arial', 7],
            -tags   => 'smc_daily',
        );
    }

    # ── Cuerpo (body_top / body_bottom): sólido, más grueso ─────────────────
    for my $pair (
        [ $dp->{body_top},    'PD body top' ],
        [ $dp->{body_bottom}, 'PD body bot' ],
    ) {
        my ($price, $label) = @$pair;
        my $y = $self->{scale}->price_to_y($price, $min, $max, $top, $h);
        next if $y < $top || $y > $top + $h;

        $canvas->createLine($left, $y, $right, $y,
            -fill  => $COLOR_DAILY_BODY,
            -width => 2,
            -tags  => 'smc_daily',
        );
        $canvas->createText($right - 4, $y - 7,
            -anchor => 'e',
            -text   => $label,
            -fill   => $COLOR_DAILY_BODY,
            -font   => ['Arial', 7, 'bold'],
            -tags   => 'smc_daily',
        );
    }

    # ── Etiqueta de zona actual (above_wick / in_upper_wick / in_body / ... )
    # cerca del precio actual, para responder visualmente "dónde estoy
    # respecto a la vela diaria" sin tener que leer números.
    my $y_cur = $self->{scale}->price_to_y($dp->{current_price}, $min, $max, $top, $h);
    if ($y_cur >= $top && $y_cur <= $top + $h) {
        $canvas->createText($left + 4, $y_cur,
            -anchor => 'w',
            -text   => 'Daily: ' . $dp->{zone},
            -fill   => $COLOR_DAILY_BODY,
            -font   => ['Arial', 7, 'italic'],
            -tags   => 'smc_daily',
        );
    }
}

1;
