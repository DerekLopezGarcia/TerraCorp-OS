# Render pipeline and VRAM double buffering

This document plans the renderer work for 0.4.x. It covers the current span
diffing in `tc.gfx`, the packed framebuffer of the 0.4 Sessions phase, and the
VRAM/bitblt double-buffer mode ("Flip") that OpenComputers 1.7.5+ offers.

## Current renderer (0.2.x–0.3.x)

`tc.gfx` keeps a cell-addressed framebuffer in Lua tables (`ch`, `fg`, `bg`)
plus a shadow copy (`pch`, `pfg`, `pbg`). `flush()` walks rows, finds maximal
runs of same-color dirty cells, and sends one `gpu.set` per run, caching
palette color selection. Cells rejected by the GPU (power, no screen) stay
dirty and retry on a later frame.

Properties that must survive every redesign:

- Coordinates are local, 1-based, and clipped by the caller (`tc.ui`).
- Failed writes never advance the shadow copy (no lost frames on low power).
- `gpu.setBackground`/`setForeground` take `true` for palette indices.
- Palette writes are avoided unless the color changed (budget discipline).

## Phase 1 — packed framebuffer (0.4.0 "Sessions")

Sessions need many framebuffers (one per session) without blowing the memory
budget, so the cell tables become packed strings: 2 bytes per cell (1 character
code + 1 attribute byte) instead of 3 Lua numbers per cell.

- A 80x25 session costs ~4 KB as strings versus ~50 KB+ of boxed numbers.
- The current dirty-span diff still works; it operates on the packed arrays.
- Sessions only need `put`/`fill`/`clear`/`bar`/`view` — no new API surface.
- Exit criterion (roadmap F3): a session framebuffer stays ≤ 64 KB.

## Phase 2 — VRAM double buffering (0.4.x "Flip")

### The OpenComputers buffer API (1.7.5 dev builds / 1.8)

Verified against the community documentation (ocdoc.cil.li and the ABKQPO
exported API docs). **All of this is pending in-game verification** in the
Supersymmetry pack; see the checklist at the end.

- `gpu.allocateBuffer([width[, height]]) -> index | nil, reason` — allocates an
  off-screen buffer (GPU max resolution by default). Allowed even with no
  screen bound. Returns a buffer index; index `0` always means the screen.
- `gpu.buffers()` — table of allocated buffer indexes (screen not included).
- `gpu.setActiveBuffer(index)` / `gpu.getActiveBuffer()` — all drawing calls
  (`set`, `fill`, `copy`, `setBackground`, `setForeground`) target the active
  buffer instead of the screen.
- `gpu.freeBuffer(index)` / `gpu.freeAllBuffers()`.
- `gpu.bitblt([dst[, col[, row[, width[, height[, src[, fromCol[, fromRow]]]]]]]])`
  — copies a region between buffers and/or the screen. `dst` defaults to `0`
  (the bound screen); `src` defaults to the active buffer. One call moves the
  whole frame: very low call-budget cost and far fewer network packets than
  dozens of `set` spans.

Buffer contents carry colors as well as characters, so a bitblt of the full
frame preserves the exact appearance. Repeated bitblt is designed to be fast.

### Why it matters

| | Span diffing (today) | VRAM + bitblt |
|---|---|---|
| Partial update (few cells) | Cheap: only dirty spans | Worse: full redraw + full blit |
| Full redraw (window switch, resize) | Many `set` calls, visible intermediate states, packet storm | Build the frame in VRAM, one blit, no flicker |
| Call budget | Many calls per frame | One blit per frame |
| VRAM requirement | None | Tier 3 GPU with enough VRAM (`vramSizes`) |
| Energy | Per `set` span | Per `bitblt` (`bitbltCost` config) + per draw into the buffer |

The two modes are complementary, not exclusive. The plan is a **hybrid
renderer**: span diffing stays the default path; when a frame is "mostly dirty"
(window open/close, app switch, resolution change), the renderer builds the
frame into a VRAM buffer and flips it with a single bitblt.

### Design

1. **Capability probe at boot** (`tc.gfx.new`): `pcall(gpu.allocateBuffer)`.
   - Success → `self.buffer = index`, render mode `"vram"`.
   - Failure (old build, no VRAM, no GPU tier) → mode `"span"`, exactly the
     current behavior. The probe result is logged once.
   - On `component_removed`/`rebindScreen`, free the buffer and re-probe.
2. **Dirty-ratio heuristic.** `flush()` already counts dirty cells; if
   `dirty / cells >= FLIP_RATIO` (target 0.2, configurable as
   `renderFlipRatio` in `/etc/terracorp.cfg`), take the VRAM path:
   1. `gpu.setActiveBuffer(buffer)`.
   2. Redraw the full frame with the same span logic (first frame: full fill;
      later frames may diff against the buffer's previous content if we track
      a second shadow — keep it simple: full redraw, spans are cheap into VRAM).
   3. `gpu.bitblt(0, 1, 1, w, h, buffer, 1, 1)` — one call to the screen.
   4. `gpu.setActiveBuffer(buffer)` stays active for the next frame.
   5. Update the shadow tables so the next small frame uses span diffing
      against the screen's actual content.
3. **Failure semantics.** A failed bitblt (low power, screen unbound) must not
   advance the shadow tables; the next flush retries. A failed `set` into the
   buffer aborts the flip and falls back to span diffing this frame.
4. **Palette.** Palette indices must render identically in buffers and on
   screen. Verify in-game; if buffers ignore the screen palette, switch to
   direct RGB colors for the VRAM path.
5. **Config.** `renderMode = "auto" | "span" | "vram"` in
   `/etc/terracorp.cfg`. `"span"` forces the legacy path (first-line debugging
   tool if a driver/VRAM edge case appears). `"auto"` is the default.
6. **No allocation churn.** One buffer for the desktop lifetime, reallocated
   only on resolution change (`gfx:resize` frees and re-probes).

### What explicitly does NOT change

- `tc.ui` and the apps keep drawing through `ctx.view`; the flip is invisible
  above `tc.gfx`.
- The span path stays the default for small frames, so energy consumption on
  idle screens does not regress (bitblt of an unchanged frame is avoided by the
  dirty check that already gates `flush`).
- The 30 Hz idle poll and the per-second UI tick are untouched.

## Harness plan

- Fake GPU gains `allocateBuffer`/`setActiveBuffer`/`bitblt`/`freeBuffer`
  mirroring the real API (indexes, defaults `dst=0`, error reasons).
- New suite `test:flip`:
  1. Probe with VRAM available → mode `vram`; a mostly-dirty frame produces
     exactly one bitblt and zero direct-to-screen `set` calls.
  2. A small dirty frame produces span `set` calls and no bitblt.
  3. bitblt rejected (power) → shadow tables unchanged, next flush retries.
  4. Probe fails → mode `span`, existing tests unchanged.
  5. `renderMode = "span"` config forces the legacy path.
- Snapshot tests (`test:screens`) run in both modes.

## In-game verification checklist (before "Flip" ships)

1. `gpu.allocateBuffer()` on a Tier 3 GPU with a T3 screen: returns an index?
   Record `gpu.buffers()` and `gpu.getTotalMemory()`/`getUsedMemory()` (VRAM
   accounting) values.
2. Draw into the buffer via `setActiveBuffer`, then `bitblt` to the screen:
   do palette colors and characters arrive intact?
3. Does `bitblt` consume power (compare `computer.energy()` before/after)?
   Does it count against the call budget like `set`?
4. Behavior with no screen bound: allocate/probe/bitblt error messages.
5. `renderFlipRatio` tuning: with the desktop open, log how often the flip
   path fires vs span diffing over a 5-minute session.
6. Repeat on a node with no GPU (headless): boot must be unaffected.

## Sequencing inside 0.4

- **0.4.0 "Sessions"** — packed framebuffer, sessions, display backends. No
  VRAM work; renderer behavior observable from apps is unchanged.
- **0.4.1 "Flip"** — VRAM double buffering per this document, behind the
  capability probe and the config switch. Ships only after the in-game
  checklist above.
- The hybrid heuristic means neither mode is load-bearing alone: if VRAM
  probing fails in the wild, TerraCorp still renders exactly as 0.3.x did.
