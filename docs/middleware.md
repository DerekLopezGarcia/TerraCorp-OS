# TerraCorp Middleware — leaves, gateways and the minimal profile

Status: **design** (0.4.1). The plant runs on **TerraCorp Middleware**: the part
of the OS that exposes components to programs outside the game, with no desktop
and no apps. The desktop build stays for computers with an operator in front.

Name and roles agreed with the pack's co-operator on 2026-11-13.

## Why a separate profile

| Reason | Detail |
|---|---|
| Ticks cost more than code | Component calls cross into the server thread, so the in-world half must do as little as possible |
| Not every computer gets an Internet Card | Cards are limited; only a gateway talks to the outside world |
| Boot must be unattended | Plain OpenComputers computers boot when the world loads; **rack servers do not** — each needs a sneak-use after a reload |
| A rack does not widen reach | A server's internals are `Visibility.Neighbors`: putting something in a rack never lets another computer see it |

So the plant is built from **plain computers**, not rack servers. Racks, Vault,
waves and Relay stay shipped and tested (`0.3.x`) but are **off the plant path**:
they answer density and pooled disks, not component access.

## Two roles

```text
                    ┌──────────────────────── servidor (fuera del juego)
                    │  bridge → plant service → agente MCP
                    │
              HTTP  │
                    ▼
            ┌───────────────┐
            │   gateway     │  internet + wired + wireless
            │  (proxy)      │  merged copy of its leaves
            └───┬───────┬───┘
        TC1     │       │      TC1
        ┌───────▼──┐  ┌─▼────────┐
        │  leaf    │  │  leaf    │   wired only, components only
        │ (proxy)  │  │ (proxy)  │
        └──────────┘  └──────────┘
```

| Role | Cards | Does | Does not |
|---|---|---|---|
| **Leaf** | wired network card | Owns its components: reads them, sets redstone, moves items on command, keeps its local registry copy | Talk to the outside world, hold plant logic |
| **Gateway** | internet + wired + wireless | The only HTTP egress; forwards frames to its leaves; merges their registry copies; serves the tablet over wireless | Read components it cannot see, decide anything |

Each computer runs a **proxy**: the local authority for its own addresses and
paths, a translator from named requests to component calls, and a **driver
registry** so a component kind the pack invents tomorrow can be registered as
data instead of patched into the kernel ([`drivers.md`](drivers.md)).

## Two transports, one verb set

The same verbs travel both legs: `component.*`, `path.*`, `move`, `gate.set`.

- **Upstream (gateway ↔ service)**: HTTP through the bridge, one POST per
  interval, 1 KB frames, bodies sliced with `LREP`/`LDATA`/`LEND`.
- **Downstream (gateway ↔ leaf)**: `tc.net` TC1 frames over the wired network.

The gateway is a **dumb proxy**: match the target node in the address, forward,
collect, return. No queue, no retry policy, no plant semantics — anything
cleverer here is the brain leaking back into the game.

## The bandwidth budget, with numbers

From `docs/opencomputers.md`: the pack allows 8192-byte packets, and the rack's
built-in switch is tier 1 — **one packet per five ticks, queue of 20**, so about
four packets per second through a switch.

| Consequence | Rule |
|---|---|
| A 50 KB snapshot takes ~12 s through a tier-1 switch | Leaves **aggregate** and send **deltas**, never full dumps through a gateway |
| Requests are cheap, replies are not | Ask for what changed, not for everything |
| Two gateways halve the traffic | Split by physical segment, not by plant function |

This is the same conclusion the cache rules reached, now with a number attached:
**the network inside the game is the scarce resource, not the CPU**.

## Registry: authoritative locally, merged outward

| Level | Authority | Holds |
|---|---|---|
| Proxy (leaf) | **Authoritative** | Its addresses, faces, `first_seen`, the paths mentioning them |
| Gateway | Merged copy | Its leaves' views, refreshed on change and on a slow heartbeat |
| Service | Combined copy | Every gateway's view — what apps and the agent resolve against |

Merging is one-directional and idempotent: leaves report, gateways merge,
service merges. Nothing publishes back down except commands.

## The tablet

A tablet is a computer with a **wireless** network card; leaves are wired, so a
tablet cannot reach them directly. The gateway therefore carries **wireless as
well as wired**, which makes it the single ingress for both the outside world and
the operator's tablet.

That is convenient and risky in the same breath: one gateway per segment means
one failure domain. Two gateways on the same segment are fine — the service
merges both copies and marks a duplicate path as `cardinality_mismatch` only when
the declared cardinality says `single`.

## Failure semantics

| Event | What happens |
|---|---|
| Leaf down | Its members go `unbound`; paths keep resolving with the rest; the service sees silence from that proxy |
| Gateway down | That segment goes invisible to the app; the service marks every path from it `stale` rather than dropping it |
| Service down | Proxies keep serving their copies and holding gate setpoints; nothing is decided |
| Tablet disconnected | Registration waits; the plant is unaffected |

## What this profile must never grow

No recipes, no thresholds, no alarm text, no planner, no job queue, no UI. The
moment one of those appears in the world, the tick budget argument dies and the
brain has leaked back into the game (decision 16).

## Verification checklist

1. Middleware boots with **no GPU** on a plain computer, and after a world reload
   without a sneak-use.
2. Memory footprint of a leaf: target as small as a bare kernel plus the
   registry and the driver table; measure it, do not assume.
3. `driver.dump` on a sign and on a chest, then a descriptor for each: the point
   is that a new kind is a file plus a reload, not a kernel change.
3. TC1 round trip leaf → gateway → service and back, with a 200-byte request.
4. With only a tier-1 switch between them, measure how long a 4 KB body takes to
   cross: the 12 s figure above should be replaced by a measurement.
5. Tablet over the wireless bridge: unclaimed list, assign a path, see it in the
   combined view.
6. Only the gateway has an Internet Card; a leaf with none still serves reads.
7. One gateway per segment at first; then add a second and confirm the merged
   copy is identical.

## Sequencing

1. `middleware` profile in the kernel: headless, registry, no apps — 0.4.1.
2. Proxy verbs and the TC1 leg — 0.4.1.
3. Gateway merge and the service ingest — 0.4.1/0.4.4.
4. Then stock reading, gates and `move` on top (0.4.2-0.4.6).

Cross-links: [`names.md`](names.md) (addresses and paths),
[`plant-service.md`](plant-service.md) (combined view), `docs/opencomputers.md`
(verified mod facts), `docs/cluster.md` (rack facts, now off the plant path).
