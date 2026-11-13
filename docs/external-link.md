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
| Gate | `npm run test:link` (16 scenarios) and `npm run test:gaia` |

The harness proves the state machine against a fake Internet Card. The in-game
behaviour is still unproven; see [Unverified](#unverified).

Deployment scope is **one machine** for now: the world host and the bridge on
the same box, which is the bridge default (`127.0.0.1:8787`). The WAN path is
parked until that setup exists, expected in a couple of weeks; its WireGuard
peer is therefore not part of the current in-game test list. See
[Deployment on one machine](#deployment-on-one-machine-current-target).

## Purpose

Let a process outside the game read what a running TerraCorp computer sees and
act on it, so an external agent can automate the OS: pull logs, run diagnostics,
read status, write files, close and open apps, restart the computer.

It is not a remote shell. A frame names one command from a closed table; no
frame carries code, and nothing is loaded from the bridge.

Scope is one computer: the commands run inside the computer that received the
frame. There is no verb that reaches another machine, the cluster, or the host
running Minecraft. A plant service may coordinate many computers
([`plant-service.md`](plant-service.md)), but it does so by sending each one its
own commands: the link itself has no notion of a cluster.

## What OpenComputers allows

The transport is constrained by the mod, not by preference:

- There are no sockets and no inbound ports. The `internet` component offers
  HTTP requests only, and this repository already uses the verified path:
  `component.invoke(internetAddress, "request", url, postData, headers)`
  returning a handle that is read in chunks and closed
  (`src/lib/tc/updater.lua`).
- It needs an Internet Card and server permission for HTTPS requests
  (`docs/versioning.md`).
- An HTTP fetch is a handle, not a callback. Reading blocks the caller, and the
  desktop runs its own loop at a 1/30 s idle wait (`src/boot/kernel.lua`). The
  link therefore cannot fetch inside the draw path.
- Frames are capped at `net.MAX_FRAME` = 1024 bytes (`src/lib/tc/net.lua`).
  Anything larger travels as slices keyed by `off`, exactly like the existing
  `FETCH` / `DATA` pair (`src/lib/tc/pull.lua`).

Because of the first point, **the OS is always the client**. A bridge cannot
push into a running computer; it queues work and the OS collects it on its
interval. Any design that assumes inbound connections is not implementable in
this mod.

## Options

| Option | Transport | Reach | Verdict |
|---|---|---|---|
| A | Outbound HTTP poll to a bridge | Any server, no port forwarding | **Recommended** |
| B | TC1 frames over the rack bus / modem | Only computers inside the world | Good for in-world agents, not for an external AI |
| C | Written bundle on a floppy or disk | Manual swap | Fine as a fallback, not a channel |

A and B are not exclusive: B can reuse the same command surface, so an in-world
agent and an external agent speak the same verbs.

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
| `fs.write` | write | `path`, `data` | `wrote=<bytes>` |
| `fs.append` | write | `path`, `data` | `wrote=<bytes>` |
| `fs.mkdir` | write | `path` | `mkdir=<path>` |
| `fs.remove` | write | `path` | `removed=<path>` |
| `fs.move` | write | `path`, `arg` | `moved=<path>` |
| `app.open` | write | `arg` (app id) | `opened=<id>` |
| `app.close` | write | `arg` (app id) | `closed=<id>` |
| `reboot` | write | — | `reboot=scheduled`, then a restart two intervals later |

A command that the current tier does not allow answers `LREP` with
`state=error reason=needs_<tier>_control` and touches nothing.

Proposed for 0.4 — the plant service verbs
([`plant-service.md`](plant-service.md)), not implemented yet:

| `cmd` | Tier | Arguments | Returns |
|---|---|---|---|
| `component.list` | read | — | Components on this proxy: address, kind, face, `first_seen`, paths |
| `component.unclaimed` | read | — | Seen but not in any path, newest first |
| `path.list` | read | — | Paths on this proxy: member count, cardinality, state |
| `path.query` | read | `path` (wildcards) | The resolved set, or `unknown_path` / `unreachable_members` |
| `path.assign` | write | `path`, `address`, `cardinality?` | Updated entry, validated against `component.list()` |
| `stock.snapshot` | read | `paths?` | Full stock listing, sliced: `kind`, `key`, `count` |
| `stock.delta` | read | `cursor` | Entries changed since the cursor plus the new one; `reason=resync` when it expired |
| `move` | write | `from`, `to`, `n`, `key`, `member?`, `policy?` | `moved=<n> slots=<k>` per member, or `moved=0 reason=<why>` |
| `line.list` | read | — | Line path → gate address and cached levels |
| `gate.set` | write | `line`, `state` | Actual state, or `refused reason=<why>` |
| `node.status` | read | — | Version, uptime, memory, energy, link health, cache age |

Every one of these speaks **semantic paths**, never UUIDs ([`names.md`](names.md)).
An external instruction has to be readable, reviewable and diffable; a frame full
of 36-character addresses is none of those. The registry resolves a path to
physical addresses at the target proxy — the caller never needs to know where a
component lives.

`gate.set` and `move` carry the same discipline: **desired state, never an
action**. A retried frame must not invert a gate, and a reboot must restore the
last setpoints without asking the bridge. The node reconciles each tick under its
own interlocks, evaluates the optional guard against its cache, and reports the
actual state plus the refusal reason.

### Control tiers

`linkControl` decides how far a command can reach. The bridge does not enforce
this and cannot: the OS is the only side that knows the tier.

| `linkControl` | Allows | Use |
|---|---|---|
| `off` (default) | `read` commands only | Watching a machine |
| `write` | `read` + user data: `/etc`, `/var`, apps, `reboot` | Automating a machine |
| `full` | everything, including the OS tree | Repairing a machine |

The OS tree — `/init.lua`, `/boot/`, `/lib/`, `/apps/` — needs `full` even when
`write` is on, because a bad write there leaves a computer that cannot boot.
Everything else on the volume is reachable at `write`.

Every mutating command is logged to `/var/log/tc.log` with its path or app id.

No `eval`, no `load`, no remote code. A command that is not in the table is
rejected with `LREP state=error cmd=unknown`, never executed.

Phase 2 may add `app.open`, `node.ping`, `update.check` — still named entries,
still not code.

## Configuration

Keys live in `/etc/terracorp.cfg` with the rest of the settings
(`src/lib/tc/config.lua`):

| Key | Default | Meaning |
|---|---|---|
| `linkSink` | empty | Base URL of the bridge; empty disables the link |
| `linkToken` | empty | Shared secret; every frame carries it |
| `linkInterval` | 5 | Seconds between exchanges |
| `linkControl` | `off` | `off`, `write` or `full`; see [Control tiers](#control-tiers) |

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
   its own config; confirm before assuming the bridge is at fault.
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
