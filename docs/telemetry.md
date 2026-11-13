# Plant telemetry (GregTech ↔ TerraCorp)

Research for reading plant state (power, machines, tanks) into TerraCorp.
Target phase: **0.4.x (F3 plant readout)**, feeding the alarm registry, the
stock readers and the alarm channel. Open work called out in `distributed.md`:
"verify which GTCE inventories/tanks the Adapter exposes before factory
telemetry work".

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

- **Power**: induction matrix / energy hatches. If gtce2oc (or fork) works:
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
3. Without the bridge: Adapter next to (a) an induction matrix,
   (b) a single-block machine hatch, (c) a multiblock tank — what, if
   anything, is exposed?
4. Comparator/redstone tap fallback: what strength does an induction matrix
   comparator output track, and is it linear in stored energy?
5. **Identifier format** for one item and one fluid (this one gates the recipe
   book, [`recipes.md`](recipes.md)): registry name, damage/metadata, whether
   NBT variants are distinguishable, and what a fluid tank reports — a name, a
   numeric id, or only a label. Recipe keys must match this byte for byte.
6. Tick cost: poll the heaviest source at 1 Hz for 5 minutes, watch
   `forge tps` / the TerraCorp TPS estimator.

## Recommendation

Gate **precision** on the verification session: if the bridge works,
`tc.telemetry` is a small config-driven module inside F3; if not, stocks stay
coarse and the phase still ships, because alarms and energy history run on
master energy and node presence alone. The alarm registry (0.4.1) is
deliberately independent of GregTech integration, so it is built first, not
last.
