# Craft orchestration: stock-limited feeding (Yordi111 requirement)

Automate feeding of crafting machines — **any machine or machines on the
segment** (today: vanilla-style logic + redstone contraptions; later possibly
GregTech). The control law is simple and machine-agnostic:

> Read the stock of the **output buffer**; feed ingredients into the
> **input buffer** only while output stock is below its limit.

TerraCorp's role: the stock-limited feeder. The machines keep their own logic;
we read, decide, gate, and alarm. Target: 0.5.x `tc/craft` on a worker node in
the crafting hall. Design; "verify" items need in-game probes.

## Architecture

```text
                     redstone gate (enable feed)
  [buffer IN] ────────────────┐
   hoppers/pipes ──> [machine(s) — own internal logic] ──> [buffer OUT]
                                                              │
                                        stock sensing: comparator or adapter
                                                              │
                                    ┌─────────────────────────┘
                              tc/craft node (worker role)
                                   │ Relay: jobs, telemetry, alarms
```

Two control modes, configurable per line in `/etc/craft.tsv`:

- **Gate mode** (today's build): feeding is passive (hoppers/pipes already
  installed); TerraCorp holds a redstone **enable line** (Redstone Card
  output): high while `out-stock < limit`, low otherwise. The machines never
  change; the OS just closes the tap.
- **Push mode** (optional later): an OC **transposer** moves ingredient
  stacks from the input buffer into the machine when a batch is due. More
  control, more moving parts — only if gate mode proves insufficient.

## Control law

Per production line (one line = one in-buffer, N machines, one out-buffer):

```
every tick-budget pass (≤ 1 Hz):
  s_out = read out-buffer stock        (comparator table or adapter count)
  s_in  = read in-buffer stock         (same sensors, optional)
  if s_out < low:  gate on
  if s_out > high: gate off            (hysteresis: low < high)
```

- Hysteresis prevents tap flapping on noisy comparator readings.
- `s_in` is not needed to *decide*, but gives the `STARVED` alarm: gate on +
  in-buffer low for > T means logistics must restock (Yordi's side).
- Multiple lines on one node are independent loops over one card (one
  redstone line per side; a card exposes 6 sides — bundled wire removes the
  limit, verify availability).

## Stock sensing (the uncertain part)

| Sensor | What to verify |
|---|---|
| Comparator on a chest/barrel | Strength→count mapping is nonlinear for containers with many slots; build the exact table per buffer type |
| Comparator on a drawer | Is it per-slot, per-drawer fraction, or total capacity? May differ per drawer type |
| **Adapter + drawer** | Does `component.list()` expose an inventory component for Storage Drawers? Exact counts would make the comparator table unnecessary |
| Redstone Card | Single-wire vs bundled reading; how many buffers per card |

Prefer the adapter path when it works; redstone comparators are the
always-works fallback, at 0–15 resolution (a 15-step stock scale is plenty
for "limit the input" — exact counts are a bonus, not a requirement).

## Failure semantics

- **Out full** past timeout with gate already off → the *machine* is jammed,
  not the feeder: `JAMMED` alarm (Relay + RC `STATE` + dashboard).
- **Gate on + in-buffer low** → `STARVED` alarm; gate stays on (do not
  compound one shortage with a stopped line).
- **Stock reading stale** (no change for N passes while gate on) → `STALLED`
  alarm; nothing is auto-fed to "fix" it.
- All decisions re-derive from fresh readings every pass; after a reboot the
  first pass reconciles (gate state = f(current stock)). No in-flight
  counters anywhere.

## Integration

- **Relay**: `stock` built-in task (read and report named buffers) and a
  `craft limit` order (`set low/high` live) from any terminal.
- **Telemetry** (`telemetry.md`): buffer levels are the first probes; the
  dashboard and the hologram wall (`holo.md`) render them as bars.
- **Names** (`names.md`): `craft1.in`, `craft1.out` — config survives card
  and buffer swaps.
- Standalone rule: the loop must run with the master offline; only alarms
  and remote orders need the link.

## Verification checklist (crafting hall session)

1. Comparator tables for the actual buffer types in use (chest, barrel,
   drawer): record strength→count curves.
2. Drawer + Adapter component probe: kinds, read methods, exact counts.
3. Redstone Card: does gate mode work with the existing hopper feed (gate
   low truly stops insertion)? Bundled wire support?
4. One card, several lines: sides available after machines' own redstone.
5. Loop cost: sensor reads + gate writes per pass at 1 Hz — confirm the
   worker node's budget holds alongside Relay duty.

## Recommendation

Ship in two slices:

1. **Stock reader** (task `stock` + dashboard tile): useful immediately,
   de-risks sensing before any control code.
2. **Gate loop**: one line end-to-end; scale by config lines, not code.

Cross-links: `distributed.md` (worker role), `telemetry.md`, `names.md`,
`relay.md`, `long-distance.md` (alarm path).
