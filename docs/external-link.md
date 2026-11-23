# External Link

Status: **phase 1 and 2 implemented**, merged for 0.3.20. What exists today:

| Piece | Where |
|---|---|
| OS client, state machine, command set | `src/lib/tc/link.lua` |
| Verbs `LINK`, `LREP`, `LDATA`, `LEND` | `src/lib/tc/net.lua` |
| Keys `linkSink`, `linkToken`, `linkInterval` | `src/lib/tc/config.lua` |
| Start after first render, one step per frame | `src/boot/kernel.lua` |
| Bridge | `tools/bridge/bridge.js` |
| Operator window: state, sink, token, tier | `src/apps/gaia.lua` |
| Gate | `npm run test:link` (48 scenarios), `npm run test:bridge` and `npm run test:gaia` |

0.4.2 adds the plant readout verbs below. The local **Plant** app does not need
the link, and the link does not need the service: the four verbs read the
service cache, so a missing bridge leaves the readout untouched.

**2026-11-16: a second transport is decided, not built** ([`sidecar.md`](sidecar.md)).
Option A stays shipped and stays the default. The sidecar replaces only the route
from the computer to the bridge — a card component instead of the Internet Card —
and adds a bulk inventory read. The protocol, the command table, the control tiers
and the body format are unchanged, and `linkTransport = "http"` keeps the stock
pack working.

The harness proves the state machine against a fake Internet Card. In-game,
0.3.33 verified `status`, `log`, `fs.read`, `fs.write`, `link.interval` and
`lua` at a 1 s cadence; see [`tests.md`](tests.md#results-log).

Deployment scope is **one machine** for now: the world host and the bridge on
the same box, which is the bridge default (`127.0.0.1:8787`). The WAN path is
parked until that setup exists, expected in a couple of weeks; its WireGuard
peer is therefore not part of the current in-game test list. See
[Deployment on one machine](#deployment-on-one-machine-current-target).

## Purpose

Let a process outside the game read what a running TerraCorp computer sees and
act on it, so an external agent can automate the OS: pull logs, run diagnostics,
read status, write files, close and open apps, restart the computer.

It is not a general remote shell. A frame names one command from a closed table.
`full` control has one deliberate exception, `lua`, added for in-game
diagnosis: the operator already owns the volume at that tier (rewrite `/lib`,
reboot), so running a chunk adds no reach, only one exchange instead of a
reboot cycle. At `off` and `write` no frame carries code and nothing is loaded
from the bridge.

Scope is one computer: the commands run inside the computer that received the
frame. There is no verb that reaches another machine, the cluster, or the host
running Minecraft. A plant service may coordinate many computers
([`plant-service.md`](plant-service.md)), but it does so by sending each one its
own commands: the link itself has no notion of a cluster.

## What OpenComputers allows

The transport is constrained by the **mod's configuration**, not by preference.
On the server this project targets — Internet Card, stock `settings.conf` — there
are no sockets and no inbound ports:

- The `internet` component answers HTTP requests, and this repository uses the
  verified path: `component.invoke(internetAddress, "request", url, postData,
  headers)` returning a handle that is read in chunks and closed
  (`src/lib/tc/updater.lua`).
- It needs an Internet Card and server permission for HTTPS requests
  (`docs/versioning.md`).
- An HTTP fetch is a handle, not a callback. Reading blocks the caller, and the
  desktop runs its own loop at a 1/30 s idle wait (`src/boot/kernel.lua`). The
  link therefore cannot fetch inside the draw path.
- Frames are capped at `net.MAX_FRAME` = 1024 bytes (`src/lib/tc/net.lua`).
  Anything larger travels as slices keyed by `off`, exactly like the existing
  `FETCH` / `DATA` pair (`src/lib/tc/pull.lua`).

**Pending verification: TCP sockets.** The pack's co-operator raised on
2026-11-16 that the `internet` API also documents TCP — `connect` for a client
socket, `open` for a listening one, and `isTcpEnabled` — gated by the mod's own
config (`enableTcp`, off in the stock configuration). Nobody here has probed it,
and this document previously claimed the API had no sockets at all, which was
wrong above the level of the deployment. One call settles it on any computer
with a card:

```lua
component.invoke(component.list("internet")(), "isTcpEnabled")
```

If it answers `true` on a given server, then "no sockets" describes this
deployment and not the mod, and the next in-game session should record the answer
in [`opencomputers.md`](opencomputers.md). The design does not depend on the
outcome: the OS speaks to the bridge with `request` only, and the verb set stays
closed either way.

Because of the first point, **the OS is always the client**. A bridge cannot push
into a running computer; it queues work and the OS collects it on its interval.
Any design that assumes inbound connections needs the server owner to open TCP,
which this project does not ask for and does not rely on.

## Options

| Option | Transport | Reach | Verdict |
|---|---|---|---|
| A | Outbound HTTP poll to a bridge | Any server, no port forwarding | **Shipped; default** |
| B | TC1 frames over the rack bus / modem | Only computers inside the world | **Retired** with the racks (decision 25); in-world publishing is the master link in [`line-node.md`](line-node.md) |
| C | Written bundle on a floppy or disk | Manual swap | Fine as a fallback, not a channel |
| D | Sidecar card component, outbound from a mod thread | Same as A, without the Internet Card or the `settings.conf` exception | **Decided 2026-11-16; not built** ([`sidecar.md`](sidecar.md)) |

A, B and D are not exclusive: they share the same command surface, so an in-world
agent, an external agent and a sidecar client speak the same verbs. D changes how
a frame leaves the computer and nothing else.

## Shape (option A)

One endpoint, one exchange per interval:

```text
POST /link/next?node=<address>&v=1
  body: result frames from the previous command, or empty
  reply: command frames to run, or NOOP
```

Each exchange carries results down and commands up. A command whose reply does
not fit in one frame is drained across successive exchanges: the OS keeps a
cursor and the bridge acknowledges the last `off` it stored.

### Verbs

New verbs, added to the closed set in `src/lib/tc/net.lua`:

| Verb | Direction | Required fields | Meaning |
|---|---|---|---|
| `LINK` | bridge → OS | `id`, `token`, `cmd` | Run one whitelisted command |
| `LREP` | OS → bridge | `id`, `token`, `state` | Header: `ok` or `error`, plus `size` or `reason` |
| `LDATA` | OS → bridge | `id`, `off` | Body slice in `data` |
| `LEND` | OS → bridge | `id`, `size` | End of a body |

Adding verbs is backward compatible: an older peer rejects a verb it does not
know, and the existing peers never send these.

### Command set (closed)

| `cmd` | Tier | Arguments | Returns |
|---|---|---|---|
| `status` | read | — | version, uptime, memory, component count |
| `log` | read | `n` (lines) | Tail of `/var/log/tc.log` |
| `check` | read | — | Status, component kinds and the log tail |
| `fs.list` | read | `path` | Directory listing |
| `fs.read` | read | `path` | File body, sliced |
| `link.interval` | link | `n` (seconds, 1–60) | `interval=<n>s` |
| `fs.write` | write | `path`, `data` | `wrote=<bytes>` |
| `fs.append` | write | `path`, `data` | `wrote=<bytes>` |
| `fs.mkdir` | write | `path` | `mkdir=<path>` |
| `fs.remove` | write | `path` | `removed=<path>` |
| `fs.move` | write | `path`, `arg` | `moved=<path>` |
| `app.open` | write | `arg` (app id) | `opened=<id>` |
| `app.close` | write | `arg` (app id) | `closed=<id>` |
| `reboot` | write | — | `reboot=scheduled`, then a restart two intervals later |
| `lua` | full | `data` (source) | Captured `print` output, or `error: <message>` |

A command that the current tier does not allow answers `LREP` with
`state=error reason=needs_<tier>_control` and touches nothing.

Implemented in 0.4.2 — the plant readout verbs
([`plant-service.md`](plant-service.md)). The first
contract is the **plant snapshot**, not a list of component addresses: an
external client reads names and counts, and the OS keeps the UUIDs and paths
inside.

| `cmd` | Tier | Slice | Arguments | Returns |
|---|---|---|---|---|
| `plant.status` | read | 0.4.2 | — | Version, uptime, memory, energy, link health, cache age, halls |
| `plant.snapshot` | read | 0.4.2 | `hall?`, `stocks?` | Paged snapshot: `kind`, `key`, `count`, `state` |
| `plant.delta` | read | 0.4.2 | `cursor` | Changed entries plus the new cursor; `reason=resync` when expired |
| `plant.alarms` | read | 0.4.2 | `since?` | Local level alarms with severity, source, first/last seen, ack |
| `plant.book` | read | 0.4.5 | `recipe?` | The operated book: recipes with their inputs and outputs |
| `plant.plan` | read | 0.4.5 | `target`, `qty?` | Steps, bottleneck, shortfall and warnings for one target |
| `plant.history` | read | 0.4.7 | `stock?`, `n?` | The bounded ring: rate, trend and recent samples per stock |
| `plant.paths` | read | 0.4.7 | `path?` | Semantic paths with cardinality, member count and bound state |
| `plant.halls` | read | 0.4.8 | — | The hall registry and the merged, prefixed stock view |
| `gate.set` | write | 0.4.8 | `line`, `state` | Actual state, or `refused=<why>`; the setpoint is stored |
| `gate.set` | write | 0.4.6 | `line`, `state` | Actual state, or `refused reason=<why>` |
| `move` | write | 0.4.6b | `from`, `to`, `n`, `key`, `member?`, `policy?` | `moved=<n> slots=<k>` per member, or `moved=0 reason=<why>` |

`component.list`, `path.list`, `path.query`, `path.assign`, `driver.*` and
`line.list` are **local** in 0.4.2: the Plant app calls them in-process. They
can join the link later if a remote editor needs them; the mirror does not need
a UUID to show a stock.

Every plant verb speaks the names the OS already knows; a name the node does not
have answers `unknown_stock` or `unknown_line`, never a guess.

### Plant body format

A plant reply is text, not JSON, so it survives the same frame escaping as any
other body:

- The first line is `format=plant.<status|snapshot|delta|alarms>.v1`.
- Scalars are one `key=value` per line.
- Records are one line each: a type (`stock`, `entry`, `alarm`, `error`) and
  then `key=value` tokens separated by one space.
- Every value is escaped with the wire rules (`%` `%25`, space `%20`, tab
  `%09`, CR `%0D`, LF `%0A`, `=` `%3D`), so a label can never forge a field or
  a record. Percent-decoding the value restores the label.

A snapshot body looks like this (one stock with one entry):

```text
format=plant.snapshot.v1
at=1002.5
generation=41
revision=4
scanning=0
calls=12
configured=1
halls=1
hall=TC-2907
stocks=1
stock name=casing/ingots kind=item state=exact total=744 age=1.250 version=4 members=1 cardinality=single path=casing/ingots rate=-3.500 trend=-12.0 rate_span=120
entry stock=casing/ingots kind=item key=gregtech:meta_ingot damage=113 label=Titanium%20Ingot count=192
```

`rate` is items (or mB) per minute over the history window; `trend` is the
signed percentage change between the previous and recent halves. A stock with
no history yet omits both fields.

`plant.status` is all scalars (`version`, `uptime`, `memory_used_kb`,
`memory_total_kb`, `energy`, `stocks`, `calls`, `revision`, `alarms`,
`link_control`, …). `plant.alarms` carries the same `alarm` records and a
`count`; `since` keeps only alarms whose `last` is at or after that uptime.

`plant.book` lists every recipe as a `recipe` record (`id`, `label`, `machine`,
`ticks`, `priority`, `machines`, `source`, `line`, `status`, `ratio`) followed
by `io` records (`recipe`, `side`, `kind`, `key`, `damage`, `qty`, `chance`).
`recipe=` returns one; `id` is already the frame id, so it cannot name the
recipe.

`plant.plan` returns `format=plant.plan.v1`, the target and quantity, the step
count, total seconds and chain rate, and the bottleneck recipe. Then one `step`
record per step (`crafts`, `seconds`, `rate` in crafts/s), one `shortfall` record
per missing leaf (`need`, `have`, `missing`), and one `warning` record per
condition (`suspect_recipe`, `cycle`, `rng_chain`, `unseen_key`, `depth_limit`).
The plan reads the cached snapshot, so it makes no component call.

`plant.history` returns `format=plant.history.v1` and one `stock` record per
stock (`samples`, `rate`, `rate_span`, `trend`, `first`, `last`) followed by its
most recent `sample` records (`t`, `total`, `state`). `t` is **ring seconds**,
not wall clock: the OS stamps samples with `base + computer.uptime()` and
continues `base` from the newest persisted sample, so a reboot does not rewind
the ring and offline time is not counted as a stall. `n` caps the samples per
stock (1–360, default 60).

`plant.paths` returns `format=plant.paths.v1` and one `path` record per semantic
path (`name`, `cardinality`, `members`, `stocks`, `bound`). It exposes no
component address: the UUIDs stay on the node, which is the point of the path.

`plant.halls` returns `format=plant.halls.v1`, the online/stale/offline counts,
one `hall` record per configured hall (`name`, `state`, `stocks`, `age`) and one
`stock` record per merged stock with its hall prefix. The local hall is always
the source; a configured hall that has not reported is `offline`, never silently
dropped.

`gate.set` stores the desired state before reconciling and answers
`line=<line> desired=<0|1> actual=<0|1>` or `refused=<reason>`. The refusal is a
successful body, because the setpoint was accepted; a retry reconciles the same
desired state, never a toggle.

The read-only MCP server (`tools/bridge/mcp.js`) wraps these verbs for an agent.
It answers over stdio, cites the verb behind every number and treats a missing
reading as an error, never as zero.

`plant.delta` compares `cursor` with the stock **revision**, not the scan
generation: an idle scan that reads the same numbers does not move it. A match
answers `resync=0 changes=0`. Anything else answers `resync=1` with
`reason=stale_cursor` (or `no_cursor` on the first call) and then
`snapshot_begin`, followed by a complete snapshot body in the same reply. A
mirror rebuilt after a lost cursor therefore needs one exchange, not a guess.

`stocks` on `plant.snapshot` is a wildcard path filter (`*` one segment, `**`
zero or more); an invalid pattern answers `bad_stocks`. `hall` accepts `local`,
`self`, the hostname or the node address; anything else answers `unknown_hall`.
`plant.status`, `plant.snapshot` and `plant.alarms` are readable at control
`off`; none of them touches a component, so the bridge sees exactly the cached
numbers the Plant app shows.

The bridge keeps the last parsed reply of each kind at
`GET /link/mirror?node=<addr>` (`status`, `snapshot`, `delta`, `alarms`), with
the receive time and the parsed records. Only a complete body whose byte count
matches `LEND` and whose first line is `format=plant.` replaces an entry, so a
truncated page or an unrelated result cannot overwrite the last good readout.

`gate.set` carries **desired state, never an action**: a retried frame must not
invert a gate, and a reboot must restore the last setpoints without asking the
bridge. `move` is a bounded action that reports what actually moved; the caller
retries from that answer, never from an assumption. The node reconciles gates
each tick under its own interlocks, evaluates the optional guard against its
cache, and reports the actual state plus the refusal reason.

### Control tiers

`linkControl` decides how far a command can reach. The bridge does not enforce
this and cannot: the OS is the only side that knows the tier.

| `linkControl` | Allows | Use |
|---|---|---|
| `off` (default) | `link.interval` only | A machine that should answer nothing |
| `read` | the `read` commands: status, log, check, files, the plant mirror | Watching a machine |
| `write` | `read` + user data: `/etc`, `/var`, apps, `reboot` | Automating a machine |
| `full` | everything, including the OS tree and `lua` | Repairing a machine |

**`off` means off.** Until 0.4.9, `off` shared a rank with `read`, so the default
silently allowed every read command — a machine left at the factory setting was
readable by anyone holding the token. There is now a `read` level of its own.
A machine whose `/etc/terracorp.cfg` still says `off` and that was being polled
for data must be set to `read`; that is the only migration.

`link.interval` sits in its own `link` tier and is allowed at **every** control
level, including `off`. It changes only this client's polling cadence, reads and
writes no user data, and is the same knob the GAIA window exposes; refusing it
would not protect anything the bridge operator cannot already do. The value is
clamped to 0.5–60 seconds, persisted in `/etc/terracorp.cfg`, and applied on the
next scheduling decision, so a reboot keeps it. Use it to make a test session
responsive (`n=0.5`) and put it back when finished: a half-second poll is 120
requests a minute on the world host.

**Locking yourself out.** `off` and `read` allow no writes, so they cannot be
undone over the link: the only tier that can raise the tier is `write`, and it
needs a write. Before lowering it on a machine you cannot walk to, know two
things:

- The configuration is read **once, at boot**. Writing `/etc/terracorp.cfg` from
  outside does not change the running tier — it applies on the next boot either
  way (`config.load` is called once in `kernel.lua`).
- The way back is out-of-band: stop the world, edit
  `…/opencomputers/<address>/etc/terracorp.cfg` on the server volume, start it.
  The computer reads the new value when it boots.

For testing a refusal, lower to `write` rather than `read`: everything except
`lua` and the OS tree still works, and `write` can restore `full` with a config
write plus `reboot`, since both are allowed at that tier.

The OS tree — `/init.lua`, `/boot/`, `/lib/`, `/apps/` — needs `full` even when
`write` is on, because a bad write there leaves a computer that cannot boot.
Everything else on the volume is reachable at `write`.

Every mutating command is logged to `/var/log/tc.log` with its path or app id.

A command that is not in the table is rejected with `LREP state=error
cmd=unknown`, never executed. `lua` is the only verb that carries code, it needs
`full`, and it is documented as a diagnosis tool rather than a protocol feature:
the chunk runs on the desktop loop with the kernel in reach, has no instruction
budget, and a runaway loop freezes the node until it reboots — the same rule as
the Lab. Its reply is the captured `print` output (capped at 16 KB); a compile or
runtime failure comes back as an `error:` line in the body, because `LREP` only
has room for a reason slug.

Phase 2 may add `app.open`, `node.ping`, `update.check` - still named entries,
still not code.

## Configuration

Keys live in `/etc/terracorp.cfg` with the rest of the settings
(`src/lib/tc/config.lua`):

| Key | Default | Meaning |
|---|---|---|
| `linkSink` | empty | Base URL of the bridge; empty disables the link |
| `linkToken` | empty | Shared secret; every frame carries it |
| `linkInterval` | 5 | Seconds between exchanges |
| `linkControl` | `off` | `off`, `read`, `write` or `full`; see [Control tiers](#control-tiers) |

The link is **off by default**. No sink, no polling, no background traffic.

The token is stored in `/etc/terracorp.cfg` in plain text, next to the other
preferences. Anyone who can read the boot volume can read it; treat the volume
as a secret.

## Lifecycle

1. Starts after the first desktop render, never during boot. The boot path stays
   minimal and the 1 MB budget is untouched (`AGENTS.md`).
2. Each desktop tick advances the state machine by at most one HTTP read, then
   returns to the UI. A cycle that has not finished by its deadline is abandoned
   and retried next interval, so a slow bridge cannot freeze input.
3. Failures are counted and logged once per transition, not once per tick.

| Condition | Behaviour |
|---|---|
| No Internet Card | Link disabled, one log line, no retry |
| `linkSink` empty | Nothing happens at all |
| Non-2xx or timeout | Backoff, one log line per transition |
| Reply larger than the response limit | Dropped, logged, cursor kept |
| Token mismatch | Frame rejected; the event is logged |

## Deployment on one machine (current target)

The bridge already defaults to this: `--host 127.0.0.1`, port 8787, no tunnel,
no certificate, no port forwarding.

```text
Java world ── POST 127.0.0.1:8787 ──► bridge.js
```

The Internet Card issues its request from the server process, so `127.0.0.1` is
the machine running the world, not the computer inside it.

**OpenComputers refuses private addresses by default.** `settings.conf` ships
with `deny private` ahead of `allow default`, and the `private` rule matches
`isLoopbackAddress()`, so the card rejects `127.0.0.1` before it opens a socket.
The OS reports `timeout`, not an explicit error, because the failure stays inside
the card's thread pool. Open loopback and restart the game — Forge reads these
rules at startup, not on a world reload:

```ini
filteringRules=[
  removeme,
  "allow ip:127.0.0.1",
  "deny private",
  "deny bogon",
  "allow default"
]
```

Only loopback is opened; public hosts (GitHub, the updater) keep working through
`allow default`. Verified in-game with OpenComputers 1.8.9a: without the rule the
bridge saw zero requests, with it `nodes=1` and `status` answered in one
interval.

1. `node tools/bridge/bridge.js --token <secret>` — add `--port` only if 8787 is
   taken.
2. `/etc/terracorp.cfg`: `linkSink = "http://127.0.0.1:8787"`, the same
   `linkToken`, `linkInterval = 10`, and `linkControl = "off"` for the first run.
3. Reboot the computer; `/var/log/tc.log` shows `external link armed`.
4. `node tools/bridge/linkctl.js nodes`, `use <address>`, then
   `queue status --wait`.

Everything else in [the checklist](#checklist-for-a-new-server-machine) applies
except the tunnel: there is no peer to ping and no private hostname to resolve.

## Deployment over a WAN (WireGuard, parked)

Parked: not the current target, and not needed while the bridge and the world
share a machine. Read it when the bridge has to leave that machine.

The computer is the client, so **the Minecraft host must reach the bridge**. A
bridge on a home LAN behind NAT is unreachable from a server elsewhere, and no
setting on the server fixes that. WireGuard solves it without opening a port on
either side: it authenticates both peers, encrypts the link, and keeps the
tunnel alive through NAT.

```text
[Minecraft host] ── UDP 51820 ──► [bridge host]
  wg0 10.8.0.2                    wg0 10.8.0.1
  linkSink = http://10.8.0.1:8787 bridge.js --host 10.8.0.1 --port 8787
```

Bridge peer:

```ini
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = <bridge-key>

[Peer]
PublicKey = <server-key>
AllowedIPs = 10.8.0.2/32
```

Minecraft host peer:

```ini
[Interface]
Address = 10.8.0.2/24
PrivateKey = <server-key>

[Peer]
PublicKey = <bridge-key>
Endpoint = <bridge-public-ip>:51820
AllowedIPs = 10.8.0.1/32
PersistentKeepalive = 25
```

Inside the tunnel the token travels encrypted, so plain `http://` is correct and
TLS would add nothing. Bind the bridge to the tunnel address — `--host
10.8.0.1`, never `0.0.0.0` — so it does not listen on the public interface.

What WireGuard does not fix:

| Risk | Detail |
|---|---|
| The tunnel must exist where the traffic leaves | The request comes from the JVM running the world. In a container, `wg0` has to be in the same netns or routed into it |
| Hosts that forbid WireGuard | Many containers lack `TUN` or the kernel module. `wireguard-go` covers userspace, but some hosts disallow it: check before migrating |
| Use the tunnel IP, not a name | A private hostname may not resolve from the computer's Internet Card |
| Keep `AllowedIPs` narrow | Only the bridge's tunnel address, not `0.0.0.0/0` |
| Keepalive | `PersistentKeepalive = 25` on whichever side is behind NAT |
| MTU | The tunnel lowers it to about 1420. Replies cap at 64 KB; if large bodies stall, look here |

A WireGuard peer is a network boundary, not an authorisation: the token stays.
A compromised peer should not be enough to queue commands.

## Checklist for a new server machine

In order, on the machine that runs the world. `<bridge-host>` is `127.0.0.1`
while the bridge lives on that same machine, or the tunnel address (`10.8.0.1`)
once it does not.

1. OpenComputers loads and the computer boots TerraCorp from its own volume.
2. The computer has an Internet Card; `component.list("internet")` returns an
   address.
3. The server permits outbound HTTP/S. OpenComputers may also restrict hosts in
   its own config; its default `filteringRules` deny every private address,
   including `127.0.0.1` (see [Deployment on one machine](#deployment-on-one-machine-current-target)).
4. WAN only: the WireGuard peer is up on that host and `ping <bridge-host>`
   answers.
5. `bridge.js` runs bound to `<bridge-host>` with a token; `/link/state` answers
   with that token.
6. `/etc/terracorp.cfg` has `linkSink = "http://<bridge-host>:8787"`, `linkToken`
   equal to the bridge's, `linkInterval = 10`, and `linkControl` at the tier you
   want.
7. Reboot the computer. `/var/log/tc.log` shows `external link armed`.
8. Queue `cmd=status` and read `/link/results`. If it is empty, look for
   `link: no_card`, `link: request_failed` or `link: timeout` in `tc.log`.
9. Queue `cmd=log n=5` and confirm the answer matches the log tail.
10. Only then raise `linkControl` and try a write.

## Security model

- The operator owns the bridge; the token is the only gate the OS can enforce.
- The token travels in the frame, so the link must be encrypted: WireGuard, or
  HTTPS with a certificate the Internet Card accepts. Plain HTTP over an open
  network leaks the token. Loopback to a bridge on the same machine does not
  leave the host, so plain `http://127.0.0.1` is correct there.
- Logs contain node names, paths and addresses. Assume the bridge is as
  sensitive as the save.
- The OS never stores the bridge's code. Only named commands run.
- `linkControl` is enforced by the OS. Whoever controls the bridge controls
  everything up to the configured tier, and no further.
- No automatic update is triggered by the link. Updates keep their own consent
  step in the Update app.

## Failure modes worth designing for

- A bridge that answers 200 with garbage: the frame decoder rejects it and the
  cursor does not advance.
- Two commands in one reply: executed in order, one reply per command.
- A command that blocks (a large `fs.read`): sliced like `FETCH`, never
  concatenated in memory.
- A reboot mid-drain: the cursor is not persisted, so the bridge must
  re-request. Documented, not "fixed" with a write per slice.

## Phasing

1. **Read-only.** `status`, `log`, `check`, `fs.list`, `fs.read` over HTTP
   polling, with the token and the loop-safe state machine. Shipped.
2. **Automation.** `fs.write`, `fs.append`, `fs.mkdir`, `fs.remove`, `fs.move`,
   `app.open`, `app.close`, `reboot`, behind `linkControl`. Shipped.
3. **In-world transport.** The same command surface over TC1 on the rack bus, so
   a Terminal Server or a slave can answer an agent without an Internet Card.
   Not started.

Not planned: arbitrary code execution, cluster or node control, anything that
reaches a machine other than the one holding the connection.

## Open decisions

- How far `linkControl = full` should go. It currently reaches the OS tree;
  whether an agent may also trigger `update.install` is undecided.
- Whether mutating commands should need an operator confirmation in the GAIA
  window, the way the updater asks before installing.

## Unverified

The harness fakes components in memory (`docs/tests.md`). These are **not**
proven by it and need an in-game test before this leaves design:

- Real HTTP request/response timing inside the pack, and how many reads fit in
  one desktop tick.
- Whether the pack's server permits an arbitrary outbound host, not just GitHub.
- Whether a held handle survives a `screen_resized` rebind or a shutdown.
- Whether WireGuard can be installed on the host that runs the world: containers
  need `TUN` or the kernel module. Not needed on the same-machine path, so this
  waits with the WAN deployment.
- The GAIA window has no in-game test yet; only its own gate drives it.
