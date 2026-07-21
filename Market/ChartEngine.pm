package Market::ChartEngine;
use strict;
use warnings;
use utf8;
use Tk;
use Encode qw(encode decode);
use lib '.';
use POSIX qw(floor ceil);
use Market::Panels::PricePanel;
use Market::Panels::ATRPanel;
use Market::ReplayProxy;
use Market::Overlays::SMC_Structures;
use Market::Overlays::Liquidity;
use Market::Indicators::ZigZagMTF;
use Market::Indicators::ZigZagVolume;
use Market::Overlays::ZigZag;
use Market::Indicators::VolumeProfile;
use Market::Overlays::VolumeProfile;

sub new {
    my ($class, %args) = @_;
    my $self = {
        # ── Estado del gráfico ───────────────────────────────────────────────
        market => $args{market}, indicators => $args{indicators},
        mw => $args{mw}, canvas => undef,
        tf => 1, visible => 160, first => 0,
        left => 4, scale_w => 92, bottom_h => 30,
        atr_h => 170, vol_h => 82, auto_y => 1, auto_atr => 1,
        lock_y_on_zoom => 0,
        price_min => 0, price_max => 1,
        locked_index => undef, mouse_index => undef,
        atr_min => undef,
        atr_max => undef,
        drag => undef, resize_atr => 0,
        debug_scroll => 1, wheel_count => 0,
        price_panel => Market::Panels::PricePanel->new(),
        atr_panel => Market::Panels::ATRPanel->new(),

        # ── 3.5: Overlays SMC y Liquidez ──────────────────────────────────────
        smc_overlay => Market::Overlays::SMC_Structures->new(),
        liq_overlay => Market::Overlays::Liquidity->new(),
        zz_overlay  => Market::Overlays::ZigZag->new(),
        vp_overlay  => Market::Overlays::VolumeProfile->new(),
        vp_visible  => 0,

        # ── Estado del sistema Replay (Fase 2) ───────────────────────────────
        # replay_mode   : 0 = normal, 1 = en modo replay activo
        # replay_cursor : índice de la última vela visible en replay
        #                 (todas las velas con índice > replay_cursor quedan ocultas)
        # replay_speed  : milisegundos entre pasos en modo Play automático
        #                 valores típicos: 500=lento, 200=normal, 80=rápido
        # replay_timer  : referencia al after() activo (undef si pausado/detenido)
        # replay_saved_first    : guarda $self->{first} para restaurarlo al salir
        # replay_saved_visible  : guarda $self->{visible} para restaurarlo al salir
        replay_mode          => 0,
        replay_cursor        => 0,
        replay_speed         => 200,
        replay_timer         => undef,
        replay_playing       => 0,
        replay_saved_first   => undef,
        replay_saved_visible => undef,
        replay_free_view     => 0,     # 1 = usuario hizo zoom/scroll libre en replay
        # replay_picking: 1 cuando el usuario está eligiendo el punto de corte
        # (modo intermedio entre "normal" y "replay activo")
        replay_picking       => 0,
        replay_pick_index    => undef,   # índice bajo el cursor mientras elige
    };
    bless $self, $class;
    return $self;
}

sub run {
    my ($self) = @_;
    my $mw = $self->{mw};
    $mw->title('Motor de Charting - TradingView simple');

    # ── Pantalla completa CON barra de título y controles nativos ───────────
    # A diferencia de -fullscreen (que quita la decoración de la ventana),
    # esto MAXIMIZA la ventana: ocupa toda la pantalla pero conserva la
    # barra de título con los botones nativos de minimizar/restaurar/cerrar.
    $mw->geometry($mw->screenwidth . 'x' . $mw->screenheight . '+0+0');

    # -zoomed es el atributo estándar de Tk para "maximizado" en Linux/X11
    # (equivalente a hacer clic en el botón de maximizar). Mantiene la
    # decoración nativa de la ventana — título, minimizar, restaurar, cerrar.
    eval { $mw->attributes('-zoomed', 1); };

    # Respaldo para Windows/macOS, donde -zoomed no siempre está soportado:
    # state('zoomed') es el equivalente en esos sistemas. Se intenta solo
    # si -zoomed falló, para no aplicar dos mecanismos redundantes en
    # sistemas donde -zoomed ya funcionó correctamente por sí solo.
    if ($@) {
        eval { $mw->state('zoomed'); };
    }

    my $top = $mw->Frame(-background => '#1e222d', -relief => 'flat')->pack(-side => 'top', -fill => 'x');

    # ── Botones Zoom [+][-] ──────────────────────────────────────────────────
    $top->Label(-text => 'Zoom', -foreground => '#b2b5be', -background => '#1e222d',
        -font => ['Arial', 9], -padx => 4, -pady => 5)->pack(-side => 'left');
    $top->Button(
        -text => '+', -relief => 'flat', -borderwidth => 0, -padx => 8, -pady => 5,
        -font => ['Arial', 9, 'bold'], -foreground => '#b2b5be', -background => '#1e222d',
        -activeforeground => '#ffffff', -activebackground => '#2a2e39', -cursor => 'hand2',
        -command => sub { $self->mouse_wheel(120); },
    )->pack(-side => 'left', -padx => 1);
    $top->Button(
        -text => '-', -relief => 'flat', -borderwidth => 0, -padx => 8, -pady => 5,
        -font => ['Arial', 9, 'bold'], -foreground => '#b2b5be', -background => '#1e222d',
        -activeforeground => '#ffffff', -activebackground => '#2a2e39', -cursor => 'hand2',
        -command => sub { $self->mouse_wheel(-120); },
    )->pack(-side => 'left', -padx => 1);

    # Separador
    $top->Label(-text => '|', -foreground => '#363a45', -background => '#1e222d',
        -font => ['Arial', 11], -padx => 4)->pack(-side => 'left');

    # ── Botones P:Auto y ATR:Auto ────────────────────────────────────────────
    my $mode_btn = $top->Button(
        -text             => 'P:Auto',
        -relief           => 'flat',
        -borderwidth      => 0,
        -padx             => 10,
        -pady             => 5,
        -font             => ['Arial', 9, 'bold'],
        -foreground       => '#089981',
        -background       => '#1e222d',
        -activeforeground => '#ffffff',
        -activebackground => '#2a2e39',
        -cursor           => 'hand2',
    );
    $mode_btn->configure(-command => sub {
        $self->{auto_y} = $self->{auto_y} ? 0 : 1;
        $self->{lock_y_on_zoom} = 0;
        if ($self->{auto_y}) {
            $mode_btn->configure(-text => 'P:Auto', -foreground => '#089981');
        } else {
            $mode_btn->configure(-text => 'P:Manual', -foreground => '#ef5350');
        }
        $self->draw;
    });
    $mode_btn->pack(-side => 'left', -padx => 4, -pady => 2);

    my $mode_btn_atr = $top->Button(
        -text             => 'ATR:Auto',
        -relief           => 'flat',
        -borderwidth      => 0,
        -padx             => 10,
        -pady             => 5,
        -font             => ['Arial', 9, 'bold'],
        -foreground       => '#089981',
        -background       => '#1e222d',
        -activeforeground => '#ffffff',
        -activebackground => '#2a2e39',
        -cursor           => 'hand2',
    );
    $mode_btn_atr->configure(-command => sub {
        $self->{auto_atr} = $self->{auto_atr} ? 0 : 1;
        $self->{lock_y_on_zoom} = 0;
        if ($self->{auto_atr}) {
            $mode_btn_atr->configure(-text => 'ATR:Auto', -foreground => '#089981');
            delete $self->{atr_min}; delete $self->{atr_max};
        } else {
            $mode_btn_atr->configure(-text => 'ATR:Manual', -foreground => '#ef5350');
        }
        $self->draw;
    });
    $mode_btn_atr->pack(-side => 'left', -padx => 4, -pady => 2);

    # Separador
    $top->Label(-text => '|', -foreground => '#363a45', -background => '#1e222d',
        -font => ['Arial', 11], -padx => 4)->pack(-side => 'left');

    # Mapa de TF → etiqueta visible en el menú
    my %TF_LABEL = (
        1   => '1m',  5   => '5m',  15  => '15m',
        60  => '1H',  120 => '2H',  240 => '4H',
        'D' => 'D',   'W' => 'W',
    );
    my @TF_ORDER = (1, 5, 15, 60, 120, 240, 'D', 'W');

    # ── Selector de temporalidad — fila de botones inline ────────────────────
    my %tf_btns;
    my $_refresh_tf_btns = sub {
        my ($active_tf) = @_;
        for my $tf (@TF_ORDER) {
            next unless $tf_btns{$tf};
            if ("$tf" eq "$active_tf") {
                $tf_btns{$tf}->configure(-background => '#2962ff', -foreground => '#ffffff', -activebackground => '#1a47cc');
            } else {
                $tf_btns{$tf}->configure(-background => '#1e222d', -foreground => '#b2b5be', -activebackground => '#2a2e39');
            }
        }
    };
    $self->{_refresh_tf_btns} = $_refresh_tf_btns;

    for my $tf (@TF_ORDER) {
        my $tf_copy = $tf;
        my $b = $top->Button(
            -text             => $TF_LABEL{$tf},
            -relief           => 'flat',
            -borderwidth      => 0,
            -padx             => 8,
            -pady             => 5,
            -font             => ['Arial', 9, 'bold'],
            -foreground       => '#b2b5be',
            -background       => '#1e222d',
            -activeforeground => '#ffffff',
            -activebackground => '#2a2e39',
            -cursor           => 'hand2',
        );
        $b->configure(-command => sub {
            $self->set_timeframe($tf_copy);
            $_refresh_tf_btns->($tf_copy);
            $mode_btn->configure(-text => 'P:Auto', -foreground => '#089981');
            $mode_btn_atr->configure(-text => 'ATR:Auto', -foreground => '#089981');
        });
        $b->pack(-side => 'left', -padx => 1);
        $tf_btns{$tf} = $b;
    }
    $_refresh_tf_btns->($self->{tf});

    # ── Variables de estado para overlays ─────────────────────────────────────
    my %smc_var = (
        swings => 0, bos_internal => 0, bos_external => 0,
        choch_internal => 0, choch_external => 0, fvg => 0, fib => 0,
        ob_internal => 0, ob_external => 0, sr => 0, trend => 0,
    );
    my $smc_master = 0;
    my $vp_var = 0;
    my %smc_menu_label = (
        swings => 'Estructura (HH/HL/LH/LL)',
        bos_internal => 'BOS interno',
        bos_external => 'BOS externo',
        choch_internal => 'CHoCH interno',
        choch_external => 'CHoCH externo',
        fvg    => 'FVG',
        fib    => 'Fibonacci',
        ob_internal => 'Order Blocks internos',
        ob_external => 'Order Blocks externos (Swing)',
        sr     => 'Support / Resistance',
        trend  => 'Trendlines / Channels',
    );
    my @smc_order = qw(swings bos_internal bos_external choch_internal choch_external fvg fib ob_internal ob_external sr trend);
    my $refresh_smc = sub {
        for my $k (@smc_order) { $self->{smc_overlay}->set_visible($k, $smc_var{$k}); }
        $self->draw();
    };
    my $sync_smc_master = sub {
        my $all = 1; $all &&= $smc_var{$_} for @smc_order;
        $smc_master = $all ? 1 : 0;
    };
    my $leaf_smc = sub { $refresh_smc->(); $sync_smc_master->(); };

    my %liq_var = (
        bsl => 0, ssl => 0, eqh => 0, eql => 0, sweep => 0, grab => 0, run => 0,
    );
    my $liq_master = 0;
    my %liq_menu_label = (
        bsl    => 'BSL - Buy Side',
        ssl    => 'SSL - Sell Side',
        eqh    => 'EQH',
        eql    => 'EQL',
        sweep  => 'Sweeps',
        grab   => 'Grabs',
        run    => 'Runs',
    );
    my @liq_order = qw(bsl ssl eqh eql sweep grab run);
    my $refresh_liq = sub {
        for my $k (@liq_order) { $self->{liq_overlay}->set_visible($k, $liq_var{$k}); }
        $self->draw();
    };
    my $sync_liq_master = sub {
        my $all = 1; $all &&= $liq_var{$_} for @liq_order;
        $liq_master = $all ? 1 : 0;
    };
    my $leaf_liq = sub { $refresh_liq->(); $sync_liq_master->(); };

    my %zz_var = (zzmtf => 0, zzvolume => 0);
    my $zz_master = 0;
    my %zz_menu_label = (
        zzmtf    => 'Interno (30m)',
        zzvolume => 'Externo (150)',
    );
    my @zz_order = qw(zzmtf zzvolume);
    my $refresh_zz = sub {
        for my $k (@zz_order) { $self->{zz_overlay}->set_visible($k, $zz_var{$k}); }
        $self->draw();
    };
    my $sync_zz_master = sub {
        my $all = 1; $all &&= $zz_var{$_} for @zz_order;
        $zz_master = $all ? 1 : 0;
    };
    my $leaf_zz = sub { $refresh_zz->(); $sync_zz_master->(); };



    # ── Barra de controles Replay ─────────────────────────────────────────────
    # Se crea oculta (pack_forget). Solo se muestra al activar el modo Replay.
    # Simula los controles de TradingView: ⏮ ◀ ▶ ▶▶ ⏸ ✕
    # Colores: fondo naranja oscuro para distinguirla visualmente del toolbar normal.

    my $replay_bar = $mw->Frame(
        -background => '#1a1a2e',
        -relief     => 'flat',
    );
    # NO hacemos pack aquí — empieza oculta

    # Etiqueta de estado en la barra replay
    my $replay_label = $replay_bar->Label(
        -text       => '[R] REPLAY',
        -foreground => '#f59e0b',
        -background => '#1a1a2e',
        -font       => ['Arial', 9, 'bold'],
        -padx       => 8,
    )->pack(-side => 'left');

    # Separador
    $replay_bar->Label(-text => '|', -foreground => '#363a45',
        -background => '#1a1a2e', -font => ['Arial', 11], -padx => 2
    )->pack(-side => 'left');

    # Estilos de botones para la barra replay
    my %RB = (                              # replay button normal
        -relief           => 'flat',
        -borderwidth      => 0,
        -padx             => 10,
        -pady             => 4,
        -font             => ['Arial', 11],
        -foreground       => '#d1d4dc',
        -background       => '#1a1a2e',
        -activeforeground => '#ffffff',
        -activebackground => '#2a2e39',
        -cursor           => 'hand2',
    );

    # ⏮ Ir al inicio del replay
    my $rb_start = $replay_bar->Button(%RB, -text => '|<<',
        -command => sub { $self->replay_go_start() }
    )->pack(-side => 'left', -padx => 1);

    # ◀ Step Backward — retroceder 1 vela
    my $rb_back = $replay_bar->Button(%RB, -text => '< ',
        -command => sub { $self->replay_step(-1) }
    )->pack(-side => 'left', -padx => 1);

    # ▶ Play / Pause — el mismo botón cambia de estado
    # Se declara primero el scalar para poder referenciarlo dentro del -command
    my $rb_play;
    $rb_play = $replay_bar->Button(%RB,
        -text             => ' > ',
        -foreground       => '#22c55e',
        -activeforeground => '#4ade80',
        -command          => sub { $self->replay_toggle_play($rb_play) }
    );
    $rb_play->pack(-side => 'left', -padx => 1);
    $self->{_rb_play} = $rb_play;

    # ▶▶ Fast Forward — duplica la velocidad mientras se mantiene activo
    my $rb_ff = $replay_bar->Button(%RB, -text => '>>',
        -command => sub { $self->replay_fast_forward() }
    )->pack(-side => 'left', -padx => 1);

    # ▶| Step Forward — avanzar 1 vela
    my $rb_fwd = $replay_bar->Button(%RB, -text => ' >|',
        -command => sub { $self->replay_step(1) }
    )->pack(-side => 'left', -padx => 1);

    # Separador antes del exit
    $replay_bar->Label(-text => '|', -foreground => '#363a45',
        -background => '#1a1a2e', -font => ['Arial', 11], -padx => 2
    )->pack(-side => 'left');

    # Etiqueta de vela actual (se actualiza al avanzar)
    my $replay_info = $replay_bar->Label(
        -text       => '',
        -foreground => '#787b86',
        -background => '#1a1a2e',
        -font       => ['Arial', 9],
        -padx       => 6,
        -width      => 22,
        -anchor     => 'w',
    )->pack(-side => 'left');
    $self->{_replay_info} = $replay_info;

    # ✕ Salir del Replay — restaura el modo normal
    my $rb_exit = $replay_bar->Button(%RB,
        -text             => 'X Salir',
        -foreground       => '#ef4444',
        -activeforeground => '#f87171',
        -command          => sub { $self->replay_exit() }
    )->pack(-side => 'right', -padx => 6);

    $self->{_replay_bar}   = $replay_bar;
    $self->{_replay_label} = $replay_label;

    # ── Botón "Replay" en el toolbar principal ────────────────────────────────
    # Separador antes del botón Replay
    $top->Label(-text => '|', -foreground => '#363a45', -background => '#1e222d',
                -font => ['Arial', 11], -padx => 4)->pack(-side => 'left');

    my $replay_btn = $top->Button(
        -text             => '>> Replay',
        -relief           => 'flat',
        -borderwidth      => 0,
        -padx             => 10,
        -pady             => 5,
        -font             => ['Arial', 9, 'bold'],
        -foreground       => '#f59e0b',
        -background       => '#1e222d',
        -activeforeground => '#fbbf24',
        -activebackground => '#2a2e39',
        -cursor           => 'hand2',
        -command          => sub { $self->replay_enter() },
    );
    $replay_btn->pack(-side => 'left', -padx => 2);
    $self->{_replay_btn} = $replay_btn;

    # ── Tools Bar y panel colapsable de Overlays ──────────────────────────────
    # Panel inline colapsable, exactamente igual a trading_view_clone:
    # una barra fija con el botón "Overlays [>]" y un panel que se
    # pack()/packForget() debajo de ella.
    my $BAR_BG   = '#1e222d';
    my $PANEL_BG = '#1e222d';

    my $tools_bar = $mw->Frame(-background => $BAR_BG);
    $tools_bar->Label(-text => 'Herramientas:', -background => $BAR_BG,
        -foreground => '#b2b5be', -font => ['Arial', 9, 'bold'])
        ->pack(-side => 'left', -padx => 8, -pady => 3);

    my $tools_panel = $mw->Frame(-background => $PANEL_BG);

    my $panel_shown = 0;
    my $panel_btn;
    $panel_btn = $tools_bar->Button(
        -text => 'Overlays [>]', -foreground => '#2962ff',
        -background => $BAR_BG, -activebackground => '#2a2e39',
        -relief => 'flat', -bd => 0, -font => ['Arial', 9, 'bold'],
        -cursor => 'hand2',
        -command => sub {
            $panel_shown = !$panel_shown;
            if ($panel_shown) {
                $tools_panel->pack(-side => 'top', -fill => 'x', -before => $tools_bar);
                $panel_btn->configure(-text => 'Overlays [v]');
            } else {
                $tools_panel->packForget;
                $panel_btn->configure(-text => 'Overlays [>]');
            }
        },
    )->pack(-side => 'left', -padx => 4, -pady => 2);
    $self->{_overlays_btn} = $panel_btn;

    $tools_bar->Label(-text => 'Clic en cada herramienta para activar/desactivar de forma independiente',
        -background => $BAR_BG, -foreground => '#787b86', -font => ['Arial', 8])
        ->pack(-side => 'right', -padx => 10);

    $tools_bar->pack(-side => 'top', -fill => 'x');

    # Helpers de construcción del panel
    my $make_col = sub {
        my ($title, $color) = @_;
        my $col = $tools_panel->Frame(-background => $PANEL_BG);
        $col->pack(-side => 'left', -anchor => 'n', -padx => 14, -pady => 6);
        $col->Label(-text => $title, -background => $PANEL_BG, -foreground => $color,
            -font => ['Arial', 9, 'bold'])->pack(-side => 'top', -anchor => 'w');
        return $col;
    };
    my $make_chk = sub {
        my ($parent, $text, $varref, $cmd) = @_;
        my $cb = $parent->Checkbutton(
            -text => $text, -variable => $varref, -onvalue => 1, -offvalue => 0,
            -background => $PANEL_BG, -activebackground => $PANEL_BG,
            -foreground => '#b2b5be', -activeforeground => '#ffffff',
            -selectcolor => '#26a69a',
            -font => ['Arial', 8], -anchor => 'w',
            ( $cmd ? ( -command => $cmd ) : () ),
        );
        $cb->pack(-side => 'top', -anchor => 'w', -fill => 'x');
        return $cb;
    };

    # ── Columna SMC Structures ─────────────────────────────────────────────
    my $col_smc = $make_col->('SMC Structures', '#5b9cff');
    $make_chk->($col_smc, 'Activar SMC', \$smc_master, sub {
        $smc_var{$_} = $smc_master for @smc_order;
        $refresh_smc->();
    });
    $make_chk->($col_smc, $smc_menu_label{swings}, \$smc_var{swings}, $leaf_smc);
    $make_chk->($col_smc, $smc_menu_label{bos_internal}, \$smc_var{bos_internal}, $leaf_smc);
    $make_chk->($col_smc, $smc_menu_label{bos_external}, \$smc_var{bos_external}, $leaf_smc);
    $make_chk->($col_smc, $smc_menu_label{choch_internal}, \$smc_var{choch_internal}, $leaf_smc);
    $make_chk->($col_smc, $smc_menu_label{choch_external}, \$smc_var{choch_external}, $leaf_smc);
    $make_chk->($col_smc, $smc_menu_label{fvg},    \$smc_var{fvg},    $leaf_smc);
    $make_chk->($col_smc, $smc_menu_label{fib},    \$smc_var{fib},    $leaf_smc);
    $make_chk->($col_smc, $smc_menu_label{ob_internal}, \$smc_var{ob_internal}, $leaf_smc);
    $make_chk->($col_smc, $smc_menu_label{ob_external}, \$smc_var{ob_external}, $leaf_smc);
    $make_chk->($col_smc, $smc_menu_label{sr},     \$smc_var{sr},     $leaf_smc);
    $make_chk->($col_smc, $smc_menu_label{trend},  \$smc_var{trend},  $leaf_smc);
    $make_chk->($col_smc, 'Volume Profile (rango visible)', \$vp_var, sub {
        $self->{vp_visible} = $vp_var ? 1 : 0;
        $self->draw();
    });

    # ── Columna Liquidity ──────────────────────────────────────────────────
    my $col_liq = $make_col->('Liquidity', '#ef5350');
    $make_chk->($col_liq, 'Activar Liquidity', \$liq_master, sub {
        $liq_var{$_} = $liq_master for @liq_order;
        $refresh_liq->();
    });
    $make_chk->($col_liq, $liq_menu_label{bsl},   \$liq_var{bsl},   $leaf_liq);
    $make_chk->($col_liq, $liq_menu_label{ssl},   \$liq_var{ssl},   $leaf_liq);
    $make_chk->($col_liq, $liq_menu_label{eqh},   \$liq_var{eqh},   $leaf_liq);
    $make_chk->($col_liq, $liq_menu_label{eql},   \$liq_var{eql},   $leaf_liq);
    $make_chk->($col_liq, $liq_menu_label{sweep}, \$liq_var{sweep}, $leaf_liq);
    $make_chk->($col_liq, $liq_menu_label{grab},  \$liq_var{grab},  $leaf_liq);
    $make_chk->($col_liq, $liq_menu_label{run},   \$liq_var{run},   $leaf_liq);

    # ── Columna ZigZag ─────────────────────────────────────────────────────
    my $col_zz = $make_col->('ZigZag', '#5b9cff');
    $make_chk->($col_zz, 'Activar ZigZag', \$zz_master, sub {
        $zz_var{$_} = $zz_master for @zz_order;
        $refresh_zz->();
    });
    $make_chk->($col_zz, $zz_menu_label{zzmtf},    \$zz_var{zzmtf},    $leaf_zz);
    $make_chk->($col_zz, $zz_menu_label{zzvolume}, \$zz_var{zzvolume}, $leaf_zz);

    my $canvas = $mw->Canvas(-background => '#131722', -highlightthickness => 0)->pack(-fill => 'both', -expand => 1);

    $canvas->configure(-cursor => 'crosshair');

    $self->{canvas} = $canvas;

    # El canvas debe tener el foco de teclado explícitamente para que los
    # binds de teclado (Escape, R, flechas, espacio, +/-) funcionen desde
    # el arranque, sin necesidad de que el usuario haga clic primero.
    $canvas->focus();

    # bindtags([$canvas, $mw]) en vez de bindtags([$canvas]):
    # El canvas sigue procesando primero sus propios eventos de mouse
    # (Motion, ButtonPress, etc. — todos atados directamente a $canvas más
    # abajo), pero ahora los eventos de TECLADO que no tienen un bind
    # específico en $canvas SÍ se propagan a $mw. Esto es lo que permite
    # que Escape, R, flechas, espacio, +/- (todos atados a $mw) funcionen
    # sin tener que duplicar cada uno de ellos también en $canvas.
    $canvas->bindtags([$canvas, $mw]);

    my $configured_once = 0;

    $canvas->Tk::bind('<Configure>' => sub {
        if (!$configured_once) {
            $configured_once = 1;
            $self->fit_all();
        }
        $self->draw();
    });
    $canvas->Tk::bind('<Motion>' => [sub {my ($w, $x, $y, $s) = @_;
        $self->mouse_move($x, $y, $s);
    },
        Tk::Ev('x'), Tk::Ev('y'), Tk::Ev('s')
    ]);

    $canvas->Tk::bind('<ButtonPress-1>' => [
        sub {
            my ($w, $x, $y) = @_;
            $self->mouse_down($x, $y);
        },
        Tk::Ev('x'), Tk::Ev('y')
    ]);

    $canvas->Tk::bind('<B1-Motion>' => [
        sub {
            my ($w, $x, $y) = @_;
            $self->mouse_drag($x, $y);
        },
        Tk::Ev('x'), Tk::Ev('y')
    ]);

    $canvas->Tk::bind('<ButtonRelease-1>' => [
        sub {
            my ($w, $x, $y) = @_;
            $self->mouse_up($x, $y);
        },
        Tk::Ev('x'), Tk::Ev('y')
    ]);
    $canvas->Tk::bind('<Button-4>' => [
    sub {
        my ($w, $x, $y, $s) = @_;
        $self->mouse_wheel(120, $x, $y, $s);
        return "break";
    },
    Tk::Ev('x'), Tk::Ev('y'), Tk::Ev('s')
]);

$canvas->Tk::bind('<Button-5>' => [
    sub {
        my ($w, $x, $y, $s) = @_;
        $self->mouse_wheel(-120, $x, $y, $s);
        return "break";
    },
    Tk::Ev('x'), Tk::Ev('y'), Tk::Ev('s')
]);
$canvas->Tk::bind('<MouseWheel>' => [
    sub {
        my ($w, $delta, $x, $y, $s) = @_;
        $self->mouse_wheel($delta, $x, $y, $s);
        return "break";
    },
    Tk::Ev('D'), Tk::Ev('x'), Tk::Ev('y'), Tk::Ev('s')
]);



    #$mw->Tk::bind('<Button-4>'       => sub { $self->mouse_wheel(120); return 'break'; });
    #$mw->Tk::bind('<Button-5>'       => sub { $self->mouse_wheel(-120); return 'break'; });
    #$mw->Tk::bind('<MouseWheel>'     => sub { $self->mouse_wheel(Tk::Ev('D')); return 'break'; });

    # Teclas de prueba: + separa velas, - junta velas.
    # Sirven para saber si falla la rueda o si falla la logica del zoom.
    $mw->Tk::bind('<plus>'  => sub { $self->mouse_wheel(120); });
    $mw->Tk::bind('<minus>' => sub { $self->mouse_wheel(-120); });
    $mw->Tk::bind('<Escape>' => sub {
        if ($self->{replay_picking}) { $self->replay_cancel_pick(); }
        elsif ($self->{replay_mode}) { $self->replay_exit(); }
        else                         { $mw->destroy; }
    });
    # IMPORTANTE: $canvas->bindtags([$canvas]) (ver arriba, justo después de
    # crear el canvas) corta la propagación normal de eventos del canvas
    # hacia Tk::Widget/Toplevel/MainWindow. Como el canvas es el widget que
    # recibe el foco de teclado real durante el uso normal del programa, el
    # bind de Escape en $mw NUNCA llega a dispararse en la práctica — el
    # evento muere en el canvas porque su bindtags ya no incluye a $mw.
    # Se duplica aquí el mismo bind directamente sobre $canvas para que
    # Escape funcione sin importar qué widget tenga el foco en ese momento.
    $canvas->Tk::bind('<Escape>' => sub {
        if ($self->{replay_picking}) { $self->replay_cancel_pick(); }
        elsif ($self->{replay_mode}) { $self->replay_exit(); }
        else                         { $mw->destroy; }
    });
    # Tecla R: cicla entre normal → picking → (clic activa replay) → exit
    $mw->Tk::bind('<r>' => sub {
        if    ($self->{replay_picking}) { $self->replay_cancel_pick(); }
        elsif ($self->{replay_mode})    { $self->replay_exit(); }
        else                            { $self->replay_enter(); }
    });
    $mw->Tk::bind('<R>' => sub {
        if    ($self->{replay_picking}) { $self->replay_cancel_pick(); }
        elsif ($self->{replay_mode})    { $self->replay_exit(); }
        else                            { $self->replay_enter(); }
    });
    # Flechas del teclado en modo Replay activo: ← retroceder, → avanzar
    $mw->Tk::bind('<Left>'  => sub { $self->replay_step(-1) if $self->{replay_mode}; });
    $mw->Tk::bind('<Right>' => sub { $self->replay_step(1)  if $self->{replay_mode}; });
    # Espacio: play/pause en modo Replay activo
    $mw->Tk::bind('<space>' => sub {
        $self->replay_toggle_play($self->{_rb_play}) if $self->{replay_mode};
    });

    $self->fit_all();
    $self->draw();
    MainLoop;
}


# ─── Replay: contrato de límite de datos ─────────────────────────────────────
# Devuelve el índice máximo visible según el estado actual:
#   - En modo normal    → last_index() del market (todos los datos)
#   - En modo replay    → replay_cursor (solo hasta la vela del cursor)
# Cualquier sub que necesite saber "hasta dónde llegan los datos visibles"
# debe llamar a este método en lugar de $self->{market}->last_index() directamente.
sub _replay_limit {
    my ($self) = @_;
    return $self->{replay_mode}
        ? $self->{replay_cursor}
        : $self->{market}->last_index();
}

# Devuelve 1 si el replay está activo y corriendo (Play), 0 si está pausado o inactivo.
sub replay_running {
    my ($self) = @_;
    return $self->{replay_mode} && $self->{replay_playing};
}



# ═══════════════════════════════════════════════════════════════════════════════
# SISTEMA REPLAY — Lógica completa (Fase 2, punto 2.2 + 2.3)
# ═══════════════════════════════════════════════════════════════════════════════

# Entra al modo Replay desde el modo normal.
# Guarda la posición actual, activa el modo y posiciona el cursor
# al 70% del historial (un punto razonable para empezar a reproducir).
sub replay_enter {
    my ($self) = @_;
    return if $self->{replay_mode};    # ya en replay
    return if $self->{replay_picking}; # ya eligiendo

    # ── Modo selección de punto (2.3-A / 2.3-B) ─────────────────────────────
    # En lugar de saltar al 70% automáticamente, activamos un modo intermedio
    # donde el usuario hace clic sobre la vela donde quiere iniciar el replay.
    $self->{replay_picking}    = 1;
    $self->{replay_pick_index} = undef;

    # Cambiar cursor del canvas a "sb_h_double_arrow" para indicar selección
    $self->{canvas}->configure(-cursor => 'sb_h_double_arrow')
        if $self->{canvas};

    # Cambiar botón a estado "eligiendo"
    $self->{_replay_btn}->configure(
        -text       => '[ Clic para iniciar ]',
        -foreground => '#f59e0b',
        -background => '#2a1a00',
    ) if $self->{_replay_btn};

    # Mostrar instrucción en barra de replay (ocultar botones de control)
    $self->{_replay_bar}->pack(
        -side   => 'top',
        -fill   => 'x',
        -before => $self->{canvas},
    ) if $self->{_replay_bar};

    # Actualizar etiqueta de la barra
    $self->{_replay_label}->configure(
        -text => '[R] Elige el punto de inicio — clic en una vela | Esc para cancelar',
    ) if $self->{_replay_label};

    $self->draw();
}

# Cancela el modo de selección sin entrar al replay.
sub replay_cancel_pick {
    my ($self) = @_;
    return unless $self->{replay_picking};

    $self->{replay_picking}    = 0;
    $self->{replay_pick_index} = undef;

    # Restaurar cursor normal
    $self->{canvas}->configure(-cursor => 'crosshair') if $self->{canvas};

    # Ocultar barra y restaurar botón
    $self->{_replay_bar}->packForget() if $self->{_replay_bar};
    $self->{_replay_btn}->configure(
        -text       => '>> Replay',
        -foreground => '#f59e0b',
        -background => '#1e222d',
    ) if $self->{_replay_btn};

    $self->draw();
}

# Activa el replay real en el índice elegido por el usuario.
# Llamado desde el clic del canvas cuando replay_picking == 1.
sub replay_enter_at {
    my ($self, $index) = @_;
    return unless $self->{replay_picking};

    # Salir del modo selección
    $self->{replay_picking}    = 0;
    $self->{replay_pick_index} = undef;

    # Validar índice
    my $total = $self->{market}->last_index();
    $index = 0      if $index < 0;
    $index = $total if $index > $total;

    # Guardar estado de la vista para restaurar al salir
    $self->{replay_saved_first}   = $self->{first};
    $self->{replay_saved_visible} = $self->{visible};

    # Activar modo replay en el índice elegido
    $self->{replay_mode}   = 1;
    $self->{replay_cursor} = $index;
    $self->{replay_free_view} = 0;   # resetear al comenzar replay desde nuevo punto

    # Restaurar cursor normal
    $self->{canvas}->configure(-cursor => 'crosshair') if $self->{canvas};

    # Actualizar etiqueta de la barra al estado de replay activo
    $self->{_replay_label}->configure(-text => '[R] REPLAY')
        if $self->{_replay_label};

    # Cambiar botón principal
    $self->{_replay_btn}->configure(
        -text       => '>> Replay [ON]',
        -foreground => '#f59e0b',
        -background => '#2a1a00',
    ) if $self->{_replay_btn};

    # Conservar la vista elegida: las siguientes velas ocuparán los espacios
    # vacíos a la derecha, en vez de desplazar las anteriores.
    $self->_replay_recalc_indicators();
    $self->_replay_update_info();
    $self->draw();
}

# Sale del modo Replay y restaura la vista normal completa.
# También cancela el modo selección si estaba activo.
sub replay_exit {
    my ($self) = @_;

    # Si estamos eligiendo punto, cancelar eso primero
    if ($self->{replay_picking}) {
        $self->replay_cancel_pick();
        return;
    }

    return unless $self->{replay_mode};

    # Detener el timer de play si está corriendo
    $self->_replay_stop_timer();

    # Desactivar modo
    $self->{replay_mode}   = 0;
    $self->{replay_cursor} = 0;

    # Restaurar indicadores completos
    $self->{indicators}->reset_all();
    $self->{indicators}->update_last($self->{market});

    # Ocultar barra de controles
    $self->{_replay_bar}->packForget() if $self->{_replay_bar};

    # Restaurar botón principal
    $self->{_replay_btn}->configure(
        -text       => '>> Replay',
        -foreground => '#f59e0b',
        -background => '#1e222d',
    ) if $self->{_replay_btn};

    # Restaurar vista guardada o ir al final
    if (defined $self->{replay_saved_first}) {
        $self->{first}   = $self->{replay_saved_first};
        $self->{visible} = $self->{replay_saved_visible};
        $self->{replay_saved_first}   = undef;
    $self->{replay_free_view}     = 0;   # resetear al salir del replay
        $self->{replay_saved_visible} = undef;
    }
    $self->limit_first();

    if ($self->{auto_y}) {
        delete $self->{price_min}; delete $self->{price_max};
    }
    if ($self->{auto_atr}) {
        delete $self->{atr_min};   delete $self->{atr_max};
    }

    $self->draw();
}

# Avanza o retrocede N velas en el replay.
# $delta = +1 → siguiente vela, $delta = -1 → vela anterior.
sub replay_step {
    my ($self, $delta) = @_;
    return unless $self->{replay_mode};
    return if $self->{replay_picking};

    # Detener play automático si está corriendo
    $self->_replay_stop_timer();
    $self->_replay_update_play_btn(' > ');

    my $total = $self->{market}->last_index();
    $self->{replay_cursor} += $delta;
    $self->{replay_cursor} = 0      if $self->{replay_cursor} < 0;
    $self->{replay_cursor} = $total if $self->{replay_cursor} > $total;

    $self->_replay_recalc_indicators();
    $self->_replay_center_view();
    $self->_replay_update_info();
    $self->draw();
}

# Ir directamente al inicio (primera vela disponible).
sub replay_go_start {
    my ($self) = @_;
    return unless $self->{replay_mode};
    $self->_replay_stop_timer();
    $self->_replay_update_play_btn(' > ');
    $self->{replay_cursor} = 0;
    $self->{first} = 0;
    $self->_replay_recalc_indicators();
    $self->_replay_update_info();
    $self->draw();
}

# Alterna entre Play y Pause.
# Si está pausado → inicia el avance automático.
# Si está corriendo → pausa.
sub replay_toggle_play {
    my ($self, $btn) = @_;
    return unless $self->{replay_mode};

    if ($self->replay_running()) {
        # Pausar
        $self->_replay_stop_timer();
        $self->_replay_update_play_btn(' > ');
    } else {
        # Iniciar play
        $self->{replay_playing} = 1;
        $self->_replay_update_play_btn('||');
        # Programar en vez de ejecutar dentro del clic: Tk actualiza el botón
        # inmediatamente y un solo clic deja un estado inequívoco.
        $self->{replay_timer} = $self->{mw}->after(1, sub { $self->_replay_tick() });
    }
}

# Duplica la velocidad actual durante 10 pasos rápidos, luego vuelve a normal.
sub replay_fast_forward {
    my ($self) = @_;
    return unless $self->{replay_mode};

    my $orig_speed = $self->{replay_speed};
    my $fast_speed = int($orig_speed / 4);
    $fast_speed = 30 if $fast_speed < 30;

    $self->_replay_stop_timer();

    my $steps_left = 20;
    my $ff_tick;
    $ff_tick = sub {
        return unless $self->{replay_mode};
        my $total = $self->{market}->last_index();
        if ($self->{replay_cursor} >= $total || $steps_left <= 0) {
            # El callback actual ya terminó: no dejar un id obsoleto que haga
            # creer a replay_running() que Fast Forward sigue ejecutándose.
            $self->{replay_timer} = undef;
            $self->_replay_update_play_btn(' > ');
            return;
        }
        $self->{replay_cursor}++;
        $steps_left--;
        $self->_replay_recalc_indicators();
        $self->_replay_center_view();
        $self->_replay_update_info();
        $self->draw();
        $self->{replay_timer} = $self->{mw}->after($fast_speed, $ff_tick);
    };
    $self->_replay_update_play_btn('>>');
    $ff_tick->();
}

# ── Helpers internos del Replay ──────────────────────────────────────────────

# Un "tick" del play automático: avanza 1 vela y programa el siguiente tick.
sub _replay_tick {
    my ($self) = @_;
    $self->{replay_timer} = undef; # el callback que nos trajo ya se consumió
    return unless $self->{replay_mode} && $self->{replay_playing};

    my $total = $self->{market}->last_index();

    if ($self->{replay_cursor} >= $total) {
        # Llegamos al final — pausar automáticamente
        $self->{replay_playing} = 0;
        $self->_replay_update_play_btn(' > ');
        return;
    }

    $self->{replay_cursor}++;
    $self->_replay_recalc_indicators();
    $self->_replay_center_view();
    $self->_replay_update_info();
    $self->draw();

    # Programar el siguiente tick
    if ($self->{replay_playing}) {
        $self->{replay_timer} = $self->{mw}->after(
            $self->{replay_speed}, sub { $self->_replay_tick() }
        );
    }
}

# Detiene el timer de avance automático.
sub _replay_stop_timer {
    my ($self) = @_;
    $self->{replay_playing} = 0;
    if (defined $self->{replay_timer}) {
        eval { $self->{mw}->after('cancel', $self->{replay_timer}); };
        $self->{replay_timer} = undef;
    }
}

# Recalcula los indicadores solo hasta replay_cursor.
# CRÍTICO: garantiza que ningún indicador "ve" velas futuras al cursor.
sub _replay_recalc_indicators {
    my ($self) = @_;

    # ── OPTIMIZACIÓN DE RENDIMIENTO ──────────────────────────────────────────
    # Antes se recalculaba TODO el prefijo 0..cursor en cada paso -> O(cursor),
    # ~3-10s por vela con 100k+ velas. Ahora:
    #   • ATR: NO se recalcula. Es causal (solo depende del pasado), así que el
    #     array completo ya calculado sirve para cualquier cursor; el panel solo
    #     dibuja el prefijo hasta el cursor.
    #   • SMC y Liquidity: se recalculan SOLO sobre una VENTANA de las últimas
    #     REPLAY_WINDOW velas (Market::WindowProxy) -> O(W) constante. Verificado:
    #     produce resultados idénticos a 0..cursor en el rango visible, ~50x más
    #     rápido. Cumple el PDF: 'cálculos limitados a velas visibles + ventana
    #     de contexto', sin filtrar velas futuras (la ventana termina en cursor).
    # Contexto proporcional al zoom. 600 cubre holgadamente swings mayores,
    # EQH/EQL y FVG sin bloquear Tk; se amplía solo al hacer zoom muy lejos.
    my $REPLAY_WINDOW = $self->{replay_window};
    if (!defined $REPLAY_WINDOW) {
        $REPLAY_WINDOW = int(($self->{visible} || 160) * 3);
        $REPLAY_WINDOW = 600  if $REPLAY_WINDOW < 600;
        $REPLAY_WINDOW = 1200 if $REPLAY_WINDOW > 1200;
    }

    my $ind = $self->{indicators};
    my $cursor = $self->{replay_cursor};

    my $wproxy = Market::WindowProxy->new($self->{market}, $cursor, $REPLAY_WINDOW);

    my $smc = $ind->get_indicator('SMC_Structures');
    $smc->calculate_all($wproxy) if defined $smc;

    my $liq = $ind->get_indicator('Liquidity');
    $liq->calculate_replay($wproxy) if defined $liq;
    $smc->apply_liquidity_context($liq) if $smc && $liq && $smc->can('apply_liquidity_context');

    # ATR: intencionalmente NO se recalcula (ver comentario arriba).

    # ZigZagMTF y ZigZagVolume: SÍ se recalculan en cada paso de replay.
    # El tramo tentativo debe actualizarse con cada nueva vela para que
    # el zigzag siga el precio en tiempo real (como TradingView en replay).
    my $zzm = $ind->get_indicator('ZigZagMTF');
    $zzm->calculate_all($wproxy) if defined $zzm;

    my $zzv = $ind->get_indicator('ZigZagVolume');
    $zzv->calculate_all($wproxy) if defined $zzv;
}

# Mantiene las posiciones mientras el cursor cabe en pantalla. Solo desplaza
# la ventana cuando la nueva vela supera el borde derecho.
sub _replay_center_view {
    my ($self) = @_;
    my $cursor = $self->{replay_cursor};
    my $start = int($self->{first});
    my $end   = $start + $self->{visible} - 1;
    my $changed = 0;
    if ($cursor > $end) {
        $self->{first} += $cursor - $end;
        $changed = 1;
    } elsif ($cursor < $start) {
        $self->{first} = $cursor;
        $changed = 1;
    }
    return unless $changed;
    if ($self->{auto_y}) {
        delete $self->{price_min}; delete $self->{price_max};
    }
    if ($self->{auto_atr}) {
        delete $self->{atr_min};   delete $self->{atr_max};
    }
}

# Actualiza la etiqueta de información (fecha/hora de la vela actual).
sub _replay_update_info {
    my ($self) = @_;
    return unless defined $self->{_replay_info};
    my $candle = $self->{market}->get_candle($self->{replay_cursor});
    return unless defined $candle;
    my $time = $candle->{time} // '';
    # Extraer fecha y hora: "2026-04-15T09:30:00-05:00" → "15/04 09:30"
    my ($date, $hh, $mm) = $time =~ /(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})/;
    my $label = '';
    if (defined $date) {
        my ($y, $m, $d) = split /-/, $date;
        my $total = $self->{market}->last_index();
        my $pct   = $total > 0 ? int($self->{replay_cursor} / $total * 100) : 0;
        $label = sprintf "%s/%s %s:%s  [%d%%]", $d, $m, $hh, $mm, $pct;
    }
    $self->{_replay_info}->configure(-text => $label);
}

# Actualiza el texto del botón Play/Pause.
sub _replay_update_play_btn {
    my ($self, $text) = @_;
    return unless defined $self->{_rb_play};
    $self->{_rb_play}->configure(-text => $text);
}

# ═══════════════════════════════════════════════════════════════════════════════

sub set_timeframe {
    my ($self, $tf) = @_;

    # ── FIX: set_timeframe() ignoraba el Replay ──────────────────────────
    # Antes, cambiar de temporalidad SIEMPRE llamaba a
    # $indicators->update_last($self->{market}) con el market SIN acotar,
    # sin importar si $self->{replay_mode} estaba activo. Eso recalculaba
    # SMC/Liquidity/ZigZag con el dataset COMPLETO — fuga de velas futuras
    # exactamente en el caso "cambio de TF durante un Replay en curso".
    #
    # Además, replay_cursor es un índice de la TF ANTERIOR; los índices no
    # significan lo mismo en la TF nueva, así que hay que reproyectarlo por
    # tiempo (epoch) antes de recalcular, para no perder ni adelantar el
    # punto exacto donde estaba el Replay.
    my $old_cursor_epoch;
    if ($self->{replay_mode}) {
        my $c = $self->{market}->get_candle($self->{replay_cursor});
        $old_cursor_epoch = $c->{epoch} if defined $c;
    }

    $self->{tf} = $tf;
    $self->{market}->set_timeframe($tf);
    $self->{indicators}->reset_all();

    # ── FIX (incrementalidad de FVG): invalidar el caché persistente de
    # FVG explícitamente al cambiar de TF. _sync_fvg() mantiene su estado
    # en índices GLOBALES entre llamadas para no recalcular todo el
    # historial en cada paso — pero el índice 500 en 1m no es la misma
    # vela que el índice 500 en 15m, así que la heurística automática de
    # "el cursor avanzó" no es fiable ante un cambio de TF. Forzar un
    # recálculo completo aquí (una sola vez, no en cada step) evita
    # mezclar FVGs de una TF con velas de otra.
    my $smc_ind = $self->{indicators}->get_indicator('SMC_Structures');
    $smc_ind->invalidate_fvg_cache() if defined $smc_ind;

    # ATR es causal (solo mira hacia atrás): recalcularlo sobre el market
    # completo NUNCA filtra futuro, se haga o no Replay, así que siempre se
    # recalcula igual que antes.
    my $atr = $self->{indicators}->get_indicator('ATR');
    $atr->calculate_all($self->{market}) if defined $atr;

    if ($self->{replay_mode}) {
        # Reproyectar el cursor a la nueva TF por epoch.
        if (defined $old_cursor_epoch) {
            my $new_idx = $self->{market}->index_at_epoch($old_cursor_epoch);
            $self->{replay_cursor} = $new_idx >= 0 ? $new_idx : 0;
        }
        my $total = $self->{market}->last_index();
        $self->{replay_cursor} = 0     if $self->{replay_cursor} < 0;
        $self->{replay_cursor} = $total if $self->{replay_cursor} > $total;

        # Recalcula SMC/Liquidity/ZigZag* acotados al cursor (WindowProxy),
        # igual que cualquier otro paso del Replay — sin fuga de futuro.
        $self->_replay_recalc_indicators();
    } else {
        $self->{indicators}->update_last($self->{market});
    }

    $self->{locked_index} = undef;
    $self->{lock_y_on_zoom} = 0;
    $self->fit_all();
    $self->draw();
}

sub fit_all {
    my ($self) = @_;
    my $n = $self->_replay_limit() + 1;   # +1 porque limit es índice base-0
    return if $n <= 0;

    $self->{visible} = 180;
    $self->{visible} = $n + 4 if $n < 180;

    $self->{first} = $n - $self->{visible} + 2;
    $self->limit_first();
}

sub layout {
    my ($self) = @_;
    my $c = $self->{canvas};
    my $w = $c->width  || 1200;
    my $h = $c->height || 700;
    my $right = $w - $self->{scale_w};
    # Los paneles siempre quedan fijos: precio arriba y ATR abajo.
    # El zoom horizontal no debe cambiar estas posiciones.
    $self->{atr_h} = 80  if $self->{atr_h} < 80;
    $self->{atr_h} = 320 if $self->{atr_h} > 320;
    my $atr_top = $h - $self->{bottom_h} - $self->{atr_h};
    $atr_top = 120 if $atr_top < 120;
    my $price_h = $atr_top;
    my $plot_w = $right - $self->{left};
    
    my $step = $plot_w / $self->{visible};  
    my $bar_w = $step * 0.65;

    $bar_w = 1 if $bar_w < 1;
    $bar_w = 120 if $bar_w > 120;


    return ($w, $h, $right, $atr_top, $price_h, $plot_w, $bar_w);
}


sub request_draw {
    my ($self) = @_;
    return if $self->{_render_pending};
    $self->{_render_pending} = 1;
    my $mw = $self->{mw};
    $mw->after(16, sub {
        $self->{_render_pending} = 0;
        $self->draw();
    });
}

sub _draw_crosshair_only {
    my ($self) = @_;
    my $ctx = $self->{_last_render_ctx};
    return $self->draw() if !$ctx;
    my $c = $self->{canvas};
    return if !$c;
    $c->delete('crosshair');
    $self->draw_crosshair(
        $ctx->{start}, $ctx->{end}, $ctx->{x_of}, $ctx->{right}, $ctx->{h}, $ctx->{state}
    ) if defined $self->{mouse_x};
}

sub draw {
    my ($self) = @_;
    my $c = $self->{canvas};
    return if !$c;
    $c->delete('all');

    my ($w, $h, $right, $atr_top, $price_h, $plot_w, $bar_w) = $self->layout();

    # --- Fondos de ejes (capa base, se dibuja primero) ---
    # Franja derecha: eje Y
    $c->createRectangle(
        $right, 0, $w, $h,
        -fill => '#0f1117', -outline => '#0f1117'
    );
    $c->createLine($right, 0, $right, $h, -fill => '#2a2e39', -width => 1);

    # Franja inferior: eje X
    $c->createRectangle(
        0, $h - $self->{bottom_h}, $w, $h,
        -fill => '#0f1117', -outline => '#0f1117'
    );
    $c->createLine(0, $h - $self->{bottom_h}, $w, $h - $self->{bottom_h},
        -fill => '#2a2e39', -width => 1);
    # --- Fin fondos de ejes ---

    

    my $last = $self->_replay_limit();   # En replay: solo velas hasta el cursor
    my $start = floor($self->{first});
    my $end = ceil($self->{first} + $self->{visible} - 1);
    
    


    $start = 0 if $start < 0;
    $end = $last if $end > $last;

    my $data = $self->{market}->get_slice($start, $end);
    my $atr = $self->{indicators}->slice_array('ATR', $start, $end);



    

    my $step = $plot_w / $self->{visible};

    my $x_of = sub {
        my ($local_i) = @_;
        my $global_i = $start + $local_i;

        return $self->{left}
            + ($step / 2)
            + ($global_i - $self->{first}) * $step;
    };

    my %state = (
        w => $w, h => $h, left => $self->{left}, right => $right, scale_w => $self->{scale_w},
        top => 0, price_h => $price_h, atr_top => $atr_top, atr_h => $self->{atr_h},
        vol_h => $self->{vol_h}, bar_w => $bar_w, auto_y => $self->{auto_y},
        auto_atr => $self->{auto_atr},
        lock_y => $self->{lock_y_on_zoom},
        price_min => $self->{price_min}, price_max => $self->{price_max}, tf => $self->{tf},
        atr_min => $self->{atr_min},
        atr_max => $self->{atr_max},
        start_index => $start,
        end_index   => $end,
        mouse_index => $self->{mouse_index},
        last_candle => $self->{market}->last_candle(),
    );

    # Los Order Blocks activos también participan del autoescalado para que
    # las zonas proyectadas por encima/debajo del precio no queden recortadas.
    my $smc_ind = $self->{indicators}->get_indicator('SMC_Structures');
    if (defined $smc_ind && ($self->{smc_overlay}->is_visible('ob_internal')
                          || $self->{smc_overlay}->is_visible('ob_external'))) {
        my $obs = $smc_ind->order_blocks_in_range($start, $end);
        for my $ob (@$obs) {
            next if defined $ob->{mitigated_at};
            next if ($ob->{scope} // 'external') eq 'internal'
                 && !$self->{smc_overlay}->is_visible('ob_internal');
            next if ($ob->{scope} // 'external') eq 'external'
                 && !$self->{smc_overlay}->is_visible('ob_external');
            $state{overlay_price_min} = $ob->{bottom}
                if !defined($state{overlay_price_min}) || $ob->{bottom} < $state{overlay_price_min};
            $state{overlay_price_max} = $ob->{top}
                if !defined($state{overlay_price_max}) || $ob->{top} > $state{overlay_price_max};
        }
    }
    if (defined $smc_ind && $self->{smc_overlay}->is_visible('fvg')) {
        my $fvgs = $smc_ind->recent_fvgs_in_range($start, $end, 3);
        for my $fvg (@$fvgs) {
            next if defined $fvg->{mitigated_at};
            $state{overlay_price_min} = $fvg->{bottom}
                if !defined($state{overlay_price_min}) || $fvg->{bottom} < $state{overlay_price_min};
            $state{overlay_price_max} = $fvg->{top}
                if !defined($state{overlay_price_max}) || $fvg->{top} > $state{overlay_price_max};
        }
    }

    $self->draw_time_axis($start, $end, $x_of, $right, $h);
    $self->{price_panel}->draw($c, $data, $x_of, \%state);
    $self->{price_min} = $state{price_min};
    $self->{price_max} = $state{price_max};

    if ($self->{vp_visible} && @$data) {
        my $profile = Market::Indicators::VolumeProfile::compute_profile(
            $data, row_size => 80, value_area_pct => 70,
            tick_size => 0.25, volume_mode => 'updown',
        );
        $self->{vp_overlay}->draw_result($c, $profile, $x_of, \%state);
    }

    # ── 3.5: Overlays SMC y Liquidez ──────────────────────────────────────────
    # Se dibujan DESPUÉS de las velas (para quedar encima) y ANTES del ATR
    # (que tiene su propio fondo). Reciben los indicadores ya calculados por
    # el IndicatorManager — cero lógica de detección aquí, solo renderizado,
    # tal como exige la separación Indicators/Overlays de la Tabla 1 del PDF.
    #
    # Compatibilidad con Replay: $state{start_index}/end_index ya vienen
    # acotados por _replay_limit() (ver arriba: "$last = $self->_replay_limit()"),
    # así que los overlays automáticamente dejan de dibujar más allá del
    # cursor sin necesitar saber nada sobre el modo Replay.
    $self->{smc_overlay}->draw($c, $smc_ind, $x_of, \%state) if defined $smc_ind;

    my $liq_ind = $self->{indicators}->get_indicator('Liquidity');
    $self->{liq_overlay}->draw($c, $liq_ind, $x_of, \%state) if defined $liq_ind;

    my $zzm_ind = $self->{indicators}->get_indicator('ZigZagMTF');
    my $zzv_ind = $self->{indicators}->get_indicator('ZigZagVolume');
    $self->{zz_overlay}->draw($c, $zzm_ind, $zzv_ind, $x_of, \%state);

    # Limpia el área del ATR para ocultar cualquier vela/volumen que se haya pasado.
    $c->createRectangle(
        $self->{left}, $atr_top,
        $right, $h - $self->{bottom_h},
        -fill => '#131722',
        -outline => '#131722'
    );

$c->createLine($self->{left}, $atr_top, $right, $atr_top, -fill => '#2a2e39', -width => 1);

$self->{atr_panel}->draw($c, $atr, $x_of, \%state);


    $self->{atr_min} = $state{atr_min};
    $self->{atr_max} = $state{atr_max};

    # Contexto de render usado para redibujar solo el crosshair al mover el mouse.
    # Así se evita repintar miles de velas solo por mover el cursor.
    $self->{_last_render_ctx} = {
        start => $start, end => $end, x_of => $x_of, right => $right, h => $h, state => { %state },
    };

    $self->draw_crosshair($start, $end, $x_of, $right, $h, \%state) if defined $self->{mouse_x};

    # ── Overlay modo selección de punto Replay (2.3-A / 2.3-B) ──────────────
    # Mientras el usuario elige dónde cortar, mostramos:
    # 1. Zona sombreada gris oscuro desde el cursor hasta el borde derecho
    #    (representa las velas "futuras" que quedarán ocultas)
    # 2. Línea vertical amarilla punteada siguiendo al mouse
    # 3. Etiqueta con la fecha/hora de la vela bajo el cursor
    if ($self->{replay_picking} && defined $self->{replay_pick_index}) {
        my $pick = $self->{replay_pick_index};
        if ($pick >= $start && $pick <= $end) {
            my $local_i = $pick - $start;
            my $px = $x_of->($local_i);

            # Zona sombreada: desde la línea hasta el borde derecho del área de precio
            if ($px < $right) {
                $c->createRectangle(
                    $px, 0, $right, $h - $self->{bottom_h},
                    -fill    => '#1a1a2e',
                    -outline => '',
                    -stipple => 'gray50',
                    -tags    => 'replay_pick',
                );
            }

            # Línea vertical de selección — amarilla sólida
            $c->createLine($px, 0, $px, $h - $self->{bottom_h},
                -fill  => '#f59e0b',
                -width => 2,
                -tags  => 'replay_pick',
            );

            # Triángulo indicador en la parte superior
            $c->createPolygon(
                $px - 7, 2,
                $px + 7, 2,
                $px,     14,
                -fill    => '#f59e0b',
                -outline => '',
                -tags    => 'replay_pick',
            );

            # Etiqueta de fecha/hora bajo la línea en el eje X
            my $candle = $self->{market}->get_candle($pick);
            if (defined $candle) {
                my ($date, $hh, $mm) = ($candle->{time} // '')
                    =~ /(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})/;
                if (defined $date) {
                    my ($y, $m, $d) = split /-/, $date;
                    my $label = "$d/$m $hh:$mm";
                    my $lw    = length($label) * 6 + 12;
                    my $lx    = $px;
                    $lx = $self->{left} + $lw / 2 + 2 if $lx < $self->{left} + $lw / 2;
                    $lx = $right - $lw / 2 - 2        if $lx > $right - $lw / 2;

                    $c->createRectangle(
                        $lx - $lw/2, $h - 28,
                        $lx + $lw/2, $h - 10,
                        -fill    => '#f59e0b',
                        -outline => '#f59e0b',
                        -tags    => 'replay_pick',
                    );
                    $c->createText($lx, $h - 19,
                        -text => $label,
                        -fill => '#000000',
                        -font => ['Arial', 8, 'bold'],
                        -tags => 'replay_pick',
                    );
                }
            }
        }
    }

    # ── Overlay del cursor Replay (modo activo) ───────────────────────────────
    # 2.3D: Zona sombreada que cubre las velas "futuras" (derecha del cursor).
    # En TradingView se ve como un área gris semitransparente que indica
    # "esto todavía no ha ocurrido". Luego encima va la línea naranja.
    if ($self->{replay_mode}) {
        my $cur = $self->{replay_cursor};
        my $local_i = $cur - $start;
        my $cx = $x_of->($local_i);

        # Zona del futuro: desde la línea del cursor hasta el borde derecho
        # Solo si el cursor está dentro de la ventana visible
        if ($cx >= $self->{left} && $cx < $right) {
            $c->createRectangle(
                $cx, 0, $right, $h - $self->{bottom_h},
                -fill    => '#0d1117',
                -outline => '',
                -stipple => 'gray25',
                -tags    => 'replay_future',
            );
        } elsif ($cx < $self->{left}) {
            # El cursor está fuera del borde izquierdo — toda la ventana es futuro
            $c->createRectangle(
                $self->{left}, 0, $right, $h - $self->{bottom_h},
                -fill    => '#0d1117',
                -outline => '',
                -stipple => 'gray25',
                -tags    => 'replay_future',
            );
        }
        # Si cx >= right el cursor está fuera de la vista a la derecha — no hay futuro visible

        # Línea vertical naranja discontinua sobre la zona sombreada
        if ($cur >= $start && $cur <= $end) {
            $c->createLine($cx, 0, $cx, $h - $self->{bottom_h},
                -fill  => '#f59e0b',
                -width => 2,
                -dash  => [6, 3],
                -tags  => 'replay_cursor',
            );
            # Marcador ">" en la parte superior de la línea
            $c->createText($cx, 12,
                -text  => '>',
                -fill  => '#f59e0b',
                -font  => ['Arial', 10, 'bold'],
                -tags  => 'replay_cursor',
            );
        }
    }
}

sub draw_time_axis {
    my ($self, $start, $end, $x_of, $right, $h) = @_;
    my $c = $self->{canvas};
    my $data = $self->{market}->get_slice($start, $end);
    return if !@$data;

    my $tf = $self->{tf};

    # ── TF diario o semanal: solo mostrar mes/año cuando cambia ──────────────
    if ($tf eq 'D' || $tf eq 'W') {
        my $last_month = '';
        my $last_x     = -9999;
        for my $i (0 .. $#$data) {
            my $time = $data->[$i]{time};
            my ($y, $m, $d) = $time =~ /(\d{4})-(\d{2})-(\d{2})/;
            next if !defined $y;
            my $month_key = "$y-$m";
            my $x = $x_of->($i);
            next if $x < $self->{left} || $x > $right;

            # Línea de separación al cambiar de mes
            if ($month_key ne $last_month) {
                $c->createLine($x, 0, $x, $h - $self->{bottom_h},
                    -fill => '#363a45', -tags => 'grid');
                if ($x - $last_x >= 40) {
                    my @months = qw(Ene Feb Mar Abr May Jun Jul Ago Sep Oct Nov Dic);
                    my $label  = $months[$m - 1] . " $y";
                    my $xl = $x;
                    $xl = $self->{left} + 28 if $xl < $self->{left} + 28;
                    $xl = $right - 28        if $xl > $right - 28;
                    $c->createText($xl, $h - 14,
                        -text => $label, -fill => '#d1d4dc',
                        -font => ['Arial', 9, 'bold'], -tags => 'time');
                    $last_x = $x;
                }
                $last_month = $month_key;
            }
        }
        return;
    }

    # ── TF horario (1H, 2H, 4H): mostrar fecha al cambiar de día + hora ──────
    if ($tf >= 60) {
        my $last_day = '';
        my $last_x   = -9999;
        for my $i (0 .. $#$data) {
            my $time = $data->[$i]{time};
            my ($date, $hh, $mm) = $time =~ /(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})/;
            next if !defined $date;
            my $x = $x_of->($i);
            next if $x < $self->{left} || $x > $right;

            if ($date ne $last_day) {
                $c->createLine($x, 0, $x, $h - $self->{bottom_h},
                    -fill => '#363a45', -tags => 'grid');
                if ($x - $last_x >= 40) {
                    my ($y, $m, $d) = split /-/, $date;
                    my $xl = $x;
                    $xl = $self->{left} + 28 if $xl < $self->{left} + 28;
                    $xl = $right - 28        if $xl > $right - 28;
                    $c->createText($xl, $h - 14,
                        -text => "$d/$m", -fill => '#d1d4dc',
                        -font => ['Arial', 9, 'bold'], -tags => 'time');
                    $last_x = $x;
                }
                $last_day = $date;
            } else {
                # Etiqueta de hora dentro del mismo día
                next if $x - $last_x < 55;
                $c->createLine($x, 0, $x, $h - $self->{bottom_h},
                    -fill => '#2a2e39', -tags => 'grid');
                $c->createText($x, $h - 14,
                    -text => "$hh:$mm", -fill => '#787b86',
                    -font => ['Arial', 9, 'normal'], -tags => 'time');
                $last_x = $x;
            }
        }
        return;
    }

    # ── TF de minutos (1m, 5m, 15m): lógica original optimizada ─────────────
    my @day_positions;
    my $last_day_x = -9999;
    my $min_day_gap = 48;

    for my $i (0 .. $#$data) {
        my $time = $data->[$i]{time};
        my ($date) = $time =~ /(\d{4}-\d{2}-\d{2})/;
        next if !defined $date;
        my $prev = $i > 0 ? $data->[$i-1]{time} : '';
        my ($prev_date) = $prev =~ /(\d{4}-\d{2}-\d{2})/;
        my $new_day = defined($prev_date) && $date ne $prev_date;
        next if !$new_day;

        my $x = $x_of->($i);
        next if $x < $self->{left} || $x > $right;
        push @day_positions, $x;
        $c->createLine($x, 0, $x, $h - $self->{bottom_h}, -fill => '#363a45', -tags => 'grid');
        next if $x - $last_day_x < $min_day_gap;
        $last_day_x = $x;
        my $x_label = $x;
        $x_label = $self->{left} + 28 if $x_label < $self->{left} + 28;
        $x_label = $right - 28        if $x_label > $right - 28;
        $c->createText($x_label, $h - 14,
            -text => _day_label($date), -fill => '#d1d4dc',
            -font => ['Arial', 9, 'bold'], -tags => 'time');
    }

    my $visible = scalar(@$data);
    my $stride  = int($visible / 12);
    $stride = 1 if $stride < 1;
    my $last_label_x = -9999;

    for (my $i = 0; $i <= $#$data; $i += $stride) {
        my $time = $data->[$i]{time};
        my ($date, $hh, $mm) = $time =~ /(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})/;
        next if !defined $date;
        my $x = $x_of->($i);
        next if $x < $self->{left} || $x > $right;

        my $near_day = 0;
        for my $day_x (@day_positions) {
            if (abs($x - $day_x) < 55) { $near_day = 1; last; }
        }
        next if $near_day;
        next if $x - $last_label_x < 55;
        $last_label_x = $x;

        $c->createLine($x, 0, $x, $h - $self->{bottom_h}, -fill => '#2a2e39', -tags => 'grid');
        $c->createText($x, $h - 14,
            -text => "$hh:$mm", -fill => '#787b86',
            -font => ['Arial', 9, 'normal'], -tags => 'time');
    }
}

sub _day_label {
    my ($date) = @_;
    my ($y, $m, $d) = split /-/, $date;
    return "$d/$m";
}

sub draw_crosshair {
    my ($self, $start, $end, $x_of, $right, $h, $state) = @_;

    my $c = $self->{canvas};

    return if !defined $self->{mouse_x};
    return if !defined $self->{mouse_y};

    my $x = $self->{mouse_x};
    my $y = $self->{mouse_y};

    return if $x < $self->{left};
    return if $x > $right;

    my $idx = $self->x_to_index($x);
    $idx = $start if $idx < $start;
    $idx = $end   if $idx > $end;

    my $local_i = $idx - $start;
    my $candle = $self->{market}->get_candle($idx);

    # Snap horizontal: la línea vertical se pega al centro de la vela.
    if ($candle) {
        $x = $x_of->($local_i);
    }
# Snap vertical a O/H/L/C solo si el mouse está cerca de esos precios.
if ($candle && $y < $state->{atr_top}) {

    my @levels = (
        $candle->{open},
        $candle->{high},
        $candle->{low},
        $candle->{close},
    );

    my $best_y;
    my $best_dist = 999999;

    for my $price (@levels) {
        my $level_y = $self->{price_panel}->{scale}->price_to_y(
            $price,
            $self->{price_min},
            $self->{price_max},
            0,
            $state->{price_h}
        );

        my $dist = abs($y - $level_y);

        if ($dist < $best_dist) {
            $best_dist = $dist;
            $best_y = $level_y;
        }
    }

    # Sensibilidad del snap: 8 px.
    # Sube a 12 si quieres que se pegue más fácil.
    if ($best_dist <= 8) {
        $y = $best_y;
    }
}



    # Línea vertical y horizontal del crosshair
    $c->createLine($x, 0, $x, $h - $self->{bottom_h},
        -fill => '#9598a1', -dash => [4,4], -tags => 'crosshair');

    $c->createLine($self->{left}, $y, $right, $y,
        -fill => '#9598a1', -dash => [4,4], -tags => 'crosshair');




    my $label;

    if ($y < $state->{atr_top}) {
        my $price = $self->{price_panel}->{scale}->y_to_price(
    $y,
    $self->{price_min},
    $self->{price_max},
    0,
    $state->{price_h}
);

$price = _round_to_tick($price, 0.25);
$label = sprintf("%.2f", $price);
    } else {
        $label = sprintf("%.2f", $self->{atr_panel}->{scale}->y_to_price(
            $y,
            $self->{atr_min},
            $self->{atr_max},
            $state->{atr_top},
            $state->{atr_h}
        ));
    }

    $c->createRectangle($right + 2, $y - 10, $right + $self->{scale_w} - 5, $y + 10,
        -fill => '#c62828', -outline => '#c62828', -tags => 'crosshair');

    $c->createText($right + 8, $y,
        -anchor => 'w',
        -text => $label,
        -fill => 'white', -tags => 'crosshair');

    

    if ($candle && $y < $h - $self->{bottom_h}) {
        my ($date, $hhmm) = $candle->{time} =~ /(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/;

        my $label_x = $x;

        # Mantener la etiqueta negra dentro del área visible.
        my $label_half_w = 55;
        my $min_x = $self->{left} + $label_half_w;
        my $max_x = $right - $label_half_w;

        $label_x = $min_x if $label_x < $min_x;
        $label_x = $max_x if $label_x > $max_x;

        $c->createRectangle($label_x - $label_half_w, $h - 34,
                            $label_x + $label_half_w, $h - 12,
            -fill => '#363a45', -outline => '#363a45', -tags => 'crosshair');

        $c->createText($label_x, $h - 23,
            -text => "$date  $hhmm",
            -fill => '#d1d4dc',
            -font => ['Arial', 9], -tags => 'crosshair');
    }


    # Mostrar OHLC de la vela actual del crosshair
if ($candle) {
    my $ohlc = sprintf(
        "O %.2f   H %.2f   L %.2f   C %.2f",
        $candle->{open},
        $candle->{high},
        $candle->{low},
        $candle->{close}
    );

    my $color = ($candle->{close} >= $candle->{open}) ? '#089981' : '#f23645';

    $c->createText(
        $self->{left} + 8,
        16,
        -anchor => 'w',
        -text => $ohlc,
        -fill => $color,
        -font => ['Arial', 10, 'bold'],
        -tags => 'crosshair'
    );
}
}

sub mouse_move {
    my ($self, $x, $y, $state) = @_;

    $self->{mouse_x} = $x;
    $self->{mouse_y} = $y;
    $self->{ctrl_down} = ($state & 0x0004) ? 1 : 0;

    my $idx = $self->x_to_index($x);
    my $last = $self->{market}->last_index();

    $idx = 0 if $idx < 0;
    $idx = $last if $idx > $last;

    $self->{mouse_index} = $idx;

    # ── Modo selección de punto Replay (2.3-B) ───────────────────────────────
    # Durante el picking, actualizar el índice bajo el cursor y redibujar
    # para mostrar el preview de la línea de corte.
    if ($self->{replay_picking}) {
        $self->{replay_pick_index} = $idx;
        $self->draw();   # redibuja con el overlay de preview
        return;
    }

    $self->_draw_crosshair_only();
    return;
}

sub x_to_index {
    my ($self, $x) = @_;
    my ($w, $h, $right, $atr_top, $price_h, $plot_w) = $self->layout();

    my $step = $plot_w / $self->{visible};

    my $idx = int(
        $self->{first}
        + (($x - $self->{left} - ($step / 2)) / $step)
        + 0.5
    );

    $idx = 0 if $idx < 0;
    $idx = $self->{market}->last_index if $idx > $self->{market}->last_index;

    return $idx;
}

sub mouse_down {
    my ($self, $x, $y) = @_;
    my ($w, $h, $right, $atr_top) = $self->layout();

    # ── Modo selección de punto Replay (2.3-A) ───────────────────────────────
    # Si estamos en modo "picking", cualquier clic en el área de precio o ATR
    # (no en los ejes) confirma el punto de inicio del replay.
    if ($self->{replay_picking}) {
        if ($x >= $self->{left} && $x < $right && $y < $h - $self->{bottom_h}) {
            my $idx = $self->x_to_index($x);
            $self->replay_enter_at($idx);
        }
        return;   # consumir el evento — no hacer drag ni zoom en este modo
    }

    # Drag sobre escala inferior: zoom horizontal
    if ($y >= $h - $self->{bottom_h}) {
        my ($w, $h, $right, $atr_top, $price_h, $plot_w) = $self->layout();

        my $ratio = ($x - $self->{left}) / $plot_w;
        $ratio = 0 if $ratio < 0;
        $ratio = 1 if $ratio > 1;

        $self->{time_scale_drag} = {
            x => $x,
            visible => $self->{visible},
            first => $self->{first},
            ratio => $ratio,
            anchor => $self->{first} + $ratio * $self->{visible},
        };

        return;
    }

    # Click sobre eje Y derecho: activar escalado vertical manual
    if ($x >= $right) {
        my $panel = ($y >= $atr_top) ? 'atr' : 'price';

        $self->{scale_drag} = {
            y => $y,
            panel => $panel,
            price_min => $self->{price_min},
            price_max => $self->{price_max},
            atr_min   => $self->{atr_min},
            atr_max   => $self->{atr_max},
        };

        return;
    }

    if (abs($y - $atr_top) < 6) {
        $self->{resize_atr} = 1;
    } else {
        my $panel = ($y >= $atr_top) ? 'atr' : 'price';

        $self->{drag} = {
            x => $x,
            y => $y,
            first => $self->{first},
            panel => $panel,

            price_min => $self->{price_min},
            price_max => $self->{price_max},

            atr_min => $self->{atr_min},
            atr_max => $self->{atr_max},
        };
    }
}

sub mouse_drag {
    my ($self, $x, $y) = @_;
    my ($w, $h, $right, $atr_top, $price_h, $plot_w) = $self->layout();


    if ($self->{time_scale_drag}) {
        my $dx = $x - $self->{time_scale_drag}{x};

        # Izquierda: alejar / más velas
        # Derecha: acercar / menos velas
        my $factor = exp(-$dx / 250);
        my $new_visible = int($self->{time_scale_drag}{visible} * $factor);

        my $n = $self->{market}->last_index() + 1;
        $new_visible = 2  if $new_visible < 2;
        $new_visible = $n if $new_visible > $n;

        my $ratio  = $self->{time_scale_drag}{ratio};
        my $anchor = $self->{time_scale_drag}{anchor};

        $self->{visible} = $new_visible;
        $self->{first} = $anchor - $ratio * $new_visible;

        $self->limit_first();

    if ($self->{auto_y}) {
        $self->{lock_y_on_zoom} = 0;
        delete $self->{price_min};
        delete $self->{price_max};
    }
    if ($self->{auto_atr}) {
        delete $self->{atr_min};
        delete $self->{atr_max};
    }

    $self->request_draw();
    return;
}

if ($self->{scale_drag}) {
    my $dy = $y - $self->{scale_drag}{y};

    # Arriba: estirar velas/ATR
    # Abajo: comprimir velas/ATR
    my $factor = 1 + abs($dy) / 180;
    $factor = 1 / $factor if $dy < 0;

    # Si Auto vertical está activo:
    # solo permitimos arrastre horizontal.
    # El eje Y se recalcula automáticamente con las velas visibles.
    if ($self->{auto_y}) {
        $self->{lock_y_on_zoom} = 0;
        $self->request_draw();
        return;
    }

    # Si Auto vertical está apagado:
    # permitimos movimiento vertical manual.
    $self->{lock_y_on_zoom} = 1;

    if ($self->{scale_drag}{panel} eq 'price') {
        my $min = $self->{scale_drag}{price_min};
        my $max = $self->{scale_drag}{price_max};
        my $mid = ($min + $max) / 2;
        my $range = ($max - $min) * $factor;

        $self->{price_min} = $mid - $range / 2;
        $self->{price_max} = $mid + $range / 2;
    } else {
        my $min = $self->{scale_drag}{atr_min};
        my $max = $self->{scale_drag}{atr_max};
        my $mid = ($min + $max) / 2;
        my $range = ($max - $min) * $factor;

        $self->{atr_min} = $mid - $range / 2;
        $self->{atr_max} = $mid + $range / 2;
    }

    $self->request_draw();
    return;
}


    if ($self->{resize_atr}) {
        my $new = $h - $self->{bottom_h} - $y;
        $new = 80 if $new < 80;
        $new = 320 if $new > 320;
        $self->{atr_h} = $new;
    }
    elsif ($self->{drag}) {
        my $dx = $x - $self->{drag}{x};
        my $dy = $y - $self->{drag}{y};

        # Movimiento horizontal: tiempo/eje X
        $self->{first} = $self->{drag}{first} - $dx / $plot_w * $self->{visible};
        $self->limit_first();
        $self->{replay_free_view} = 1 if $self->{replay_mode};

            if ($self->{auto_y}) {
        $self->{lock_y_on_zoom} = 0;
        delete $self->{price_min};
        delete $self->{price_max};
    }
    if ($self->{auto_atr}) {
        delete $self->{atr_min};
        delete $self->{atr_max};
    }
    if ($self->{auto_y} || $self->{auto_atr}) {
        $self->request_draw();
        return;
    }
        $self->{lock_y_on_zoom} = 1;

        if ($self->{drag}{panel} eq 'price') {
            my $range = $self->{drag}{price_max} - $self->{drag}{price_min};
            $range = 1 if $range == 0;

            my $shift = $dy / $price_h * $range;

            $self->{price_min} = $self->{drag}{price_min} + $shift;
            $self->{price_max} = $self->{drag}{price_max} + $shift;
        }
        elsif ($self->{drag}{panel} eq 'atr') {
            my $range = $self->{drag}{atr_max} - $self->{drag}{atr_min};
            $range = 1 if !defined($range) || $range == 0;

            my $shift = $dy / $self->{atr_h} * $range;

            $self->{atr_min} = $self->{drag}{atr_min} + $shift;
            $self->{atr_max} = $self->{drag}{atr_max} + $shift;
        }
    }

    $self->request_draw();
}

sub mouse_up {
    my ($self, $x, $y) = @_;

    delete $self->{drag};
    delete $self->{resize_atr};
    delete $self->{scale_drag};
    delete $self->{time_scale_drag};

    $self->request_draw();
}

sub mouse_wheel {
    my ($self, $delta, $mouse_x, $mouse_y, $state) = @_;

    my $n = $self->{market}->last_index() + 1;
    return if $n <= 0;

    my ($w, $h, $right, $atr_top, $price_h, $plot_w, $bar_w) = $self->layout();

    my $old_visible = $self->{visible};
    my $old_first   = $self->{first};
    my $old_right   = $old_first + $old_visible;

    my $ctrl = defined($state) && ($state & 0x0004);

    my $new_visible;

    if ($delta > 0) {
        $new_visible = int($old_visible * 0.80);   # acercar
        $new_visible = $old_visible - 1 if $new_visible == $old_visible;
    } else {
        $new_visible = int($old_visible * 1.25);   # alejar
        $new_visible = $old_visible + 1 if $new_visible == $old_visible;
    }

    # Límites absolutos de zoom
    $new_visible = 2  if $new_visible < 2;
    $new_visible = $n if $new_visible > $n;

    if ($ctrl && defined($mouse_x) && $mouse_x >= $self->{left} && $mouse_x <= $right) {

        my $current_index = $self->x_to_index($mouse_x);
        $current_index = 0      if $current_index < 0;
        $current_index = $n - 1 if $current_index > $n - 1;

        # Se actualiza el ancla si es primera vez o si cambiaste de vela.
        if (
            !$self->{ctrl_zoom_anchor}
            || $self->{ctrl_zoom_anchor}{mouse_index} != $current_index
        ) {
            $self->{ctrl_zoom_anchor} = {
                index       => $current_index,
                mouse_index => $current_index,
                mouse_x     => $mouse_x,
            };
        }

        my $anchor_index = $self->{ctrl_zoom_anchor}{index};
        my $anchor_x     = $self->{ctrl_zoom_anchor}{mouse_x};

        my $new_step = $plot_w / $new_visible;

        # Fórmula compatible con x_of:
        # x = left + step/2 + (index - first) * step
        # Despejando first:
        $self->{first} = $anchor_index
            - (($anchor_x - $self->{left} - ($new_step / 2)) / $new_step);

    } else {

        # Si ya no hay Ctrl, se libera el congelado.
        delete $self->{ctrl_zoom_anchor};

        # Scroll normal mantiene fijo el borde derecho.
        $self->{first} = $old_right - $new_visible;
    }

    $self->{visible} = $new_visible;

    # IMPORTANTE:
    # En Ctrl + scroll NO llamamos limit_first porque mueve la vela ancla.
    # En scroll normal sí.
    if (!$ctrl) {
        $self->limit_first();
    }

    eval { $self->{canvas}->yviewMoveto(0); };

    if ($self->{auto_y}) {
        $self->{lock_y_on_zoom} = 0;
        delete $self->{price_min};
        delete $self->{price_max};
    }
    if ($self->{auto_atr}) {
        delete $self->{atr_min};
        delete $self->{atr_max};
    }
    if (!$self->{auto_y} && !$self->{auto_atr}) {
        $self->{lock_y_on_zoom} = 1;
    }

    # En replay: zoom del usuario → activar vista libre
    $self->{replay_free_view} = 1 if $self->{replay_mode};

    $self->request_draw();
}


sub limit_first {
    my ($self) = @_;

    my $n = $self->_replay_limit() + 1;   # +1: límite es índice base-0
    return if $n <= 0;

    # Extremo izquierdo:
    # permite espacio blanco a la izquierda y deja las 2 primeras velas
    # pegadas al lado derecho, junto a la escala.
    my $min_first = 2 - $self->{visible};

    # Extremo derecho:
    # permite que las 2 últimas velas queden al lado izquierdo
    # y luego haya espacio blanco hacia la derecha.
    my $max_first = $n - 2;

    $max_first = 0 if $max_first < 0;

    $self->{first} = $min_first if $self->{first} < $min_first;
    $self->{first} = $max_first if $self->{first} > $max_first;
}

sub go_to_start {
    my ($self) = @_;

    # Inicio: las 2 primeras velas quedan junto a la escala derecha.
    $self->{first} = 2 - $self->{visible};
    $self->limit_first();

    if ($self->{auto_y}) {
        delete $self->{price_min};
        delete $self->{price_max};
    }
    if ($self->{auto_atr}) {
        delete $self->{atr_min};
        delete $self->{atr_max};
    }
    $self->{lock_y_on_zoom} = 0;
    $self->draw();
}

sub go_to_end {
    my ($self) = @_;

    my $n = $self->_replay_limit() + 1;   # +1: límite es índice base-0

    # Queremos que en el borde izquierdo queden solo 2 velas visibles
    # y luego espacio blanco hasta la última vela en el lado derecho.
    $self->{first} = $n - 2;

    if ($self->{auto_y}) {
        delete $self->{price_min};
        delete $self->{price_max};
        delete $self->{atr_min};
        delete $self->{atr_max};
        $self->{lock_y_on_zoom} = 0;
    }

    $self->draw();
}

sub _round_to_tick {
    my ($value, $tick) = @_;
    $tick = 0.25 if !defined $tick || $tick <= 0;
    return int($value / $tick + ($value >= 0 ? 0.5 : -0.5)) * $tick;
}

1;
