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

## The sensing requirement (harder than plain gating)

Type + quantity selection **requires inventory reads** — a comparator cannot
tell item types apart. This is the load-bearing dependency:

| Sensor | Role | To verify |
|---|---|---|
| **Adapter on buffer (chest/barrel/drawer)** | `inventory` component: `getStackInSlot`-style reads with item type + count (full NBT per OC's inventory_controller precedent) | Does the Adapter expose the exact buffer types in use? Especially **Storage Drawers** — not on OC's vanilla integration list |
| Comparator | Fast coarse stock (0–15) for the gate when OUT is a simple container | strength→count table per buffer type |
| Transposer (optional later) | Push-mode feeding if the passive feed + gate cannot respect per-type quantities | insertion into the circuit's entry point |

**Degradation rule**: if a buffer cannot be item-read (adapter path fails),
that line runs in **coarse mode** — gate on total comparator stock only, with
a persistent warning "ingredient types unverified". The program must never
pretend to know types it did not read.

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

1. **Adapter inventory reads on the real buffers**: kinds, methods, and
   whether full item NBT (type + count) comes through — especially drawers.
2. Comparator tables (coarse mode) per buffer type.
3. Gate semantics: does gate-low truly stop the existing feed?
4. Read cadence: cost of a full inventory read at 1 Hz on a worker node
   alongside Relay duty.
5. Delta accounting: consume items manually and confirm the loop's
   `fed_so_far` tracks the deltas correctly.

## Recommendation

Three slices, each independently useful:

1. **Stock reader**: `stock` Relay task + dashboard tile (types + counts of
   named buffers). Useful on day one even with zero automation.
2. **Selection UI + gate loop**: one line, one run, end to end.
3. **Scale by config**: more lines = more TSV rows, not more code.

Cross-links: `distributed.md` (worker role), `telemetry.md`, `names.md`,
`relay.md`, `long-distance.md` (alarm path), `holo.md` (wall bars).
