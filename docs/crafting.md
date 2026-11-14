# Craft orchestration: buffer-driven recipes (Yordi111 requirement)

Automate crafting across any machines connected by logic + redstone between
two buffers. The operator's flow, verbatim from field operations:

> Put base ingredients in a buffer that feeds the crafting circuit on the
> other side. The program reads **ingredients and result as items** from the
> buffers: select the input ingredients **by type and quantity**, then the
> result appears on the other side, with a **stock limit**.

So the **gate loop needs no declared recipe**: it reads the buffers and feeds by
delta. Declaring what a line produces belongs to the planning layer
([`recipes.md`](recipes.md), 0.4.5) — and a real run of this loop is exactly what
calibrates a declared recipe (input deltas against declared inputs). The two
layers feed each other instead of duplicating a recipe database.

TerraCorp's job here: inspect both buffers as inventories (item types + counts),
let the operator pick which types to allow and how much to feed, and gate the
feed while the result's stock is below its limit. Target: 0.8.x `tc/craft` plus a
selection UI; the stock reader it depends on is 0.4.2 (F3 plant readout).
Design; "verify" items need in-game probes.

**Why this exists**: drawers ship a redstone upgrade that outputs 0–15 by
fill fraction — too coarse for precise or large stores. The program
**replaces that redstone logic**: exact item counts from inventory reads,
aggregate warehouses (many drawers = one logical stock), and per-type control.
Redstone stays only as wiring the program emits, never as the sensor of
record.

## Architecture

```text
[buffer IN] ──(existing pipes/hoppers + logic circuit)──> [buffer OUT]
   │          machines keep their own redstone logic               │
   │ inventory read: item types + counts                           │ same
   └──────────────── tc/craft node ────────────────────────────────┘
        gate line (redstone) controls the feed from IN into the circuit
                          │ Relay: jobs, telemetry, alarms
```

- **buffer IN**: operator dumps whatever base ingredients. The program reads
  its contents as an inventory (types + counts per slot/side) — it must
  discover the recipe inputs from what is actually there.
- **buffer OUT**: the crafted result accumulates here; the program reads the
  result type and its count to enforce the stock limit.
- **Gate**: one redstone line (Redstone Card) enables/disables the feed from
  IN into the circuit. The circuit and machines are untouched.

## Warehouse abstraction

A **named stock** is the unit of control, not a physical container. Today the
buffers are drawers, but any container type may serve — **GregTech crates**
are the expected upgrade path for higher per-unit capacity (fewer containers
per stock, more items each):

```
craft1.in  = drawer A + drawer B + crate 1     (mixed types allowed)
craft1.out = drawer C + crate 2
```

- The program sums exact per-type counts across every container assigned to a
  name, regardless of kind. This is what makes stores **bigger** (N containers
  — drawers or GT crates — behave as one stock with full precision, no 0–15
  ceiling) and **more precise** (true counts, no fill fractions).
- Containers join/leave a stock by config line; the loop never changes.
- Per-kind read cost will differ (drawers vs GT crates), so the aggregation
  pass must time each container kind and stay inside the 1 Hz budget.
- The drawer redstone upgrade (0–15 by fill) is acknowledged but **not
  used by TerraCorp**: it is the constraint being replaced. It remains
  available for dumb vanilla-side indicators.

## Program contract

### 1. Recipe selection (a setpoint, not a recipe)

Selection says *which types may feed, how many, and up to which output limit*.
It is normally made in the plant-service panel
([`plant-service.md`](plant-service.md)) and arrives at the node as a run
descriptor plus the line's desired state (0.4.6); the node also accepts it
locally from the Terminal, so a hall without a bridge still runs a line.

1. `read IN` — list every item type currently in the input buffer with its
   count (live re-read; the buffer is the recipe source of truth).
2. Operator selects which types are **ingredients for this run** and, per
   type, the **max quantity** to feed (the batch definition lives in the
   buffer, not in a config file).
3. Operator selects the **result type** (picked from the OUT buffer once the
   first batch appears, or named by the operator) and the **stock limit**.

The selection is persisted (`/etc/craft.tsv`, one line per run) so it survives
reboots; changing selection means setting it again, from the panel or locally.

### 2. The control loop

```
every pass (≤ 1 Hz):
  out_count = count(OUT, result_type)
  if out_count < limit and fed_so_far < selected_quantity:
      gate on
  else:
      gate off
  feed accounting: delta(IN counts) per pass = what the circuit consumed
  alarm checks (below)
```

- `fed_so_far` is derived from **input buffer deltas** (fresh readings every
  pass), never from an internal counter — a reboot reconciles automatically
  from the next delta.
- The gate obeys the run descriptor and the last **desired state** sent from
  outside, with a **local guard** the node evaluates against its cache each tick
  (`max_resident`, `min_input`). That one comparison is what keeps a limit honest
  between two polls; the service still decides what the limit is (0.4.6). A
  desired state that contradicts the cache is **refused with a reason**, never
  obeyed.
- When `out_count` crosses the limit, the gate closes and the selection
  stays armed for the next run (or auto-resets, configurable).

## The sensing requirement (the load-bearing dependency)

Type + quantity selection and precise limits **require inventory reads** —
the drawer upgrade's 0–15 signal cannot identify types or give exact counts:

| Sensor | Role | To verify |
|---|---|---|
| **Adapter on chest / GT crate** | `inventory` component: per-slot reads with item type + count (OC's inventory_controller precedent returns full NBT). Sensor of record where it works | The Adapter does **not** expose a Storage Drawer (verified in-game 2026-11-14); chests, GT crates and machines still to confirm |
| **Transposer** | Reader **and** pusher: `getInventoryName(side)` / `getInventorySize(side)` per face, then per-slot reads. It **does** see drawers and pipes (below) | The stack shape (`name`, `damage`, `size`, `label`, `tag`) and whether `transferItem` respects per-type limits |
| Drawer redstone upgrade (0–15) | Emergency fallback only: gate on total fill when adapter reads are unavailable, with a persistent "types unverified" warning | Fill fraction basis (per slot? per capacity?) |

Transposer faces read in-game on 2026-11-14 (six faces, one Transposer):

| Face | `getInventoryName` | `getInventorySize` |
|---|---|---|
| 0 | `minecraft:hopper` | 5 |
| 1 | `minecraft:chest` | 27 |
| 2 | `gregtech:machine` | 90 |
| 3 | `storagedrawers:basicdrawers` | 2 |
| 4 | `nil` (`no inventory`) | — |
| 5 | `gregtech:item_pipe_small` | 1 |

Two consequences:

- **Drawers are visible to the Transposer** even though the Adapter does not
  expose them; the "drawers are not a sensor" conclusion only held for the
  Adapter. Per-slot reads on that face are still to confirm.
- **A pipe answers like a one-slot inventory.** It must be classified as
  transport and never counted as a stock member: otherwise every pipe adds a
  phantom slot and the item in transit inflates the count. Classify by kind
  (descriptor), never by `size == 1` — a real one-slot container exists.

The name is the block's registry name, so the driver layer can key on it without
asking the block itself. A face with nothing on it answers `nil` plus
`"no inventory"`: the reader treats that as absent, not as a failed read.

Re-read the matrix after every rebuild. The face numbers follow the physical
sides, and moving a container to another side changes which number it answers
on; the Transposer's own address also changes if it was re-placed.

Reading slots: `getStackInSlot` answers **`nil` for an empty slot**, which is a
valid result, not a failure. `nil, "invalid slot"` means the index is past that
face's `getInventorySize` (a pipe has 1, a basic drawer 2, a chest 27). The
reader asks for the size first and walks `1..size`, skipping empty slots
silently; "no table" from a probe usually means the container is empty.

Read cost (in-game 2026-11-14): 200 `getStackInSlot` calls took **10,000 ms** and
50 `getAllStacks` calls took **2,549 ms**, both ~50 ms with `clock=uptime` — one
server tick per host call whatever the payload. Per-slot scans are for
diagnostics and `move` only; `getAllStacks` is the snapshot read, and the budget
is **about one face per tick**. A sweep is scheduled round-robin instead of
reading every face at once: twenty faces fill a second, forty take two. The
snapshot period follows from that, not from a wish for 1 Hz.

A per-slot benchmark must keep the index inside `getInventorySize`: a loop
`1..n` over a 27-slot chest asks for slot 28 onwards, gets `invalid slot`, and
aborts before printing. Benchmark one fixed slot, or wrap with
`(i - 1) % size + 1`; the number is the same, because the cost is the call.

**Degradation rule**: a line without inventory reads runs in **coarse mode**
(gate by total fill only, warning shown). The program must never pretend to
know types or exact counts it did not read. Precision is opt-in per container,
and the UI must show which stocks are exact and which are coarse — a stock
mixing an unreadable crate with readable drawers stays coarse until every
container reads.

## Failure semantics

- `STARVED`: gate on + a selected ingredient type at zero while the run is
  incomplete → logistics must restock (Yordi's side). Gate stays on.
- `LIMIT REACHED` is not an alarm — it is the normal end state.
- `MISMATCH`: OUT shows a different type than selected → `JAMMED`-class
  alarm (circuit producing the wrong thing); gate closes.
- `STALE`: no delta in IN for N passes while gate on and run incomplete →
  alarm; nothing auto-fed to "fix" it.
- Item reads are the only state source; every pass re-derives. After a
  reboot, the first pass reconciles (gate = f(current counts)).

## Integration

- **Plant service** ([`plant-service.md`](plant-service.md)): the panel holds the
  selection, the plan and the alarms; it sends setpoints and reads back refusals.
  `stock.snapshot`/`stock.delta` are how buffer levels reach it.
- **Relay**: `stock` built-in task (named buffers, types + counts) and
  `craft limit` orders (set limit / reset run) from any terminal.
- **Telemetry / UI**: buffer levels feed the panel and hologram wall
  (`holo.md`) as bars.
- **Names** (`names.md`): `craft1.in`, `craft1.out`.
- Standalone rule: the loop runs with the master and the service offline;
  selection can be set locally, and Relay only carries reports and orders.

## Verification checklist (crafting hall session)

1. **Adapter inventory reads on the real containers**: kinds, methods, and
   whether full item NBT (type + count) comes through — for **drawers and
   for GregTech crates**. This decides whether the project delivers
   precision or stays coarse.
2. Drawer redstone upgrade (fallback): fill-fraction basis of the 0–15
   signal, for the coarse mode only.
3. Aggregation probe: read mixed drawers + a GT crate from one node at 1 Hz
   — read cost per kind and whether component visibility allows it from a
   single machine.
4. GT crate capacity: record per-crate item capacity (how many containers
   per stock the config needs to stop growing).
5. Gate semantics: does gate-low truly stop the existing feed?
6. Delta accounting: consume items manually and confirm the loop's
   `fed_so_far` tracks the deltas correctly.

## Recommendation

Three slices, each independently useful, split across the two layers
([`plant-service.md`](plant-service.md)):

1. **Stock reader** (node, 0.4.2): exact types and counts of named buffers,
   pushed out as snapshot and deltas. Useful on day one even with zero
   automation.
2. **Gate loop** (node, 0.4.6): one line, one run, end to end, driven by a
   desired state and defended by local interlocks.
3. **Selection and orders** (service, 0.4.5 + F7): the panel sets the run and
   the plan, and more lines are more config rows, not more code.

Cross-links: [`plant-service.md`](plant-service.md), [`recipes.md`](recipes.md),
`distributed.md` (worker role), `telemetry.md`, `names.md`, `relay.md`,
`long-distance.md` (alarm path), `holo.md` (wall bars).
