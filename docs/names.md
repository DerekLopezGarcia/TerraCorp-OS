# Component addressing and the semantic registry

Status: **0.4.1, first slice of F3**. Two namespaces, deliberately separate: an
opaque **physical address** for routing, and a **semantic path** for search and
grouping. Nothing outside the game ever handles the physical one by hand.

Design agreed with the pack's co-operator on 2026-11-13; it supersedes the
earlier single-name registry.

## Two namespaces, one job each

| | Physical address | Semantic path |
|---|---|---|
| Looks like | `1a2b…:9f3c…:north` (node, component, face) | `hall1/ore_processing/grinders` |
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
  The per-side inventory API and the `address:side` argument form are
  **pending in-game verification** (see the checklist); until then the face is
  part of the address but the operations pass it explicitly.

The registry also keeps a short **node alias** (`hall1-oc`) so logs and the
combined view can print `hall1-oc/9f3c…:north` instead of two UUIDs.

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
hall1/ore_processing/grinders
hall1/ore_processing/entrada
lineas/grinder_1/entrada
```

- Segments separated by `/`; `-` or `_` inside a segment. Using `-` between
  segments makes compound words ambiguous (`ore_processing-grinders` cannot say
  whether that is two levels or one).
- **Many-to-many.** A component appears in every path that describes it, so the
  same drawer is in `hall1/ore_processing/entrada` and in
  `lineas/grinder_1/entrada` at once. This is what the registry exists for.
- **Prefix and wildcard queries**: `hall1/*/tanks`, `**/grinders`,
  `lineas/*/entrada`. Semantic search is the point: the agent should not need to
  memorise the base.
- **Declared, never inferred.** The system may *propose* `hall2/nuevo_drawer_3`
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

The rule the co-operator set: **each local proxy manages its own copy, and a
combined view of all proxies is offered to the app.**

| Level | Authority | Contents |
|---|---|---|
| **Proxy** (one per computer, leaf or gateway) | Authoritative | Its components, faces, first-seen, and the paths that mention them |
| **Gateway** | Merged copy of its leaves | The segment's view; the only one with an Internet Card |
| **Plant service** | Merged copy of the gateways | The combined view apps and the agent consume |

- No peer-to-peer DNS protocol between computers inside the game. A leaf asks its
  gateway; the gateway asks the service or answers from its copy. Anything more
  becomes Relay with a different name.
- A path may span nodes: each proxy resolves the members it owns and reports the
  rest as `unreachable_members`, so a partial view is always marked as partial.
- Every member keeps `first_seen` (OpenComputers has no placement timestamp; see
  [the registration flow](#first-seen-the-registration-flow)).

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

## Moving by path

```text
move from=hall1/ore_processing/entrada to=hall1/ore_processing/grinders
     n=64 key=gregtech:meta_ore* policy=fill
```

1. Resolve both paths (and the transport's) on the owning proxy; `unknown_path`
   if any fails.
2. Read the source slots, keep the ones whose key matches the selector.
3. Transfer **slot by slot** through the transposer, up to `n` units, honouring
   `policy` when the target is a pool.
4. Return what actually moved, per member: `moved=<n> slots=<k>`, or
   `moved=0 reason=<why>` — never a cheerful `ok`.

Honest limits: cost is per slot **examined**, not per item moved, so a narrow
selector on a 40-slot chest costs 40 reads to move three stacks. Drawers group
like items for free; crates do not. `n` is capped per command; the service loops.

## Command surface

| Command | Tier | What it does |
|---|---|---|
| `component.list` | read | Components on this proxy: address, kind, face, first_seen, paths |
| `component.unclaimed` | read | Seen but not in any path, newest first |
| `path.list` | read | Paths on this proxy with member counts and declared cardinality |
| `path.query` | read | Path or wildcard → set of physical addresses, kinds, states |
| `path.assign` | **write** | Adds or removes a member for a path; validates the address against `component.list()` |
| `driver.list` | read | Registered drivers: kind, capabilities, source file |
| `driver.dump` | read | `component.methods` + `component.doc` for one address — data, safe to paste |
| `driver.reload` | **write** | Re-parses `/etc/drivers/*.lua` without a reboot; a broken file degrades that kind to `unknown` |
| `move` | **write** | Bounded transfer by path (above) |
| `gate.set` | **write** | Desired state of a line's gate, guarded by the cache |

Errors are first-class and never guessed around: `unknown_path`,
`unreachable_members`, `unbound_member`, `wrong_kind`, `cardinality_mismatch`,
`policy_missing`.

## In-game verification checklist

Verified facts used above (`component.list()` shape, address stability,
`component_added`) are in `docs/opencomputers.md`. Still to prove:

1. **Per-side inventory API**: do the Adapter's inventory methods take a side, and
   what do they return for an invalid or empty side?
2. **Transposer argument form**: does it accept `address:side` (and `:slot`), or
   must the side be passed per method? This decides whether faces are free.
3. **Inventory read shape**: one slot per call or a range — 40 slots at 40 calls
   changes the budget of `move`.
4. Path wildcards against a real proxy: `**/…` and `hall1/*/…` return what a hand
   count says.
5. Rename a path and confirm the saved line still points at the same address.
6. Re-place a block on an Adapter face, then a native OpenComputers component:
   the face address stays the same for the same kind, the native id always
   changes. **Verified in-game on 2026-11-14** for one Adapter; a second adapter
   is still worth checking.

## Sequencing

1. **`tc.addr`** — physical addresses, faces, `component.list`, `first_seen`.
2. **`tc.path`** — paths, wildcards, assign/query, cardinality.
3. **Proxy + gateway wiring** — the merged copy and the two transports
   ([`middleware.md`](middleware.md)).
4. **`move` and `gate.set`** — last, because they depend on the probe answers.

Cross-links: [`middleware.md`](middleware.md) (leaf, gateway, profiles),
[`plant-service.md`](plant-service.md) (combined view, verbs),
[`recipes.md`](recipes.md) (paths in lines),
[`roadmap.md`](roadmap.md) (decisions 17-21), `docs/opencomputers.md`.
