# Roadmap

> **Intent.** TerraCorp OS is the control and observability plane of a plant
> whose logistics must scale: many halls, many stores, **items and fluids as
> first-class stocks**, and a fast answer to the two questions that stop
> production — *where is the bottleneck* and *what is out of power*. Everything
> below serves that. The pack's pipes, hoppers and machines move the goods;
> TerraCorp reads them, decides, alarms and gates.

> **Constraints that do not move.** The OS must still boot and stay useful on
> one offline computer with 1 MB and no mod integration: when a sensor or a
> bridge is missing, readout degrades to coarse samples and the desktop keeps
> working. Networking, servers and the data center are layers on top, never a
> requirement for the isolated node.

> Target model: **one application server and lightweight terminals in each
> factory**. See [`distributed.md`](distributed.md). The 0.3.x cluster is the
> first layer: the existing computer becomes the master, and rack servers become
> nodes.

Each phase has measurable exit criteria. Do not start the next phase until the
current phase meets its criteria.

## F0 — Tested prototype (0.1.x) · evidence recorded

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

> The user confirmed a clean 30-minute session without `ERR` entries and
> working behavior on the published build in-game on 2026-10-26. F0 is
> considered closed; keep `npm run measure` and in-game `tc.log` checks
> available for regressions.

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
originally planned for 0.2.x is folded into F4 Sessions; 0.3.x only adds the
`tc.net` transport and cluster modules needed for nodes.

## F2 — Cluster (0.3.x) · built, in-game verification pending

**Goal:** discover cable-connected racks, install a slave system on each server,
delegate work, and delegate storage. This phase is the substrate the plant
readout runs on: Relay moves the jobs, the node registry says who is alive, and
Vault owns the file storage.

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

### 0.3.1 Pull — built, in-game checks pending

- Shrink the installer floppy to a pull bootstrap: `/init.lua` (`netfetch.lua`)
  plus `tc.net`, marked by `/ready.txt`; re-arming reuses it per version and
  legacy payload floppies are converted.
- Add the network install path: the unprovisioned server pulls the runtime
  from the master over `LIST`/`FETCH` after `ASSIGN`, and the boot address
  moves to the HDD only after a complete copy.
- Gate the node list on a boot integrity check: `HELLO`/`ACK` no longer
  register nodes; only a verified `STATUS` does.
- Add **Refresh** (global PING) and per-node **Forget** in Nodes.
- Track node versions: `STATUS` carries `v`, the registry gains a `v` column,
  and Nodes shows it on the node card.
- Add master-driven updates: the master stages the latest GitHub release into
  `/var/nodeupdate/<version>/` (falling back to its own runtime), offers
  `PULL` to the nodes, and the boot-time applier applies the staged tree with
  backups and rollback.

**Exit criteria:** two nodes provisioned from a bootstrap floppy come back
online with their versions; a newer release published on GitHub propagates to
the nodes through **Update** without touching the master's own install; an
interrupted pull retries cleanly from the floppy.

### 0.3.2 Relay — built, in-game checks pending

Design in [`relay.md`](relay.md): a **coordinator-less** work queue. Any node
can publish work and any worker can take it — the publisher only books its own
jobs (disk journal, re-offer on restart), the first claim wins, and leases
re-offer stalled jobs. Adding nodes to the bus never requires a central
broker — this is the scaling model the plant readout reuses: a new hall adds
one reader node and one config file, not new code.

**0.3.2a and 0.3.2b built:** `tc.jobs` with the six verbs, the `/var/jobs.tsv`
journal (resumed on boot), worker slots with the built-in tasks (`fs.check`,
`disk.report`, `log.tail`, `comp.count`), drain persistence, and the Nodes
**Check** and **Drain**/**Undrain** actions with the header as `plant status`.

Still to build:

- Timeouts surfaced to the requesting app and result history browsing.
- Keep jobs contracted: a node runs a named task, not arbitrary remote code.

**Exit criteria (in-game run pending):** a batch job runs on a worker and
returns to its requester; draining a node stops new assignments without losing
queued work; a master restart does not lose the queue.

### 0.3.3 Waves — built, in-game checks pending

- Batched node updates: **Update** offers `PULL` to half of the remaining
  nodes at a time, so part of the rack always stays online while the rest
  reboots into the new version.
- A wave advances when its nodes report the target version, go offline, or
  hit the 120 s wave window; the next wave starts immediately.
- The Nodes line shows live progress: `Update <v> · wave N · X/Y updated ·
  Z queued`, and `Update <v> finished · X/Y node(s) updated` at the end.
- Nodes without a known modem address are skipped and reported.

**Exit criteria:** with at least two nodes, **Update** reboots one while the
other stays online, and the desktop shows wave progress without operator
intervention.

### 0.3.4 Vault — built (0.3.4a), in-game checks pending

Decision in [`vault.md`](vault.md): **no RAID and no mirror inside TerraCorp**.
Every server's system disk stays local for the OS and programs; all other
disks on every server join one shared storage pool presented as a single
namespace — more storage, not redundant storage. When redundancy is wanted,
the pack's **RAID block** provides it at the hardware layer and its volume
joins the pool like any other disk (pending in-game verification).

**0.3.4a built:** the `VDISK`/`VOPEN`/`VDATA`/`VDACK`/`VDONE`/`VERR`/`VREAD`/
`VLST`/`VDIRS`/`VDEL` verbs, the node disk gateway (spare disks only — the
boot volume and read-only media stay out), the master pool with placement to
the disk with the most free space, the index in `/var/vault/index.tsv`
(restored on boot), chunked transfers one frame per tick, partial-write
protection via part files and rename, virtual listings from the index, and the
`vaultWrite`/`vaultRead`/`vaultRemove`/`vaultList`/`vaultUsage` API.

**0.3.4b built (v0.3.5):** the **Vault** app (browse, read into the cache,
store from `/var/vault-in`, save out to `/var/vault-out`, delete), the
`vault`/`vls`/`vput`/`vget`/`vrm` Terminal commands, pool usage in Nodes, and
the index backup restored from a pool disk on a fresh master.

Still to build:

- Surface per-disk health once the pack's RAID block is verified in-game.

**Exit criteria:** a 64 KB file is stored and read back through the pool; the
namespace is browsable from the master; the pool reports usage per disk.

> Vault holds **files**, not goods. Item and fluid storage is the world's
> containers, surfaced by the stocks in F3 (decisions 11 and 12).

### 0.3.20 External link — shipped; WAN deployment parked

The operator's agent can read and drive one computer from outside the game
([`external-link.md`](external-link.md)). Same-machine deployment only for now;
the WAN path is parked (decision 9).

**Phase exit criteria (one session, one checklist):** the rack, Relay,
waves, Vault and external-link checks in [`tests.md`](tests.md) pass in-game in
one sitting, and the Adapter probe from F3 is recorded in the same session — the
probe needs the world running anyway, so it rides along instead of costing
another run.

## F3 — Plant readout (0.4) · next

**Goal:** turn the plant into numbers an operator can act on — items and fluids
as named stocks, energy per node, an alarm list, and a plan that names its own
bottleneck. The phase has **two layers** (decision 14,
[`plant-service.md`](plant-service.md)): the nodes read and hold, the service
remembers, plans and explains. Neither layer is optional.

### 0.4.0 The probe (no code, blocks everything precise)

One in-game session answering what OpenComputers can actually see, recorded in
[`telemetry.md`](telemetry.md#in-game-verification-checklist): an Adapter next
to a **Storage Drawer**, a **GregTech crate**, a plain chest, a **multiblock
tank**, an induction matrix and a single-block machine. Record kinds, methods,
units, read cost, the **identifier format** for one item and one fluid, and
whether the world host can reach an HTTP service on loopback.

If nothing reads, the phase ships coarse mode only (drawer redstone 0–15) and
every precise stock item below stops there. Writing `tc.stock` before this
probe is guessing.

### 0.4.1 Addressing, semantic paths and the middleware profile

Design in [`names.md`](names.md) and [`middleware.md`](middleware.md). Two
namespaces, not one: an **opaque physical address** (`node:component:face`) that
routes, and a **hierarchical semantic path** (`hall1/ore_processing/grinders`)
that searches. Nothing outside ever handles the first by hand.

- **Proxies:** each computer is authoritative for its own components, faces,
  `first_seen` and the paths that mention them (`component.list`,
  `component.unclaimed`, `path.list`, `path.query`, `path.assign`).
- **Paths resolve to sets; the operation reduces them:** reads sum with a
  per-member breakdown (drift is **skew**, a bottleneck symptom); writes dispatch
  by the policy **in the command** (`all`, `any`, `fill`; `round_robin` is the
  service's cursor sent as `member=`). A declared cardinality of `single` that
  resolves to two members is `cardinality_mismatch`.
- **Many-to-many:** a component lives in every path that describes it, so the same
  drawer is in `hall1/ore_processing/entrada` and `lineas/grinder_1/entrada`.
  Wildcards (`**/grinders`, `hall1/*/tanks`) are how the agent finds things
  without memorising the base.
- **Merged outward, never pushed down:** proxy → gateway → service. Saved configs
  reference addresses, so renaming a path cannot silently rewire a line.
- **Middleware profile:** leaves (wired only, components only) and gateways
  (internet + wired + wireless, the single ingress, dumb proxy). Plain computers,
  not rack servers — those do not boot after a world reload and their internals are
  never visible to anyone else.
- **Driver registry:** an Adapter can expose signs, chests, tanks and machines as
  readily as drawers, so each kind is described by a **declarative descriptor**
  (`/etc/drivers/<kind>.lua`) over a **closed capability vocabulary**
  (`inventory`, `tank`, `energy`, `redstone`, `text`, `transfer`). A descriptor is
  data, never code: `/etc` is writable through the link, and a descriptor that
  executed Lua would turn a config edit into remote code execution. An unknown
  kind shows up as `driver=unknown`, `driver.dump` gives its methods, and a reload
  registers it without touching the kernel ([`drivers.md`](drivers.md)).
- **Node status:** `node.status` — version, uptime, memory, energy, link health,
  cache age. Cheap, no component scan.
- **Service:** skeleton, ingest, the alarm engine (severity, source, first/last
  seen, ack) and the panel with per-hall liveness.
- The proxy keeps **no alarm registry**: naming, thresholds and grouping are
  decisions, and decisions live outside the world (decision 16).

### 0.4.2 Stock — items as named stocks

- **Node:** `tc.stock` is a batch reader, not a plant module. A **named stock**
  is a list of containers in `/etc/stocks.tsv`; the reader walks them with a
  **per-tick call budget**, caches every answer, and serves `stock.snapshot` /
  `stock.delta` from that cache. Idle means no calls at all.
- Snapshot and delta verbs: the first listing is paged like `FETCH`, later polls
  carry only changes against a cursor, and an expired cursor answers `resync`.
  A snapshot that silently truncates is worse than none.
- Coarse fallback: any container in a stock that cannot be read marks the whole
  stock **coarse**, and the UI says so. The OS never reports a count it did not
  read.
- **Service:** ingest, history, and a per-hall stock view keyed by exactly what
  the node reported. Rate and trend maths live here.

### 0.4.3 Tanks — fluids

- **Node:** same reader for fluids: per tank, fluid type, amount, capacity,
  aggregated per named tank group.
- **Service:** same ingest and history; thresholds raise input-empty and
  output-full alarms.

### 0.4.4 Rates and plant alarms

- **Service only.** Rates (items/min, mB/min) come from its own sample history,
  because the node has no memory for it and the panel needs the trend.
- Alarms derived from samples: `STARVED` (below minimum while a consumer runs),
  `FULL` (above maximum), `STALLED` (rate collapsed while the line is up),
  `TREND` (projected to hit a limit within the horizon), plus chain-level ones
  the node cannot know ("hall A waits on hall B").
- Thresholds live in the service config per stock: a new hall sets its own
  limits without a code change.

### 0.4.5 Recipe book and planning

- **Service only.** Design in [`recipes.md`](recipes.md). The readout says what
  is in the hall; the book says what the hall can become — and without it a
  level that stops moving can never be told apart from "step X is the limit".
- **Declared or imported, measured, verified**: the numbers drive the planner
  until a real run contradicts them; then the recipe turns `suspect`, the
  measured ratio wins, and an alarm says so. Imported is not verified.
- **Chain**: priority between alternative recipes, bounded passes for GT
  reprocessing cycles, chance byproducts at their expected value and flagged
  when a plan leans on luck. Bottleneck and shortfall per
  [`recipes.md`](recipes.md).
- **Lines**: the node owns the hardware binding (`/etc/lines.tsv`: line name →
  gate address), the service owns the planning binding (line name → recipe,
  limits). The line name is the join key; a name on one side only is an
  `unknown_line` alarm, never a guess.
- **Reference library, optional**: a published pack export may be imported
  read-only and pinned by version and checksum, so the operated book points at
  reference ids instead of retyping ticks and EU/t
  ([`research-susy-planner.md`](research-susy-planner.md)). We never derive
  recipes from the mods ourselves and never vendor pack data here.

### 0.4.6 Gates — desired state and interlocks

- **Node:** `gate.set` stores the **desired** state in `/var/gates.tsv`,
  reconciles it every tick and reports the actual state with the last refusal
  reason. Interlocks are local: no feeding a full output, no opening a line
  whose input stock is empty, no state change the node cannot verify.
- Desired state, never toggles: a retried request must not invert a gate, and a
  reboot must restore the last setpoints without asking anyone.
- **Service:** turns a plan into setpoints, shows refusals, and after N
  consecutive refusals raises `DISOBEDIENT LINE` and stops resending.
- `gate.set` requires `linkControl = write`; with `off` the node reports and
  refuses to move anything.

### 0.4.6b Movement — `move` by name

The only physical operation the node performs, because nobody else can: items
leave one inventory and arrive in another ([`names.md`](names.md#moving-by-name-move)).

- `move from=<name> to=<name> n=<amount> key=<selector>` resolves both names
  (and the transport's name), reads the source slots, filters by selector and
  transfers **slot by slot** through the named transport, capped per command.
- The answer is what actually moved, per source member; `moved=0 reason=…` when
  nothing did. A cheerful `ok` for a move that did not happen is the worst
  possible reply.
- Cost is per slot examined, not per item moved, so the selector and the stock
  layout matter: drawers group like items for free, a chest does not.

### 0.4.7 Agent tools — read-only MCP

The decision layer is a **local model** that gets the plant as MCP tools and
decides through them ([`agent.md`](agent.md)). This slice exposes only what
cannot hurt: `plant_situation`, `stock_query`, `alarm_list`, `history`, `plan`,
`line_list`, `name_list`, `name_resolve`, `recipe_query`, `audit_tail`.

- The situation report is **pre-aggregated and bounded**: halls, top alarms,
  stocks out of limits, rates, stale sources. A dump of every item type would
  bury the signal and burn the context.
- The deterministic planner is a **tool**, never arithmetic the model does in its
  head. Every number the agent states must be traceable to a tool result.
- Read-only on purpose: it validates whether the model understands the plant
  before it can move a gate, and it cannot break anything while it learns.

Not in this phase: write tools, autonomous policy, approvals.

Not in this phase: moving items, restock orders, hologram walls, sessions.

**Exit criteria:**

- **Node:** one hall with two stocks (items and fluid) reports **exact** counts
  to the service with no visible drop in the TPS sampler; pulling a drawer
  raises `STARVED` in the service within one polling cycle and clears on refill;
  an idle hall makes **zero** component calls per tick; a node's energy falling
  raises an alarm before the node halts; with the service stopped, gates hold
  their last desired state and the node keeps serving its cache; a reboot
  restores setpoints with the service absent.
- **Service:** a three-step chain plans in under a second, names its bottleneck
  step, and its shortfall matches a hand count; a refused gate shows up as an
  alarm instead of a silent retry; the panel marks every hall `stale` after a
  config drift rather than planning on old numbers.
- **Agent:** with read tools only, the local model answers three posed questions
  — "what limits the gear chain", "which hall runs dry first", "what changed in
  the last hour" — citing the tool call behind every number, and inventing none.
- **Paths:** `move from=hall1/ore_processing/entrada
  to=hall1/ore_processing/grinders n=64 policy=fill` runs without a single UUID in
  the command; a path resolving to two members sums its reads and dispatches by
  the policy it was given; a second member under a `single` path raises
  `cardinality_mismatch`; a mutating command on a multi-member path with no policy
  is refused; breaking and re-placing one drawer leaves that member `unbound`
  while the path keeps resolving; renaming a path does not rewire a saved line.
- **Degradation:** with the Adapter absent or `linkControl = off`, the apps show
  `coarse`, `no telemetry` or `refused` — never an invented number.
- **Scale:** a second hall is one reader node plus config on both sides, with no
  new app or module.

## F4 — Sessions and displays (0.5) · moved after the readout

**Goal:** replace the desktop singleton with sessions, so apps can later run on a
node with more RAM. Sessions come second on purpose: a stock number on the
master is useful on day one, while a movable session is not.

- Add `tc.session` for per-session windows, apps, focus, and lifecycle.
- Add `tc.display` backends: local GPU, remote terminal spans, and headless.
- Pack the framebuffer into strings (2 bytes per cell) instead of Lua tables.
- Add `desktop` and `kiosk:<app>` session profiles.
- Keep local session behavior unchanged.
- Finish the service/app-contract split deferred from 0.2.x.
- Follow up with the VRAM double-buffer renderer ("Flip") in 0.5.1 per
  `docs/render.md`: capability-probed buffers, a single bitblt per mostly-dirty
  frame, span diffing still the default path.
- The concrete module and milestone plan for 0.5.0 lives in
  `docs/sessions.md`.

**Exit criteria:** two headless sessions and one local session under 200 KB
total, at most 64 KB per session, boot within 1.5 seconds, and a multi-session
harness test.

## F5 — Application server and terminals (0.6)

**Goal:** run apps on the node with the most free RAM and use lightweight
terminals in factories — the plant dashboard is the first app that matters
here, because it is the thing an operator wants on the hall wall.

- Reuse `tc.net`; add `SESSION`, `FRAME`, `INPUT`, and `RESUME` messages.
- Place a session on the eligible node with the most free RAM; keep the session
  on its node across terminal reconnects.
- Resume a terminal's session after disconnect.
- Discover cores and use a shared per-segment key.
- Add a minimal terminal client and kiosk profile.
- Limit remote-session refresh to 10 Hz and group spans; local screens have no
  fixed Hz setting in OpenComputers.
- The verb-level terminal contract is specified in `docs/terminal-protocol.md`
  (FRAME/INPUT/RESUME, input ACK piggyback, bandwidth ceilings).

**Exit criteria:** two terminals (cable and Linked Card) connected to a headless
core, reconnect under 5 seconds, documented bandwidth/latency, no session-state
loss when a terminal disconnects, and a session placed on the node with the most
free RAM.

## F5.5 — Long-distance links and tablets (optional; does not block F6)

Researched in `docs/long-distance.md` (transport comparison, RC framing,
tablet client, spike script, and per-transport verification checklists):
linked cards for cross-dimension packets, wireless modem for long-range
same-dimension links, and Redstone Control as a signal-level fallback
(~80 B/s/channel). Each transport needs its in-game probe before any code.

- Verify Redstone Control bandwidth/tick behavior, the OpenComputers Adapter
  API, interdimensional wireless availability, and tablet limits before coding.
- Add Redstone Control as a `tc.net` transport: 32-bit frames, ACKs for commands,
  best-effort state updates.
- Use Linked Cards as the primary inter-base link. The alarm channel carries the
  F3 alarm codes, so a remote base raises `STARVED` or `NO POWER` on the master
  without a second alarm model.
- Add a resumable tablet client; sessions do not survive dimension changes or
  reconnects without an explicit resume.
- Add a reduced lunar kiosk for status and emergency controls.

**Exit criteria:** transfer 1 KB with a valid CRC between dimensions, command
round-trip under 2 seconds, and emergency control remains available if the
primary link fails. See [`long-distance.md`](long-distance.md).

## F6 — Data center and power (0.7)

**Goal:** operate the cluster as a data center rather than a set of racks.
Alarms and energy history already exist from F3; this phase adds the policy
that acts on them.

- Inventory nodes, disks, power, and network links across racks.
- Refine roles: `core`, `storage`, `worker`, and `edge`.
- Add UPS and power-plant monitoring, reserve budgets, and staged shedding
  ([`power.md`](power.md)).
- Automatically boot in stages above 60% UPS charge, with per-node checks and
  a watchdog.
- Shut down in order: workers, terminals, storage, then core.
- Document the permanent chunk-loader requirement.
- Add health checks, alerts, and rebalancing for the Vault pool. Redundancy
  comes from the pack's RAID block (see [`vault.md`](vault.md)): no software
  mirroring. Verify the RAID block's filesystem component in-game; F6 keeps
  only the monitoring and rebalancing work.
- Attribute operator names in the UI/log without user accounts.
- Display a data-center map and node/disk/relay/UPS alerts.

**Exit criteria:** inventory two racks/six nodes, automatic startup after world
reload above 60% charge, terminal file reads/writes, and one-node failure
without data corruption or taking down the rest of the system.

## F7 — Logistics automation (0.8)

**Goal:** act on the readout: hold a stock at its limit without an operator
watching it. Design in [`crafting.md`](crafting.md), [`recipes.md`](recipes.md),
[`agent.md`](agent.md) and [`holo.md`](holo.md). The knowledge, the setpoints and
the read tools already exist by 0.4.7; F7 gives the agent hands and the plant a
way to trade across halls.

- **Agent write tools** with `request_id`, `dry_run` and the authoritative
  post-state returned on every call: `gate_set`, `move`, `name_assign`,
  `order_create`, `recipe_upsert`, `alarm_ack`, `proposal_create`.
- **Tiered approval:** routine actions run automatically; structural ones
  (`linkControl` raise, mass recipe edit, a new line) wait for a human.
- **Injection defence in the loop:** item labels, notes and log lines travel in
  a data envelope, control characters stripped and length capped. World text is
  data; a label that issues instructions is reported, never obeyed.
- **Orders that cross halls:** a `STARVED` becomes an order derived from
  `plan()` — source hall, amount, priority — and the receiver confirms when the
  stock actually moved.
- **Catalogue view:** every stock, its rate, its limits and the lines that touch
  it, in one page — the operator's answer to "what do I have and what is it
  doing".
- **Machine-stop alerts and production counters** on the kiosk, from the same
  machine reads the probe proved (or did not).
- **Hologram wall**: stocks and alarms as bars in the hall
  ([`holo.md`](holo.md)), fed by the cached samples, not by live polling.

**Exit criteria:** the agent runs one crafting line unattended for 30 minutes,
stops at its stock limit, raises `STARVED` on a missing ingredient and restocks
it by order rather than by editing config; its audit shows every action traceable
to a tool result; a label containing instructions produces an alarm and no
action; the wall shows the same numbers as the panel.

## Prioritized backlog

| # | Work item | Phase | Size |
|---|---|---|---|
| 1 | In-game 0.3.x verification + probe, identifiers and loopback (one session) | F2/F3 | L |
| 2 | Names (DNS), `node.status`, service skeleton, ingest, alarm engine, panel | 0.4.1 | L |
| 3 | `tc.stock` reader, snapshot and delta verbs; service history | 0.4.2 | L |
| 4 | Tanks as stocks | 0.4.3 | M |
| 5 | Rates and plant alarms in the service | 0.4.4 | M |
| 6 | Recipe book, lines and chain planning in the service | 0.4.5 | L |
| 7 | `gate.set`, desired state, local interlocks, refusals | 0.4.6 | M |
| 8 | `move` by name: selector, transport, bounded accounting | 0.4.6b | M |
| 9 | Read-only MCP surface for the local agent | 0.4.7 | M |
| 10 | Sessions, display backends, packed framebuffer | 0.5 | L |
| 11 | App placement, remote session protocol, terminal client | 0.6 | L |
| 12 | Data-center power, UPS, health, rebalancing | 0.7 | M |
| 13 | Agent write tools, approvals, cross-hall orders | 0.8 | L |
| 14 | Hologram wall | 0.8 | M |
| 15 | Redstone Control measurement spike and transport | F5.5 | M |
| 16 | Resumable tablet client | F5.5 | M |

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
8. **Order change (2026-11-13):** plant readout (F3, 0.4) ships **before**
   sessions (F4, 0.5). Sessions only change where the UI runs; stocks, energy
   and alarms are what the plant needs on day one. Sessions still come before
   app placement, which depends on them.
9. **External link deployment:** one machine first — the world host and the
   bridge on the same box, which is the bridge default. The WAN path
   (WireGuard, or HTTPS with a trusted certificate) is parked until that setup
   exists, expected in a couple of weeks. See
   [`external-link.md`](external-link.md).
10. **TerraCorp is the control plane, not the transport.** It reads, decides,
    alarms and gates. Pipes, hoppers and the pack's own logistics move the
    goods; TerraCorp never implements item transport.
11. **AE2 is a crafting terminal, not the store.** The pack has Applied
    Energistics, but it is expensive and used for manual machine crafting; the
    plant's stocks are drawers, GregTech crates and tanks, read through the
    Adapter. If an ME network ever becomes a store, only the F3 sensor layer
    changes, not the model.
12. **Vault holds files, not goods.** The pooled disks store OS and operator
    files. Item and fluid storage is the world's containers, surfaced as
    stocks; the Vault app is not a warehouse UI.
13. **Recipes are calibrated before they are trusted.** A recipe arrives either
    **declared** by the operator or **imported** from a published pack export
    (amended 2026-11-13, see decision 19), always keyed by the identifiers the
    sensor actually reports. Neither provenance is trusted on arrival: a real run
    calibrates the numbers, measurement wins over belief, and a contradiction
    raises an alarm instead of being smoothed over. See
    [`recipes.md`](recipes.md).
14. **The brain lives outside the world (2026-11-13).** The recipe book,
    planner, history, plant alarms and panel run in the **plant service**; the
    nodes keep sensors, gates, interlocks and the last desired state. Two facts
    force it: a polled link with a 5-10 s interval cannot close a 1 Hz loop, and
    1 MB cannot hold the book. Consequences: `gate.set` carries **desired
    state**, never a toggle, so a retry cannot invert a gate; the OS refuses
    locally whatever its interlocks reject and reports why; a dead service means
    "hold the last setpoints", not "stop the plant". See
    [`plant-service.md`](plant-service.md).
15. **The decision-maker is a local agent, on tools (2026-11-13).** A local model
    connects over **MCP** and decides goals, priorities and sequencing. It gets
    no arithmetic and no free execution: numbers come from deterministic tools
    (`plan`, `history`, `stock_query`), writes carry `request_id`, `dry_run` and
    the authoritative post-state, and the node keeps the final say through its
    cached interlocks. Text from the world — labels, notes, logs — is **data**,
    never instructions. Read tools ship first (0.4.7), hands later (F7). See
    [`agent.md`](agent.md).
16. **The node is a translator (2026-11-13).** The world does no plant thinking:
    no recipe, no rate, no threshold, no alarm text, no planner. It turns named
    requests into component calls under a per-tick budget, caches the answers,
    and reports. The reason is the server's tick budget — component calls cross
    into the server thread, so frequency costs more than cleverness — plus the
    fact that anything on a 1 MB computer competes with the OS itself. The
    translator still refuses what its **cache** shows to be wrong, and never
    spends an extra component call to decide.
17. **The translator's first job is a DNS (2026-11-13).** Components get
    **semantic, hierarchical paths** — `hall1/ore_processing/grinders` — and every
    command from outside speaks those paths, never a UUID. A path resolves to a
    **set**, so several components under one path is the normal way to say
    "replicas, parallelise": the declared cardinality separates a replica set
    (`pool`) from a wiring mistake (`single`), reads sum with a per-member
    breakdown, and writes dispatch by a policy that travels **in the command**.
    A member that disappears goes `unbound` while the rest keeps serving; a kind
    change is a hard error. Paths are what make external instructions readable,
    reviewable and diffable, and they ship first because every other verb depends
    on them. See [`names.md`](names.md).
18. **Where each fact lives (2026-11-13).** Binding, kind and cardinality
    describe the hardware, so they live in the node and survive a service
    restart. Dispatch policy, amount, selector and limits describe what the
    command wants, so they travel in the frame and the node keeps no memory of
    intent — which is also why `round_robin` is the service's cursor and not a
    node mode. A mutating command on a multi-member pool without a policy is
    refused rather than defaulted: guessing "fan out" or "drain one" is wrong half
    the time. **One deliberate exception:** the last desired state of a gate is
    persisted in the node, because its whole purpose is to hold position while the
    brain is absent. It is last-write-wins, carries no policy, and expires into
    "closed" only when an operator says so.
19. **Recipes may be imported, never redistributed (2026-11-13).** The normalized
    dataset behind **SuSy Factory Flow** — a fork of the GTNH planner retargeted
    at SuSy and maintained in the **SuSy developers' own organisation** — is a
    legitimate **read-only reference library**, pinned by version and checksum,
    and our operated book points at its recipe ids instead of retyping ticks and
    EU/t. Because it is the pack's own tooling, its schema is the closest thing to
    a data standard for SuSy: we **adopt** it and justify any divergence, instead
    of inventing a parallel format. This amends decision 13: `imported` joins
    `declared` as a provenance, and **imported is not verified** — only a real run
    promotes a recipe. Pack data is never vendored into this repository, and their
    solver is reused rather than reinvented if optimization is ever needed. See
    [`research-susy-planner.md`](research-susy-planner.md).
20. **The plant runs on plain computers, not rack servers (2026-11-13).** Leaves
    and gateways are ordinary computers in the world. Two verified mod facts force
    it: a rack server's internals are `Visibility.Neighbors`, so a rack never
    widens what can be read, and servers **do not boot after a world reload**
    without a sneak-use each. Racks, Vault, waves and Relay stay shipped and
    tested, but off the plant path — there to answer density and pooled disks, not
    component access. Consequence: no in-world redundancy for the translator
    layer; a dead proxy is silence the service must interpret, and Sessions and
    remote terminals (F4/F5) stop gating anything plant-related until a use
    appears for them.
21. **Two namespaces, authority inside, merge outside (2026-11-13).** A physical
    address routes and a semantic path searches; configs store addresses so a
    rename cannot silently rewire a line. Each proxy is authoritative for its own
    components and paths, the **gateway merges its leaves**, and the **service
    merges the gateways** into the view apps and the agent consume — a
    one-directional merge, never pushed back down. The app's whole job is to
    execute calls on components through those paths. See [`names.md`](names.md)
    and [`middleware.md`](middleware.md).
22. **Component kinds are plugins, and a plugin is data (2026-11-13).** An Adapter
    can expose signs, chests, tanks and machines as readily as drawers, so no block
    name is hardcoded. A kind is described by a declarative descriptor over a
    **closed capability vocabulary**; the kernel interprets it and the descriptor
    never runs. That is a security boundary, not neatness: `/etc` is writable
    through the link, so executable config would be remote code execution with a
    different name. New kind = unknown component + `driver.dump` + a file + a
    reload. New *capability* is a kernel decision. See [`drivers.md`](drivers.md).
