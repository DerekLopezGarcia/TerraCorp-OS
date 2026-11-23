# Sidecar

Status: **decided 2026-11-16; not built.** A small Forge mod that takes the
Internet Card out of the plant's path to the bridge and adds the one read the OS
cannot afford today: a whole inventory in a single host call.

Naming: this is the **option B** of the design conversation of 2026-11-16. The
`B` row in [`external-link.md`](external-link.md#options) is a different, retired
idea (TC1 frames over the rack bus), so read that row as dead with the racks
(decision 25). Everywhere else this document calls the new path the **sidecar**.

## Why a mod, in three measured facts

1. **The card is the obstacle, not the transport.** OpenComputers ships
   `settings.conf` with `deny private` ahead of `allow default`, so the Internet
   Card refuses `127.0.0.1` and the OS reports `timeout`
   ([`external-link.md`](external-link.md#deployment-on-one-machine-current-target)).
   Every deployment starts by editing a server file that Forge reads at startup.
2. **A host call costs 50 ms of server tick** (measured, `tests.md`), and the cost
   lands on two different things. Reading a container is already one call
   (`getAllStacks`, in-game 2026-11-14), so a sweep is affordable; **moving** is
   not: `transferItem` moves at most one stack per call, so a 40-stack transfer is
   40 calls ≈ 2 s of tick and `move` loops once per stack. And every container has
   to own a Transposer before the OS can see it at all, so the density of a
   base-wide readout is also the density of its hardware.
3. **The exchange runs inside the desktop loop.** `internet.request` returns a
   handle that blocks while it is read in chunks, so every exchange competes with
   the draw path.

The card removes 1 and 3 by construction. The scanner answers 2 for reads, and the
bus in [`bus.md`](bus.md) answers it for transfers.

## What it is

A separate repository, `terracorp-sidecar` (MIT, Forge 14.23.5.2860, Java 8), with
three pieces that are independently useful:

| Piece | Kind | Component | What it does |
|---|---|---|---|
| **Bridge Card** | OC card item | `tc_bridge` | Moves opaque frames between the OS and `bridge.js` from a server-side thread |
| **Inventory Scanner** | OC block | `tc_scanner` | One call returns every slot of the inventory it faces |
| **Port and Bus Core** | OC blocks | `tc_port`, `tc_bus` | Moves items and fluids between any two ports on the network, by name ([`bus.md`](bus.md)) |

None of them is a new protocol. The card carries the same 1024-byte bodies the HTTP
path already carries; the scanner reports the same identifiers the readers already
parse (`name` + `damage` + `tag`, fluid tables); the bus executes the `move` the OS
already knows, with a longer reach.

## What does not change

- The closed command table, the tiers `off`/`write`/`full`, and the rule that the
  OS is the only side that enforces them. The mod has no opinion about commands.
- `gate.set` carries desired state, never a toggle (decision 18).
- The text body format `format=plant.*.v1` and the percent escaping.
- The brain stays outside the world (decisions 14, 23) and the node stays a
  translator (16). The card is a transport, the scanner is a reader that replaces
  a Transposer and reports items, fluids and energy in one call, and the bus is
  the `move` the OS already knows with a longer reach.
- `bridge.js`, its `/link/*` endpoints and the MCP server keep their contracts.

## Shape

```text
network                       thread
──────────────────────────────────────────────────────────────────────
Lua   kernel loop   bridge.push(body) ──► outbox (≤64 frames)
                                                │
                     mod HTTP client ───────────┘  POST /link/next
                                                │
                     mod inbox ◄──── reply frames
                                                │
      kernel loop   bridge.pull() ◄─────────────┘
```

- **Outbound only.** The mod never listens on a port: no new inbound surface on
  the server, no port to open, and `bridge.js` stays the single endpoint the
  operator exposes. This is the main reason it is a card and not a server.
- **Nothing blocks the computer.** The HTTP exchange runs on the mod's own
  thread; `push` and `pull` are queue operations on the Lua side.
- **Opaque bytes.** The mod does not parse, filter or interpret a body, and it
  cannot execute anything from the inbox. An attacker who can write to the bridge
  gains exactly what they gain today.

### Card methods

| Method | Returns | Notes |
|---|---|---|
| `push(body)` | `true`, or `nil, reason` | Body ≤ 1024 bytes (the send policy in `net.lua:3`, not the guard: `MAX_FRAME` is 8192); `queue_full` at 64 queued frames |
| `pull()` | one body, or `nil` | Dequeues one inbound frame |
| `stats()` | table | `queued`, `inbox`, `pushed`, `dropped`, `errors`, `last` (`ok`/`timeout`/`refused`) |
| `address()` | the bridge URL in use | Diagnostics only; it carries no secret |

`stats().dropped` is the honest counter: a full queue drops the **oldest** frame
and every drop is a number, never a silent hole.

### Scanner methods

| Method | Returns | Notes |
|---|---|---|
| `probe()` | capability set | `item`, `fluid`, `energy`, `none`; decides whether a path can be bound |
| `snapshot()` | slots, fluids and the face | One host call; capabilities read through Forge, so any `IItemHandler` or fluid handler works |

The scanner reads the block it **faces**, like a hopper. Binding it to a path is
the node's job ([`names.md`](names.md)), so the two namespaces hold: the scanner
has an address, the stock has a name.

## Budget

| Item | Today | With the sidecar |
|---|---|---|
| Read one container | one call (`getAllStacks`) through its own Transposer | one call (`snapshot()`), items, fluids and energy together |
| Read 20 containers | 20 calls ≈ 1 s, plus 20 Transposers | 20 calls ≈ 1 s, plus 20 scanners |
| Move 40 stacks | 40 calls ≈ 2 s, one stack per `transferItem` | one bus move |
| Exchange blocking | in the desktop loop | off-thread |
| Transport prerequisite | Internet Card plus a `settings.conf` edit | the card item |

The 50 ms figure is the measured host-call cost, not an estimate
([`tests.md`](tests.md#results-log)). Reading a container was already one call, so
the scanner's win is hardware density and one call for items, fluids and energy;
the expensive half is moving, and that is the bus.

## Configuration

`/etc/terracorp.cfg` gains one key:

| Key | Default | Meaning |
|---|---|---|
| `linkTransport` | `http` | **planned key, not in `config.lua` yet**: `http` (Internet Card, today) or `sidecar` (the card) |

`linkSink`, `linkToken`, `linkInterval` and `linkControl` keep their meaning and
their defaults. The transport changes only how a frame leaves the computer; the
body, the token inside it and the tier check stay the same code path. Switching
back is one key, so a broken card is never a dead plant.

The mod keeps its own settings outside the world
(`config/terracorp-sidecar.toml`): the bridge URL and the transmit timeout. It
stores **no secret**. The token travels inside the frame as it does today, and
`bridge.js` keeps validating it.

## Failure modes

| Condition | Behaviour |
|---|---|
| Mod not installed | `linkTransport=sidecar` finds no card: the link reports `no_transport` and stays off; the readout is untouched |
| Card missing from the computer | As above, one log line, no retry storm |
| `bridge.js` down | Exponential backoff, one log line per transition; the outbox fills, then drops with a counter |
| Queue full | Drop the oldest, increment `dropped`, log once per transition |
| Two cards in one computer | The second is ignored with a log line; the first keeps the link |
| Card pulled while running | The component disappears: the link stops, `stats()` is gone, one log line |
| World reload | The outbox and the inbox are **volatile**; frames in flight are lost, never duplicated |
| Reply larger than 1024 B | The same `off=` slicing rule as today, handled by the OS, not by the mod |

## Deployment

Two facts the operator has to accept:

1. **It is a mod.** A new item and a new block mean every player needs it in the
   pack and the server needs it installed; it is not a client-less plugin. It
   ships as its own jar, MIT, pinned by version like any other mod. This
   repository neither vendors nor redistributes it.
2. **The pack stops being stock.** Today the OS does not modify or redistribute
   Supersymmetry (`AGENTS.md`). Adding the sidecar is an explicit operator
   decision recorded in the release notes, and `linkTransport = "http"` stays
   tested so a stock pack keeps working.

## Verification

In-game, numbered, none of it done yet:

1. `component.list()` from a computer holding the card and standing next to a
   scanner: record the exact kind names, and whether a third-party component
   appears without a config entry.
2. One `push` and one `pull` against a local `bridge.js`; a bad token is still
   rejected by the bridge, not by the mod.
3. Cost: `computer.uptime()` around 20 × `snapshot()` and around 20 ×
   `getAllStacks` on the same containers; then 40 stacks through `transferItem`
   against one bus move. Record all three deltas.
4. Overflow: push 100 bodies, check `stats().dropped = 36` and that the newest 64
   survived.
5. Reload the world with frames queued: nothing is delivered twice.
6. A client without the mod: confirm the join fails and that the pack ships it.
7. GT coexistence: a Susy crate and a Storage Drawer both answer `snapshot()`, and
   the identifiers match what [`crafting.md`](crafting.md) recorded.

## Phasing

**0.4.10, after the line nodes (0.4.9).** Two slices:

- **0.4.10a — bridge card.** Transport parity: `tc.link` gains two backends behind
  one interface (`linkHttp`, `linkSidecar`), `linkTransport` joins the config, and
  the harness gains a fake card so `npm run test:link` runs every scenario on both
  transports. A fake that answers `queue_full` and a fake that times out are part
  of the matrix.
- **0.4.10b — scanner.** `snapshot()` behind the existing stock reader, so
  `tc.stock` gains a bulk path without a second identifier format.
  `npm run test:sidecar` covers a 540-slot fake with the 50 ms budget applied.

The card unblocks nothing on its own. The scanner is what makes a base-wide index
affordable, and an index is the precondition for any "AE2 without AE2" argument —
decision 11 keeps AE2 as a terminal and the world's containers as the store.

## Open decisions

1. Card or block for the bridge as well? A card matches the Internet Card it
   replaces; a block could double as the antenna for in-world agents.
2. Does the scanner belong in the line node payload, which has no room for it
   (decision 25), or only on the master?
3. Should `pull()` return one frame or a page? One frame keeps the 1024-byte
   contract; a page complicates the acknowledgement.

## Unverified

- The exact `li.cil.oc.api.Driver` overload that registers an item as a component
  in OC 1.7.x, and whether the card needs a slot class or a `Visibility`.
- Whether a third-party component appears in `component.list()` on
  Supersymmetry's OpenComputers build without a config entry.
- Which capability GT crates and Storage Drawers expose in 1.12.2
  (`IItemHandler` versus `IInventory`), and whether `IInventory` needs a wrapper.
- The real cost of `snapshot()` on a 27-slot crate and on a multiblock tank.
