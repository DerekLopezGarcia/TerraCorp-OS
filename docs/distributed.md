# Distributed Model and Data Center

This document records the target architecture for OpenComputers and the
Supersymmetry modpack. The design is a single application server with
lightweight terminals in each factory; only the local core exists today.

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

## Roles and sessions

| Role | Hardware | Responsibility |
|---|---|---|
| `core` | Server with CPU/RAM, no screen | Runtime, sessions, apps, logging |
| `terminal` | Computer with screen, keyboard, and network | Render session and send input |
| `storage` | RAID server | Files, replicas, backups |
| `worker` | Headless server | Batch jobs |
| `gateway` | Relay/Net Splitter | Segment networks; run no services |

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

F2 introduces `tc.display.local`, `tc.display.remote`, and
`tc.display.headless` backends.

## Memory budget

The current Lua-table framebuffer may consume 200-250 KB per 80x25 session, so
it cannot support multiple tier-2 sessions. F2 packs each cell into two bytes:

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
- A per-segment shared key pairs machines; it does not authenticate people.
- Remote jobs invoke contracted methods only; they cannot request components.
- Main risks: relay saturation, per-session memory, chunk loading, power policy,
  and premature network complexity.
- Verify which GTCE inventories/tanks the Adapter exposes before factory
  telemetry work.

Long-distance transport details are in [`long-distance.md`](long-distance.md).
