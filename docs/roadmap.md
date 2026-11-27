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
> nodes. F3 starts with **one self-contained computer**; the application-server
> model returns when a second hall exists.

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

## F2 — Cluster (0.3.x) · dropped (racks removed 2026-11-16)

> **Dropped, not lost.** The cluster was built and partly verified in-game, then
> removed from the product when the plant chose a small line node instead of a
> rack fleet (decision 25). What follows records what was built, so the code and
> the in-game findings stay traceable. None of it ships in a line node. The
> transport (`tc.net`), the node registry and the Nodes app survive, because a
> line node still publishes its status to a master
> ([`line-node.md`](line-node.md)).

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

> 0.3.0 shipped on 2026-10-26. Provisioning and Relay are verified in-game
> (0.3.9/0.3.10); the second node, update waves, Vault and the RAID probe remain.
> See [`tests.md`](tests.md) for the checklist.

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
another run. **Partially met:** provisioning, Relay, the 0.3.33 update and the
external link pass; the second node, waves, Vault and the RAID probe remain.

## F3 — Plant readout (0.4) · in progress

**Goal:** turn the plant into numbers an operator can act on — items and fluids
as named stocks, energy per node, an alarm list, and a plan that names its own
bottleneck. The first layer is **self-contained**: the computer that can see the
components reads them, caches the answers, evaluates its own level alarms and
shows them in the **Plant** app. A service outside the world is **optional** and
owns only what the node cannot — long history, the reference dataset, planning at
scale and the MCP agent (decision 23, amending 14, 16, 17 and 21). The 64 MB
memory change verified in-game on 2026-11-15 is what makes the local layer
affordable; the 50 ms per host call still governs every read.

> **Revision 2026-11-15:** F3 is local-first (decision 23). The service is
> optional; 0.4.1 delivers the readout, 0.4.2 the mirror. The second hall and the
> gateway this revision still expected were **removed on 2026-11-16** (decisions
> 25 and 26).

### 0.4.0 The probe · done 2026-11-15

One in-game session answering what OpenComputers can actually see, recorded in
[`telemetry.md`](telemetry.md#in-game-verification-checklist) and the results
log in [`tests.md`](tests.md#results-log). Measured with a Transposer, an Adapter
(Tank Controller), a Power Substation controller and its hatches, a Storage
Drawer with a Redstone Upgrade, a Redstone I/O and a Redstone Control `rsio`.

| Area | Answer |
|---|---|
| Item key | `name` + `damage` (+ `tag` only when `hasTag`); `size`, `label`, `maxSize`, `maxDamage` alongside |
| Fluid key | `name` is the Forge registry name (`water`), `label` display-only, `hasTag` marks NBT; `getFluidInTank` returns an **array** of tanks |
| Inventory | Transposer per face (`getInventoryName/Size`, `getStackInSlot`, `getAllStacks`); one entry per slot, empty slots are empty tables |
| Tanks | Same shape with `getTankLevel/Capacity/Count`; an Adapter needs **Tank Controller** and appears as `tank_controller`, not `adapter` |
| Energy | `power_substation` exposes `getStored`/`getCapacity` as **formatted strings** (BigInteger); the **input** hatch alone exposes numeric container reads, the output hatch exposes none |
| Coarse | Drawer Redstone Upgrade gives a linear 0–15 (≈112 items per level on a 2-slot drawer); Redstone I/O or `rsio` reads it, and both signal changes as events |
| Cost | **50 ms per host call**, uniformly — one server tick |

Precision is viable: items and fluids read exactly, energy reads with a string
normalizer and the 2^53 caveat, and coarse redstone is a working fallback. One
probe remains and does not block 0.4.1: a **multiblock tank** (several tanks
behind one face). The working-machine probe is no longer needed for F3: a line is
a black box and its rate comes from the boundary deltas (decision 24); machine
progress is diagnostics, not readout.

### 0.4.1 Plant — local registry, readers, alarms and the app

**0.4.1a Registry.** `tc.addr` (physical `node:component:face`, `first_seen`,
faces), `tc.path` (local semantic paths, wildcards, assign/query, cardinality)
and `tc.driver` (declarative descriptors over the closed capability vocabulary).
`node.status` reports version, uptime, memory, energy, link health and cache age
without a component scan. **No gateway and no DNS protocol in this slice:** the
computer is the authority for its own components and paths.

**0.4.1b Readout.** `tc.stock` and `tc.tank` are batch readers, not plant
modules. A named stock is a list of containers in `/etc/stocks.tsv` — a **line
boundary**, not every container inside the line. The reader walks the boundary
containers with a per-tick call budget, uses `getAllStacks` / `getFluidInTank`
where the probe showed them, caches every answer and serves the snapshot and
delta verbs from that cache. Energy reads use the GT driver names and a string
normalizer for `power_substation`. Any container that cannot be read marks its
stock **coarse**; the app says so and the OS never reports a count it did not
read. Idle means zero component calls.

**0.4.1c Alarms and app.** A local alarm engine evaluates **level** rules against
the cache (`STARVED`, `FULL`, `NO POWER`, `STALE`, `UNBOUND`) with severity,
source, first/last seen and ack; thresholds live in `/etc/plant.tsv`. The
**Plant** app shows halls, stocks, tanks, energy and alarms in one page, exact vs
coarse and the age of each source. A headless plant computer keeps the same core
and serves snapshots without a GPU; a desktop or kiosk draws the app. No extra
component call is spent to decide an alarm.

- **Exit:** one hall with an item stock, a tank and an energy source reports
  **exact** counts and the app shows them; pulling a drawer raises `STARVED`
  within one polling cycle and clears on refill; an idle hall makes **zero**
  component calls per tick; a removed container goes `unbound`/`coarse`, never
  zero; the plant core fits comfortably in the 64 MB machine and the 30 Hz
  desktop loop shows no visible drop.

> **0.4.1 built and verified in-game (2026-11-15):** `tc.addr`, `tc.path`,
> `tc.driver`, `tc.stock`, `tc.tank`, `tc.plant` and the Plant app are in the
> tree; `npm run test:plant` and the `plant` screen scenario pass. The casing
> hall reported 744 input items and 5 casings `exact`, the app drew with zero
> failures, `STARVED` fired and cleared, and an idle line made zero calls.

### 0.4.2 Mirror — the link exposes the local readout

The external link carries the readout without requiring a service:
`plant.status`, `plant.snapshot` (paged with the existing `LREP`/`LDATA`/`LEND`
slicing), `plant.delta` (cursor plus `resync`) and `plant.alarms`. The bridge
stores the mirror, so an operator or a later service can read the same numbers
the app shows. The link is **read-only for the plant** in this slice; the local
app keeps working with the bridge down.

- **Exit:** an external client reads a hall's exact stock, tanks and alarms; a
  snapshot that would exceed one frame is paged and never silently truncated;
  killing the bridge leaves the app and its cache untouched.

> **0.4.2 built and verified in-game (2026-11-15):** the four verbs are in
> `tc.link`, the bridge parses completed plant bodies into `GET /link/mirror`,
> `npm run test:link` covered 32 scenarios then (including a 40-stock body split
> across pages) and `npm run test:bridge` proves the mirror parser and its
> truncation guard. The delta cursor is the stock revision, so an idle scan does
> not force a resync. In-game: the real 1232-byte snapshot paged intact, an old
> cursor resynced with a complete snapshot, and 50 s with the bridge down left
> the scan, cache and Plant window untouched.

### 0.4.3 Second hall — one computer per hall, a simple merge · superseded

> **Superseded 2026-11-16 (decision 26):** the merge survives, the table does
> not. `tc.halls` and `/etc/halls.tsv` go with the racks; the master merges the
> snapshots it receives from its line nodes and keys the paths on the **node
> name** in `/var/nodes.tsv`, which is the DNS. The prefix rule and the
> `offline`/`stale` marking below are the behaviour being kept
> ([`line-node.md`](line-node.md)).

A hall is one computer plus its config. The **aggregator** — the bridge when
every hall has an Internet Card, or the master over TC1 when they are wired —
keeps `halls.tsv` (hall name → computer address) and merges `plant.snapshot` from
each hall. Paths
stay local to each computer; the merged view prefixes the hall name. **No
leaf/gateway, no TC1 DNS protocol, no service required.**

- **Exit:** two halls report into one page; a hall that is offline is `stale`,
  not dropped; adding a hall is one computer and one config row, with no new app
  or module.

> **0.4.3 module built, in-game pending (2026-11-15; corrected 2026-11-23):**
> `tc.halls` resolves the local hall from the configured name and merges the
> snapshots it is given; it no longer loads `/etc/halls.tsv` (decision 26-A), and
> `halls.load`/`save`/`PATH` were deleted in `6236f99`. It prefixes merged
> stocks and marks missing/old halls `offline`/`stale`; `plant.halls` exposes
> the view. In-game
> the 0.4.8 build reports one online hall with the two prefix-stocks; a second
> computer with Transposers is required to verify the two-hall merge, so
> `npm run test:field` is the rest of the evidence.

### 0.4.4 History — rates and rate alarms

The OS keeps a **bounded ring** of samples on disk (downsampled, oldest dropped
first) and computes items/min and mB/min from the **line boundary deltas**;
`STALLED` and `TREND` join the level alarms. The ring is sized for the panel and the agent, not for months of
history: long retention stays in the optional service. Thresholds remain local;
cross-hall policy stays outside.

- **Exit:** a rate collapse raises `STALLED` while the line is up; a projected
  limit raises `TREND`; the ring survives a reboot and never grows without a
  cap; the panel shows rate and age together.

> **0.4.4 built and verified in-game (2026-11-15):** `tc.history` keeps 720
> samples per stock in `/var/plant/history.tsv`, computes items/min and mB/min
> from boundary deltas, and raises `STALLED`/`TREND` through the existing alarm
> engine. The snapshot and the Plant app carry rate and trend. `npm run
> test:history` covers the bounded ring, the 60 items/min rate, a -90% trend,
> reboot persistence and compaction; `test:plant` covers the `flow` threshold
> and the plant-level `STALLED`. In-game: the ring survived a reboot (18 → 34
> samples), `STALLED` fired for a `flow` stock and cleared, and the Plant window
> drew with zero failures. `TREND` remains harness-only: the rig is idle.

### 0.4.5 Book — recipes and planning, local when it fits

The operated book stays small and local (`recipes.tsv`, `recipe-io.tsv`,
`lines/*.line`) — the twenty recipes the plant actually runs, not the encyclopedia.
A **line program** is one data file per line (`/etc/lines/<line>.line`) with
`stock in`/`stock out` and `rule` blocks: `mat in = mat out`, several items and
fluids per rule, no code ([`recipes.md`](recipes.md#the-line-program)).
`plan()` computes steps, seconds, bottleneck and shortfall in the OS for that
book. The SuSy reference dataset remains **outside** (tens of MB and not ours to
vendor) and is optional; when the book or the optimizer outgrows the node, the
service takes it over without changing the lines or the keys. `declared`,
`imported`, `measured` and `verified` keep their meanings.

- **Exit:** a three-step chain plans in under a second on the in-game computer,
  names its bottleneck, and its shortfall matches a hand count; a declared
  quantity contradicted by a run turns `suspect` and raises an alarm; the
  absence of the reference dataset changes no local plan.

> **0.4.5a built (2026-11-15):** `tc.line` (`src/lib/tc/line.lua`) parses the
> line program format and `npm run test:line` covers the casing fixture and
> malformed input. The planner, lines and calibration remain.

> **0.4.5b/c built and verified in-game (2026-11-15):** `tc.book` loads the
> operated book and the line rules; `tc.plan` walks the chain, names the
> bottleneck, lists the shortfall against the cached stock and applies
> `declared`/`verified`/`suspect` calibration. `plant.book` and `plant.plan`
> expose both over the link. `npm run test:book` covers a three-step chain, the
> hand-counted shortfall, a 25% contradiction and cycle/rng warnings. In-game:
> the book loaded 5 recipes with 0 errors; 100 EV casings planned 98 crafts and
> a 592-ingot shortfall; a 3-step synthetic chain ran 1000 plans in under 0.05 s;
> and a 1.25 calibration turned `suspect` with 980 ingots before restoring
> `verified`.

### 0.4.6 Gates — desired state and interlocks

`gate.set` stores the desired state in `/var/gates.tsv`, reconciles it every tick
and reports the actual state with the last refusal reason. Interlocks are local
and run on the cache: no feeding a full output, no opening a line whose input
stock is empty, no state change the node cannot verify. Desired state, never
toggles; a reboot restores the setpoints without asking anyone. A repeated
refusal raises `DISOBEDIENT LINE` and stops resending. `gate.set` requires
`linkControl = write`; with `off` the node reports and refuses to move anything.

### 0.4.6b Movement — `move` by name

The only physical operation the node performs, because nobody else can: items
leave one inventory and arrive in another ([`names.md`](names.md#moving-by-name)).

- `move from=<name> to=<name> n=<amount> key=<selector>` resolves both names
  (and the transport's name), reads the source slots, filters by selector and
  transfers **slot by slot** through the named transport, capped per command.
  The transport must accept the insert **and have a destination**: the same
  crate→pipe call answered `true, 0` while the pipe was disconnected and
  `true, 8` once it fed the bender (in-game 2026-11-15). A connected GT pipe is
  a valid sink; a disconnected one is not.
- The answer is what actually moved, per source member; `moved=0 reason=…` when
  nothing did. A cheerful `ok` for a move that did not happen is the worst
  possible reply.
- Cost is per slot examined, not per item moved, so the selector and the stock
  layout matter: drawers group like items for free, a chest does not.

> **0.4.6 modules built, in-game pending (2026-11-15):** `tc.gate` stores
> desired setpoints in `/var/gates.tsv`, applies the empty-input and full-output
> interlocks and raises `DISOBEDIENT LINE` after three refusals; `gate.set` is
> `write` tier and answers the actual state or the refusal. `tc.move` reads the
> source slots and transfers by name through a transposer, reporting what
> actually moved. The rig has no gate/redstone and no transport that accepts an
> insert: the 0.4.8 build loads `Gates: 0 lines` and `gate.set` answers
> `unknown_line`, so `npm run test:field` is the evidence and the hardware run is
> pending.

### 0.4.7 Agent tools — read-only MCP, optional service

The decision layer is a local model that gets the plant as MCP tools. With the
self-contained readout the tools can be served by the **bridge** from the local
mirror (no service required) or by the optional service when it is running:
`plant_situation`, `stock_query`, `alarm_list`, `history`, `plan`, `line_list`,
`path_list`, `path_query`, `recipe_query`, `audit_tail`. The situation report
is **pre-aggregated and bounded**: halls, top alarms, stocks out of limits,
rates, stale sources. The deterministic planner is a **tool**, never arithmetic
the model does in its head; every number the agent states must be traceable to a
tool result. Read-only on purpose: it validates whether the model understands
the plant before it can move a gate, and it cannot break anything while it
learns.

Not in this phase: write tools, autonomous policy, approvals, restock orders,
the hologram wall, sessions.

**Exit criteria:**

- **Node:** one **line** with an input stock, an output stock and an energy
  source reports **exact** counts to the app; the casing rig falls by 8 ingots
  and rises by 1 casing, and the machine buffers in between are **not read**;
  pulling the input stock below its minimum raises `STARVED` within one polling
  cycle and clears on refill; an idle line makes **zero** component calls per
  tick; a removed boundary container goes `unbound`/`coarse`, never zero; a
  node's energy falling raises `NO POWER` before it halts; with the bridge
  stopped the app keeps serving its cache; a reboot restores the desired states.
- **Mirror:** an external client reads the same snapshot, tanks and alarms the
  app shows; a body larger than one frame is paged and never silently truncated;
  killing the bridge leaves the app untouched.
- **Halls:** two halls report into one page; a hall that is offline is `stale`,
  not dropped; adding a hall is one computer and one config row.
- **Service (optional):** when it runs, a three-step chain plans in under a
  second and names its bottleneck; its shortfall matches a hand count; a refused
  gate shows up as an alarm instead of a silent retry; a hall with a config
  drift is marked `stale` rather than planned on old numbers.
- **Agent:** with read tools only, the local model answers three posed questions
  — "what limits the gear chain", "which hall runs dry first", "what changed in
  the last hour" — citing the tool call behind every number, and inventing none.
- **Paths:** `move from=hall1/ore_processing/entrada
  to=hall1/ore_processing/grinders n=64 policy=fill` runs without a single UUID
  in the command; a path resolving to two members sums its reads and dispatches
  by the policy it was given; a second member under a `single` path raises
  `cardinality_mismatch`; a mutating command on a multi-member path with no
  policy is refused; breaking and re-placing one drawer leaves that member
  `unbound` while the path keeps resolving; renaming a path does not rewire a
  saved line.
- **Degradation:** with the Adapter absent or `linkControl = off`, the app shows
  `coarse`, `no telemetry` or `refused` — never an invented number.
- **Scale:** a second hall is one reader computer plus config on both sides,
  with no new app or module and no gateway.

> **0.4.7 built and verified in-game (2026-11-15):** `tools/bridge/mcp.js`
> serves nine read-only tools over stdio. Each reads the cached mirror or queues
> one `plant.*` verb, cites the verb in the answer, and fails loudly when a
> reading is missing. `tools/bridge/plant.js` is the shared body parser;
> `plant.history` and `plant.paths` complete the data. `npm run test:mcp` drives
> the real bridge and a fake node through all nine tools, including the three
> questions. In-game: the server answered the situation, the stock entries and
> the 100-casing plan from the real rig (1128 exact, 592 missing, bottleneck
> 0.0204 targets/s), each with its source line.

## F3.5 — Line nodes (0.4.9) · built 2026-11-16, tagged 2026-11-27

> Built and cut as 0.4.9 "Flint"; tagged and published as `v0.4.9` on
> 2026-11-27; `v0.4.10` is now the newest release ([`versioning.md`](versioning.md)
> records both and the remaining in-game caveat). `tc.naming`, `tc.installer` with
> `boot/install.lua`, the `role = "line"` runtime, `tc.report`, `tc.master`, the
> Nodes app as the DNS, the Lines app with configuration push and `tc.flash` to
> write the installer medium from the master (**Nodes**, key **I**). The rack layer
> (cluster, node, netboot, netfetch, provision, vault, pull, jobs, the Vault app
> and the console's vault commands) is gone; the manifest went from 62 to 55
> files. `npm run size` holds the installer image at 237.3 KB of the 512 KB floppy
> and `test:naming`, `test:installer`, `test:report`, `test:master` and
> `test:apps` cover the new code. Pending in-game: a never-booted computer
> booting the floppy, and `setBootAddress` on a plain computer.

**Goal:** replace the cluster with the smallest OS that keeps one line observable
and publishes it. A line node boots from a floppy, reads its two boundary stocks,
raises its own level alarms and sends its status to the master, which owns the
merged view and the names. Racks go with it: no provisioning, no Relay, no waves,
no Vault, no netboot and no desktop on the node
([`line-node.md`](line-node.md)).

Slices: the installer image and the `role = "line"` boot; `tc.naming` with the
name as the root of the paths and guessed from the output label; `tc.master`, the
registry columns and `ASSIGN` on rename; the Nodes app as the DNS view; the Lines
app with config push to the node; `npm run size` as the budget gate.

**Exit criteria:** the installer image fits the 512 KB floppy, installs onto the
computer's HDD and never writes to the floppy, so one floppy commissions every
node; two simulated nodes publish under their own names and the master merges
them by path; a rename from the app changes every path and lists the references
that break; Lines edits a line's stocks and alarms, the master pushes them, and
the node keeps them locally so it still alarms with the master gone; the rack
modules and their tests are gone and `npm run check`, `npm run sim` and
`npm run sim:oc` stay green.

## F3.5b — DNS Settings and the slave role (0.4.10) · built 2026-11-27, published 2026-11-27

> Built, cut and published as 0.4.10 "Compass". Settings → DNS is the operator path for the
> three modes: Off, Master and Client, with the master address, port and
> transport, a live status line, validation and rollback. Apply restarts only
> the DNS runtime, not the desktop; leaving Master asks for confirmation. The
> headless publisher is now the `slave` role, with `line` kept as the 0.4.9
> compatibility alias. See [`dns-settings-ui.md`](dns-settings-ui.md).
> Harness: `test:apps`, `test:dns` (222 checks), `test:installer`, `test:flash`,
> `test:master`, the 55-screen matrix and the docs gate.

**Exit criteria:** the three modes start and stop from Settings without a
reboot; a malformed address, port or transport is refused before the file is
written; a failed start restores the previous mode; the master cache survives a
trip through Off; a 0.4.9 volume with `role = "line"` still boots; new installs
write `role = "slave"`. The in-game settings walk-through remains manual.

## F3.6 — Sidecar (0.4.11) · decided 2026-11-16, not built

**Goal:** take the Internet Card out of the plant's critical path, read a container
without giving it a Transposer, and move stock between named endpoints that a pipe
cannot reach. A small Forge mod supplies three components: `tc_bridge`, a card that
moves frames to `bridge.js` from its own thread; `tc_scanner`, a block that returns
a whole container in one host call; and the bus, a port per container plus a core
that moves items and fluids between any two ports by name. The protocol, the closed
command table, the control tiers and the body format do not change; the transport
and the price of a sweep and a move do ([`sidecar.md`](sidecar.md),
[`bus.md`](bus.md)).

Slices: `linkTransport` with two backends behind one `tc.link` interface and a
fake card in the harness (0.4.11a); `snapshot()` behind `tc.stock` with the
20-container budget test (0.4.11b); the bus — ports and core, `move` behind the
existing `transfer` capability, then fluids, power and rate (0.4.12) — whose
policy wiring lands in F7 ([`bus.md`](bus.md)).

**Exit criteria:** `npm run test:link` passes every scenario on both transports;
switching `linkTransport` back to `http` needs no code change; a 27-slot crate
sweep costs one call instead of 27; a missing card reports `no_transport` and
leaves the readout untouched; a full queue is counted by `stats().dropped`, never
silent; a 40-stack bus move costs one call instead of 40 and refuses with
`no_power` or `throttled` when the meters say so; the sidecar is a separate,
MIT-licensed jar that this repository does not vendor, and the release notes say
the pack is no longer stock.

## F4 — Sessions and displays (0.5) · moved after the readout

> **Memory note (2026-11-15).** The 64 MB change removes the original
> 64 KB/session pressure that motivated packing the framebuffer. Sessions are
> still needed for terminals, kiosks and moving the UI off a plant computer, but
> they no longer gate the readout. The packed framebuffer remains the target for
> remote sessions; the local desktop keeps the current renderer until the remote
> path needs it.

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
total, boot within 1.5 seconds, and a multi-session harness test. (The original
"64 KB per session" cap came from the 1–2 MB machines and was retired when the
client `ramSizes` were scaled ×32 and 64 MB was verified in-game on 2026-11-15;
it is no longer a target.)

## F5 — Application server and terminals (0.6) · blocked, no host decided

> **Blocked.** The premise — a fleet of nodes whose free RAM decides where a
> session runs — went with the racks (decision 25). A line node has no desktop and
> no apps, so there is nothing to place. Re-scope this phase before starting it:
> either the master alone hosts sessions, or a new decision brings back a machine
> that can.

**Blocked on a host decision.** Until that decision names the machine a session
runs on, this phase has no Goal and no exit criteria. The placement requirement
the old phase carried is withdrawn with the racks (decision 25) and is not a
requirement of any later phase; hosting sessions on the master alone is one
option under consideration, not a decision already taken.

The terminal work below survives a re-scope. It is design only: nothing here is
scheduled and nothing is built.

- Reuse `tc.net`; add `SESSION`, `FRAME`, `INPUT`, and `RESUME` messages.
- Resume a terminal's session after disconnect.
- If a later decision adds more than one host, discover cores and use a shared
  per-segment key.
- Add a minimal terminal client and kiosk profile.
- Limit remote-session refresh to 10 Hz and group spans; local screens have no
  fixed Hz setting in OpenComputers.
- The verb-level terminal contract is specified in `docs/terminal-protocol.md`
  (FRAME/INPUT/RESUME, input ACK piggyback, bandwidth ceilings).

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

> **Re-scoped.** The cluster it described is gone (decision 25): no rack
> inventory, no `worker`/`storage` roles, no Vault pool, no UPS fleet. What
> survives is the *policy*, and it needs hardware that can carry it before any of
> it is built. Read [`power.md`](power.md), which says the same at its top.

**Goal:** operate the plant as a set of machines with a power policy. Alarms and
energy history already exist from F3; this phase adds the policy that acts on
them.

- Inventory the computers the plant actually has — the master and its line nodes
  — with their power, energy and network links.
- Raise the policy's alerts on the master: a line node that stops reporting, a
  disk that stops answering, or a node whose energy runs low.
- Where the plant has a UPS the bridge can read, add reserve budgets and staged
  shedding ([`power.md`](power.md)); without that hardware the phase stops at
  alerts.
- Shut down in order: line nodes, then the master.
- Document the permanent chunk-loader requirement.
- Attribute operator names in the UI/log without user accounts.
- Display a plant map and node/disk alerts for the master and its line nodes.

**Exit criteria:** the master and every line node appear in the inventory after a
world reload, a line node that stops reporting raises an alert instead of
vanishing, terminal file reads/writes still work, and one line node fails
without data corruption or taking down the rest of the plant.

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
| 1 | In-game 0.3.x verification + probe — **done 2026-11-15**; a multiblock tank and one working machine remain | F2/F3 | L |
| 2 | Local plant core: `tc.addr`, `tc.path`, drivers, stock/tank/energy readers, cache, level alarms, Plant app, `node.status` | 0.4.1 | L |
| 3 | Mirror: `plant.status/snapshot/delta/alarms` over the link, paged and never truncated | 0.4.2 | M |
| 4 | ~~Second hall: one computer per hall, `halls.tsv`, merged view, no gateway~~ — dropped with the racks (decision 25); the node registry is the DNS | — | — |
| 5 | Local history ring, rates, `STALLED`/`TREND` | 0.4.4 | M |
| 6 | Local book and `plan()`; the reference dataset stays optional and outside | 0.4.5 | L |
| 7 | `gate.set`, desired state, local interlocks, refusals | 0.4.6 | M |
| 8 | `move` by name: selector, transport, bounded accounting | 0.4.6b | M |
| 9 | Read-only MCP surface over the mirror (bridge or service) | 0.4.7 | M |
| 10 | Sessions, display backends, packed framebuffer | 0.5 | L |
| 11 | App placement, remote session protocol, terminal client | 0.6 | L |
| 12 | Data-center power, UPS, health, rebalancing | 0.7 | M |
| 13 | Agent write tools, approvals, cross-hall orders | 0.8 | L |
| 14 | Hologram wall | 0.8 | M |
| 15 | Redstone Control measurement spike and transport | F5.5 | M |
| 16 | Resumable tablet client | F5.5 | M |
| 17 | Line node payload: `role = "line"`, readout, level alarms and a status publisher, no desktop | 0.4.9 · done | L |
| 18 | Naming: `tc.naming`, the name in `/etc/terracorp.cfg`, `ASSIGN` from the master, `conflict` state | 0.4.9 · done | M |
| 19 | `tc.master`, registry columns and the Nodes app as the DNS view | 0.4.9 · done | M |
| 20 | `npm run size`: the node payload budget as a failing gate | 0.4.9 · done | S |
| 21 | [DNS settings UI](dns-settings-ui.md): Off/Master/Client, address, port and transport in Settings, applied without a reboot | 0.4.10 · done | M |
| 22 | Slave role name: installer, kernel and node tags write `slave`; `line` stays a 0.4.9 alias | 0.4.10 · done | S |

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
    **Moot 2026-11-16 (decision 25):** the Vault was removed with the racks. The
    rule survives: the OS never stores goods; the world's containers do.
13. **Recipes are calibrated before they are trusted.** A recipe arrives either
    **declared** by the operator or **imported** from a published pack export
    (amended 2026-11-13, see decision 19), always keyed by the identifiers the
    sensor actually reports. Neither provenance is trusted on arrival: a real run
    calibrates the numbers, measurement wins over belief, and a contradiction
    raises an alarm instead of being smoothed over. **Re-pointed 2026-11-16
    (decision 25):** the book is local, on the node that uses it; the reference
    dataset outside stays optional. See [`recipes.md`](recipes.md).
14. **The brain lives outside the world (2026-11-13).** The recipe book,
    planner, history, plant alarms and panel run in the **plant service**; the
    nodes keep sensors, gates, interlocks and the last desired state. Two facts
    force it: a polled link with a 5-10 s interval cannot close a 1 Hz loop, and
    1 MB cannot hold the book. Consequences: `gate.set` carries **desired
    state**, never a toggle, so a retry cannot invert a gate; the OS refuses
    locally whatever its interlocks reject and reports why; a dead service means
    "hold the last setpoints", not "stop the plant". See
    [`plant-service.md`](plant-service.md).
    **Amended 2026-11-15 (decision 23):** with 64 MB the readout, cache, local
    level alarms and the Plant app live in the OS; the service owns long
    history, the reference dataset, planning at scale and the agent. The
    `gate.set`/desired-state rule is unchanged.
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
    **Amended 2026-11-15:** the node evaluates **local level thresholds**
    against its own cache and raises its own level alarms; cross-hall policy,
    rates, recipes and alarm interpretation stay outside. The no-extra-call
    rule is what keeps this honest.
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
    **Amended 2026-11-15:** paths are local to each computer first; the gateway
    merge was planned for the second hall (0.4.3), not for the first readout.
    **Removed 2026-11-16 (decisions 25 and 26):** there is no second hall and no
    gateway; a node's name is the root of its paths and the master's registry is
    the DNS.
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
    without a sneak-use each. Racks, Vault, waves and Relay were kept off the
    plant path then to answer density and pooled disks, not component access;
    **decision 25 later removed them from the product.** Consequence: no in-world
    redundancy for the translator
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
    **Amended 2026-11-15:** the first version has no gateway; each computer is
    its own authority. **Removed 2026-11-16 (decisions 25 and 26):** the second
    hall and the gateway are gone; the master's registry is the DNS and there is
    no merge tier. The two-namespaces rule itself stands.
22. **Component kinds are plugins, and a plugin is data (2026-11-13).** An Adapter
    can expose signs, chests, tanks and machines as readily as drawers, so no block
    name is hardcoded. A kind is described by a declarative descriptor over a
    **closed capability vocabulary**; the kernel interprets it and the descriptor
    never runs. That is a security boundary, not neatness: `/etc` is writable
    through the link, so executable config would be remote code execution with a
    different name. New kind = unknown component + `driver.dump` + a file + a
    reload. New *capability* is a kernel decision. See [`drivers.md`](drivers.md).
23. **Self-contained readout first (2026-11-15).** The computer that sees the
    plant has up to 64 MB (verified in-game: `memory=863KB/65536KB`), so the
    readout, cache, level alarms and Plant app run in the OS; a service is
    optional and owns long history, the reference dataset, planning at scale and
    the MCP agent. The gateway/DNS/leaf split went with the second hall:
    decisions 25 and 26 removed both, and the node registry is the DNS. This
    does not repeal the tick budget: reads are trickled, cached and
    never polled in the draw path, and no alarm spends an extra component call.
    It amends 14, 16, 17 and 21 as noted there.
24. **Lines are black boxes with an input and an output (2026-11-15).** A
    production line exposes exactly two boundary stocks — what goes in and what
    comes out — and Transposers sit only at those boundaries. The OS reads and
    moves the boundary stocks; it never reads the machine buffers inside the
    line. The line's recipe and rate are measured from input/output deltas, not
    from `getProgress` or `getEUt`. This keeps the reader small, removes the
    Adapter requirement for rates, and makes a line observable even when its
    internal machines are invisible to OpenComputers.
25. **Racks are dropped; a line node replaces them (2026-11-16).** The cluster
    layer — rack discovery, netboot provisioning, Relay, waves, Vault and the
    worker and storage roles — is removed from the product. What replaces it is
    the opposite of density: one ordinary computer per line, booting from a
    512 KB floppy that is the whole install, reading its two boundary stocks,
    raising its own level alarms and publishing its status to a master. Decisions
    20 and 23 already said why: a rack server's internals are
    `Visibility.Neighbors`, so a rack never widens what a node can read, and
    servers do not boot after a world reload. A line node is commissioned by
    putting a floppy in a computer. This supersedes decisions 1, 3–7, 14 (the
    service tiers) and phase F2 — not 20, which asked for exactly this; 12 goes
    moot and 13 keeps its rule with the book moved local. It keeps `tc.net`, the
    node registry, the Nodes app and the desired-state rule for gates, because a
    line node still reports to a master. See [`line-node.md`](line-node.md).
26. **The node registry is the DNS (2026-11-16).** A line node is named, and its
    name is the root of its paths: `casing/ingots`. The master's registry in
    `/var/nodes.tsv` is the table of names that feed it, and the Nodes app is the
    view and the editor of that table. The node proposes the name it carries in
    `/etc/terracorp.cfg`; the master answers with the name it holds. So the master
    assigns and the node adopts: a rename is one frame, not a trip to the floppy.
    A node with no master keeps its local name and can be commissioned alone, and
    a duplicate name is a `conflict`, never a silent merge of two nodes' stocks.
    Renaming a node that already published lists the thresholds, recipes and line
    rules that still mention the old prefix. This amends 17 and 21: there is no
    gateway and no separate `halls.tsv` — the live registry is the DNS. See
    [`names.md`](names.md).

    **26-A (2026-11-23) — the hall module is kept, the file is not.** 26 removed a
    file and a gateway, not the merge function. A node's hall is its own name,
    merged in memory: `plant.lua:316-321` builds a one-row registry from the
    configured name, `/etc/halls.tsv` is never read, and `halls.load`,
    `halls.save` and `halls.PATH` were deleted in `6236f99`. The payload still
    ships `halls.lua` because the plant requires it (`payload.lua:27`), and
    `plant.halls` stays a read verb (`link.lua:48`). A second hall would be a new
    decision, not a new table format.
27. **The sidecar replaces the card, not the protocol (2026-11-16).** The plant's
    route to the bridge moves to a mod component that runs its HTTP exchange on its
    own thread. Three measured facts force it: the Internet Card refuses loopback
    until a server file is edited, an exchange blocks the desktop loop while its
    handle is read, and a host call costs 50 ms of tick while `transferItem` moves
    one stack per call, which is what prices a base-wide move loop out of
    existence. `push`/`pull` carry the same 1024-byte bodies, so
    `bridge.js`, the closed command table, the control tiers and the desired-state
    rule do not change, and `linkTransport = "http"` stays as the fallback for a
    stock pack. The same mod adds a scanner block whose single `snapshot()` replaces
    27 reads — that, and not the card, is what makes an index over the base's
    containers affordable. It is a mod, so the pack is no longer stock: an operator
    decision recorded in the release notes, with the mod kept in its own repository
    and never vendored here. See [`sidecar.md`](sidecar.md).
28. **A bus may move stock between named endpoints (2026-11-16), not built.** This
    amends 10: TerraCorp still does not run the plant's logistics, but it may
    execute one metered, reported move between two bindings, which is what a
    decentralised warehouse needs. `move` keeps its contract; only the transport
    behind it changes — a port anywhere on the network instead of an adjacent
    Transposer face, one call per move instead of one per stack, energy and a rate
    cap per core, no force-loading, and no cross-dimension unless a quantum link
    pair is enabled. Where a pipe reaches, the pipe wins. See [`bus.md`](bus.md).
