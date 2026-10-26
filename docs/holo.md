# Hologram status wall

Using an OpenComputers hologram projector as the factory status wall — plant
KPIs visible across the hall, updated by the cluster. Research for a 0.5.x
optional module (`tc/holo.lua`); nothing here is implemented.

## Verified API (community docs, pending in-game check)

Provided by the **Hologram Projector** block; component kind `hologram`.

- Resolution: **48 x 32 x 48 voxels** (x, y, z), projected over up to
  **9 x 6 x 9 blocks** at max scale. (Note: it is 32 tall, not 48 — the
  bit-mask column model below is why 48-wide z/x rows exist.)
- **Tier 1**: monochrome voxels (on/off). **Tier 2** (OC ≥ 1.3): three
  colors, palette editable (`getPaletteColor`-style calls on the projector).
- Per-column access: `set(x, z, value)` where `value` is the column's 32-bit
  height mask (each bit = one voxel), `get(x, z)`, `fill(x, z, minY, maxY,
  value)`, `copy`, `translate`, `clear()`.
- `setScale(0.33…3)` — bigger scale draws bigger but **consumes more energy**;
  scale 3 covers the 9x6x9 area.
- Energy: the projector needs constant power while rendering; a projector
  without energy stops updating (last frame persists).

## What fits on a wall

There is no text API — the hologram renders voxels only. Text means a voxel
font: a 3x5 font gives 16 characters across (48 / 3) and 6 rows (32 / 5) per
plane; two planes (background mask + foreground color mask) for the T2
projector.

Realistic layouts:

- **Bar wall**: one column per metric (power, TPS, pool usage, node states) —
  bars are `fill` calls, no font needed. Cheapest and most legible at
  distance.
- **Status glyphs**: big 7x7 pictograms (OK / WARN / ALARM / OFF) per bay,
  updated by flipping masks.
- **Short labels**: 3x5 font for names like `PWR`, `TPS`, `VAULT` above bars.
  Longer text belongs on the real screens, not the wall.

## Cost model

- Full redraw via `set` = 48x48 = 2,304 column calls — too many. Budget rule:
  use `fill` for bars (one call per bar per plane) and per-column `set` only
  for fonts/text; a typical frame is ≤ 60 calls.
- Differential updates: keep a shadow of the last masks; only changed columns
  are sent. Idle wall = zero calls.
- Call budget: the projector honors the GPU-style call budget; a full
  pictogram flip must be spread across ticks if the budget rejects calls.
  Same retry rule as `tc.gfx`: failed calls leave the shadow untouched.

## Design sketch

- `tc/holo.lua`: `wall.open(address)` builds planes from a tiny layout DSL
  (`bar(id, x, w)`, `glyph(id, x, z)`, `label(id, x, z, text)`); `wall:tick()`
  pushes differential updates; values come from `tc.telemetry` caches
  (`docs/telemetry.md`), never from live component reads inside the draw path.
- Color mapping on T2: palette slots fixed by config (e.g. 1=ok, 2=warn,
  3=alarm); on T1, warn/alarm blink by toggling visibility.
- The wall runs on a dedicated cheap node (microcontroller or Tier 1 computer)
  fed by the cluster: Relay `STATE` job or a `TFRAME`-style one-way stream on
  the wired segment; it must degrade to "stale" display when the feed stops —
  a frozen wall must look frozen (blink the border) so operators do not trust
  old numbers.

## In-game verification checklist

1. Resolution and masks: confirm 48x32x48 and the `set(x, z, mask)` bit
   order (which bit is the bottom voxel?).
2. T2 palette: set the three colors; do all three render independently?
3. Energy: consumption at scale 1 vs 3, and behavior (freeze? dim?) when
   the projector runs dry.
4. Call budget: how many `set`/`fill` calls per tick are accepted before
   rejections start (compare with the GPU budget config).
5. Latency: end-to-end time from a Relay state change to a visible wall
   update.

## Sequencing

Only after 0.4 sessions ship: the wall is a consumer of telemetry and
session-free, so it can be built any time after `tc.names` + telemetry caches
exist — target 0.5.x alongside the terminal clients.

Cross-links: `distributed.md` (data center), `telemetry.md` (sources),
`long-distance.md` (alarm channel), `render.md` (retry/shadow discipline).
