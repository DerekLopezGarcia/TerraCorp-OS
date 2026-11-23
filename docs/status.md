# Status — where the plan stands

Last updated: 2026-11-16. This is the "pick it up cold" page: what we decided,
what exists, what is only on paper, and what blocks what. The authoritative
detail lives in the linked documents; this page is the index and the honest
ledger.

## The pivot, in one paragraph

The OS is a **self-contained plant readout first**: the computer that can see
the **line boundaries** reads them, caches the answers, evaluates its own level
alarms and shows them in the **Plant** app. A line is a black box with an input
stock and an output stock; the machines inside are not read (decision 24). A
**plant service** outside the game is
optional and owns only what the node cannot — long history, the reference
dataset, planning at scale and the MCP agent. With 64 MB in the computer (verified
in-game on 2026-11-15) the operated book and a short history fit; the first
number never waits for the bridge (decision 23, amending 14, 16, 17 and 21).

Since 2026-11-16 the cluster is gone (decision 25). Each line runs a **line
node**: a small OS on a floppy that reads its two boundary stocks, raises its own
level alarms and publishes its status to a master. The master's node registry is
the plant's DNS — names, not addresses, on the outside (decision 26). See
[`line-node.md`](line-node.md).

## The stack

```text
agente local (MCP)   ──  decide objetivos, prioridades, qué encender   [opcional]
plant service        ──  historia larga, dataset, planner, MCP          [opcional]
bridge (HTTP)        ──  un POST por intervalo, verbos en lista cerrada
OS de planta (OC)    ──  lee, cachea, alarma, muestra; gates y setpoints
```

The first three rows are optional. The fourth row is the product: it must show
exact stocks and raise its own alarms with nothing else running.

## Decisions, 1-27

1-7 are the original frame: system model (app server + terminals), no accounts,
native Remote Terminals, data-center autonomy, core apps, 0.3.x split, rack
discovery.

8. Plant readout ships **before** sessions.
9. External link deploys **on one machine** first; WAN is parked.
10. TerraCorp is the **control plane**, not the transport.
11. AE2 is a crafting terminal, **not the store**.
12. Vault holds **files**, not goods.
13. Recipes are **calibrated before trusted**; declared and imported are
    provenances, neither is verified.
14. The long-lived brain lives **outside** the world; amended: the readout,
    cache, level alarms and app live in the OS (23).
15. The decision-maker is a **local agent on MCP**, with deterministic tools and
    no free execution.
16. The node is a **translator**: no cross-hall recipe, rate, threshold or alarm
    text; amended: local level thresholds against its own cache are allowed.
17. Its first job is a **DNS**: semantic, hierarchical paths; no UUIDs outside;
    amended: paths are local first, merged with the second hall.
18. **Hardware facts live in the world**; intents travel in the command. One
    exception: a gate's desired state persists.
19. Recipes may be **imported**, never redistributed; the SuSy devs' dataset is
    the reference library and their schema is the one to adopt.
20. The plant runs on **plain computers, not rack servers**.
21. **Two namespaces**: addresses route, paths search; authority inside, merge
    outward; amended: no gateway until a second hall exists.
22. Component kinds are **plugins, and a plugin is data** — declarative
    descriptors over a closed capability vocabulary, never executable config.
23. **Self-contained readout first (2026-11-15).** The OS reads, caches, alarms
    and shows its own hall; the service is optional; the gateway/DNS split waits
    for a second hall.
24. **Lines are black boxes with an input and an output (2026-11-15).**
    Transposers sit only at the boundary stocks; the machines inside are not
    read; the line's rate comes from the input/output deltas.
25. **Racks dropped, line nodes instead (2026-11-16).** The cluster layer — rack
    discovery, netboot, Relay, waves, Vault, worker and storage roles — leaves the
    product. One ordinary computer per line, booting from a 512 KB floppy that is
    the whole install, reading, alarming and publishing to a master. Supersedes
    1, 3–7, 14 (service tiers), 20 and phase F2; keeps `tc.net`, the registry, the
    Nodes app and gate desired-state. See [`line-node.md`](line-node.md).
26. **The node registry is the DNS (2026-11-16).** A node's name is the root of
    its paths (`casing/ingots`); `/var/nodes.tsv` is the table of names feeding
    the master and the Nodes app is its view and editor. The master assigns, the
    node adopts; a node alone keeps its local name; a duplicate is a `conflict`,
    never a silent merge. Amends 17 and 21: no gateway, no `halls.tsv`.
    See [`names.md`](names.md).
27. **The sidecar replaces the card, not the protocol (2026-11-16), not built.**
    A Forge card moves the same 1024-byte frames off the desktop loop, which the
    Internet Card cannot: it refuses loopback until `settings.conf` is edited and
    blocks while its request handle is read. A scanner block reads a container for
    items, fluids and energy in one call without giving it a Transposer, because 50
    ms per host call also prices the hardware density of a base-wide readout out.
    `bridge.js`, the command table, the tiers and the desired-state rule are
    untouched, and `linkTransport = "http"` stays as the stock fallback.
    See [`sidecar.md`](sidecar.md).
28. **A bus may move stock between named endpoints (2026-11-16), not built.** This
    amends 10: TerraCorp still does not run the plant's logistics, but it may
    execute one metered, reported move between two bindings, which is what a
    decentralised warehouse needs. `move` keeps its contract; only the transport
    behind it changes — a port anywhere on the network instead of an adjacent
    Transposer face, one call per move instead of one per stack, energy and a rate
    cap per core, no force-loading, and no cross-dimension unless a quantum link
    pair is enabled. Where a pipe reaches, the pipe wins.
    See [`bus.md`](bus.md).

## What exists today

- **0.4.9 "Flint" is built**: the line node (installer, `role = "line"`, status
  publisher, status page), `tc.master` with the registry as the DNS, and the
  Nodes and Lines apps. The cluster layer and its apps are gone (decision 25);
  the manifest is 55 files and the installer image is 163.3 KB of the 512 KB
  floppy. Harness: `check`, `sim`, `sim:oc`, `test:naming`, `test:installer`,
  `test:report`, `test:master`, `test:apps`, `test:plant`, `test:link`,
  `test:bridge`, `test:history`, `test:book`, `test:mcp`, `test:field`,
  `test:line` and the screen matrix.
- **0.3.x is built and tagged** up to `v0.3.33`, and **0.4.1 is built and
  verified in-game** (2026-11-15): `tc.net`, netboot provisioning, node registry, Relay,
  waves, Vault, the desktop shell with **eleven apps**, the GAIA app and the
  external-link bridge (loopback verified in-game, including remote writes,
  `link.interval` and `lua`), the Lab with its Lua interpreter, and the Plant
  readout. Updates leave the notes of every skipped release in
  `/var/whatsnew.md`.
- **0.4.1 Plant readout**: `tc.addr`, `tc.path`, `tc.driver`, `tc.stock`,
  `tc.tank`, `tc.plant` and the Plant app; boundary stocks, exact/coarse states,
  level alarms and one component call per second. `npm run test:plant` covers
  the casing hall against fake components. In-game: 744 input items and 5
  casings read `exact`, the app drew with zero failures, `STARVED` fired and
  cleared, and an idle line made zero calls across three seconds.
- **0.4.2 Mirror**: `plant.status`, `plant.snapshot`, `plant.delta` and
  `plant.alarms` read the plant cache over the External Link, paged with the
  existing `LREP`/`LDATA`/`LEND` slicing. The bridge parses each completed body
  and keeps the last reply of each kind at `GET /link/mirror`. A delta cursor is
  the stock revision, so an idle scan does not force a resync. `npm run
  test:link` (32 scenarios) and `npm run test:bridge` cover it. In-game: the real
  1232-byte snapshot paged intact, the stale cursor resynced, the bridge mirror
  parsed both stocks, and 50 s with the bridge down left the scan, cache and
  Plant window untouched.
- **0.4.4 History**: `tc.history` keeps a bounded ring per stock in
  `/var/plant/history.tsv` (720 samples, two hours at a 10 s scan), computes
  items/min and mB/min from boundary deltas, and raises `STALLED` for a stock
  marked `flow` that does not move and `TREND` for a rate change over the
  configured percentage. The Plant app and `plant.snapshot` show rate and trend.
  `npm run test:history` covers the ring, rates, trend, reboot and bounds.
  In-game: the ring persisted 34 samples across a reboot, the snapshot reported
  `rate=0.000 rate_span=133` while idle, `STALLED` fired for a `flow` stock and
  cleared on restore; `TREND` is harness-only because the rig is idle.
- **0.4.5 Book/planner**: `tc.book` loads `/etc/recipes.tsv`,
  `/etc/recipe-io.tsv` and the `/etc/lines/*.line` rules; `tc.plan` walks the
  chain, names the bottleneck, lists the shortfall against the cached stock and
  calibrates recipes as `declared`, `verified` or `suspect`. `plant.book` and
  `plant.plan` expose it over the link, read-only. `npm run test:book` covers a
  three-step chain, a hand-counted shortfall, a 25% contradiction and cycles.
  In-game: the book loaded 5 recipes with 0 errors; 100 EV casings planned 98
  crafts with a 592-ingot shortfall, a 3-step synthetic chain ran 1000 plans in
  under 0.05 s, and a 1.25 calibration turned `suspect` with the measured ratio
  (980 ingots) before restoring `verified`.
- **0.4.7 Oracle (MCP)**: `tools/bridge/mcp.js` is a read-only MCP server over
  stdio. Nine tools — `plant_situation`, `stock_query`, `alarm_list`, `history`,
  `plan`, `path_list`, `path_query`, `recipe_query`, `audit_tail` — read the
  cached mirror or queue one `plant.*` verb, and every answer names the verb
  behind it. A missing reading is an error, never a zero. `npm run test:mcp`
  covers the full path with a fake node. In-game: the server answered the three
  questions from the real rig, naming `casing/ingots` (1128 exact), the stock
  entries and the 100-casing plan (bottleneck 0.0204 targets/s, 592 missing).
- **0.4.8 Keystone (harness-only slices)**: `tc.halls` names each computer in
  `/etc/halls.tsv` and merges snapshots with a hall prefix, marking a missing
  hall `offline` and an old one `stale`. `tc.gate` stores desired setpoints in
  `/var/gates.tsv`, applies local interlocks (empty input, full output) and
  raises `DISOBEDIENT LINE` after three refusals. `tc.move` transfers by name
  through a transposer and reports what actually moved. `plant.halls` and
  `gate.set` expose them over the link. The second hall, the gate and the
  transport are not built: `npm run test:field` covers the modules. In-game the
  modules load (`Gates: 0 lines, 0 errors`), `plant.halls` reports the local hall
  with 1128 and 5, and `gate.set` answers `unknown_line` without a configured
  gate; the real second-hall merge, gate reconciliation and move remain pending.
- **Harness green**: `npm run check` (72 files, 55-file manifest), `test:link`
  (48 scenarios), `test:bridge`, `test:history`, `test:book`, `test:mcp`,
  `test:field`, `test:plant`, `test:line`, `sim`, `sim:oc` and the
  50-combination screen matrix.
- **0.4.5a parser written**: `tc.line` parses `/etc/lines/*.line` (`stock in/out`,
  multiple rules, multi-item/fluid terms, `ticks`/`limit`) without executing it;
  `npm run test:line` covers the casing fixture and malformed input. The planner
  and calibration are not wired yet.
- **Probe answers are recorded**: items (`name` + `damage`, `tag` only when
  `hasTag`), fluids (Forge `name`, `label`, `amount`, `capacity`, `hasTag`;
  `getFluidInTank` returns an array), tanks through `tank_controller`, energy
  (`power_substation` formatted strings; the input hatch numbers), coarse
  redstone 0–15 linear, Redstone Control `rsio` ports 0–7 with `rs_change`
  events, and **50 ms per host call**. See [`tests.md`](tests.md#results-log)
  and [`telemetry.md`](telemetry.md#in-game-verification-checklist).
- **First line verified in-game** on 2026-11-15: 8 titanium ingots → 1 EV
  machine casing, with the Transposers only at the input (`502a3776…`) and
  output (`05be29b9…`) crates; the bender and assembler buffers are opaque. A
  batch of 8 moved in one `transferItem` and produced one casing; the same line
  made LV/MV/HV from steel/aluminium/stainless, and the output crate held 2 EV,
  1 HV, 1 LV and 1 MV. ULV needs wrought iron, which was not in the crate.
- **64 MB verified in-game** on 2026-11-15: the client `ramSizes` were scaled
  ×32 (top module 32 MB, cap 64 MB) and `status` answered
  `memory=863KB/65536KB`, 18 components, version 0.4.0. The `supersymmetry-local`
  server config was **not** changed.
- **Partial 0.3.x in-game verification**: provisioning, Relay, Drain and the
  0.3.33 update pass; the second node, update waves, Vault and the RAID probe
  remain.

## What is designed but not written

| Area | Document | Slice |
|---|---|---|
| Reference dataset (SuSy Factory Flow) | [`research-susy-planner.md`](research-susy-planner.md) | optional |
| Sidecar transport (bridge card) and bulk reads (scanner) | [`sidecar.md`](sidecar.md) | 0.4.10 |
| Bus: ports, core and metered moves between named endpoints | [`bus.md`](bus.md) | 0.4.11 |
| Multi-hall gateway/DNS (leaf, gateway, TC1 merge) | [`middleware.md`](middleware.md) | deferred |

Nothing here has a line of code yet, and none of it is required for F3: the
reference dataset is optional and the gateway is deferred. The 0.4.3 and 0.4.6
modules exist but their in-game halves need hardware the rig does not have.

## What is missing, in dependency order

**1. The remaining probe.** A multiblock tank (how many tanks behind one face),
which affects 0.4.1 tank groups. The working-machine probe is **not needed for
F3**: a line is a black box and its rate comes from the boundary deltas
(decision 24); `getProgress` is diagnostics, not readout.

**2. The reference dataset check** (no game needed): pin a commit of
`susy-factory-flow`, read `src/lib/model/types.ts`, inspect RecipeViewer's
`recipedump.json.gz`, confirm which SuSy version it carries. Until then
`imported` recipes stay optional and outside.

**3. The rest of the 0.3.x in-game checklist** ([`tests.md`](tests.md)): second
node, waves, Vault, RAID. It can ride a later session; it no longer blocks the
plant readout.

**4. Implementation order:** `tc.addr` → `tc.path` → driver registry →
stock/tank/energy readers with cache → local level alarms → Plant app → link
mirror → second hall → ring/rates → local book/plan → gates/move → MCP read
tools.

## Known risks we accepted

- The plant core competes with the desktop for the same 64 MB and the same
  event loop. Reads are trickled and cached; the app draws from the cache.
- The OS ring is bounded: long history is a service feature, not a promise.
- A line's internal machines are opaque: a jam shows as a boundary delta
  stall, not as a named machine fault. Diagnostics need an Adapter, but the
  readout does not.
- The local book is small on purpose; the full dataset and the optimizer stay
  outside and are optional.
- A dead service means no long history or cross-hall plan: the OS keeps reading,
  alarming and holding gates.
- No in-world redundancy for the readout; a dead computer is silence.
- The gateway is a single ingress per segment when it arrives; two gateways will
  be allowed later.

## Resuming cold

Read in this order: this page → [`roadmap.md`](roadmap.md) →
[`plant-service.md`](plant-service.md) → [`names.md`](names.md) →
[`crafting.md`](crafting.md) → [`recipes.md`](recipes.md) → [`agent.md`](agent.md).
[`middleware.md`](middleware.md) is the deferred multi-hall design; read it
before 0.4.3, not before 0.4.1. Everything else is supporting material.
