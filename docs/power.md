# Plant power policy

How TerraCorp coordinates the staged startup, shutdown, and load shedding
described in `distributed.md` ("The data center uses a dedicated power plant
and UPS…"). Design for 0.5.x; depends on Relay (0.3.2), the alarm channel
(`long-distance.md`), and telemetry (`docs/telemetry.md`).

## The hard constraint first

**OC servers have no remote power-on.** After a world reload a player must
sneak-use each rack server (`distributed.md`). The chunk loader keeps the rack
loaded, but a node that lost power stays down until power returns *if* the
server's power buffer kept the EEPROM alive — otherwise it needs a player.

Therefore the policy coordinates **software**, not electricity: TerraCorp
cannot turn machines on, but it can decide when a powered node is allowed to
boot into full service, when to shed load, and when to alarm.

## States

| State | Meaning | Entry |
|---|---|---|
| `ONLINE` | All nodes serving | Default |
| `DEGRADED` | A node down or a feed lost; sessions/Relay continue | Node offline > 60 s, telemetry stale |
| `SHED` | Load shedding active: workers drained, noncritical terminals refused | UPS charge < 60% (bridge) or operator order |
| `ISLAND` | Grid lost; essentials only: master + storage alive, everything else drained | UPS charge < 30% or `ISLAND` order |
| `BLACKOUT` | Nodes losing power; master closes files and halts | Master's own energy < reserve |

Transitions are one-way toward safety; recovery walks back up in reverse
order. No automatic recovery into a higher state without two consecutive
good samples (10 s apart) — flap protection.

## Who decides

- **Master** runs `tc/plant.lua`, a small state machine ticked once per
  second from the kernel loop (same budget discipline as the TPS sampler).
- Inputs: `computer.energy()` of the master itself (always available), node
  `STATUS` reports, telemetry probes (UPS charge, if the bridge works —
  `telemetry.md`), operator orders (Nodes app button / Terminal
  `plant shed` / `plant island`).
- **Outputs**: Relay jobs (`drain`, `shutdown`), the alarm channel, the
  dashboard banner, the hologram wall (if built, `holo.md`).

## Startup sequencing (after a power event)

The documented order is network → storage → core → workers → terminals,
about 5 s per stage. TerraCorp's role: gate services, not power.

1. Nodes boot headless into a **standby** mode (EEPROM/kernel knows `role`).
   In standby, a node answers `STATUS` and Relay only; it does not claim
   jobs, join the Vault pool, or open sessions.
2. The master promotes nodes stage by stage by publishing a `plant stage`
   job: storage first (Vault disks join), then workers, then terminals
   accept sessions. Each stage requires the previous stage's jobs done.
3. If the master itself was down, it self-promotes last: boot → verify
   index (`vault.md` restore path) → publish stages.

## Shutdown and shedding

- **Shed**: publish `drain` to all workers, refuse new sessions (`TREJECT`
  "plant shedding"), drop the wall to low detail. Vault writes already in
  flight complete; new writes get a clean "vault is shedding" error.
- **Island**: additionally close remote sessions, checkpoint the Vault index
  (force the backup write, `vault.md`), and stop telemetry sampling except
  the power probes.
- **Blackout**: the master flushes logs and the Vault index synchronously
  and stops — `kernel:poweroff` path, never an abrupt halt.

## Alarm channel role

The RC link (`long-distance.md`, ~80 B/s) carries `STATE` frames with the
plant state + power numbers, both directions if the remote base runs its own
plant. Heartbeat: `PING` every 10 s; three misses raise `DEGRADED` locally.
A plant that cannot reach its peer treats the *link* and the *plant* as
separate alarms — never mask one with the other.

## Verification checklist

1. Standby boot: does a node with `role` in config still start all services?
   If yes, the standby gate needs a boot-time flag (`/var/plant.standby`).
2. Energy semantics: does `computer.energy()` on a rack server reflect the
   rack's power buffer? Compare against the rack GUI while draining.
3. Stage timing: measure how long a freshly powered node takes from
   sneak-use to answering `STATUS` (target < 10 s).
4. Relay job latency under shed (jobs still flowing while workers drain).
5. Blackout behavior: pull rack power mid-write; verify the Vault part-file
   rename discipline left no corrupt files and the index survives.

## Sequencing

1. `tc/plant.lua` core (states, orders, dashboard banner) — small, ships
   with 0.5.x after sessions; standby gating can even land in 0.4.x.
2. UPS telemetry inputs — blocked on the gtce2oc verification in
   `telemetry.md`; until then the policy runs on master energy + node
   presence only.
3. Cross-base coordination — rides the RC alarm channel once that link
   is proven (`long-distance.md` exit criteria).

Cross-links: `distributed.md` (policy source), `relay.md`, `vault.md`
(checkpoint), `telemetry.md`, `long-distance.md`.
