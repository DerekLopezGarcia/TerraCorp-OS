# Prior art: SuSy Factory Flow and RecipeViewer (research)

Status: **research closed** (2026-11-13). Not a plan and not a commitment: it
records what exists, what is reusable, and what would have to be checked before
adopting the reference dataset in F3. Design decisions live in
[`roadmap.md`](roadmap.md) (13, 19) and [`recipes.md`](recipes.md).

- <https://github.com/SymmetricDevs/susy-factory-flow>
- <https://github.com/SymmetricDevs/RecipeViewer>

## What they are

| Project | What it actually is |
|---|---|
| **SuSy Factory Flow** | A Next.js **planner** for SuSy production chains: recipe browser with HEI-style pages, React Flow factory graph, and a pure-TypeScript **throughput solver** (`src/lib/solver/`). Plans are JSON; published recipe data is read-only; a local `/recipes` workshop edits experimental versions. |
| **RecipeViewer** | A static web **viewer** for SuSy recipes — "so you don't have to wait 6 minutes for the game to launch". Small app; ships `recipedump.json.gz` (3.4 MB) in the repo. |

Provenance matters here: Factory Flow is a **fork of
`Samiracle64/gtnh-factory-flow` retargeted at SuSy**, and it lives in
**SymmetricDevs**, the organisation of the Supersymmetry developers themselves
(the README credits the GTNH lineage and notes the fork has diverged into an
independent codebase). That is a different trust level from a stranger's side
project: this is the pack's own tooling, so its dataset schema is the closest
thing to a **de facto data standard for SuSy** that exists today.

Which means the default should be **adopt their schema rather than invent
ours**: if the pack's developers change recipe data, they change it there first.

The first one matters much more than its README suggests: it is not a diagram
tool, it is a dataset-driven planning engine with a real solver.

## The dataset, in its own words

`src/lib/datasets/types.ts` defines `RecipeDataset`:

```text
schemaVersion, datasetVersionId, gtnhVersion, sourceInfo,
resources[], recipes[], oreDictionary{}, recipeMaps[]
```

and each `Recipe` carries, among others:

```text
id, name, kind, category, recipeMap, machineType, minimumTier,
durationTicks, eut, programmedCircuit, specialValue,
machineHandlers, machineConfigControls, inputs[], outputs[]
```

Inputs and outputs are `ResourceAmount`s with `kind: item | fluid | aspect` and
an `alternatives` field, and the dataset carries a full `oreDictionary` map.
Versions are published with `channel` (stable/daily/experimental) and
`checksumSha256`.

Translation: **ticks, EU/t, machine type, minimum tier, chance and ore-dictionary
alternatives are already in the data.** That is everything [`recipes.md`](recipes.md)
was asking an operator to type by hand.

## What we should reuse, in order of value

1. **The normalized dataset as the reference library.** Our book is the small set
   we actually operate; the dataset is the encyclopedia behind it. A line's
   recipe points at a dataset recipe id, and the service reads duration, EU/t,
   tier and alternatives from there instead of from a hand-written TSV.
2. **The extraction pipeline (`gtnh-oracle`, `recipedump.json`).** They run a
   real client with an oracle mod and dump recipes, rendering item icons along the
   way. If a version-specific dump is ever needed, the path exists and is
   scripted; we should not invent our own exporter.
3. **The solver, or its tests.** `throughput.ts` (55 KB), `equilibrium.ts`
   (110 KB), `machine-count-optimizer.ts` (50 KB), plus `simplex.ts`,
   `lp-engine.ts`, `power.ts`, `heat.ts`, `hatch-input.ts`, `pool-mode.ts`,
   `production-groups.ts`, `storage-ratios.ts`. There is an LP engine and a
   machine-count optimizer in there. Our `plan()` needs simple arithmetic
   (rates, shortfall, bottleneck by step); **if optimization is ever needed, we
   call or vendor theirs, we do not write a second LP engine.** MIT allows it
   with attribution.
4. **RecipeViewer's dump as a bootstrap.** A 3.4 MB gzipped dump gets us real
   recipes on day one for lookup and for seeding, without running a client.

## What stays ours

Their tool answers *"how do I build this base"*. TerraCorp answers *"what is
happening right now and what should move"*. The overlap is the dataset, not the
job:

- Live levels, rates from real samples, skew between pool members.
- Dispatch, gates, `move` by name, the OS-side translator.
- **Calibration against real runs**, which is precisely where they say their
  model is thin: their own README lists ore-dictionary resolution, exact tier
  metadata, multiblock rules, maintenance, pollution and chance distribution as
  not fully solved. Measurement is our half of the deal.

So the division is flattering: they model the pack, we measure the plant.

## What this changes in our design

- [`recipes.md`](recipes.md) gains a **two-tier storage**: the reference dataset
  (read-only, versioned, checksummed) and the operated book (ours, small, keyed by
  dataset recipe ids). Hand-typing 20 000 recipes was never the plan; typing the
  twenty we automate still is.
- Provenance gains a legitimate **`imported`** state next to `declared`:
  imported is not verified. A real run still promotes a recipe, and a
  contradiction still turns it `suspect`.
- Version pinning becomes mandatory: the book records `datasetVersionId` +
  checksum. A pack update that changes ticks silently invalidates every rate, and
  a rate you cannot trust is worse than no rate.

## Constraints and open questions

| Item | Status |
|---|---|
| License | Code is MIT in both repos (Factory Flow keeps the original `gtnh-factory-flow` copyright, as its README states). |
| Recipe data | **Not ours to redistribute.** It is derived from pack/mod data; RecipeViewer happens to ship a dump, Factory Flow deliberately does not. We use it locally, never vendor it into this repo. |
| Ownership | `src/lib/model/types.ts` (`Recipe`, `RecipeInput`, `RecipeOutput`, `ResourceAmount`) was not read yet; the `alternatives` and chance shapes need confirming before we commit to the schema. |
| Pack identity | The field is still named `gtnhVersion` because of the fork, while the project is SuSy-facing and maintained by SuSy's own devs. The *code* is therefore trustworthy; a *published dataset* still needs its SuSy version and channel confirmed before we trust tier or EU/t numbers. |
| Solver reuse | Vendoring 100 KB+ of TypeScript into the service is fine license-wise; it is a maintenance decision, not a legal one. Prefer calling it until we need it in-process. |
| Availability | Maintained by the pack's developers, but still a moving target in active development: pin a commit, not `main`, and treat schema changes as pack changes. |

## What to do next, whenever this is picked up

1. Download RecipeViewer's `recipedump.json.gz` and inspect the real shape of
   `recipes[]`, `alternatives`, chance outputs and `oreDictionary` — and check
   whether that dump matches the schema version Factory Flow consumes today.
2. Pin a commit of `susy-factory-flow`, read `src/lib/model/types.ts`, and check
   the pipeline docs for which SuSy version and channel the published datasets
   carry. Being the devs' own repo, its issues and pipeline logs are the fastest
   source for that answer.
3. Only then decide: import the dataset into the service as the reference
   library, and rewrite `recipes.md`'s storage section around it.

Until those three are done, the F3 plan stands as written — the dataset is an
accelerator, not a dependency. What changes now is the default: if we ever need
our own recipe schema, we start from theirs and justify each divergence.
