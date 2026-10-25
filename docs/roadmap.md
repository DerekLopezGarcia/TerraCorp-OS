# Roadmap

> Guiding principle: **minimal core, everything else optional**. TerraCorp OS
> must boot and remain useful on one offline computer with 1 MB of storage.
> Networking, servers, and the data center are added in layers and must never
> break the isolated-node use case.
>
> Target model: **one application server and lightweight terminals in each
> factory**. See [`distributed.md`](distributed.md). The 0.3.x cluster is the
> first layer: the existing computer becomes the master, and rack servers become
> nodes.

Each phase has measurable exit criteria. Do not start the next phase until the
current phase meets its criteria.

## F0 — Tested prototype (0.1.x) · evidence still open

**Goal:** validate the existing OS in Supersymmetry, document real behavior,
and provide a safe update path before architectural expansion.

- Test with Tier 2 CPU and Tier 2/3 screens.
- Measure free memory, time to first render, and redraw activity.
- Exercise all apps and fix issues found in-game.
- Add an About-screen updater backed by stable GitHub Releases.
- Version stable builds with matching semantic Git tags and GitHub Releases.
- Keep settings, user data, boot configuration, and EEPROM outside the updater's
  write set.
- Record in-game results in [`tests.md`](tests.md).

**Exit criteria:** 30 minutes without `ERR` entries, at least 250 KB free on a
Tier 2 node, first render within 2 seconds, and a tested release update that
preserves settings and supports rollback on handled installation failures.

> 0.2.3 shipped without recording the 30-minute clean log and the Tier 2
> memory/first-render figures. Record them before the 0.4 session work.

## F1 — Desktop shell (0.2.x) · shipped

**Goal:** ship a desktop icon shell and the update path on top of the 0.1.x
prototype.

- **0.2.0 Grid:** single-click desktop icons, taskbar window chips, keyboard
  navigation when no window is focused, and a SYSTEM section in About.
- **0.2.1 Mosaic:** drag icons within the grid, persist the order, and render
  System with a distinct accent tile. F1-F6 remain bound to apps, not grid
  positions.
- **0.2.2 Drift:** expand the icon grid to the whole screen, keep empty-cell
  positions in `iconLayout`, allow move-or-swap drops, and draw the dragged icon
  as a floating tile.
- **0.2.3 Glyph:** give every app a 9x5 box-drawing pictogram, rename About to
  Update, migrate saved `about` positions, and enforce the desktop-icon contract
  in `npm run check`.

**Outcome:** 0.2.3 is the last 0.2.x release. The service/app-contract split
originally planned for 0.2.x is folded into 0.4; 0.3.x only adds the `tc.net`
transport and cluster modules needed for nodes.

## F2 — Cluster (0.3.x) · current

**Goal:** discover cable-connected racks, install a slave system on each server,
delegate work, and delegate storage.

### 0.3.0 Rack — shipped

- Add `tc.net`: text frames over a wired network card, versioned verbs, 1 KB
  limit, ACK/retry, and idempotent handling.
- Add a headless boot mode: no GPU requirement, role and master keys in
  `/etc/terracorp.cfg`, and a minimal status render on a screen if one exists.
- Add netboot provisioning through the rack's mountable disk drive: the master
  writes the payload, the server copies it to its first HDD, sets its boot
  address, and reboots without touching its EEPROM.
- Define `HELLO`, `ASSIGN`, `ACK`, `STATUS`, `PING`, and `PONG`.
- Keep the node registry in `/var/nodes.tsv`, preserved by the updater.
- Add the Nodes app as the seventh app, bound to F7 for now with a 9x5 rack
  pictogram. Keyboard shortcuts will be removed later.
- Show the rack segment, node, state, memory, disk, and last-seen data. Offer
  **Prepare installer** and per-node **Rename** and **Set role**.
- Add harness coverage: two nodes on one modem bus, provisioning, reboot,
  registry persistence, offline detection, and a failed install.

**Exit criteria:** one rack with two servers is provisioned from the rack floppy;
both are online after a reboot; the master reports aggregate RAM and disk; the
registry survives an OS update; no EEPROM is written.

> 0.3.0 shipped on 2026-10-26. The in-game rack build and provisioning test are
> still pending; see [`tests.md`](tests.md) for the checklist.

### 0.3.1 Relay — next

- Add a persistent job queue and dispatch jobs to `worker` nodes.
- Add timeouts, retries, cancellation, and result return to the requesting app.
- Add `plant status` and `node drain` commands.
- Keep jobs contracted: a node runs a named task, not arbitrary remote code.

**Exit criteria:** a batch job runs on a worker and returns to its requester;
draining a node stops new assignments without losing queued work; a master
restart does not lose the queue.

### 0.3.2 Vault

- Add a remote filesystem service: chunked reads and writes, checksums, and
  atomic rename over `tc.net`.
- Add the `storage` role and mount remote volumes in Files.
- Mirror to a second node; a single node failure must not corrupt data.
- Do not attempt distributed RAID; use the storage node's own RAID where
  available.

**Exit criteria:** read and write a 64 KB file with a valid checksum; a node
failure leaves the mirror readable; the UI reports storage usage per node.

## F3 — Sessions and displays (0.4)

**Goal:** replace the desktop singleton with sessions, so apps can later run on a
node with more RAM.

- Add `tc.session` for per-session windows, apps, focus, and lifecycle.
- Add `tc.display` backends: local GPU, remote terminal spans, and headless.
- Pack the framebuffer into strings (2 bytes per cell) instead of Lua tables.
- Add `desktop` and `kiosk:<app>` session profiles.
- Keep local session behavior unchanged.
- Finish the service/app-contract split deferred from 0.2.x.

**Exit criteria:** two headless sessions and one local session under 200 KB
total, at most 64 KB per session, boot within 1.5 seconds, and a multi-session
harness test.

## F4 — Application server and terminals (0.5)

**Goal:** run apps on the node with the most free RAM and use lightweight
terminals in factories.

- Reuse `tc.net`; add `SESSION`, `FRAME`, `INPUT`, and `RESUME` messages.
- Place a session on the eligible node with the most free RAM; keep the session
  on its node across terminal reconnects.
- Resume a terminal's session after disconnect.
- Discover cores and use a shared per-segment key.
- Add a minimal terminal client and kiosk profile.
- Limit remote-session refresh to 10 Hz and group spans; local screens have no
  fixed Hz setting in OpenComputers.

**Exit criteria:** two terminals (cable and Linked Card) connected to a headless
core, reconnect under 5 seconds, documented bandwidth/latency, no session-state
loss when a terminal disconnects, and a session placed on the node with the most
free RAM.

## F4.5 — Long-distance links and tablets (optional; does not block F5)

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

## F5 — Data center and power (0.6)

**Goal:** operate the cluster as a data center rather than a set of racks.

- Inventory nodes, disks, power, and network links across racks.
- Refine roles: `core`, `storage`, `worker`, and `edge`.
- Add UPS and power-plant monitoring, reserve budgets, and staged shedding.
- Automatically boot in stages above 60% UPS charge, with per-node checks and
  a watchdog.
- Shut down in order: workers, terminals, storage, then core.
- Document the permanent chunk-loader requirement.
- Add health checks, alerts, and rebalancing for the 0.3.2 mirrors.
- Attribute operator names in the UI/log without user accounts.
- Display a data-center map and node/disk/relay/UPS alerts.

**Exit criteria:** inventory two racks/six nodes, automatic startup after world
reload above 60% charge, terminal file reads/writes, and one-node failure
without data corruption or taking down the rest of the system.

## F6 — Factory integration (0.7)

- Verify which GTCE inventories/tanks are exposed through the Adapter.
- Add machine-stop alerts and production counters to the kiosk.

Do not plan further work until this is tested in-game.

## Prioritized backlog

| # | Work item | Phase | Size |
|---|---|---|---|
| 1 | In-game Supersymmetry test and F0 evidence | F0 | S |
| 2 | `tc.net` framing, ACK, retry, idempotency | 0.3.0 | L |
| 3 | Headless slave boot and netboot provisioning | 0.3.0 | L |
| 4 | Node registry and Nodes app | 0.3.0 | M |
| 5 | Job queue and worker delegation | 0.3.1 | L |
| 6 | Remote filesystem service and mirror | 0.3.2 | L |
| 7 | Sessions, display backends, packed framebuffer | 0.4 | L |
| 8 | App placement, remote session protocol, terminal client | 0.5 | L |
| 9 | Data-center power, UPS, health, rebalancing | 0.6 | M |
| 10 | Redstone Control measurement spike and transport | F4.5 | M |
| 11 | Resumable tablet client | F4.5 | M |
| 12 | Factory telemetry and kiosk alerts | F6 | M |

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
6. **0.3.x split:** Rack, Relay, and Vault are separate patch releases — decided.
7. **Rack discovery:** racks are not components; discover them through the
   mountable disk drive and node announcements — decided.
8. **Sessions move after the cluster:** sessions and displays are 0.4, so apps
   can be placed on the node with the most free RAM — decided.
