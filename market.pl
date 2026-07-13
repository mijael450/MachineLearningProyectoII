use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use lib "$FindBin::Bin/Market";
use lib ".";
use Tk;
use Market::MarketData;
use Market::IndicatorManager;
use Market::Indicators::ATR;
use Market::Indicators::SMC_Structures;
use Market::Indicators::Liquidity;
use Market::Indicators::ZigZagMTF;
use Market::Indicators::ZigZagVolume;
use Market::ChartEngine;

# ─── Resolución de archivos CSV ──────────────────────────────────────────────
# Prioridad:
#   1. Archivos pasados como argumentos: perl market.pl 2026_04.csv 2026_05.csv ...
#   2. Archivos estándar del proyecto encontrados junto al script
# Si se pasa un solo CSV (compatibilidad con Fase 1), funciona igual que antes.

my @csv_files;

if (@ARGV) {
    # Modo explícito: el usuario pasa los archivos que quiere
    @csv_files = map { -f $_ ? $_ : "$FindBin::Bin/$_" } @ARGV;
} else {
    # Modo automático: buscar los CSVs estándar junto al script
    my @candidates = (
        "$FindBin::Bin/2026_04.csv",
        "$FindBin::Bin/2026_05.csv",
        "$FindBin::Bin/2026_06_29.csv",
        # Fallback al nombre original del proyecto anterior
        "$FindBin::Bin/2026_03.csv",
    );
    for my $f (@candidates) {
        push @csv_files, $f if -f $f;
    }
    # Desduplicar: si solo existe 2026_03.csv (el que era abril renombrado), usarlo
    if (!@csv_files) {
        die "No se encontraron archivos CSV.\n"
          . "Uso: perl market.pl [archivo1.csv archivo2.csv ...]\n";
    }
}

# ─── Carga de datos ──────────────────────────────────────────────────────────

my $market = Market::MarketData->new();

if (@csv_files == 1) {
    # Compatibilidad: carga simple de un solo archivo
    print "Cargando datos desde '$csv_files[0]'...\n";
    $market->load_csv($csv_files[0]);
} else {
    print "Cargando " . scalar(@csv_files) . " archivos CSV...\n";
    $market->load_csv_files(@csv_files);
}

$market->set_timeframe(1);
$market->print_summary();

# ─── Indicadores ─────────────────────────────────────────────────────────────

my $indicators = Market::IndicatorManager->new();
$indicators->register('ATR', Market::Indicators::ATR->new(period => 14));
# PDF 4.1: "valor inicial recomendado k = 3" para la profundidad de Swing Points
$indicators->register('SMC_Structures', Market::Indicators::SMC_Structures->new(depth => 5));
# PDF 4.1/4.2/4.3: k=3, tolerancia EQH/EQL=ATR*0.10, N=3 velas para Run, 3 velas para Grab
$indicators->register('Liquidity', Market::Indicators::Liquidity->new(depth => 3));
$indicators->register('ZigZagMTF',    Market::Indicators::ZigZagMTF->new());
$indicators->register('ZigZagVolume', Market::Indicators::ZigZagVolume->new());
$indicators->update_last($market);

# ─── Interfaz gráfica ────────────────────────────────────────────────────────

my $mw    = MainWindow->new();
my $chart = Market::ChartEngine->new(
    mw         => $mw,
    market     => $market,
    indicators => $indicators,
);
$chart->run();
