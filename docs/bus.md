# Bus

Status: **decided 2026-11-16; not built.** The transport half of the sidecar: a
port block next to any container and a core that lets the OS move items and fluids
between **any two of them, by name, at any distance** — a Transposer's reach
without a Transposer's face.

This is the piece that lets the plant decentralise: one warehouse per hall, one
tank farm per line, and the control plane moves stock between them instead of
laying a pipe from A to B with a Transposer at each end.

## Why this is a decision and not a detail

Decision 10 says TerraCorp is the control plane, not the transport: "pipes,
hoppers and the pack's own logistics move the goods". A bus that moves items
across the base **is** transport, and pretending otherwise would be dishonest. It
is admitted under a narrower rule (decision 28):

- The bus moves **only what a named command orders** — `move(from, to, n, key)`
  with both endpoints already bound to paths. It never balances, never fills "as
  needed", never runs a schedule of its own. Policy lives in the OS and the
  service, as it already does for `gate.set`.
- It is **metered and bounded**: energy per stack, a capped rate per core, and `n`
  capped per command. It is not a substitute for a pipe that fits; it is the
  answer when the alternative is two hundred blocks of duct.
- It **reports what moved**, like `move` today: `moved=<n> slots=<k>` or
  `moved=0 reason=<why>`. Never a cheerful `ok`.

Where a pipe already reaches, the pipe wins: it is cheaper, it keeps running with
the computer off, and it does not charge power per stack. The bus exists for the
gap.

## What it is

Two blocks, in the same mod as the card and the scanner:

| Block | Component | Attaches to | What it does |
|---|---|---|---|
| **Port** | `tc_port` | one container or tank, on the face it touches | declares an endpoint; answers `probe()` and `snapshot()` like the scanner |
| **Bus Core** | `tc_bus` | — | joins the ports on one cable network into one namespace and executes moves between them |

A port is also a reader: the same one-call `snapshot()`, so a base that can be
indexed can be moved. One block per container, instead of a Transposer per
container with six faces and a cable run.

The bus does not replace the path registry. Ports are components, so
`component.list`, `path.assign` and `path.query` already name them
([`names.md`](names.md)); the core only has to know which ports are on its
network, and that is reachability on the cable.

## The verb does not change

`move` keeps its contract ([`names.md`](names.md#command-surface)): resolve two
paths on the owning proxy, read the source, transfer up to `n` units honouring
`policy`, and return what actually moved. What changes is the transport behind it:

| | Today | With the bus |
|---|---|---|
| Endpoint | a face of the computer's Transposer | a port anywhere on the bus |
| Reach | adjacent | the core's radius, same dimension |
| Cost | 1 call per stack moved | 1 call per move, whatever the stack count |
| Failure | `nil, "no inventory"` | a reasoned refusal: `full`, `no_match`, `unloaded`, `no_power`, `throttled`, `unbound` |

The OS keeps one `tc.move`; the descriptor declares `transfer` against either kind
([`drivers.md`](drivers.md)), so a line node with a Transposer and a hall with a
bus speak the same command.

## Reach, power and rate

Three knobs, all server config, because the pack decides balance, not the mod:

| Knob | Default | Meaning |
|---|---|---|
| `maxRange` | 96 blocks | Ports farther than this from their core are not on its bus; a second core bridges with a **trunk** pair |
| `euPerStack` | 32 EU per item stack, 250 EU per 1000 mB | Charged to the core before the move; `no_power` when short |
| `maxOperationsPerTick` | 1 per core | A hard ceiling, so a runaway loop cannot saturate the server |

Distance is not free: the cost scales in buckets (short, medium, long over
`maxRange`), so a hall moving stock across two hundred blocks pays for it, and the
operator tunes it without touching code. The numbers above are the shape of the
decision, not a balance claim; they get set once the pack's EU economy is compared
against its pipes.

**Cross-dimension is off by default.** Two cores can be paired with a quantum link
item (a code, not a channel) and the pairing multiplies `euPerStack`; a server
that never enables it cannot be gamed by building one.

## Unloading and the rest of the world

- Both endpoints' chunks must be loaded, otherwise `unloaded` and nothing moves.
  The bus never force-loads a chunk and never teleports into an unloaded one. A
  hall that trades continuously keeps its own chunk loader; that is the hall
  owner's decision, not the bus's.
- A port removed or rotated goes `unbound` on the next call. It is never silently
  rebound to whatever container took its place.
- A move is one server-thread operation on the two handlers. There is no in-flight
  state, nothing to persist and nothing to resume: a restart mid-move either
  happened or it did not, and the caller learns which from the return value.
- Machines are not addresses. A port binds to a container or a tank and refuses a
  machine's internal buffer, so reading a line's inside stays forbidden
  (decision 24).

## Why not just use the pipes the pack already has

Because a pipe cannot be **named and asked**. The plant's model is "the OS decides,
the world executes": a `STARVED` alarm on one hall becomes one `move` from the
warehouse hall, and the operator reads the answer. A pipe is built for the worst
case and stays built; a bus is used when the control plane says so. The
compromise is deliberate — the bus is slower and dearer per stack than a pipe, so
it does not delete the pack's logistics, it fills the gaps where a pipe run is
absurd.

An operator who does not want it never crafts the block and the feature is inert:
nothing in the OS depends on it, exactly as the card falls back to
`linkTransport = "http"`.

## AE2, honestly

The ask behind this is "AE2 without AE2". What AE2 gives that the bus does not:

| AE2 | Bus |
|---|---|
| One virtual store; items live "in the network" | Items stay in real containers; the OS keeps the index |
| A terminal that searches the whole network | `path.query` plus the index the scanner reads; the search is the OS's |
| Autocrafting from patterns | `book`/`plan` at the logic level; execution belongs to the line |
| Channels and P2P | One cable, one core, ports |
| Fluid and gas virtualisation | Ports on real tanks; no virtual tank |

What the bus gives that a terminal does not: an endpoint the control plane can
address **by name, anywhere, with a bounded, reported, metered move**. That is the
programmable part. The storage model stays where decisions 11 and 12 put it.

## Verification

1. Reach: ports at 30, 90 and 200 blocks from their core — which answer, and does
   `maxRange` refuse cleanly at the boundary?
2. Cost: `computer.uptime()` around one 40-stack move and around 40
   `transferItem` calls; record both.
3. Power: with an empty buffer `no_power`; with exactly the cost it moves; one EU
   short and it refuses.
4. Rate: a loop asking for ten moves per tick is throttled, and `throttled` is
   counted, not logged per call.
5. Unloaded: a port in an unloaded chunk answers `unloaded` and moves nothing.
6. Identity: a stack moved by the bus arrives with the same `name`, `damage` and
   `tag` the source reported ([`crafting.md`](crafting.md)).
7. Fluid: `port_a` to `port_b` in mB, with both tanks reading the same amount
   afterwards.
8. A container swapped behind a port: the next call answers `unbound`, not a move.

## Phasing

**0.4.11, after the card and the scanner (0.4.10).** The bus is the third slice of
the same mod and it is useless before the index exists: a move cannot be decided
for a stock that cannot be named.

- **0.4.11a — ports and core**, local range, items only, `move` behind the
  existing `transfer` capability.
- **0.4.11b — fluids, power and rate**, the trunk pair and the refusal reasons.
- **0.4.11c — cross-dimension**, off by default.

Wiring the **policy** — orders that cross halls, a `STARVED` becoming a move —
stays in F7 ([`roadmap.md`](roadmap.md)), where the agent gets hands.

## Open decisions

1. One block with two roles (reader and endpoint) or two blocks? One block is
   cheaper to build and impossible to misconfigure; two blocks let a hall index
   without opening a move endpoint.
2. Trunk between cores: a cable block, or a paired item like the quantum link?
3. Does the core meter energy from its own buffer, or per operation from a GT
   energy hatch on its face?
4. Should `move` accept a whole `plan()` step, turning a shortage into one command
   instead of a Lua loop of moves?

## Unverified

- `IItemHandler` versus `IInventory` on GT crates and drawers — the same open
  question as [`sidecar.md`](sidecar.md#unverified).
- Whether a multiblock tank exposes `fill`/`drain` from a block face, and how many
  tanks sit behind one face (the outstanding probe in
  [`telemetry.md`](telemetry.md)).
- The throughput ceiling of one core at `maxOperationsPerTick = 1`, and the
  server-tick cost of a move, in-game.
