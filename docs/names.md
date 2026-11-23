# Component addressing and the semantic registry

Status: **design record, partly built.** Two namespaces, deliberately separate: an
opaque **physical address** for routing, and a **semantic path** for search and
grouping. Nothing outside the game ever handles the physical one by hand; the link
exposes plant snapshots, not UUIDs.

What is current (decisions 25 and 26, 2026-11-16): a **line node and the master,
two levels only** — no gateway, no plant-service tier — and a node's **name is the
root of its paths** (`casing/ingots`), with `/var/nodes.tsv` as the table of names
([`line-node.md`](line-node.md)). `tc.addr` and `tc.path` are built; the rest of
this page is the design they were built against, and the examples below use the
node-rooted shape rather than the old `hall1/…` prefix.

Design agreed with the pack's co-operator on 2026-11-13; it supersedes the
earlier single-name registry. The gateway and plant-service tiers it described
were dropped with the racks (decision 25).

## Two namespaces, one job each

| | Physical address | Semantic path |
|---|---|---|
| Looks like | `1a2b…:9f3c…:north` (node, component, face) | `casing/ingots` |
| Answers | *Where does this call go?* | *What is this thing, and what else is like it?* |
| Uniqueness | One owner, one address | Many members, many paths per component |
| Written by | Machines: the registry and the proxies | Humans, from the tablet or the app |
| Stored in configs | **Yes** — a saved line references the address | Only as a convenience; renames must not break configs |

Routing needs uniqueness; meaning needs redundancy. Trying to have both in one
string is what makes plant configs unmaintainable.

## Physical address

```text
<node-address>:<component-address>:<face>
1a2b3c4d-…:9f3c5e21-…:north
```

- `node-address` is the computer that can actually **see** the component: the one
  whose bus it hangs from. A rack server's internals are `Visibility.Neighbors`,
  so this can never be "some computer on the network" — it is the owner.
- `component-address` is what `component.list()` reports, stable across reboots.
  How long it survives a block edit depends on what exposes it: a **native
  OpenComputers component** carries its own address, assigned when the block is
  placed, so breaking and re-placing it always produces a new one; a block seen
  **through an Adapter** follows the adapter's rule instead (next section).
- `face` is which side of the block is being addressed. It matters because
  inventories are read and transposed **per side**, so the same block can behave
  as several endpoints. Kinds without sides (a filesystem, a CPU) carry `-`.
  The face is **physical**: it stays put while the block and its Adapter or
  Transposer do not move, but a rebuild can leave the same container on another
  face. A saved `address:face` is only valid for the layout it was read from.
  The per-side inventory API is **verified in-game (2026-11-14)**: the
  Transposer answers `getInventoryName(side)`, `getInventorySize(side)`,
  `getStackInSlot(side, slot)` and `getAllStacks(side)`, and `getAllStacks`
  returns one entry per slot. The `address:side` shorthand is not used by the
  OS; the face stays part of the address for routing and the operation passes
  it as an argument.

The node's **name is its alias** (decision 26): logs and the merged view print
`casing/9f3c…:north` instead of two UUIDs, because the name is already the root of
every path the node publishes.

### Adapter faces are derived, not minted

Verified by hand in-game on 2026-11-14 (0.3.22, `census()` between edits):

| Edit | Address |
|---|---|
| Break and re-place the same crate on the same face | unchanged |
| Change that face to another container kind | new |
| Remove and re-place the Adapter | every face regenerates |
| Put a Storage Drawer on a free face | no component at all |

So an Adapter face behaves like `f(adapter instance, face, exposed kind)`, not
like a placement token. Four consequences for the registry:

- A block edit that keeps the kind and the face keeps routing: the stored
  address is still the live one, so no path goes unbound.
- A different kind on that face is a different component. The old config line
  answers `wrong_kind`; the registry never adopts the replacement because they
  share a face.
- Replacing the Adapter invalidates every face it exposed at once, because the
  derivation is keyed to the adapter's own address. They are dropped together
  and the next sweep registers the new ones.
- A kind the Adapter does not expose (a Storage Drawer) has no address at all:
  silence is the expected answer, not a failed read.

This was observed on one Adapter in one session; a second Adapter should confirm
the same derivation before the registry treats a face address as surviving
block edits by design rather than by luck.

## Semantic path

```text
casing/ingots
casing/feed
lv/feed
```

- Segments separated by `/`; `-` or `_` inside a segment. Using `-` between
  segments makes compound words ambiguous (`ore_processing-grinders` cannot say
  whether that is two levels or one).
- **The first segment is the node's name** (decision 26), so a path is
  `<node>/<what the stock means>`: `casing/ingots`, `lv/feed`. A component appears
  in every path *of its own node* that describes it, so the same drawer can be
  `casing/feed` and `casing/ingots` at once; across nodes it cannot, because each
  computer owns the components on its own bus.
- **Prefix and wildcard queries**: `casing/*`, `**/ingots`,
  `lv/*`. Semantic search is the point: the agent should not need to
  memorise the base.
- **Declared, never inferred.** The system may *propose* `casing/nuevo_drawer_3`
  for a component it just noticed, but a human accepts the path. Declared
  cardinality (`single` / `pool`) records intent, so a `single` path resolving to
  two components is `cardinality_mismatch` — an alarm, not a silent choice.
- **Renaming** updates the registry and reports the saved lines that mention the
  old path. Configs store addresses, so a rename never silently rewires a line.

## A path resolves to a set; the operation reduces it

This is where the pool idea and the DNS idea turn out to be the same mechanism:

| Operation | Reduction over the resolved set |
|---|---|
| Read | Sum, with the per-member breakdown (skew is a bottleneck signal) |
| Write / move | Dispatch by the policy **in the command**: `all`, `any`, `fill`; or pin one with `member=<address>` |

`round_robin` needs memory between commands, so it is the service's cursor, sent
as `member=` — the proxy keeps no intent (decision 18).

## Who is authoritative

The rule the co-operator set: **each local node manages its own copy, and a
combined view of all nodes is offered to the app.**

| Level | Authority | Contents |
|---|---|---|
| **Line node** (one per computer) | Authoritative | Its components, faces, first-seen, the paths that mention them, and its own name |
| **Master** (the desktop that receives them) | Merged copy | The names it assigns, the merged view, and everything that reasons over it |

Two levels, not three: the gateway tier went with the racks and the halls model
(decisions 25 and 26), and a line node publishes its status straight to the
master (decision 26).

- The master's node registry in `/var/nodes.tsv` **is** the DNS: the table of
  names that feed it, each with its state, worst alarm and stock count. The Nodes
  app is that table's view and its editor.
- No peer-to-peer DNS protocol between computers inside the game. A node asks the
  master only for what the master owns — its name — and never asks it to resolve
  another node's paths.
- A combined query such as `**/ingots` asks each node for its own members and
  the master merges the answers; it is never one cross-node path. A node that
  cannot answer is reported as `unreachable_members`, so a partial view is
  always marked as partial.
- Every member keeps `first_seen` (OpenComputers has no placement timestamp; see
  [the registration flow](#first-seen-the-registration-flow)).

### Naming the nodes

A node's name is the root of its paths: `casing/in`, `casing/out`. It must be a
path segment — `[A-Za-z0-9_-]`, at most 24 characters — and it is normalised once
instead of being kept in two spellings.

**The master assigns and the node adopts.** On contact a node proposes the name it
carries in `/etc/terracorp.cfg`; the master answers with the name it holds,
registering the proposal when the name is free and suffixing it (`casing-2`) when
it is not. Renaming from the Nodes app is therefore one frame, and the node
re-qualifies its paths on the next scan. A node with no master keeps its local
name, so it can be commissioned alone; if the operator renames it locally while a
master is present, the master wins and the node says so on screen and in
`/var/log/tc.log`. A duplicate name is a `conflict`, visible in the app, never a
silent merge of two nodes' stocks. Renaming a node that has already published
lists the thresholds, recipes and line rules that still mention the old prefix.

## First seen: the registration flow

1. Place the block. The proxy notices it — on `component_added`, or on its cheap
   periodic scan — and records it as **unclaimed** with a `first_seen` and a
   **driver**. An Adapter can expose signs, chests, tanks and machines as readily
   as drawers, so the registration list is generic: what a component can *do*
   comes from its driver's capability set, not from its block name
   ([`drivers.md`](drivers.md)). A kind with no driver appears as
   `driver=unknown` with its method dump one command away, instead of being
   ignored.
2. The operator connects the tablet first, as agreed, and opens the unclaimed
   list, newest first.
3. They give it a path (or several) and a cardinality, and its role when it
   belongs to a line. Kind, address and node are already known.
4. The component becomes `bound` and the path is usable from outside.

The periodic scan is cheap because it is local (`component.list()`), so the list
stays alive without touching the tick budget. **Reading inventories** is the
expensive half and stays on demand, trickled across ticks.

## Moving by name

```text
move from=casing/ingots to=casing/line
     n=8 key=gregtech:meta_ingot* policy=fill
```

`from` is the input stock; `to` is the line's input boundary (the transport
that feeds it). The machine buffers inside the line are not named and not read
(decision 24).

1. Resolve both paths (and the transport's) on the owning proxy; `unknown_path`
   if any fails.
2. Read the source slots, keep the ones whose key matches the selector.
3. Transfer **slot by slot** through the transposer, up to `n` units, honouring
   `policy` when the target is a pool. The transport must be an inventory the
   transposer can insert into, **and its network must have a destination**: the
   same crate→pipe call answered `true, 0` while the pipe was disconnected and
   `true, 8` after it was routed to the bender (in-game 2026-11-15). A connected
   GT pipe is a valid sink; verify the route, not just the face.
4. Return what actually moved, per member: `moved=<n> slots=<k>`, or
   `moved=0 reason=<why>` — never a cheerful `ok`.

The transport is any component that declares `transfer` ([`drivers.md`](drivers.md)).
A Transposer is what exists today; a bus port anywhere on the network is the same
capability with a longer reach ([`bus.md`](bus.md)). Nothing in the command
changes: only the price of a move and the endpoints it can name.

Honest limits: cost is per slot **examined**, not per item moved, so a narrow
selector on a 40-slot chest costs 40 reads to move three stacks. Drawers group
like items for free; crates do not. `n` is capped per command; the service loops.

## Command surface

**Only the last row exists on the link today.** `tc.addr` and `tc.path` implement
addresses and local paths as modules, and `gate.set` is the one verb exposed over
the External Link; everything else in this table is the designed surface of the
plant service and answers `unknown_cmd` until it is built. The list is kept whole
because it is the contract the modules are being built towards, but nothing here
should be scripted against yet.

| Command | Tier | Status | What it does |
|---|---|---|---|
| `component.list` | read | designed | Components on this proxy: address, kind, face, first_seen, paths |
| `component.unclaimed` | read | designed | Seen but not in any path, newest first |
| `path.list` | read | designed | Paths on this proxy with member counts and declared cardinality |
| `path.query` | read | designed | Path or wildcard → set of physical addresses, kinds, states |
| `path.assign` | **write** | designed | Adds or removes a member for a path; validates the address against `component.list()` |
| `driver.list` | read | designed | Registered drivers: kind, capabilities, source file |
| `driver.dump` | read | designed | `component.methods` + `component.doc` for one address — data, safe to paste |
| `driver.reload` | **write** | designed | Re-parses `/etc/drivers/*.lua` without a reboot; a broken file degrades that kind to `unknown` |
| `move` | **write** | designed, arrives with the bus (0.4.11) | Bounded transfer by path (above) |
| `gate.set` | **write** | **shipped over the link** | Desired state of a line's gate, guarded by the cache |

Errors are first-class and never guessed around: `unknown_path`,
`unreachable_members`, `unbound_member`, `wrong_kind`, `cardinality_mismatch`,
`policy_missing`.

## In-game verification checklist

Verified facts used above (`component.list()` shape, address stability,
`component_added`) are in `docs/opencomputers.md`. Still to prove:

1. **Per-side inventory API** — **verified in-game 2026-11-14 for the
   Transposer**: `getInventoryName(side)`, `getInventorySize(side)`,
   `getStackInSlot(side, slot)` and `getAllStacks(side)`; an empty side is
   `nil, "no inventory"`. The Adapter's inventory exposure for chests and GT
   crates is still pending; the Tank Controller path is verified.
2. **Transposer argument form** — **verified in-game 2026-11-14/15**: the side
   is passed per method; `transferItem(from, to, count[, sourceSlot[,
   sinkSlot]])` takes slot integers and moves at most one stack per call. The
   `address:side` shorthand is not used.
3. **Inventory read shape** — **verified in-game 2026-11-14**: `getAllStacks`
   returns an array with one entry per slot, empty slots are empty tables, and
   `getStackInSlot` returns `nil` for an empty slot. One call per face, so the
   budget of `move` is per face, not per slot.
4. Path wildcards against a real proxy: `**/…` and `casing/*` return what a hand
   count says.
5. Rename a path and confirm the saved line still points at the same address.
6. Re-place a block on an Adapter face, then a native OpenComputers component:
   the face address stays the same for the same kind, the native id always
   changes. **Verified in-game on 2026-11-14** for one Adapter; a second adapter
   is still worth checking.

## Sequencing

1. **`tc.addr`** — physical addresses, faces, `component.list`, `first_seen`.
2. **`tc.path`** — local paths, wildcards, assign/query, cardinality.
3. **Local readers, cache and Plant app** — 0.4.1.
4. **`plant.*` mirror** — 0.4.2.
5. **Line node, names and the master's merge** — 0.4.9 (F3.5), one small OS per
   line that publishes under its own name ([`line-node.md`](line-node.md)). The
   gateway is gone with the racks; [`middleware.md`](middleware.md) stays as the
   record of that dropped design, not a plan.
6. **`move` and `gate.set`** — on the verified transposer and cache, and only
   when a real gate or transport exists.

Cross-links: [`middleware.md`](middleware.md) (leaf, gateway, profiles),
[`plant-service.md`](plant-service.md) (combined view, verbs),
[`recipes.md`](recipes.md) (paths in lines),
[`roadmap.md`](roadmap.md) (decisions 17-21), `docs/opencomputers.md`.
