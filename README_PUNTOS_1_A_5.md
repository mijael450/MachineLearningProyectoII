# TradingViewProyect2 — alcance puntos 1 a 5

Esta copia implementa únicamente los puntos 1–5 de
`Especificacion_Proyeto_2a_Fase.pdf`:

1. Arquitectura separada de datos, indicadores y overlays.
2. Temporalidades 1m, 5m, 15m, 1H, 2H, 4H, D y W.
3. Replay sin velas futuras, con Play/Pausa, pasos, avance rápido y salida.
4. SMC, FVG y Liquidity: BSL/SSL, EQH/EQL, Sweep/Grab/Run, máquina de
   estados, volumen 1m/5m/15m y niveles internal/external.
5. Concurrencia: Sweep pondera CHoCH, Run pondera BOS, Grab activa una
   reversión y el FVG asociado se marca como zona de alta reacción.

No se incluyen Strategy Builder, Volume Profile ni Anchored VWAP porque
pertenecen a los puntos 6–8.

## Ejecutar y verificar

```bash
perl market.pl
perl market.pl --all
perl -I. tools/verify_points_1_to_5.pl
```

El primer comando abre solamente el CSV más reciente para iniciar rápido. La
opción `--all` carga abril, mayo y junio cuando se necesita todo el historial.
Los indicadores complejos trabajan sobre 4,000 velas recientes más su contexto;
ATR permanece calculado sobre el archivo completo.
