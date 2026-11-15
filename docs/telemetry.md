# Plant telemetry (GregTech ↔ TerraCorp)

Research for reading plant state (power, machines, tanks) into TerraCorp.
Target phase: **0.4.x (F3 plant readout)**, feeding the alarm registry, the
stock readers and the alarm channel. Open work called out in `distributed.md`:
"verify which GTCE inventories/tanks the Adapter exposes before factory
telemetry work".

**Status 2026-11-15: the probe is done** for items, fluids, energy and coarse
redstone; a multiblock tank and one working machine remain (see checklist 3 and
the machine driver names below). Every measurement is 50 ms per host call.

## The integration landscape (1.12.2)

| Path | What it gives | Status |
|---|---|---|
| **gtce2oc** (CurseForge, 1.12.2, last release 2020-11) | Bridges OC into the GregTech CE wire network; **read-only Lua API for `IEnergyContainer`s**; exposes GT machines as OC components via an opt-in config (`config/opencomputers/gregtechce.recipes`) | Built for GregTech **CE**, not the CEu fork. Compatibility with Supersymmetry's GregTech build must be verified in-game; a CEu-compatible fork may exist |
| **Stock OC Adapter** | Exposes blocks of *integrated* mods as components. GregTech machines are not on the vanilla integration list — without a bridge, the Adapter sees nothing on a GT machine | Verify per machine in-game: `component.list()` next to an Adapter touching the target |
| **inventory_controller / tank_controller upgrades** | Read item stacks (full NBT) and tank contents in *robot/inventory* contexts — not arbitrary external machines | Limited to what the Upgrade sits in; useful for logistics robots, not the plant |
| **Redstone Card** | Read/write I/O on blocks that expose vanilla redstone | GT machines mostly do not; usable for diode-level status bits only |

**Applied Energistics** is in the pack but is used as a manual crafting
terminal, not as a store (decision 11 in `roadmap.md`). An ME network is not a
stock source for F3 and no AE2 integration is planned; if one ever becomes a
store, it enters here as one more read path, not as a new model.

## Candidate telemetry sources in Supersymmetry

- **Power**: Power Substation / energy hatches. If gtce2oc (or fork) works:
  `getEnergyStored`/`getMaxEnergyStored`-style read-only calls on the wire
  network. Otherwise: an OC **energy detector**-style integration or manual
  Redstone Card taps on comparator outputs (strength 0–15 only).
- **Machines**: running/idle/fault state, progress. Without a bridge this is
  not reachable — the fallback is monitoring the multiblock's redstone
  behavior or the pack's own sensor integrations, per machine.
- **Fluids**: tank contents. Same bridge dependency; OC `tank_controller`
  does not apply to external multiblock tanks.

## Design sketch (pending verification)

- `tc.telemetry` module: named probes (`power.matrix`, `machine.ebf1`) built
  on top of the address/path registry (`docs/names.md`); each probe = (component address,
  kind, read method, scale) declared in config, not code.
- Sampling discipline (per `distributed.md`): event-driven or ≥1 s polls;
  batch into one Relay state job; the dashboard reads cached values.
- The alarm channel (`long-distance.md` RC protocol `STATE` frames) carries
  compact probes: 2-byte id, 4-byte value, sequence — telemetry survives
  interdimensional links at 80 B/s.
- Graceful degradation: an absent bridge must show "no telemetry bridge" in
  the System card, never boot errors; probes are config, so removing one is a
  file edit.

## In-game verification checklist

1. Is gtce2oc (or a CEu fork) in the pack's mod list? If added manually:
   does it load against Supersymmetry's GregTech version?
2. With the bridge: `component.list()` from a computer wired to the GT wire
   network — which kinds appear? Record `getEnergyStored`/`getCapacity`
   signatures and units.
3. Without the bridge: Adapter next to (a) a Power Substation,
   (b) a single-block machine hatch, (c) a multiblock tank — what, if
   anything, is exposed?

   **Partial answer 2026-11-15 (drums).** An Adapter needs the matching upgrade
   to expose a channel: with **Tank Controller** fitted it reports a
   `tank_controller` component with the same `getTankLevel/getTankCapacity/
   getTankCount/getFluidInTank` API as a Transposer, side per face. The adapter
   itself never appears in `component.list()`, and the drums appear as
   `drum_tungstensteel` components that only carry GregTech's `getCover`, `slot`
   and `type`. Still open: Power Substation and multiblock tank.

   **Power, from the mod jar (GT 2.8.10).** There is no induction matrix in this
   pack; the GregTech jar ships its own OpenComputers drivers, so the energy
   store to probe is the **Power Substation**:

   | Driver | Methods (class constants) |
   |---|---|
   | `DriverEnergyContainer` (hatches, battery buffers) | `getEnergyStored`, `getEnergyCapacity`, `getInputVoltage`, `getInputAmperage`, `getInputPerSec`, `getOutputVoltage`, `getOutputAmperage`, `getOutputPerSec` |
   | `DriverPowerSubstation` | `getStored`, `getCapacity`, `getAverageInLastSec`, `getAverageOutLastSec`, `getPassiveDrain`, `getMaintenanceProblems`, `getNumMaintenanceProblems` |

   The names come from the class files, not from a running game: the in-game pass
   still has to confirm which of them an Adapter exposes, the units (EU), and the
   per-call cost.

   **In-game 2026-11-15 (Power Substation controller + energy block).** The
   Adapter exposes `power_substation` with `getStored`, `getCapacity`,
   `getAverageInLastSec`, `getAverageOutLastSec`, `getPassiveDrain` and
   `getMaintenanceProblems` — every name the jar predicted except
   `getNumMaintenanceProblems`, which is not exposed. **The values are strings,
   not numbers**: `getStored()` answered `"261,015,954,464"` and `getCapacity()`
   `"83,010,348,331,692,982,263"`. That capacity is larger than a signed 64-bit
   integer, so the driver formats a BigInteger; a reader has to strip the commas
   and accept that anything past 2^53 loses precision as a double.

   The second energy block appeared as `infinite_energy` with numeric values —
   stored 69, capacity 420, output `2097152` V × `64` A = `2684354560` EU/s
   (`perSec` is voltage × amperage × 20). Its kind name comes from
   `gregtech.machine.infinite_energy` in the jar, the **Infinite GT Energy Unit
   Emitter**, so it is a creative block and not the dynamo hatch it was meant to
   stand in for; the hatch itself was not separately probed. Both cost **50 ms
   per call**, like every other host read.

   **Substation hatches 2026-11-15.** Only the **input** hatch
   (`substation_hatch_input_64a_uhv`) exposes the energy container API, and with
   plain numbers: stored 0, capacity 2,147,483,648 (2^31 EU), input 2,097,152 V ×
   64 A, 50 ms per call. The **output** hatch
   (`substation_hatch_output_64a_uhv`) exposes only `getCover`, `slot` and
   `type`; the driver attaches no energy capability on that face. Energy reads
   therefore target the input hatch, while the totals live on the
   `power_substation` controller as formatted strings.
4. Comparator/redstone tap fallback: what strength does a Power Substation
   comparator output track, and is it linear in stored energy?

   **Answered for drawers 2026-11-15 (coarse mode).** A Storage Drawers
   **Redstone Upgrade** emits a proportional 0–15 for total storage, and it is
   linear: 64/128 items → 1, 192/256 → 2, 320/384 → 3, 448 → 4 on a 2-slot basic
   drawer, symmetric when the stock goes back up. It is **not** the vanilla
   comparator curve (448 would be 7 there); it fits `round(15 × fill / capacity)`
   with a capacity around 1,650–1,920 items, so one level is ≈112 items. Read it
   with a **Redstone I/O** block against the drawer: a Redstone Card inside the
   computer only sees the computer's own six sides and read 0 everywhere while
   the drawer touched the Adapter and the Transposer.
5. **Identifier format** for one item and one fluid (this one gates the recipe
   book, [`recipes.md`](recipes.md)): registry name, damage/metadata, whether
   NBT variants are distinguishable, and what a fluid tank reports — a name, a
   numeric id, or only a label. Recipe keys must match this byte for byte.

   **Fluid: answered in-game 2026-11-15.** A GregTech drum read through a
   Transposer reports a table, not a string:
   `name=water`, `label=Water`, `amount=11000`, `capacity=1024000`,
   `hasTag=false`. The key is the Forge registry name (`water`, lowercase,
   namespaced when the mod uses a domain), the label is display-only, and
   `hasTag` says whether the fluid stack carries NBT. `getFluidInTank(side)`
   returns an **array** of those tables, one per tank, so a reader takes `[1]`;
   see [`tests.md`](tests.md#results-log). The item half was already recorded in
   [`crafting.md`](crafting.md#the-sensing-requirement-the-load-bearing-dependency):
   `name` + `damage` (+ `tag` only when `hasTag`), with `size`, `label`, `maxSize`
   and `maxDamage` alongside.
6. Tick cost: poll the heaviest source at 1 Hz for 5 minutes, watch
   `forge tps` / the TerraCorp TPS estimator.

## Recommendation

Gate **precision** on the verification session: if the bridge works,
`tc.telemetry` is a small config-driven module inside F3; if not, stocks stay
coarse and the phase still ships, because alarms and energy history run on
master energy and node presence alone. The alarm registry (0.4.1) is
deliberately independent of GregTech integration, so it is built first, not
last.
