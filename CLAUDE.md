# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Perl/Tk desktop charting engine that replicates core TradingView functionality: candlestick chart with multiple timeframes, ATR/volume panel, Smart Money Concepts (SMC) structure detection, liquidity analysis, ZigZag indicators, and a bar-by-bar Replay mode. It reads OHLCV data from local CSV files — there is no network/broker connection.

## Running

```
perl market.pl [file1.csv file2.csv ...]
```

With no arguments it auto-discovers `2026_04.csv`, `2026_05.csv`, `2026_06_29.csv`, falling back to `2026_03.csv`, in the script directory. CSV format: `time,open,high,low,close,Volume` with ISO-8601 timestamps (`2026-04-01T00:00:00-05:00`).

Requires Perl with `Tk` installed. There is no test suite, build step, or linter configured — verify changes by running the app and exercising the UI (timeframe buttons, overlays menu, mouse drag/zoom/wheel, Replay controls).

`sml.pm` at the repo root is an unrelated/unused ML utility scratch file (dataset normalization, train/test split helpers) — not part of the charting app's dependency graph.

## Architecture

### Data flow
`market.pl` wires everything together: loads CSVs into `Market::MarketData`, registers indicators on a `Market::IndicatorManager`, then hands both to `Market::ChartEngine`, which owns the Tk `MainWindow`/`Canvas` and the whole UI/event loop (`ChartEngine::run` never returns — it calls Tk's `MainLoop`).

### Strict three-layer separation (do not blur these)
1. **`Market::MarketData`** — owns raw OHLCV candles per timeframe (1/5/15/60/120/240/D/W minutes). Builds higher timeframes from the 1m base via bucketing (`build_tf_candles`). All timeframe/index/epoch lookups (binary search helpers, `get_slice`, `get_tf_data_upto`) live here.
2. **`Market::Indicators::*`** (ATR, SMC_Structures, Liquidity, ZigZagMTF, ZigZagVolume) — pure calculation, zero drawing. Common contract: `new(%args)`, `reset()`, `values()`, `calculate_all($market_data)`. They only ever read via `$market_data->get_slice(0, $market_data->last_index())` (or `get_tf_data`/`get_tf_slice`) — never index into MarketData directly. This is what makes them replay-safe (see below).
3. **`Market::Overlays::*`** and **`Market::Panels::*`** — pure rendering onto the Tk `Canvas`, given an already-computed indicator object plus `$x_of` (index→pixel closure) and a shared `$state` hashref (`price_min/max`, `top`, `price_h`, `left`/`right`, etc). Overlays never compute detection logic themselves.

`Market::IndicatorManager` is the registry connecting layers 1 and 2: `register(name, obj)`, `update_last(market_data)` calls `calculate_all` on every registered indicator, `get_indicator(name)` exposes the raw object for indicators with rich query APIs (e.g. `SMC_Structures->swing_at`, `swings_in_range`, `events_in_range`).

### Replay mode and the proxy pattern
Replay (`ChartEngine::replay_*` methods) must guarantee indicators never see future candles. Rather than special-casing every indicator, `Market::ReplayProxy` wraps a real `MarketData` and overrides `last_index()`/`size()`/`get_slice()`/`get_tf_data()` etc. to clamp everything to `replay_cursor`; indicators call the same methods they always do and are automatically limited.

For performance, per-step replay recalculation (`ChartEngine::_replay_recalc_indicators`) does **not** recompute SMC/Liquidity/ZigZag over the full 0..cursor prefix (that's O(cursor), too slow at scale). Instead it uses `Market::WindowProxy` (same file as ReplayProxy), which exposes only a sliding window of the last N candles ending at the cursor, so indicators recompute in O(window). Indicators that support windowed recalculation accept a "warm-up" slice (`get_warmup_slice`) so trend-state (HH/HL/LH/LL classification, BOS/CHoCH pivot state) isn't reset at the window boundary — see the warm-up handling in `SMC_Structures::calculate_all`. ATR is intentionally *not* recalculated per replay step because it's purely causal — the full precomputed array is always valid for any cursor position; only the drawn slice changes.

When indicator results are computed on a window/proxy with a nonzero `base_index()`, all stored indices are local to that window and must be shifted back to global indices before use — see `_offset_indices` / `_trim_warmup` in `SMC_Structures.pm` and `Liquidity.pm`.

### SMC_Structures indicator internals
Two independent swing detections run over the same candle data at different neighborhood depths (`depth`, default 5 = "internal/minor structure" vs `major_depth`, default 50 = "external/major structure", mirroring LuxAlgo's Internal/Swing Structure lengths). Internal structure produces dense HH/HL/LH/LL and BOS/CHoCH used for fine detail; external/major structure is what's actually drawn for swing labels, Order Blocks, Trendlines, and Fibonacci (reduces visual noise ~10x). Order Blocks are only generated from **external**-scope BOS events. BOS/CHoCH is detected on candle **body** (not wicks) crossing the last unconsumed swing level.

### Timeframe switching
`ChartEngine::set_timeframe` reprojects the replay cursor by epoch (not index) when switching timeframes mid-replay, since candle indices mean different things across timeframes — see the comment block there before touching TF-switch logic.

### Canvas rendering
`ChartEngine::draw` fully redraws the canvas each frame (`$c->delete('all')`) with candle-grouping-by-pixel when more candles are visible than there are pixels (`PricePanel::_build_pixel_groups`), to keep frame time bounded when zoomed far out. Mouse move only triggers a crosshair-only redraw (`_draw_crosshair_only`) using a cached `_last_render_ctx`, not a full `draw()`. Drag/wheel redraws are throttled via `request_draw` (`after(16, ...)`, ~60fps) rather than drawing synchronously on every event.

Menus in this app are deliberately **not** native Tk `Menu` popups — WSL/WSLg doesn't render them. Timeframe selection and the Overlays panel use always-visible Buttons/Checkbuttons in a real `Toplevel` window instead. Keep this pattern for any new menu-like UI.
