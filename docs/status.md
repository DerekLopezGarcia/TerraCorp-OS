# Status — where the plan stands

Last updated: 2026-11-15. This is the "pick it up cold" page: what we decided,
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

## The stack

```text
agente local (MCP)   ──  decide objetivos, prioridades, qué encender   [opcional]
plant service        ──  historia larga, dataset, planner, MCP          [opcional]
bridge (HTTP)        ──  un POST por intervalo, verbos en lista cerrada
OS de planta (OC)    ──  lee, cachea, alarma, muestra; gates y setpoints
```

The first three rows are optional. The fourth row is the product: it must show
exact stocks and raise its own alarms with nothing else running.

## Decisions, 1-24

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

## What exists today

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
- **Harness green**: `npm run check` (59 files, 50-file manifest), `test:plant`,
  `test:line`, `sim`, `sim:oc` and the 50-combination screen matrix.
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
| Addresses, faces, first seen, local paths, drivers | [`names.md`](names.md), [`drivers.md`](drivers.md) | 0.4.1 |
| Line-boundary stock/tank/energy readers, cache, coarse fallback | [`crafting.md`](crafting.md), [`telemetry.md`](telemetry.md) | 0.4.1 |
| Local level alarms and the Plant app | [`plant-service.md`](plant-service.md) | 0.4.1 |
| `plant.*` mirror over the link | [`external-link.md`](external-link.md) | 0.4.2 |
| Second hall, `halls.tsv`, merged view | [`plant-service.md`](plant-service.md) | 0.4.3 |
| Sample ring, rates, `STALLED`/`TREND` | [`plant-service.md`](plant-service.md) | 0.4.4 |
| Local book, `plan()`, bottleneck, shortfall | [`recipes.md`](recipes.md) | 0.4.5 (parser written) |
| Gates, desired state, `move` by name | [`crafting.md`](crafting.md), [`names.md`](names.md) | 0.4.6/0.4.6b |
| Read-only MCP tools | [`agent.md`](agent.md) | 0.4.7 |
| Reference dataset (SuSy Factory Flow) | [`research-susy-planner.md`](research-susy-planner.md) | optional |
| Multi-hall gateway/DNS (leaf, gateway, TC1 merge) | [`middleware.md`](middleware.md) | deferred |

Nothing in the 0.4.1 rows has a line of code yet. That is the honest state.

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
