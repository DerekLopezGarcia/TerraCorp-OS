# Plant service — the brain outside the game (0.4)

Status: **design**. This document is the other half of F3: [`roadmap.md`](roadmap.md)
splits the plant into an in-game **translator** (names, component calls, cache,
gate reconciliation) and this service (recipe book, planner, history, alarms,
panel).

Decision 14 in the roadmap: **the brain lives outside the world**; decision 16
makes the in-world half a translator, not a smaller copy of the brain.

## Why the split exists

| Constraint | Consequence |
|---|---|
| The Internet Card only makes outbound requests; there are no inbound ports | The OS is always the client: it polls and collects queued work. "Receive a message" means *poll* |
| `linkInterval` is 5 s by default and 10 s in the checklist | A control loop driven from outside is blind between messages — the fast loop cannot live here |
| 1 MB of memory and no shared RAM | The recipe book, the sample history and the planner would eat the budget the kernel needs |
| Only the computer next to a component can read it | Sensors and redstone gates cannot move out; they are physical |
| The recipe book and the planner iterate constantly | Editing files and restarting a service beats flashing a disk inside Minecraft |

The split follows from those five facts, not from taste.

## What each side owns

| Layer | Lives in | Owns |
|---|---|---|
| **Proxies** | TerraCorp Middleware, in the world ([`middleware.md`](middleware.md)) | Turning addressed requests into component calls: inventory and tank reads, redstone writes, transfers, the cached answer, the last desired gate state. Each proxy is **authoritative for its own components and paths**; the gateway merges its leaves |
| **Combined view** | This service | The merge of every gateway's registry — one tree of semantic paths over addresses, refreshed one-directionally |
| **Brain** | This service | Recipe book, chains, rates, bottleneck, history, alarms, panel, cross-hall coordination — exposed to the operator agent as MCP tools ([`agent.md`](agent.md)) |
| **Operator** | The agent, and a human behind it | The agent decides goals and priorities through those tools; the human sets goals and approves structural changes |

Rule of thumb: **the proxies translate, the service thinks, the agent decides.**
Nothing in the world knows what a recipe is, what a bottleneck is, or what an
alarm means. A proxy knows addresses, faces, paths, methods and a cache.

The app's job is exactly what the co-operator described: **execute calls on the
components it wants**, through paths that the registry resolves. The registry is
merged outward (proxy → gateway → service) and never written back down except as
commands.

### The node is a translator, not a plant computer

The concern that drives this is the Minecraft server's tick budget, and it is
the right one: component calls cross into the server thread, so *how often* the
node calls a component costs more than *how clever* the code around it is.

| Rule | Why |
|---|---|
| **Read on demand**, never on a fixed global timer | The brain asks when it needs numbers; idle halls cost nothing |
| **Batch inside the node** | 200 individual round-trips over a 5-10 s poll is impossible; one `stock.snapshot` that walks the containers locally is one command |
| **Trickle across ticks** with a per-tick call budget | A 200-container scan spread over a few seconds never spikes the server |
| **Cache and serve** | A repeat read of an unchanged container is a cache hit, not a component call |
| **Silent when idle** | No command queued and no scan due means the node's tick does nothing |
| **Allowlist, not reflection** | The node exposes named verbs and an allowlisted set of component kinds; it never grows into a generic `invoke anything` |
| **No plant UI in the world** | Rendering the plant on a 40x16 screen burns GPU work nobody needs; the panel is outside |

Interlocks still exist, but they run on **cached state only**: the node refuses a
gate command that contradicts the last reading it already has, and never
triggers an extra component read to decide. Safety must not cost ticks.

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
inside "translator" because the service still decides *what* the limit is.

## The protocol between them

The transport is the external link ([`external-link.md`](external-link.md)):
one POST per interval, results down, commands up, 1 KB per frame. This service
adds commands to the closed set and never carries code.

### Commands the service can send (new, 0.4)

| Command | Tier | Arguments | Returns |
|---|---|---|---|
| `component.list` | read | — | Components on this proxy: address, kind, face, `first_seen`, paths |
| `component.unclaimed` | read | — | Seen but not in any path, newest first |
| `path.list` | read | — | Paths on this proxy with member counts and declared cardinality |
| `path.query` | read | `path` (wildcards allowed) | The resolved set: addresses, kinds, states; `unreachable_members` when part of it lives elsewhere |
| `path.assign` | **write** | `path`, `address`, `cardinality?` | The updated entry, validated against `component.list()` |
| `stock.snapshot` | read | `paths?` | Full listing, sliced: `kind`, `key`, `count`; internal trickle budget |
| `stock.delta` | read | `cursor` | Entries changed since the cursor, plus the new cursor; `reason=resync` when it is too old |
| `move` | **write** | `from`, `to`, `n`, `key`, `member?`, `policy?` | `moved=<n> slots=<k>` per member, or `moved=0 reason=<why>` |
| `line.list` | read | — | Lines the proxy can drive: path, gate address, last cached levels |
| `gate.set` | **write** | `line`, `state` (`open`/`closed`) | `state=<actual>`, or `refused reason=<why>` from the cache |
| `node.status` | read | — | Version, uptime, memory, energy, link health, cache age — cheap, no component scan |

Every verb speaks **semantic paths**; the registry resolves them to physical
addresses (`node:component:face`) before a proxy touches anything
([`names.md`](names.md)). A frame never carries a path the target cannot resolve:
`unknown_path` comes back instead.

`gate.set` is actuation, so it requires `linkControl = write` at minimum. With
`off`, the node reports and refuses to move anything.

`node.status` replaces the local alarm registry that an earlier draft put in the
world: energy and liveness are cheap reads, and **interpreting** them is the
service's job, not the node's.

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

A hall with 400 item types does not fit 1 KB. The first `stock.snapshot` is
paged through the existing `LREP`/`LDATA`/`LEND` slicing; after that,
`stock.delta cursor=N` carries only what changed. The node keeps a ring buffer
of changes; when the cursor falls out of it, the answer is `reason=resync` and
the service asks for a snapshot again. **A snapshot that silently truncates is
worse than no snapshot**: the service would plan against imaginary stocks.

Sequence numbers on every body let the service drop duplicates after a retry.

### Who owns which config

| Fact | Lives in | Why |
|---|---|---|
| Which gate address is line `craft1` | The node (`/etc/lines.tsv`) | It is hardware, and only that node knows its components |
| Which recipe a line runs, its limits and priority | This service | It is planning, and it changes while the world runs |
| Item keys | Both, identical | The service keys off the identifiers the node reports (see [`recipes.md`](recipes.md)) |

The join key is the **line name** and the **item key**. A name that exists on
one side and not the other is reported as `unknown_line` or `unknown_key`,
never guessed. That mismatch alarm is how a config drift is caught before it
becomes a wrong plan.

## What the service computes

- **Stocks** per hall and per named stock, with rates (items/min, mB/min) from
  its own sample history — the OS sends samples, the service keeps time.
- **Plant alarms**: `STARVED`, `FULL`, `STALLED`, `TREND`, plus chain-level
  ones the OS cannot know: "hall A waits on hall B", "this plan needs a
  byproduct we cannot supply".
- **Recipes, lines and plans** as specified in [`recipes.md`](recipes.md),
  computed here and not on the master.
- **Everything an alarm means.** The node reports energy, uptime and cache age;
  thresholds, severity, grouping and naming are decided here.
- **Panel**: one page with the plant state, the bottleneck named by step, and the
  alarm list.

## Failure semantics

| Event | What happens |
|---|---|
| Service or bridge down | Nodes keep the last setpoints; nothing is raised in the world, and the panel shows `stale since <t>` for every hall. A plant with no brain holds position, it does not improvise |
| Node reboot | Desired states restored from `/var/gates.tsv`; the service sees a fresh sequence and re-syncs by cursor |
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
- `linkControl` is the blast radius. A hall that only watches runs with `off`.

## Out of scope

- **Moving items.** The service sets gates and asks for readings; the pack's
  pipes and hoppers move goods (decision 10).
- **Reading the world directly.** No Minecraft mod API, no second connection to
  the game. If the node cannot see it, the service does not know it.
- **Automatic recipe import.** The book stays declared and calibrated
  (decision 13).
- **Replacing the OS UI.** The desktop keeps its local screens; the panel is
  where the plant is operated.

## Verification checklist

Out of game:

1. Bridge reachable from the world host on loopback; `/link/state` answers.
2. `stock.snapshot` of a hall with ~50 types: measure body size, slice count,
   wall-clock time for the full paging, and the node's per-tick call budget.
3. `stock.delta` across ten intervals: entries match the node's own log.
4. Kill the service mid-run: gates keep their last state for 10 minutes, the
   node keeps its cache, and nothing in the world spins.
5. Kill the node (reboot): the service shows a gap, then resumes by cursor.
6. Force a cursor expiry: the node answers `resync`, the service re-pages the
   snapshot without duplicating history.
7. Refusal path: ask a full output to open, confirm `refused` from the cache
   plus the alarm after the configured retries.
8. Idle cost: with no command queued, the node's tick performs no component call
   (verify with a counter in `tc.log`).

In game, in the probe session:

9. The loopback HTTP path works from the world host (F3 probe).
10. Cost of one real snapshot of a hall on a Tier 2 node: no visible drop in the
    TPS sampler while the trickle runs.

## Sequencing

| Slice | Where | Content |
|---|---|---|
| 0.4.1 | Proxies + service | Addressing and paths, the middleware profile (leaf and gateway), merged registry, `node.status`; service skeleton, ingest, alarm engine, panel |
| 0.4.2 | Proxies + service | Batch scan with trickle and cache; `stock.snapshot`/`stock.delta`; history |
| 0.4.3 | Node + service | Tanks, same shape |
| 0.4.4 | Service | Rates, limits and plant alarms |
| 0.4.5 | Service | Recipe book, chains, bottleneck, shortfall |
| 0.4.6 | Node + service | `gate.set`, cached interlocks, setpoint persistence, refusals |
| 0.4.7 | Service | Read-only MCP surface for the agent ([`agent.md`](agent.md)) |

F7 then builds restock orders and cross-hall coordination on top, and the wall
([`holo.md`](holo.md)) renders what the panel already knows.

Cross-links: [`external-link.md`](external-link.md) (transport and verbs),
[`middleware.md`](middleware.md) (leaf, gateway, bandwidth), [`names.md`](names.md)
(addresses and paths), [`agent.md`](agent.md) (decision layer),
[`recipes.md`](recipes.md) (book and planner), [`crafting.md`](crafting.md) (gate
loop and its interlocks), [`roadmap.md`](roadmap.md) (F3 split, decisions 14-21),
[`power.md`](power.md) (plant policy consumes the same data).
