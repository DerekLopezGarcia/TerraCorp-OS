# Craft orchestration: buffer-driven recipes (Yordi111 requirement)

Automate crafting across any machines connected by logic + redstone between
two buffers. The operator's flow, verbatim from field operations:

> Put base ingredients in a buffer that feeds the crafting circuit on the
> other side. The program reads **ingredients and result as items** from the
> buffers: select the input ingredients **by type and quantity**, then the
> result appears on the other side, with a **stock limit**.

So the recipe is **not declared — it is read from the buffers**. TerraCorp's
job: inspect both buffers as inventories (item types + counts), let the
operator pick which types to allow and how much to feed, and gate the feed
while the result's stock is below its limit. Target: 0.5.x `tc/craft` plus a
selection UI. Design; "verify" items need in-game probes.

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

### 1. Recipe selection (operator, via UI)

A small TerraCorp app (or Terminal commands) on the hall node:

1. `read IN` — list every item type currently in the input buffer with its
   count (live re-read; the buffer is the recipe source of truth).
2. Operator selects which types are **ingredients for this run** and, per
   type, the **max quantity** to feed (the batch definition lives in the
   buffer, not in a config file).
3. Operator selects the **result type** (picked from the OUT buffer once the
   first batch appears, or named by the operator) and the **stock limit**.

The selection is persisted (`/etc/craft.tsv`, one line per run) so it
survives reboots; changing selection = re-open the UI.

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
- When `out_count` crosses the limit, the gate closes and the selection
  stays armed for the next run (or auto-resets, configurable).

## The sensing requirement (the load-bearing dependency)

Type + quantity selection and precise limits **require inventory reads** —
the drawer upgrade's 0–15 signal cannot identify types or give exact counts:

| Sensor | Role | To verify |
|---|---|---|
| **Adapter on drawer / GT crate / chest** | `inventory` component: per-slot reads with item type + count (OC's inventory_controller precedent returns full NBT). This is the sensor of record | Does the Adapter expose **Storage Drawers** and **GregTech crates**? Drawers are not on OC's vanilla integration list; GT crates depend on the gtce2oc/Adapter question in `telemetry.md` |
| Drawer redstone upgrade (0–15) | Emergency fallback only: gate on total fill when adapter reads are unavailable, with a persistent "types unverified" warning | Fill fraction basis (per slot? per capacity?) |
| Transposer (optional) | Push-mode feeding if the passive feed + gate cannot respect per-type quantities | Insertion into the circuit's entry point |

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

- **Relay**: `stock` built-in task (named buffers, types + counts) and
  `craft limit` orders (set limit / reset run) from any terminal.
- **Telemetry / UI**: buffer levels feed the dashboard and hologram wall
  (`holo.md`) as bars; the Craft app on the master renders the same data for
  selection when the operator is at the desk instead of the hall.
- **Names** (`names.md`): `craft1.in`, `craft1.out`.
- Standalone rule: selection and the loop run with the master offline;
  Relay only carries reports and remote orders.

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

Three slices, each independently useful:

1. **Stock reader**: `stock` Relay task + dashboard tile (types + counts of
   named buffers). Useful on day one even with zero automation.
2. **Selection UI + gate loop**: one line, one run, end to end.
3. **Scale by config**: more lines = more TSV rows, not more code.

Cross-links: `distributed.md` (worker role), `telemetry.md`, `names.md`,
`relay.md`, `long-distance.md` (alarm path), `holo.md` (wall bars).
