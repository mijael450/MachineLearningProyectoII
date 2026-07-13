# Especificación de reparto de trabajo — Segunda entrega (13/07)

**Contexto:** entrega el 13/07, hoy 11/07. Base de código en Perl/Tk, arquitectura de 3 capas estricta (`MarketData` → `Indicators::*` → `Overlays::*`/`Panels::*`). Cada bloque de trabajo abajo está delimitado por archivo para que las 3 personas puedan hacer commit/push sin pisarse. **Orden de merge a `main`: P1 → P2 → P3.**

> Reparto para 3 personas: se fusionaron las dos tareas más pequeñas y menos riesgosas (data+ZigZag y fix de etiquetas) en una sola persona, ya que ninguna de las dos toca los archivos de integración compartidos. VWAP+Volume Profile y Strategy Builder quedan igual que en el reparto anterior, uno por persona.

---

## PERSONA 1 — Datos nuevos + temporalidades en ZigZag + arreglo de etiquetas SMC

### Archivos que le pertenecen
`MarketData.pm`, `ZigZagMTF__indicator.pm`, `ZigZagVolume__indicator.pm`, `ZigZag_overlay.pm`, `SMC_Structures_overlay.pm`

Esta persona cubre dos bloques de trabajo independientes entre sí (no comparten ningún archivo), en el orden que prefiera.

### Bloque A — Datos + temporalidades en ZigZag

**1.1. Integrar la data nueva subida al aula virtual**
- Copiar el/los CSV nuevo(s) al directorio del script, con el mismo formato que ya usa el proyecto: `time,open,high,low,close,Volume`, timestamps ISO-8601 (`2026-04-01T00:00:00-05:00`).
- `market.pl` autodescubre `2026_04.csv`, `2026_05.csv`, `2026_06_29.csv` (fallback `2026_03.csv`) — si el archivo nuevo tiene otro nombre/mes, hay que **añadirlo a esa lista de autodiscovery** en `market.pl` (no solo dejarlo en la carpeta).
- Verificar que `MarketData::build_tf_candles` genera bien las temporalidades derivadas (5/15/60/120/240/D/W) a partir de la nueva data 1m — correr la app y revisar visualmente que no haya huecos/gaps de velas en el candlestick al cambiar de TF.

**1.2. Selector de temporalidad en ZigZag (los 2 tipos)**
- **Problema actual:** `ZigZagMTF__indicator.pm` tiene el TF de referencia **hardcodeado a 30 minutos** (`resolution => $a{resolution} // 30` en `sub new`, línea ~42). El parámetro existe en el constructor pero **no hay ningún control de UI que lo cambie** — el usuario no puede seleccionar 15m/30m/60m desde la interfaz.
- **Qué hay que construir:**
  1. En `ChartEngine.pm`, dentro del panel de Overlays (Toplevel con Checkbuttons — recuerda que en este proyecto los menús NO son Tk::Menu nativos, ver nota de arquitectura en `CLAUDE.md`), agregar un control de selección de temporalidad para ZigZag (radiobuttons o botones tipo los de cambio de TF del gráfico principal: 15/30/60).
  2. Ese control debe llamar a `Market::Indicators::ZigZagMTF->new(resolution => $tf)` — recreando el indicador y re-registrándolo en `IndicatorManager` (o exponiendo un método `set_resolution($tf)` que fuerce recálculo completo, no incremental).
  3. Repetir el mismo patrón para `ZigZagVolume__indicator.pm` — revisar su `sub new` (línea ~39) para ver si ya acepta un parámetro de TF/periodo; si no, agregarlo siguiendo el mismo mapeo lineal resolución→factor que ya usa ZigZagMTF (línea ~106-111 de ese archivo) como referencia de diseño.
  4. `ZigZag_overlay.pm` debe leer la resolución activa desde el indicador (no un valor fijo) para que la etiqueta en pantalla (ej. "ZZMTF (Dir. Interna) — 30m") refleje la temporalidad seleccionada — así el usuario ve con qué TF está mirando el zigzag, tal como en TradingView.

### Criterio de aceptación (Bloque A)
- La app arranca con la data nueva sin errores y sin huecos de velas en ninguna temporalidad.
- Se puede cambiar la temporalidad de referencia de ZZMTF y de ZZ Volume desde la UI, en caliente, sin reiniciar la app, y el overlay se redibuja con el nuevo cálculo.

---

### Bloque B — Arreglo de etiquetas SMC (FVG, Order Blocks, Trendlines/Channels)

Archivo: `SMC_Structures_overlay.pm` **únicamente** (no toca el indicador `SMC_Structures__indicator.pm` — la detección ya es correcta, el problema es solo visual/de dibujo).

### Qué falta y por qué

El PDF exige explícitamente (cronograma 29/06, ya vencido, y sigue siendo requisito de la entrega actual) estas etiquetas visibles en el gráfico:
- FVG con desvanecimiento progresivo
- Trendlines/Channels: below or above
- OB: Inside Order Blocks
- Support/Resistance: below support or above resistance levels

**Estado actual encontrado en el código** (con comentarios de historial de fixes ya en el archivo):
- **FVG**: hay ya varias iteraciones de fix documentadas en comentarios (líneas ~311-420) sobre cuándo debe dejar de dibujarse un FVG mitigado vs. uno activo. **Revisar que el comportamiento final coincida exactamente con la regla del PDF**: un FVG activo (sin mitigar) SIEMPRE se dibuja mientras intersecte el rango visible; uno mitigado deja de dibujarse por completo apenas se mitiga. Verificar visualmente en varias temporalidades que no queden FVGs "fantasma" ni FVGs activos que desaparecen antes de tiempo.
- **Order Blocks (línea ~562)**: la etiqueta de texto `'OB'` existe pero es genérica — confirmar que se distinga visualmente Order Block alcista vs. bajista (color/dirección), y que la etiqueta esté anclada al bloque correcto y no se solape con otras etiquetas (Trendlines, S/R) cuando coinciden en el mismo rango de precio/tiempo.
- **Support/Resistance (`_draw_support_resistance`, línea ~571)**: el PDF pide "below support or above resistance" — es decir, la etiqueta de texto debe posicionarse *debajo* del nivel cuando es soporte y *arriba* cuando es resistencia (para no tapar el precio). Revisar que el posicionamiento actual cumpla esto y no esté invertido o centrado.
- **Trendlines/Channels (`_draw_trendlines`, línea ~610)**: mismo criterio "below or above" — validar posicionamiento de la etiqueta relativo a la línea de tendencia, y que el canal (si se dibuja) tenga las dos líneas paralelas correctamente etiquetadas.

### Cómo trabajar sin romper nada
- Solo tocas overlays (capa 3), nunca el indicador (capa 2) — el indicador ya calcula bien los datos, el trabajo es 100% de renderizado/posicionamiento de texto en Canvas.
- Prueba en Replay mode paso a paso para confirmar que las etiquetas aparecen/desaparecen en el momento correcto (no adelantadas ni atrasadas respecto a la vela que las genera).

### Criterio de aceptación (Bloque B)
- Las 4 etiquetas (FVG, OB, Trendlines/Channels, Support/Resistance) se ven correctamente posicionadas, sin solaparse entre sí, y sin "fantasmas" tras mitigación/invalidación.

### Criterio de aceptación global de Persona 1
- Ambos bloques (A y B) cumplidos. Como no comparten archivos, puede mergear cada uno por separado en cuanto esté listo, sin esperar al otro.

---

## PERSONA 2 — Anchored VWAP + Volume Profile avanzado (módulos nuevos)

### Archivos que le pertenecen (todos nuevos, cero conflicto con el resto del equipo)
`VWAP__indicator.pm`, `VWAP_overlay.pm`, `VolumeProfile__indicator.pm`, `VolumeProfile_overlay.pm`

### Qué falta
**Ninguno de estos dos módulos existe en el repo hoy** (confirmado por búsqueda: 0 coincidencias de VWAP, POC, VAH, VAL, Volume Profile en todo el proyecto).

**3.1. Anchored VWAP (sección 8 del PDF)** — debe comportarse como el VWAP anclado de TradingView, reiniciando la suma acumulada de volumen×precio en cada uno de estos anclajes:
1. Inicio de sesión — anclado al primer tick/vela de la sesión.
2. Apertura de mercado — anclado a la apertura oficial.
3. BOS confirmado — se re-ancla en la vela exacta donde `SMC_Structures` valida un BOS (usar `IndicatorManager->get_indicator('SMC_Structures')` para consultar eventos, mismo patrón que ya usa `Liquidity_overlay.pm`/`SMC_Structures_overlay.pm` para leer swings/eventos).
4. CHoCH confirmado — igual, ancla en la vela del CHoCH.
5. Por Volume Profile — se ancla dinámicamente al nodo POC (requiere que el punto 3.2 esté calculado primero).

Implementación sugerida: seguir el contrato estándar del proyecto — `new(%args)`, `reset()`, `values()`, `calculate_all($market_data)` — leyendo datos solo vía `get_slice`/`get_tf_data` (nunca indexando MarketData directo, para que sea replay-safe igual que los demás indicadores). El overlay dibuja la línea de VWAP + bandas de desviación estándar (como TradingView) desde el punto de anclaje hasta la vela actual.

**3.2. Volume Profile avanzado (sección 7 del PDF)** — calcula POC (Point of Control), VAH (Value Area High) y VAL (Value Area Low), proyectados horizontalmente, con 3 modos:
- **Por sesión**: se inicializa/segmenta con la apertura cronológica de cada sesión.
- **Por BOS/CHoCH**: acumula volumen usando como anclas de inicio/fin los eventos BOS/CHoCH confirmados en 1H, 2H, 4H, D, W (misma fuente de eventos que el punto anterior).
- **Por velas históricas del pasado lejano (contingencia)**: se activa automáticamente solo si no hay datos/velas en el pasado reciente del activo — cae al inicio de sesión lejana o a eventos macro HTF.

### Criterio de aceptación
- VWAP se re-ancla visualmente en cada uno de los 5 eventos listados, verificable en Replay paso a paso.
- Volume Profile muestra POC/VAH/VAL correctos en los 3 modos, y el modo de contingencia se activa solo cuando corresponde (no se dispara con datos suficientes).
- Ambos overlays son activables/desactivables desde el panel de Overlays, siguiendo el mismo patrón Toplevel+Checkbutton del resto (no usar `Tk::Menu`).

---

## PERSONA 3 — DIY Strategy Builder + integración final

##INDICADOR EN TRADING VIEW SIMILAR :  DIY Custom Strategy Builder -> Activar Supply/Demand Zone
### Archivos que le pertenecen
`SuperTrend__indicator.pm`, `HalfTrend__indicator.pm`, `RangeFilter__indicator.pm`, `SupplyDemand__indicator.pm`, `StrategyBuilder_overlay.pm`, y **al final** `market.pl` + `IndicatorManager.pm` (registro/integración de todo lo de P1 y P2).

⚠️ **Importante:** P3 empieza sus 4 indicadores nuevos en paralelo con los demás (son archivos nuevos, sin conflicto), pero **NO toca `market.pl` ni `IndicatorManager.pm` hasta que P1 y P2 estén mergeados a `main`**. Esos dos archivos son el punto de convergencia de todo el equipo — tocarlos antes generaría conflictos de merge garantizados.

### Qué falta (sección 6 del PDF, componente por componente)

Ninguno de estos 5 componentes existe hoy en el repo:

| Componente | Comportamiento algorítmico exigido |
|---|---|
| **SuperTrend** | Cálculo y actualización dinámica por vela cerrada, en base a un multiplicador ATR (reutilizar `ATR__indicator.pm` ya existente como dependencia — no reimplementar ATR). |
| **HalfTrend** | Determinación dinámica de la dirección de tendencia + filtros de reversión. |
| **Range Filter** | Suavizado dinámico del precio para aislar fases de acumulación/distribución. |
| **Supply Zones** | Persistencia en memoria de bloques de órdenes de venta validados por volumen. |
| **Demand Zones** | Persistencia en memoria de bloques de órdenes de compra validados por volumen. |

Cada uno debe seguir el contrato estándar (`new`, `reset`, `values`, `calculate_all`) y ser replay-safe (solo lectura vía `get_slice`/`get_tf_data`, igual que el resto).

`StrategyBuilder_overlay.pm` combina las señales de estos 5 componentes en tiempo real para generar reglas de entrada/salida — es el overlay que las visualiza en el gráfico.

### Tarea final de integración (después del merge de P1 y P2)
1. En `market.pl`, agregar los `use Market::Indicators::X` de los 6 indicadores nuevos (VWAP, VolumeProfile de P2; SuperTrend, HalfTrend, RangeFilter, SupplyDemand de P3) y sus llamadas `$indicators->register('Nombre', ...)`, siguiendo el patrón ya existente (líneas 66-72 de `market.pl`).
2. En `ChartEngine.pm`, agregar los checkbuttons correspondientes al panel de Overlays para cada módulo nuevo.
3. Prueba de humo final: correr `perl market.pl` con la data nueva, activar/desactivar cada overlay uno por uno, y correr Replay completo para confirmar que no hay crash ni fuga de velas futuras en ninguno de los indicadores nuevos.

### Criterio de aceptación
- Los 5 componentes del Strategy Builder calculan correctamente y son replay-safe.
- La app arranca sin errores con todo integrado, y cada overlay se puede togglear independientemente desde el menú.

---

## Resumen de riesgos

- **Tiempo:** con 2 días y solo 3 personas para 3 módulos completos desde cero (VWAP, Volume Profile, Strategy Builder de 5 componentes) más data nueva, temporalidades y fixes de etiquetas, el alcance es muy ambicioso — más que con 4 personas. Si hay que priorizar, el orden sugerido de valor/esfuerzo es: **VWAP > Volume Profile > Strategy Builder** (los dos primeros están pedidos explícitamente; el Strategy Builder es el bloque más grande, con 5 sub-indicadores).
- Persona 1 tiene ahora doble carga (data+ZigZag y etiquetas SMC) pero son las dos tareas de **menor esfuerzo relativo** del proyecto — por eso se fusionaron, dejando a P2 y P3 enfocados cada uno en un módulo grande.
- **Orden de merge no negociable:** P1 → P2 → P3, porque P3 es el único que toca los archivos de integración compartidos (`market.pl`, `IndicatorManager.pm`).
- **Antes de que P3 toque esos dos archivos**, debe hacer `git pull` de `main` ya con P1 y P2 mergeados, para no rehacer su rama dos veces.
- Si el tiempo aprieta, considera que P1 termine primero el Bloque A (data) cuanto antes, porque P2 y P3 lo necesitan para probar sus overlays con la data real — el Bloque B (etiquetas) puede ir después sin bloquear a nadie.
