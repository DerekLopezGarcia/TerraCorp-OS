# Plant service — the optional brain outside the game (0.4)

Status: **design; optional after the 0.4.2 mirror**. This is the other half of F3:
[`roadmap.md`](roadmap.md) splits the plant into an in-game **readout** (names,
component calls, cache, level alarms, Plant app) and this service (long history,
reference dataset, planning at scale, MCP agent). Decision 23 (2026-11-15)
amends the original decision 14: **the first number never waits for the bridge.**
With 64 MB in the computer, the operated book and a short history fit; the
service is no longer a precondition for the readout.

## Why the split exists

| Constraint | Consequence |
|---|---|
| The Internet Card only makes outbound requests; there are no inbound ports on a stock server (TCP availability is [pending verification](external-link.md#what-opencomputers-allows)) | A service outside is always the client: it polls and collects queued work. The OS does not need it to read |
| `linkInterval` is 5 s by default and 10 s in the checklist | A control loop driven from outside is blind between messages. The fast loop (gates, level alarms) lives in the OS |
| 64 MB now, 1 MB when this was written | The operated book and a short sample ring fit in the OS; the full reference dataset and months of history do not |
| Only the computer next to a component can read it | Sensors and gates cannot move out; they are physical |
| The reference book and the planner iterate constantly | Editing files in the service still beats flashing a disk, but only when the book outgrows the node |

The split is a **gradient, not a wall**: the OS does the readout and the fast
loop; the service does the long memory and the heavy book.

## What each side owns

| Layer | Lives in | Owns |
|---|---|---|
| **OS readout** | The plant computer, in the world | The **line boundary stocks**, cache, **local level alarms**, the **Plant app**, gates, the last desired state, a bounded sample ring |
| **Service** | Outside the game | Long history and rates beyond the ring, the reference dataset, planning at scale, cross-hall alarms, the MCP tool surface, an optional remote panel |
| **Agent** | The decision layer | Goals, priorities, sequencing through tools; never arithmetic |

Rule of thumb: **the OS reads and shows, the service remembers and plans at
scale, the agent decides.** Nothing in the world needs the service to display a
stock; nothing outside can read a component the OS cannot see.

The app's job is exactly what the co-operator described: **execute calls on the
components it wants**, through paths that the local registry resolves. The
registry is authoritative on the computer; the service's merged view is a copy,
never a write-back.

### The node is a reader first, a translator second

The concern that drives this is the Minecraft server's tick budget: component
calls cross into the server thread, so *how often* the node calls a component
costs more than *how clever* the code around it is.

| Rule | Why |
|---|---|
| **Read on demand**, never on a fixed global timer | The app and the service ask when they need numbers; idle halls cost nothing |
| **Batch inside the node** | 200 individual round-trips over a 5-10 s poll is impossible; one `plant.snapshot` that walks the containers locally is one command |
| **Trickle across ticks** with a per-tick call budget | A 200-container scan spread over a few seconds never spikes the server |
| **Cache and serve** | A repeat read of an unchanged container is a cache hit, not a component call |
| **Silent when idle** | No command queued and no scan due means the node's tick does nothing |
| **Local level alarms only** | `STARVED`, `FULL`, `NO POWER`, `STALE`, `UNBOUND` evaluate the cache; no extra component call, no extra read |
| **No cross-hall policy** | Rates, recipes, thresholds that span halls and alarm interpretation stay in the service |
| **Allowlist, not reflection** | The node exposes named verbs and an allowlisted set of component kinds; it never grows into a generic `invoke anything` |
| **The app draws, the headless node does not** | A plant computer with a screen runs the Plant app; a headless hall computer serves snapshots and skips the GPU |

### Lines are black boxes

A line exposes exactly two boundary stocks: the **input** buffer and the
**output** buffer. Transposers sit only there; the machines, pipes and internal
buffers between them are opaque to the OS. The reader never reads a bender or
assembler buffer, and the line's recipe/rate comes from the boundary deltas
(decision 24). This is why a line stays observable without Adapters, and why
`getProgress` is diagnostics, not readout.

### The local guard (the one exception, and why)

A hard output limit cannot be enforced from a 5-10 s poll: a fast line would
overshoot by thousands of items between two messages. So a `gate.set` may carry a
**guard**: a tiny, fixed expression over the cached reading, e.g.
`max_resident=<count>` or `min_input=<count>`. The node evaluates it each tick
against the cache it already holds and closes the gate itself when the guard
trips.

That is deliberately not a scripting language: one numeric comparison per line
against one cached quantity, no expressions from outside, no new reads. It is
the smallest amount of in-world logic that keeps a limit honest, and it stays
inside "reader" because the service still decides *what* the limit is.

## The protocol between them

The transport is the external link ([`external-link.md`](external-link.md)):
one POST per interval, results down, commands up, 1 KB per frame. The link
carries the **plant readout**, not component addresses: the service never needs
a UUID to show a stock.

### Commands the link exposes (0.4.2+)

| Command | Tier | Slice | Arguments | Returns |
|---|---|---|---|---|
| `plant.status` | read | 0.4.2 | — | Version, uptime, memory, energy, link health, cache age, hall list |
| `plant.snapshot` | read | 0.4.2 | `hall?`, `stocks?` | Paged stock/tank/energy snapshot; `kind`, `key`, `count`, `state` |
| `plant.delta` | read | 0.4.2 | `cursor` | Entries changed since the cursor plus the new one; `reason=resync` when it expired |
| `plant.alarms` | read | 0.4.2 | `since?` | Local level alarms with severity, source, first/last seen and ack state |
| `gate.set` | **write** | 0.4.6 | `line`, `state` (`open`/`closed`) | `state=<actual>`, or `refused reason=<why>` from the cache |
| `move` | **write** | 0.4.6b | `from`, `to`, `n`, `key`, `member?`, `policy?` | `moved=<n> slots=<k>` per member, or `moved=0 reason=<why>` |

`component.list`, `path.list`, `path.query`, `path.assign`, `driver.*` and
`node.status` are **local** in 0.4.1: the Plant app calls them in-process, and
the link does not need them. They can join the link later if a remote editor
needs them.

Every plant verb speaks the names the OS already knows; a stock name the node
does not have answers `unknown_stock`, never a guess.

### Desired state, never toggles

On a polled transport with retries, `gate.toggle` is a bug waiting to happen: a
duplicated request opens what should be closed. So:

- The service sends the **desired state** of a line, not an action.
- The OS stores it in `/var/gates.tsv`, reconciles every tick, and reports the
  **actual** state and the last refusal reason.
- After a reboot the OS restores its desired state from disk and reconciles
  without asking anyone. A dead service means "hold the last setpoints", never
  "stop the plant".

### Snapshots and deltas

A hall with 400 item types does not fit 1 KB. The first `plant.snapshot` is
paged through the existing `LREP`/`LDATA`/`LEND` slicing; after that,
`plant.delta cursor=N` carries only what changed. The node keeps a ring buffer
of changes; when the cursor falls out of it, the answer is `reason=resync` and
the service asks for a snapshot again. **A snapshot that silently truncates is
worse than no snapshot**: the service would plan against imaginary stocks.

Sequence numbers on every body let the service drop duplicates after a retry.

### Who owns which config

| Fact | Lives in | Why |
|---|---|---|
| Which containers make a stock | The node (`/etc/stocks.tsv`) | It is hardware, and only that node knows its components |
| Local level thresholds | The node (`/etc/plant.tsv`) | The app must alarm with the bridge down |
| Which gate address is line `craft1` | The node (`/etc/gates.tsv`) | It is hardware |
| Which recipe a line runs, limits, priority at scale | The service (or the local book in 0.4.5) | Planning; it changes while the world runs |
| Long history and the reference dataset | The service | They do not fit the node |
| Item keys | Both, identical | The service keys off the identifiers the node reports (see [`recipes.md`](recipes.md)) |

The join key is the **line name** and the **item key**. A name that exists on
one side and not the other is reported as `unknown_line` or `unknown_key`,
never guessed. That mismatch alarm is how a config drift is caught before it
becomes a wrong plan.

## What the service computes

- **Long history**: rates (items/min, mB/min) and trends beyond the OS ring,
  computed from the line boundary deltas and kept with retention the node cannot
  hold.
- **Cross-hall alarms**: "hall A waits on hall B", "this plan needs a byproduct
  we cannot supply" — the ones the node cannot know.
- **Recipes at scale**: the reference dataset, more recipes than fit the node,
  the optimizer if it is ever needed.
- **MCP tools**: the read-only surface 0.4.7 exposes to the local agent.
- **An optional remote panel**: the Plant app already shows the local hall; the
  service panel adds the merged, long-history view.

## Failure semantics

| Event | What happens |
|---|---|
| Service or bridge down | The OS keeps reading, alarming and showing its own hall; gates keep their setpoints; the mirror is `stale since <t>` |
| Node reboot | Cache rebuilt from the containers; desired states restored from `/var/gates.tsv`; the service sees a fresh sequence and re-syncs by cursor |
| Cursor too old | `resync`, full snapshot, paginated; no partial plan |
| Repeated refusal | The node refuses with a reason N times from its cached reading, the service raises `DISOBEDIENT LINE` and stops resending until a human looks — silent retries hide a broken interlock |
| Token rotation | Rotate on the node first (`/etc/terracorp.cfg`), then the service; the bridge accepts the old token for one interval to avoid a gap |
| Clock | The node reports monotonic uptime, the service stamps arrival; no wall-clock trust in either direction |

## Security posture

This service is plant control, so it is treated as production:

- Token in the frame, link encrypted (loopback now; WireGuard or TLS when the
  bridge leaves the machine — see [`external-link.md`](external-link.md)).
- The bridge binds to loopback or the tunnel address, never `0.0.0.0`.
- Every `gate.set` is logged with the service action id that caused it, on both
  sides: the node writes its `tc.log` line, the service writes its own.
- `linkControl` is the blast radius. A hall that only watches runs with `read`.

## Out of scope

- **Moving items.** The OS `move` performs the transfer; the service asks for it
  (decision 10).
- **Reading the world directly.** No Minecraft mod API, no second connection to
  the game. If the node cannot see it, the service does not know it.
- **Machine progress.** A line is a black box: its internal buffers and
  `getProgress` are diagnostics, not plant signals (decision 24).
- **Automatic recipe import.** The book stays declared/imported/measured, never
  auto-trusted (decision 13).
- **Replacing the Plant app.** The local app is the primary UI; the service
  panel is optional and only adds the merged view.

## Verification checklist

Local readout (no service):

1. One line with an input stock, an output stock, a tank and an energy source:
   exact counts match a hand count; the machine buffers in between are not read;
   a removed boundary container goes `unbound`/`coarse`, not zero.
2. Idle cost: with no command queued, the node's tick performs no component call
   (verify with a counter in `tc.log`).
3. Pull a drawer: `STARVED` appears within one polling cycle and clears on
   refill.
4. Reboot: the app reloads the cache and the gates keep their desired state.
5. The ring: the oldest samples drop first; the file never grows without a cap.

Link and service:

6. `plant.snapshot` of a hall with ~50 types: body size, slice count, wall-clock
   time, and the node's per-tick budget.
7. `plant.delta` across ten intervals matches the node's own log.
8. Kill the service mid-run: the app keeps showing, gates hold, and the mirror
   goes stale; nothing in the world spins.
9. Kill the node (reboot): the service shows a gap, then resumes by cursor.
10. Force a cursor expiry: `resync`, no duplicate history.
11. Refusal path: ask a full output to open; `refused` from the cache plus the
    alarm after the configured retries.
12. In game: the loopback HTTP path works from the world host, and a real
    snapshot on a Tier 2 node shows no visible TPS drop while the trickle runs.

## Sequencing

| Slice | Where | Content |
|---|---|---|
| 0.4.1 | OS | Local registry, readers, cache, level alarms, Plant app, `node.status` |
| 0.4.2 | OS + bridge | `plant.status/snapshot/delta/alarms`; the mirror |
| 0.4.3 | OS | Second hall, `halls.tsv`, merged view; no gateway |
| 0.4.4 | OS | Bounded ring, rates, `STALLED`/`TREND`; long history stays optional |
| 0.4.5 | OS (+ service) | Local book and `plan()`; the reference dataset/optimizer outside |
| 0.4.6 | OS | `gate.set`, local interlocks, setpoint persistence, refusals; `move` |
| 0.4.7 | Bridge/service | Read-only MCP over the mirror |

F7 then builds restock orders and cross-hall coordination on top, and the wall
([`holo.md`](holo.md)) renders what the panel already knows.

Cross-links: [`external-link.md`](external-link.md) (transport and verbs),
[`middleware.md`](middleware.md) (the multi-hall profile, deferred),
[`names.md`](names.md) (addresses and paths), [`agent.md`](agent.md) (decision
layer), [`recipes.md`](recipes.md) (book and planner), [`crafting.md`](crafting.md)
(gate loop and its interlocks), [`roadmap.md`](roadmap.md) (decision 23),
[`power.md`](power.md) (plant policy consumes the same data).
