# Component naming service (tc.names)

Design research for a "component DNS": friendly, stable names for the pieces
of the plant, so operators and apps stop passing raw 36-character addresses.

Status: **design** — targeted at 0.4.x after Sessions, in parallel with the
inter-segment links in `docs/redlink.md`.

## Why addresses hurt today

- Component addresses are 36-character UUIDs (`component.list()`), stable per
  component instance but meaningless to humans and painful in configs.
- Registry entries already store node addresses (`/var/nodes.tsv`), Vault
  disks (`/var/vault/disks.tsv`) — but there is no one namespace tying
  "the induction matrix at the moon base" to an address.
- `component.invoke` accepts a **unique prefix** instead of a full address,
  but the prefix only resolves against *the local machine's* components —
  remote components are behind their node's network and unreachable by
  address from the master at all (that is why Vault needed the node gateway).

## What OC gives us to build on

- `component.list([kind])` — local component inventory `(address, kind)`.
- `component.invoke(address|prefix, method, ...)` — prefix must be unique
  locally.
- Component addresses persist across reboots (NBT-persisted per block/card),
  but change when a component is physically replaced or re-crafted. Anything
  addressing-cached must survive an address change gracefully.
- `component_added` / `component_removed` signals — the kernel already
  unmounts on removal; the name service can hook the same events.

## Design: a two-level name service

### Level 1 — local names (`tc.names`)

Maps a short name to a local component address, persisted at
`/var/names.tsv`, one line per entry:

```
name<TAB>kind<TAB>address<TAB>label
matrix<TAB>induction_matrix<TAB>1a2b…<TAB>Reactor hall IM
store<TAB>filesystem<TAB>9f3c…<TB>The big vault disk
```

- `names:resolve(name)` — exact match, else unique prefix among *named*
  components, else nil with reason.
- `names:bind(name, address)` — operator action (Settings or Terminal
  `name <component> <name>`), validated against `component.list()`.
- Self-healing: on `component_added`, entries whose old address vanished but
  whose kind matches a single new candidate get **re-bound automatically**
  and logged ("Rebound 'matrix' to 3fa2…"); ambiguous cases go to a warning
  state surfaced in the System card.
- `names:proxy(name)` — convenience: resolve then `component.proxy`.

### Level 2 — cluster names (master registry)

The cluster registry (nodes) already is a level-2 DNS for *computers*. The
extension is naming **peripherals behind nodes**: a node announces its
components (kinds + addresses) with its `STATUS`, the master keeps
`name → (node, address)`, and apps call through the Relay (a named-task call)
or through a new `INVOKE` verb so the master never touches the remote
component directly.

- Verb sketch: `INVOKE { node, address|name, method, args… }` → job-style
  reply. Reuses Relay's lease/ACK machinery instead of inventing a new one.
- Security posture matches Relay: only **named, contract-bound procedures**
  may run remotely; the DNS layer never turns into arbitrary remote code
  execution. A remote invoke is allowed for whitelisted component kinds
  (filesystem, redstone, transposer…) — never for arbitrary `component`.

### Cross-segment names

When `docs/redlink.md` lands, names become global: the gateway wraps
`INVOKE` per segment exactly like Vault disk requests. Names are unique per
plant, owned by the master that knows the component's node.

## In-game verification checklist

1. Address stability: note a screen/disk address, reboot the world (not just
   the machine), re-log — same address? Break and re-place — new address?
2. Prefix invocation: `component.invoke("<8 hex>", "get")` against a redstone
   card — does the short form resolve on 1.7.5 and 1.8?
3. Redstone Control probe (if installed): `component.list()` next to a port —
   any kind names appear? Do ports emit events OC can receive?
4. `component_added` fires for hot-plugged cards in a rack server?

## Sequencing

1. Level 1 (local names) — small, self-contained, useful immediately for
   configs and Terminal; ships with 0.4.x, no protocol work.
2. Level 2 (component announcements in STATUS + INVOKE verb) — rides on
   Relay, targeted with the 0.5 application server.
3. Cross-segment resolution — only after the Linked Card transport is proven.

Cross-links: `docs/roadmap.md` F3/F4, `docs/redlink.md`, `docs/cluster.md`
(STATUS, Relay), `docs/net.md` (framing).
