# Distributed Model and Data Center

This document records the target architecture for OpenComputers and the
Supersymmetry modpack. The design is a single application server with
lightweight terminals in each factory; 0.3.x adds the first cable-connected
cluster, while sessions remain local until 0.4.

## Mod constraints

| Component | Observed constraint | Design impact |
|---|---|---|
| RAM | Each node has separate memory | No shared/distributed RAM |
| Relay | About 4 packets/s without upgrades, queue 20, up to 5 hops | Bandwidth is scarce; send deltas |
| Relay | Passes messages, not remote components | Use RPC, not component proxies |
| Rack | Four servers plus terminal server; integrated switch and power | Organize the data center by racks |
| Terminal server | Four remote terminals, roughly tier-2 screen/keyboard | Native low-cost rack administration |
| Linked Card | Point-to-point quantum tunnel | Inter-base/dimension links |
| RAID | Combines disks into one volume | Data-center storage |
| Net Splitter | Separates networks without routing | Zone segmentation |

An 80x25 display has 2,000 cells. A full colored frame is roughly 4-6 KB, so
sending every cell at relay speed is not viable. Send changed spans instead.

## 0.3.x cluster

The first cluster is deliberately small and wired:

- The existing computer is the **master**. It keeps the desktop, the node
  registry, and the provisioning payload.
- A **rack** holds servers and one mountable disk drive. The rack is not a
  component; the master discovers it through the drive and through node
  announcements.
- Each server runs a headless TerraCorp system from its first HDD. The master
  provisions it from the rack floppy: the server copies the runtime, writes
  `role` and `master` to `/etc/terracorp.cfg`, and sets its boot address.
- Nodes speak to the master over a wired network card using `tc.net`. The same
  side bus also carries the floppy filesystem, which is `Visibility.Network`.
- Server HDDs and internal components stay `Visibility.Neighbors`; the master
  cannot read them over the cable. Storage must be a service (0.3.2), not bus
  access.
- There is no remote power-on. After a world reload, a player starts each server
  with a sneak-use. A chunk loader must cover the rack.

The physical build, rack GUI wiring, and protocol are in
[`cluster.md`](cluster.md).

## Roles and sessions

| Role | Hardware | Responsibility |
|---|---|---|
| `core` / `master` | Server or desktop with CPU/RAM, no screen required | Runtime, sessions, apps, logging, registry |
| `terminal` | Computer with screen, keyboard, and network | Render session and send input |
| `storage` | RAID server | Files, replicas, backups |
| `worker` | Headless server | Batch jobs |
| `gateway` | Relay/Net Splitter | Segment networks; run no services |

In 0.3.x the `core` is the existing desktop and is called the master. The
`worker` and `storage` roles are assigned to rack nodes; `terminal` arrives with
remote sessions in 0.4.

Each terminal has its own desktop session (windows, apps, focus). Profiles are
`desktop` and `kiosk:<app>`. Session state lives on the server so a replacement
terminal can resume it. Multiple players may connect, but one operates at a
time; attribute actions by player name without accounts or passwords.

## Remote display

Reuse the local row-delta renderer. Send spans as
`(row, column, foreground, background, text)`:

- Full 80x25 redraw on connect/app change: a few KB, once.
- Pointer/key input: typically 1-3 spans.
- Proposed remote-session refresh target: up to 10 Hz, grouped into spans. This
  is a network bandwidth policy, not an OpenComputers screen refresh limit.
- RLE may encode repeated row backgrounds; do not send video or images.

0.4 introduces `tc.display.local`, `tc.display.remote`, and
`tc.display.headless` backends.

## Memory budget

The current Lua-table framebuffer may consume 200-250 KB per 80x25 session, so
it cannot support multiple tier-2 sessions. 0.4 packs each cell into two bytes:

| Allocation | Estimate |
|---|---:|
| Front buffer, 80x25 | ~4 KB |
| Back buffer | ~4 KB |
| Windows and app state | ~20-40 KB |
| Per session target | <64 KB |
| Four sessions plus core | <400 KB |

If the budget is exceeded, reduce terminal resolution before reducing session
count.

## Network choices

| Scope | Medium | Intended use |
|---|---|---|
| Same rack | Rack bus | No network overhead |
| Same base | Cable/modem | Local network |
| Between base zones | Relay/Net Splitter | Segmentation; low throughput |
| Nearby, same dimension | Wireless | Mobile terminals |
| Other base/dimension | Linked Card | Primary point-to-point link |
| Long-distance emergency | Redstone Control | Commands and telemetry |
| Mobile | Tablet wireless | Client; no Redstone Control |

Recommendation: cable within a base, Linked Cards between bases, relays only
for segmentation, and wireless for mobile/field terminals.

## Services and data-center operation

Apps call services rather than the network directly. A service chooses local or
remote transport and enforces a versioned contract. Telemetry is event-driven,
not polled faster than 1 Hz.

The data center uses a dedicated power plant and UPS. The UPS supports orderly
shutdown and startup surges, not continued production. Startup is automatic
above 60% UPS charge and staged about five seconds per node: network, storage,
core, workers, terminals. A permanent chunk-loader is required. Shed load in
order: workers, noncritical terminals, storage after closing files, then core.
Never shut down storage during a write.

Target operation: inventory two racks/six nodes, monitor nodes/disks/power/
network, and let a terminal read/write remote storage. A single node failure
must not corrupt data or take down the remaining system.

## Security, risks, and open work

- No accounts; attribute `touch`, `drag`, and `key_down` to the player.
- 0.3.x uses a per-provisioning token to reject stale assignments. It is not
  authentication; the cluster is a local cable segment.
- A per-segment shared key pairs machines; it does not authenticate people.
- Remote jobs invoke contracted methods only; they cannot request components.
- Main risks: relay saturation, per-session memory, chunk loading, power policy,
  and premature network complexity.
- Verify which GTCE inventories/tanks the Adapter exposes before factory
  telemetry work.

Long-distance transport details are in [`long-distance.md`](long-distance.md).
