# Automated crafting orchestration (Yordi111 requirement)

Automate crafting across multiple GregTech machines, each fed by an **input
buffer** and drained to an **output buffer**, with stock readable either by
**redstone** (comparator) or by an **Adapter on a drawer**. This is a
logistics requirement from field operations — TerraCorp becomes the brain
that decides what to feed, when, and raises alarms when it jams.

Target: 0.5.x `tc/craft` on a dedicated worker node in the crafting hall.
Design; every "verify" item needs the in-game probe before implementation.

## Architecture

The crafting hall is its own wired segment with one TerraCorp node (worker
role). It must work **standalone** (local brain + local stock readings) and
report upward; it must not depend on the master being online to keep
crafting.

```text
[drawer/buffer IN] ──(transposer)──> [GT machine(s)] ──> [buffer OUT]
        │                (self-processing)              │
   adapter/redstone                              adapter/redstone
        └─────────────── tc/craft node ─────────────────┘
                     │
                Relay ──> master (jobs, telemetry, alarms)
```

- **Input path**: OC **transposer** pulls recipe ingredient stacks from the
  input buffer (chest/drawer) and pushes them into the machine's input hatch
  side. The machine self-processes (GT multiblocks run their own logic); we
  only feed and observe.
- **Output path**: machine auto-ejects to the output buffer (GT machine
  output configuration), or the transposer extracts on completion.
- **Stock sensing**: two options per buffer, configured per site:
  1. **Redstone**: comparator on the buffer, Redstone Card reads strength.
  2. **Adapter + drawer**: if Storage Drawers exposes an inventory component
     through the OC Adapter, read exact counts.

## Per-machine contract (config, not code)

`/etc/craft.tsv` — one line per machine:

```
name, machine-side, recipe-id, ingredient slots+counts, batch size,
stock-in low/high thresholds, stock-out low/high thresholds, input method
```

- `tc/craft` loops: read out-buffer stock → below low threshold and in-buffer
  has ingredients → dispatch one batch → wait for out-stock to rise or a
  completion signal → repeat. Hysteresis between low/high prevents flapping.
- Multiple machines = independent loops over one shared input buffer, with a
  per-ingredient reservation so two machines do not race the same stack.

## Failure semantics

- **Out-buffer full** (high threshold): stop feeding that machine; keep
  reading. If it stays full beyond a timeout → `JAMMED` alarm (Relay + RC
  `STATE` frame + dashboard).
- **In-buffer empty at low in-stock**: `STARVED` alarm (logistics problem,
  Yordi's side), crafting pauses for that recipe only.
- **Machine stopped mid-batch** (no progress over N seconds while powered):
  `STALLED` alarm; the loop must not double-feed to "fix" it.
- Every state change is idempotent: the loop re-derives everything from
  stock readings, never from an assumed in-flight count. After a reboot the
  first tick reconciles from scratch.

## Integration

- **Relay**: a `craft` job type (`recipe`, `count`) lets the master or any
  terminal request batches; the node claims it like any Relay job.
- **Telemetry** (`telemetry.md`): out-stock levels are the first real
  telemetry consumers; the same probes feed the dashboard and hologram wall.
- **Names** (`names.md`): buffers and machines get stable names
  (`ebf.in`, `ebf.out`) so the config survives card swaps.

## Verification checklist (one session in the crafting hall)

1. **Drawer + Adapter**: does `component.list()` next to an Adapter facing a
   Storage Drawer expose an inventory component? Record the kind and the
   read methods (`getStackInSlot`? sizes? exact counts per drawer slot?).
2. **Comparator on drawer/buffer**: what strength maps to what fill fraction
   (is it linear per drawer slot, per total capacity, or top-slot only)?
   Record the mapping — the redstone path needs an exact table.
3. **Transposer into GT**: can a transposer push into a machine's input hatch
   (bus side)? Which side? Does it respect GT bus slot filters?
4. **Machine auto-output**: confirm the machine can eject to the out-buffer
   without transposer help; if not, add extraction to the loop.
5. **Throughput**: measure ticks per insert operation and per stock read —
   the loop budget is one pass per second at most.
6. **Redstone Card limits**: bundled vs single-wire reading on the pack's
   card tier; how many buffers can one card watch (one per side = 6)?

## Recommendation

Build in two slices:

1. **Stock reader first** (adapter or comparator): a `stock` Relay built-in
   task + dashboard tile. Useful even before any crafting automation, and it
   de-risks sensing, the least certain part.
2. **Feeding loop second**: one machine, one recipe, end to end; then scale
   to multi-machine by adding contract lines, not code.

Cross-links: `distributed.md` (worker role), `telemetry.md` (probes),
`names.md` (stable buffer names), `relay.md` (jobs), `long-distance.md`
(alarm path).
