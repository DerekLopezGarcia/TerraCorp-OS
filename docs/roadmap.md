# Roadmap

> Guiding principle: **minimal core, everything else optional**. TerraCorp OS
> must boot and remain useful on one offline computer with 1 MB of storage.
> Networking, servers, and the data center are added in layers and must never
> break the isolated-node use case.
>
> Target model: **one application server and lightweight terminals in each
> factory**. See [`distributed.md`](distributed.md).

Each phase has measurable exit criteria. Do not start the next phase until the
current phase meets its criteria.

## F0 — Tested prototype (0.1.x) · current

**Goal:** validate the existing OS in Supersymmetry, document real behavior,
and provide a safe update path before architectural expansion.

- Test with Tier 2 CPU and Tier 2/3 screens.
- Measure free memory, time to first render, and redraw activity.
- Exercise all six apps and fix issues found in-game.
- Add an About-screen updater backed by stable GitHub Releases.
- Version stable builds with matching semantic Git tags and GitHub Releases.
- Keep settings, user data, boot configuration, and EEPROM outside the updater's
  write set.
- Record in-game results in [`tests.md`](tests.md).

**Exit criteria:** 30 minutes without `ERR` entries, at least 250 KB free on a
Tier 2 node, first render within 2 seconds, and a tested release update that
preserves settings and supports rollback on handled installation failures.

## F1 — Desktop shell and minimal core (0.2.x)

**Goal:** ship a desktop icon shell, then reduce the core surface before adding
distributed features.

- **0.2.0 Grid:** single-click desktop icons, taskbar window chips, keyboard
  navigation when no window is focused, and a SYSTEM section in About. No
  service or app-contract refactor in this patch release.
- **0.2.1 Mosaic:** drag icons within the grid to arrange them, persist the
  order in `/etc/terracorp.cfg`, and render System with a distinct accent tile.
  F1-F6 remain bound to apps, not grid positions.
- **0.2.2 Drift:** expand the icon grid to the whole screen, keep empty-cell
  positions in `iconLayout`, allow move-or-swap drops, and draw the dragged icon
  as a floating tile that eases toward the pointer like a window.
- **0.2.3 Glyph:** give every app a 9x5 box-drawing pictogram on its desktop
  tile, rename About to Update (arrow above a disk), migrate saved `about`
  positions to `update`, and enforce the desktop-icon contract in
  `npm run check`.
- **0.2.x:** separate the kernel (boot, VFS, signals) from services (logging and
  APIs).
- Apps consume services instead of calling kernel internals.
- Keep Shell, Files, and Editor in the core; move System and Settings to
  system apps.
- Raise the app API to version 2 and document app/service contracts.
- Remove unused code.

**Exit criteria:** core at or below 1,200 lines, boot within 1.5 seconds,
unchanged user-visible behavior after the refactor, and a green contract-test
harness. 0.2.0 shipped on 2026-10-25 to validate the icon shell and updater; the
remaining 0.2.x refactor waits for the F0 exit criteria (30-minute clean log and
Tier 2 figures).

## F2 — Sessions and displays (0.3)

**Goal:** replace the desktop singleton with sessions, enabling an application
server later.

- Add `tc.session` for per-session windows, apps, focus, and lifecycle.
- Add `tc.display` backends: local GPU, remote terminal spans, and headless.
- Pack the framebuffer into strings (2 bytes per cell) instead of Lua tables.
- Add `desktop` and `kiosk:<app>` session profiles.
- Keep the local session behavior unchanged.

**Exit criteria:** two headless sessions and one local session under 200 KB
total, at most 64 KB per session, boot within 1.5 seconds, and a multi-session
harness test.

## F3 — Application server and terminals (0.4)

**Goal:** run apps on a server and use lightweight terminals in factories.

- Add `tc.net` framing, measured payload limits, ACKs, retries, and idempotency.
- Define `HELLO`, `SESSION`, `FRAME`, `INPUT`, and `PING` messages.
- Resume a terminal's session after reconnect.
- Discover cores and use a shared per-segment key.
- Add a minimal terminal client and kiosk profile.
- Limit remote-session refresh to 10 Hz and group spans; local screens have no
  fixed Hz setting in OpenComputers.

**Exit criteria:** two terminals (cable and Linked Card) connected to a
headless core, reconnect under 5 seconds, documented bandwidth/latency, and no
session-state loss when a terminal disconnects.

## F3.5 — Long-distance links and tablets (optional; does not block F4)

- Verify Redstone Control bandwidth/tick behavior, the OpenComputers Adapter
  API, interdimensional wireless availability, and tablet limits before coding.
- Add Redstone Control as a `tc.net` transport: 32-bit frames, ACKs for commands,
  best-effort state updates.
- Use Linked Cards as the primary inter-base link.
- Add a resumable tablet client; sessions do not survive dimension changes or
  reconnects without an explicit resume.
- Add a reduced lunar kiosk for status and emergency controls.

**Exit criteria:** transfer 1 KB with a valid CRC between dimensions, command
round-trip under 2 seconds, and emergency control remains available if the
primary link fails. See [`long-distance.md`](long-distance.md).

## F4 — Data center and storage (0.5)

- Inventory nodes, disks, power, and network links.
- Assign `core`, `storage`, `worker`, and `edge` roles.
- Add UPS and power-plant monitoring, reserve budgets, and staged shedding.
- Automatically boot in stages above 60% UPS charge, with per-node checks and
  a watchdog.
- Shut down in order: workers, terminals, storage, then core.
- Document the permanent chunk-loader requirement.
- Provide remote RAID storage with a second-node copy.
- Attribute operator names in the UI/log without user accounts.
- Display a data-center map and node/disk/relay/UPS alerts.

**Exit criteria:** inventory two racks/six nodes, automatic startup after world
reload above 60% charge, terminal file reads/writes, and one-node failure
without data corruption or taking down the rest of the system.

## F5 — Lightweight cluster (0.6)

- Queue jobs for workers and return results to the requesting terminal.
- Replicate files to two verified copies.
- Fail over the log if the core fails.
- Add plant CLI commands such as `plant status` and `node drain`.

**Exit criteria:** a batch job runs on a worker and returns to its requester;
core failure does not lose data.

## F6 — Factory integration

- Verify which GTCE inventories/tanks are exposed through the Adapter.
- Add machine-stop alerts and production counters to the kiosk.

Do not plan further work until this is tested in-game.

## Prioritized backlog

| # | Work item | Phase | Size |
|---|---|---|---|
| 1 | In-game Supersymmetry test and results | F0 | S |
| 2 | Measure RAM, boot, and redraw behavior | F0 | S |
| 3 | GitHub Release versioning and in-OS updater | F0 | M |
| 4 | Extract `tc.service` and `tc.session` | F1-F2 | L |
| 5 | Packed framebuffer and display backends | F2 | L |
| 6 | Trim apps/dead code and version app/service contracts | F1 | M |
| 7 | `tc.net` framing and ACKs | F3 | L |
| 8 | Session protocol (`FRAME`/`INPUT`) | F3 | L |
| 9 | Terminal client and kiosk | F3 | M |
| 10 | Data-center inventory, health, and power | F4 | M |
| 11 | Remote RAID storage | F4 | M |
| 12 | Job queue and file replication | F5 | L |
| 13 | Redstone Control measurement spike/transport | F3.5 | M |
| 14 | Resumable tablet client | F3.5 | M |

## Decisions

1. **System model:** application server plus lightweight terminals — decided.
2. **Multi-user:** no accounts; several players may connect, one operates at a
   time, with operator attribution — decided.
3. **Terminals:** native Remote Terminal for rack administration and TerraCorp
   terminals for factory use — decided.
4. **Data-center autonomy:** automatic boot with a UPS and dedicated power plant;
   staged shedding and ordered shutdown — decided.
5. **Core apps:** Shell, Files, and Editor proposed; System and Settings are
   system apps. Confirm in F1.
