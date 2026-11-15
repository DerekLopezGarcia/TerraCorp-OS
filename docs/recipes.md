# Recipe book, lines and planning (0.4.5)

Status: **design**. Slice 0.4.5 of F3 (plant readout), running in the **OS** for
the small operated book and optionally in the **plant service**
([`plant-service.md`](plant-service.md)) for the full dataset and planning at
scale. The gate side is 0.4.6. Depends on the 0.4.0 probe for identifier formats
and on stocks (0.4.1) for live levels. Nothing here moves items.

The readout answers *what is in the hall*. It cannot answer what the hall can
**become**: that 2 ingots and 1 plate make 1 gear, in which machine, in how many
ticks, fed from which store. That knowledge is the recipe book, and without it
three questions stay unanswerable:

- Can I make N of X with what I have right now?
- If not, what is missing, and how long until it is not?
- Which step limits the chain — the bottleneck — and which step is merely
  starved?

## Declared, imported, measured, verified

Four states, never blurred:

| State | Where it comes from | How it is used |
|---|---|---|
| **declared** | The operator writes it: inputs, outputs, machine, ticks | Planning, with the numbers exactly as written |
| **imported** | Copied from a published pack export ([`research-susy-planner.md`](research-susy-planner.md)) | Planning, with the dataset's numbers and the dataset's version recorded |
| **measured** | Stock deltas observed across a real run | Calibration of the declared or imported numbers |
| **verified** | Declared/imported and measured agree within tolerance | The planner prefers these numbers and stops warning |

**Imported is not verified.** A dataset says what the pack believes; only a run
says what the plant does. Importing is how we avoid typing twenty thousand
recipes, not how we earn trust in a rate.

The rule that keeps the system honest: **the planner never silently trusts a
recipe that measurement contradicts.** It keeps planning, marks the recipe
`suspect`, uses the measured ratio, and raises an alarm. A recipe book that is
wrong quietly is worse than no recipe book.

The gate loop in [`crafting.md`](crafting.md) stays empirical and does **not**
depend on the book: it reads the buffers and feeds by delta. Recipes are the
planning layer, not a precondition for automating one line.

## Storage

Two tiers, because an encyclopedia and a notebook are different objects:

| Tier | Size | Where | Mutable |
|---|---|---|---|
| **Reference dataset** | thousands of recipes, tens of MB | The SuSy developers' published export (Factory Flow dataset), pinned by version and checksum | No. Read-only, replaced whole |
| **Operated book** | the recipes this plant actually runs | The OS (0.4.5), or the service when the book outgrows it; flat files below | Yes, by operator or agent |

The small book lives in the **OS**; the full book and the reference dataset live
in the optional service ([`plant-service.md`](plant-service.md)). It is planning
data: the node holds the twenty recipes it runs, not the encyclopedia. Two flat
files, greppable and diffable, parsed once at start:

```text
recipes.tsv     id  dataset_recipe  label  machine  ticks  energy  priority
recipe-io.tsv   recipe  side  kind  key  qty  chance
```

`side` is `in` or `out`; `kind` is `item` or `fluid`; `chance` is empty for a
guaranteed output; `dataset_recipe` is the reference id when the numbers were
imported rather than typed, so a pack update can be diffed against what we run.

Two files, not one, because a recipe has a variable number of ingredients: a
changed quantity should be a one-line diff, not a rewritten blob. A recipe costs
roughly a kilobyte of RAM once parsed; a few hundred recipes are comfortable,
and a book that stops fitting must fail loudly instead of half-loading.

## Identifiers (the hidden dependency)

A recipe key must match **exactly** what the sensor reports, byte for byte.
That is not a detail to settle later: the 0.4.0 probe must record the format the
Adapter returns for an item (registry name, damage/metadata, NBT variants) and
for a fluid. If the sensor exposes only display labels, keys are display strings
and the book is fragile — the planner keys off whatever the sensor gives and
keeps a separate display map, but it cannot invent precision the sensor lacks.

Two keys never mix: an item and a fluid with similar names, and a fluid inside a
cell versus the fluid itself.

### Machine casings (assembler, circuit 8)

RecipeViewer's dataset (`recipedump.json.gz`, 2026-11-15) and the in-game line
agree: **8 plates → 1 casing**, circuit **8**, 16 EU/t, 50 ticks (25 for ULV).
The material selects the tier; the circuit does not change.

| Casing | Plates | Metadata |
|---|---|---:|
| ULV | Wrought Iron (335) | 0 |
| LV | Steel (324) | 1 |
| MV | Aluminium (2) | 2 |
| HV | Stainless Steel (323) | 3 |
| EV | Titanium (113) | 4 |

The rig's four materials cover LV-EV; ULV needs wrought iron. The line produced
2 EV, 1 HV, 1 LV and 1 MV from 8 ingots each.

### The line program

A line is a black box (decision 24), so its program is a small **data file**, not
Lua. One file per line, edited in the Plant app or through the link at `write`
tier, parsed as data:

```text
# /etc/lines/casing.line
stock in  casing/ingots
stock out casing/casings

rule lv
  in  8 item gregtech:meta_ingot@324
  out 1 item gregtech:machine_casing@1
rule mv
  in  8 item gregtech:meta_ingot@2
  out 1 item gregtech:machine_casing@2
rule hv
  in  8 item gregtech:meta_ingot@323
  out 1 item gregtech:machine_casing@3
rule ev
  in  8 item gregtech:meta_ingot@113
  out 1 item gregtech:machine_casing@4

ticks 50
limit 64 item gregtech:machine_casing@4
```

- `item <name>@<damage>` is the exact key the sensor reports; `fluid <name>` is
  the Forge fluid name. Multiple terms are joined with `+`:
  `in 4 item ... + 1000 fluid water`. A rule may have several inputs and
  several outputs at once. NBT variants (`hasTag=true`) are not in this first
  grammar; a tag field comes when a stock reports one.
- A rule is `in = out` with quantities per craft. A line can hold several
  rules; the app selects one by name or by its input key.
- `ticks` and `limit` are **line-level**: they close the previous rule and
  apply to the whole program. A rule cannot override them in this version;
  repeat `limit` once per output you want to cap.
- The file is **data**: no functions, no expressions, no Lua. `/etc` is writable
  through the link, so executable config would be remote code execution
  (decision 22).
- The parser is `tc.line` (`src/lib/tc/line.lua`); it returns
  `stocks.inputs` / `stocks.outputs` (Lua reserves `in`). `npm run test:line`
  runs the casing fixture and the malformed-input cases.
- The declared rule is `declared`; the boundary deltas make it `measured` and
  then `verified`; a contradiction turns it `suspect` (decision 13).
- The line still only exposes its two boundary stocks. The program says
  `mat in = mat out`; the machines between them are not named.

## From recipe to plant: lines

A recipe says *what*. A **line** says *where*: which stock feeds each input,
which stock receives each output, and which gate the loop drives
([`crafting.md`](crafting.md) has the gate semantics).

The binding is split across the two sides, because each knows one half:

```text
node /etc/lines.tsv      line  gate            # hardware: which component
service lines.tsv        line  recipe  in:<stock>  out:<stock>  machines
```

- `machines` is the number of parallel machines behind the gate; it multiplies
  the step's rate.
- Bindings are per stock name, so moving a line between halls is a config edit.
- A line without every input bound is refused at load time with a named error —
  a half-bound line would silently plan against nothing.
- The **line name is the join key**. A name that exists on one side and not the
  other is an `unknown_line` alarm on both panels, never a guess.

## The chain

Planning walks backwards from the target:

1. Find the recipe that produces the target, highest `priority` first, skipping
   `suspect` ones unless nothing else produces it.
2. Recurse into its inputs until every leaf is a raw stock or an input nobody
   declares a recipe for.
3. **Cycles** (GT reprocessing: macerate → smelt → macerate) are allowed and
   bounded by a configured number of passes; the planner counts the byproduct
   share each pass contributes and stops when a pass adds less than the
   configured floor.
4. **Byproducts with chance** contribute `qty × chance`. A chain that needs more
   of a byproduct than its expected yield is flagged: that plan depends on luck,
   and the operator should know before building it.

The planner returns a table, not prose:

```text
plan(target, qty) -> steps[] {recipe, line, crafts, seconds, in[], out[]}
                     bottleneck = {recipe, rate}
                     shortfall[] = {key, need, have, missing}
                     warnings[]  = {unseen_key | suspect_recipe | rng_chain}
```

## Rate and bottleneck

- A step's rate is `machines / ticks` crafts per second; its consumption and
  production rates follow from its inputs and outputs.
- The chain's rate is the **minimum** across steps. That step is the bottleneck
  by name, not by percentage, and the UI shows it as such.
- Stock level into time: given the current level and the step's rate, how long
  the line runs before it stops. That number is what turns "STARVED" from a
  complaint into a deadline.

This is the answer to *fast bottleneck detection*: without recipes the OS can
only see that a level is not moving; with them it can say which step is the
reason.

## Where it runs

In the **OS** for the small book, and in the optional **plant service**
([`plant-service.md`](plant-service.md)) when the book or the dataset outgrows
the node. In both cases it is a pure function over the book plus the cached
stock snapshots; the local planner reads no components itself, costs no tick
time, and survives a hall going offline: the plan shows the last known levels
and their age instead of pretending they are current.

Actuation is not this slice. The plan turns into `gate.set` setpoints (0.4.6)
and the node reconciles them under its own interlocks; restock orders across
halls come in F7.

## Calibration

After a run, compare what the stocks lost against `crafts × declared inputs`:

- Ratio within tolerance → `verified`, with the measured ratio stored.
- Outside tolerance → `suspect`, alarm, planner switches to measured numbers.
- No run yet → `declared`, plan as written and say so in the UI.

The same mechanism catches the classic operator error: the byproduct that was
assumed at 100 % and is really 25 %.

## Failure modes worth designing for

| Case | Behaviour |
|---|---|
| Recipe mentions a key no stock has ever reported | Allowed and marked `unseen` — a cheap typo detector, not a load error |
| Two recipes produce the same item | Priority decides; ambiguity is visible in the plan, never silently averaged |
| Recipe whose outputs are also its inputs | Allowed as a cycle; the planner bounds the passes |
| Fluid amount units | `mB` everywhere; the probe records what the sensor reports, no conversion guesswork |
| Reference dataset too large to load whole | Query it by id and by target instead of loading everything; a book that does not fit must fail loudly, not half-load |

## What this deliberately is not

- **Not a NEI replacement.** A published pack export is imported as read-only
  reference ([`research-susy-planner.md`](research-susy-planner.md)); we never
  derive recipes from the mods ourselves, and pack data is never vendored into
  this repo.
- **Not machine control.** F7 turns a plan into gates and orders; this slice
  computes.
- **Not a stock.** Levels live in the stock reader; the book never infers a
  quantity from a recipe.

## In-game verification checklist

1. Identifier format from the 0.4.0 probe, for one item and one fluid cell.
2. One declared single-step recipe reproducing exactly one real batch: recorded
   ticks, no byproduct surprise.
3. A cycle with a byproduct (macerate → smelt → macerate): confirm the planner's
   pass floor and warning.
4. Plan cost on a Tier 2 master: a three-step chain planned under 1 s, and the
   plan recomputed at 1 Hz without disturbing the desktop.
5. Deliberate mismatch: declare the wrong quantity, run one batch, confirm
   `suspect` plus the measured ratio.

## Sequencing

1. **0.4.5a** — files, parser, one-step feasibility ("can I make N of X?").
2. **0.4.5b** — chain DAG, bottleneck, shortfall, lines.
3. **0.4.5c** — calibration against real runs, `suspect` state and alarm.
4. **F7** — gates and restock orders consume `plan`.

Cross-links: [`crafting.md`](crafting.md) (gate loop, stocks as buffers),
[`roadmap.md`](roadmap.md) (F3.5, F7), [`telemetry.md`](telemetry.md) (probe
and identifiers), [`names.md`](names.md) (stock and machine names).
