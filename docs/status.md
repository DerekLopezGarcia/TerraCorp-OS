# Status — where the plan stands

Last updated: 2026-11-13. This is the "pick it up cold" page: what we decided,
what exists, what is only on paper, and what blocks what. The authoritative
detail lives in the linked documents; this page is the index and the honest
ledger.

## The pivot, in one paragraph

The OS used to aim at being an in-game desktop with a cluster behind it. It is now
the **in-world half of a two-layer plant**: TerraCorp Middleware runs on plain
computers, exposes components by semantic path, and executes calls; the recipe
book, planner, history, alarms and panel live in a **plant service** outside the
game; a **local agent** drives that service over MCP with deterministic tools.
The in-world half translates. It does not think (decisions 14, 16, 20, 21).

## The stack

```text
agente local (MCP)   ──  decide objetivos, prioridades, qué encender
plant service        ──  recetas, historial, tasas, alarmas, panel, registro combinado
bridge (HTTP)        ──  un POST por intervalo, verbos en lista cerrada
gateway (OC)         ──  internet + cable + wireless; proxy tonto; copia del segmento
leaves (OC)          ──  solo componentes; autoridad de sus direcciones y rutas
```

## Decisions, 1-22

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
14. The brain lives **outside** the world.
15. The decision-maker is a **local agent on MCP**, with deterministic tools and
    no free execution.
16. The in-world half is a **translator**: no recipe, no rate, no threshold, no
    alarm text.
17. Its first job is a **DNS**: semantic, hierarchical paths; no UUIDs outside.
18. **Hardware facts live in the world** (binding, kind, cardinality); intents
    travel in the command (policy, amount, selector). One exception: a gate's
    desired state persists so the plant holds position without a brain.
19. Recipes may be **imported**, never redistributed; the SuSy devs' dataset is
    the reference library and their schema is the one to adopt.
20. The plant runs on **plain computers, not rack servers** (they do not boot
    after a world reload and their internals are invisible).
21. **Two namespaces**: addresses route, paths search; authority inside, merge
    outward (proxy → gateway → service), never pushed back down.
22. Component kinds are **plugins, and a plugin is data** — declarative
    descriptors over a closed capability vocabulary, never executable config.

## What exists today

- **0.3.x is built and tagged** up to `v0.3.21`: `tc.net`, netboot provisioning,
  node registry, Relay, waves, Vault, the desktop shell with ten apps, the GAIA
  app and the external-link bridge, and the Lab Lua scratchpad.
- **Harness green**: `npm run check` (48 files, manifest synced) plus the suites
  the repo carries.
- **In-game verification of 0.3.x is still pending** — rack, Relay, waves, Vault
  and the external link were never exercised in a live world.

## What is designed but not written

| Area | Document | Slice |
|---|---|---|
| Addresses, faces, first seen, registration | [`names.md`](names.md) | 0.4.1 |
| Semantic paths, wildcards, reduction by policy | [`names.md`](names.md) | 0.4.1 |
| Leaves, gateways, two transports, bandwidth budget | [`middleware.md`](middleware.md) | 0.4.1 |
| Declarative drivers and capability vocabulary | [`drivers.md`](drivers.md) | 0.4.1 |
| Combined registry, ingest, alarm engine, panel | [`plant-service.md`](plant-service.md) | 0.4.1+ |
| Stock readers, snapshots and deltas | [`plant-service.md`](plant-service.md) | 0.4.2 |
| Tanks | [`plant-service.md`](plant-service.md) | 0.4.3 |
| Rates and plant alarms | [`plant-service.md`](plant-service.md) | 0.4.4 |
| Recipe book, chains, bottleneck, shortfall | [`recipes.md`](recipes.md) | 0.4.5 |
| Gate setpoints and `move` by path | [`names.md`](names.md), [`crafting.md`](crafting.md) | 0.4.6, 0.4.6b |
| Read-only MCP tools for the agent | [`agent.md`](agent.md) | 0.4.7 |
| Reference dataset (SuSy Factory Flow) | [`research-susy-planner.md`](research-susy-planner.md) | optional seed |

Nothing in that table has a line of code yet. That is the honest state.

## What is missing, in dependency order

**1. The in-game probe (blocks almost everything below).** One session in a live
world:

| Question | Unblocks |
|---|---|
| Per-side inventory API: do methods take a side, what for an invalid one | faces in the address, stock reads |
| Transposer argument form: `address:side`, `:slot`, amount limit, return value | `move` semantics |
| Slot read shape: one call per slot or a range | the per-tick budget, `move` cost |
| Item key fields: name, damage, label, NBT | stock keys, recipe keys |
| Fluid read: level/capacity, identifier form | fluid stocks |
| `driver.dump` for drawer, crate, chest, tank, **sign**, transposer | the first six driver descriptors |
| Loopback HTTP from the world host to the service | the whole external split |

**2. The reference dataset check** (no game needed): pin a commit of
`susy-factory-flow`, read `src/lib/model/types.ts`, inspect RecipeViewer's
`recipedump.json.gz`, confirm which SuSy version it carries. Until then
`imported` recipes stay a plan.

**3. The 0.3.x in-game checklist** ([`tests.md`](tests.md)) — still owed from the
previous phase, and it can ride the same session as the probe.

**4. Implementation order once (1) lands:** `tc.addr` → `tc.path` → driver
registry → proxy/gateway wiring → stock reads → gates → `move` → service →
MCP read tools → agent hands (F7).

## Known risks we accepted

- A dead service means no automation: the plant holds setpoints. Tolerable while
  service and world share a machine; they fail together.
- A dead proxy is silence, and the service must interpret it.
- No in-world redundancy for the translator layer; plain computers do not fail
  over.
- The gateway is a single ingress and a single failure domain per segment; two
  gateways are allowed.
- Pack data is never redistributed; the dataset stays local and pinned.

## Resuming cold

Read in this order: this page → [`roadmap.md`](roadmap.md) → [`middleware.md`](middleware.md)
→ [`names.md`](names.md) → [`plant-service.md`](plant-service.md) →
[`recipes.md`](recipes.md) → [`agent.md`](agent.md). Everything else is
supporting material.
