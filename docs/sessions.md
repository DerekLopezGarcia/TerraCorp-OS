# 0.4.0 Sessions — implementation plan

The model, memory budget, and display backends are specified in
`distributed.md`; the renderer work is planned in `render.md`. This document
turns the 0.4.0 "Sessions" phase into a concrete module and release plan.

## Module plan

| Module | Responsibility |
|---|---|
| `tc/framebuffer.lua` | Packed 2 B/cell buffers: `new(w, h)`, `put`, `fill`, `clear`, `bar`, `view`, `diff` (returns spans). Extracted from `gfx.lua`; `gfx` keeps only GPU I/O |
| `tc/display.lua` | Backend interface: `open(w, h)`, `flip(spans | buffer)`, `input()`; three implementations `local` (GPU), `remote` (spans over `tc.net`), `headless` (no I/O, spans kept for tests) |
| `tc/session.lua` | Per-session app list, focus, key routing, framebuffer, lifecycle (`create`/`close`); profile `desktop` or `kiosk:<app>` |
| `boot/kernel.lua` | Runs N sessions; the event loop dispatches to the session owning the focused window; per-session tick budget |

## Sequenced milestones

1. **s1 — framebuffer extraction** (no behavior change): move cell packing
   into `tc/framebuffer.lua`; `gfx` shrinks to GPU calls + span flush.
   Existing suites must stay green unchanged.
2. **s2 — backend split**: `tc.display.local` wraps today's behavior;
   `headless` feeds tests. Harness gains a two-sessions scenario.
3. **s3 — sessions**: multi-session kernel, focus switching, per-session
   tick budget, session profiles. Exit criteria from `roadmap.md`: two
   headless + one local session, ≤64 KB per session, boot ≤1.5 s.
4. **s4 — Flip** (from `render.md`): VRAM double buffering, capability
   probed, only after its in-game checklist.

## Invariants

- An app never learns which session or backend it is in; it only sees
  `ctx.view`/`ctx.text`/`ctx.colors`.
- A failed remote `flip` must not advance the session's shadow state
  (same rule as GPU power failures).
- The desktop kernel stays under the 0.3.x boot budget; headless nodes
  gain nothing they did not have.

## Risks

- Packed-cell diffing must keep span quality (chars+attributes in one byte
  limits to 256 colors — palette indices only; document the constraint).
- Session focus stealing between players: one operator at a time is the
  0.4 rule (`distributed.md`); the 0.5 terminal client must respect it.
- Remote backend lands with 0.5, but the backend *interface* must be final
  in 0.4.0 so 0.5 does not reopen session code.
