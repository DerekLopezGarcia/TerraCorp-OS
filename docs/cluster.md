# Cluster Build and Node Protocol

Status: 0.3.0, shipped 2026-10-26. This document covers the physical build of a
TerraCorp cluster and the node protocol used by 0.3.x.

- **0.3.0 Rack:** discover cable-connected racks, provision slave systems, keep
  a node registry, and add the Nodes app.
- **0.3.1 Relay:** delegate jobs to nodes.
- **0.3.2 Vault:** store files on nodes.

## Roles and scope

| Role | Hardware | Responsibility |
|---|---|---|
| `master` | Existing TerraCorp computer with a wired network card | Desktop, registry, provisioning, job dispatch |
| `node` | Rack-mounted server, headless | Runs a slave system and announces itself |
| `worker` | Node with `role=worker` | Runs delegated jobs (0.3.1) |
| `storage` | Node with `role=storage` | Serves remote files (0.3.2) |

A **rack** is a housing, not a component. The master cannot address a rack
directly. It discovers a rack through the mountable disk drive in it and through
the nodes that announce themselves on the rack's network.

Physical rack and slot numbers are not exposed by OpenComputers. The master can
identify a **rack segment** by its mountable drive and the nodes heard on that
segment. If two racks share one data bus, they appear as one segment; name nodes
with a rack prefix (for example `R1-S1`) when that distinction matters.

0.3.0 does **not** include:

- remote power-on;
- remote access to a server's components or HDD over the cable;
- remote sessions or app migration;
- job delegation (0.3.1) or remote storage (0.3.2).

## Bill of materials

### Minimum: one rack, one node

| Qty | Item | Notes |
|---:|---|---|
| 1 | Rack | Four mountable slots |
| 1 | Mountable Disk Drive | Must be rack-mounted; a normal Disk Drive cannot join the rack bus |
| 1 | Floppy Disk | 512 KB in Supersymmetry; holds the netboot payload |
| 1 | Server (Tier 1) | CPU Tier 2, 2x RAM Tier 2, 2x HDD Tier 2 |
| 1 | CPU (Tier 2) | Fits a Tier 1 server |
| 2 | RAM (Tier 2) | Fits a Tier 1 server |
| 2 | HDD (Tier 2) | First HDD is the system disk; the second is spare capacity |
| 1 | Component Bus (Tier 2) | Optional for 0.3.0; the CPU alone supports 12 components |
| 1 | EEPROM | Stock Lua BIOS; never reflash it |
| 1 | Network Card (wired) | The node's link to the master; not a Tier 1 wireless card |
| 1 | Network Card (wired) | For the master, in a free expansion slot |
| 1 | OC Cable run | From the master to the rack's data side |
| 1 | OC Power Converter | Or an existing OC power feed; a Capacitor is optional |
| 1 | Chunk loader | Must cover the master and the rack |

The master also needs a graphics card, a screen, and a keyboard. A Tier 2 screen
(80x25) is recommended for the Nodes app; 50x16 works but is cramped.

### Recommended for 0.3.x and 0.4

| Qty | Item | Notes |
|---:|---|---|
| 1 | Rack | Three servers plus the provisioning drive |
| 3 | Server (Tier 2) | Headroom for delegated apps in 0.4 |
| 3 | CPU (Tier 3) | One per Tier 2 server |
| 9 | RAM (Tier 3) | Three per Tier 2 server |
| 9 | HDD (Tier 3) | Three per server; extra disks can become storage in 0.3.2 |
| 3 | Component Bus (Tier 3) | Optional; useful for expansion |
| 3 | EEPROM | One per server |
| 3 | Network Card (wired) | One per server |
| 1 | Mountable Disk Drive | Shared provisioning and rescue drive |
| 2 | Floppy Disk | One payload, one spare |

A Tier 2 server accepts a Tier 3 CPU, three Tier 3 RAM, three Tier 3 HDD, two
Tier 3 component buses, two Tier 2 plus one Tier 3 expansion card, and one
EEPROM. A Tier 1 server accepts a Tier 2 CPU, two Tier 2 RAM, two Tier 2 HDD,
one Tier 2 component bus, and two Tier 2 expansion cards.

### Rack capacity

A rack has four mountable slots. The provisioning drive occupies one, so a
single rack holds at most **three servers**. A Terminal Server (planned for 0.4)
would occupy another slot.

To grow past three nodes, add a second rack and join its data bus to the first
rack's data bus (same side on both racks). One mountable drive can provision
every server on that shared bus. A server must stay in a rack to run.

## Placement and cabling

Choose one rack side as the **data bus** and one as the **power bus**. Use the
rack's left side for data and its back for power in the examples below; the GUI
labels are what matter.

1. Place the rack with its front accessible. The front is used for the rack GUI
   and for sneak-right-click power-on. The front has **no bus**.
2. Run cable from the master's network card to the rack's left face. The cable
   must touch that face. A cable on the front, back, top, or bottom joins a
   different bus and will not see the mountables configured for the left bus.
3. Feed power into a different face, preferably the back. The rack distributes
   power to all four slots, so one feed is enough. Keeping power on its own bus
   keeps the data network clean.
4. For a second rack, run cable from the first rack's left face to the second
   rack's left face. Both racks then share one data bus. Do not rely on relay
   mode to bridge components; relay mode passes messages only.
5. Keep relay mode **disabled** in every rack GUI.
6. If other OC networks run nearby, use a distinct cable color for the cluster
   run so a stray cable cannot bridge the networks.

```
[master]---- cable ----[ rack A, left bus ]---- cable ----[ rack B, left bus ]
                              |                                  |
                     servers + disk drive                 servers on the same bus
```

The master's network card must be wired. A Tier 1 wireless card cannot receive
wired messages; a Tier 2 wireless card can, but the plain Network Card is the
intended part.

## Rack GUI wiring

Open the rack GUI by right-clicking the rack. The GUI is a grid:

- five bus columns: **Top**, **Bottom**, **Left**, **Right**, **Back**;
- one row group per mountable: one thick dot (primary connection) and up to
  three slim dots (secondary connections);
- a server shows one slim dot per installed network card;
- a mountable disk drive shows only the primary dot;
- clicking a dot connects that connection to that bus; clicking it again
  disconnects it.

The labels are relative to the rack's front: **Left** is the side to your left
when you face the front, even if that is east or west in the world. Put the
cable on the physical side that matches the label you click.

For a data bus on **Left**:

| Slot | Mountable | Row | Column |
|---:|---|---|---|
| 1 | Server A | Thick (primary) | Left |
| 1 | Server A | First slim (network card) | Left |
| 2 | Server B | Thick (primary) | Left |
| 2 | Server B | First slim (network card) | Left |
| 3 | Server C | Thick (primary) | Left |
| 4 | Mountable Disk Drive | Thick (primary) | Left |

Leave every other dot empty. Set the relay button to **Disabled**.

Why the primary connection is required: the server boots from the floppy in the
rack drive. The drive's filesystem is visible across the side bus, and the
server needs component access to see it. Why the slim connection is also
recommended: it is the documented way for a rack server's network card to reach
the bus, and it keeps modem traffic working if the primary is later disconnected.

## Power

The rack is also a power distributor. Feed it once and it powers every slot.

- Use the same OC energy source as the master (Power Converter from the base
  grid, with an optional Capacitor buffer).
- Feed the rack on the **Back** bus, not the data bus.
- Verify with an Analyzer that the rack and each server receive energy.
- Power does not start a server. A server starts only when a player sneak-uses
  its front face (normal use opens its GUI). There is no API to power on another
  server.
- After a world reload, servers are off until a player starts them again. The
  Nodes app shows them as offline; this is expected, not a fault.

## Provisioning procedure

1. Install 0.3.0 on the master as usual.
2. Insert a floppy into the mountable disk drive. The master sees the drive on
   the data bus.
3. In the Nodes app, choose **Prepare installer**. The master writes the
   netboot payload and a manifest to the floppy. The payload is a small
   `/init.lua`, the runtime files, and the slave config template; it fits in
   512 KB.
4. Sneak-right-click the front of an unprovisioned server to power it on. It has
   no boot address yet, so the BIOS boots the only `/init.lua` it can see: the
   rack floppy.
5. The payload sends `HELLO` to the master and waits for `ASSIGN`. The master
   replies with the node's name, role, and its own addresses.
6. The payload copies the runtime from the floppy to the server's first HDD,
   writes `/etc/terracorp.cfg` with `role` and `master`, sets the boot address to
   that HDD, sends `ACK`, and reboots.
7. The server boots its HDD in headless mode and sends `STATUS`. The Nodes app
   lists it as online with its memory and disk capacity.
8. Repeat for the next server. One payload can provision every server on the
   bus; each server is identified by its own computer address, so several may
   be powered on together.
9. Leave the floppy in the drive as a rescue medium. Provisioned servers boot
   their HDD because their boot address is set; the floppy is only used when a
   server has no valid boot address.
10. Record the rack slot, the node name, and the computer address. The OS
    identifies nodes by address, not by physical slot.

Re-provisioning is not automatic. The payload must detect an existing TerraCorp
installation on the target HDD and stop with a message instead of overwriting
it. To reinstall a node in 0.3.0, wipe or replace its system HDD (or use a fresh
server) and power it on with the floppy inserted. Remote reinstall is future
work.

## Node protocol (0.3.0)

Transport: a wired network card, UDP-like modem messages on port `4200`. The
rack's built-in switch is tier 1 and the pack allows 8192-byte packets, but the
protocol stays at or below 1 KB per message. Bulk data is 0.3.2 work.

Frames are text, not serialized tables:

```
TC1 <verb> key=value key=value ...
```

Values are percent-escaped; the parser rejects unknown verbs, missing fields,
and frames over 1 KB. One request produces at most one reply.

| Message | Direction | Fields |
|---|---|---|
| `HELLO` | node to master | `v`, `id` (computer address), `name`, `modem`, `mem`, `disk`, `role=unprovisioned` |
| `ASSIGN` | master to node | `id`, `name`, `role`, `master` (modem address), `masterId`, `token` |
| `ACK` | node to master | `token` (required), `id`, `v`, `boot` (HDD address), `mem`, `disk` |
| `STATUS` | node to master | `id`, `name`, `role`, `state`, `mem`, `disk`, `uptime`, `jobs` |
| `PING` | master to node | `id`, optional `master` and `masterId` |
| `PONG` | node to master | `id`, `state`, `mem`, `disk` |

Rules:

- `id` is `computer.address()`, stable for the life of the computer. `modem` is
  the network card address used for routing.
- The master keeps the registry in `/var/nodes.tsv`, one line per node:
  `id`, `name`, `role`, `modem`, `state`, `mem`, `disk`, `lastSeen`. The
  updater must preserve this file in addition to `/etc` and `/var/notes.txt`.
- A node sends `HELLO` every 5 seconds for 60 seconds after boot, then every 10
  seconds while unprovisioned. It sends `STATUS` every 10 seconds when running.
- The master marks a node offline after 30 seconds without a message and pings
  it once before doing so.
- The master answers `HELLO` only while its installer window is armed (600
  seconds) and only for a node that is not already online. A stale floppy
  therefore cannot overwrite a running node.
- A node adopts `master` and `masterId` from a later `PING`, so replacing the
  master's network card does not require reinstalling every node.
- The token prevents a stale `ASSIGN` from being applied by a node that already
  provisioned. It is not authentication; the cluster is a local cable segment.
- The master never sends code or component requests in 0.3.0. `ASSIGN` only
  carries identity and configuration.

0.3.1 adds `JOB`, `RESULT`, and `CANCEL` on the same port. 0.3.2 adds chunked
`FS_READ`, `FS_WRITE`, and `FS_STAT` frames with checksums and atomic rename.

## Failure modes

| Symptom | Check |
|---|---|
| Server does not boot the floppy | Drive has a floppy; drive primary and server primary are on the same bus; relay is off; the server has no valid boot address |
| Master does not see the drive | Master's card is wired; cable touches the configured rack face; drive primary is on that face's bus; rack is powered |
| Server boots but the master never sees `HELLO` | Network card is installed; server primary is connected; the card's slim row is connected; port 4200 is open; no relay |
| Node disappears when the player leaves | Chunk loader does not cover the rack |
| Node is offline after a world reload | Servers do not auto-start; sneak-use each front face |
| Master cannot read a node's files | Expected: server components are `Visibility.Neighbors`; use 0.3.2 storage, not the bus |
| Provisioning overwrote a node | The payload did not detect the existing install and the node booted the floppy; wipe or replace the HDD and re-provision |

## Build checklist

- [ ] Master has a wired network card in a free expansion slot.
- [ ] Rack is placed with its front accessible and inside a chunk loader.
- [ ] Data bus side is chosen; cable touches that exact face on every rack.
- [ ] Power feed touches a different face; Analyzer shows energy at the rack.
- [ ] Rack holds the mountable disk drive and one to three servers.
- [ ] Every server has CPU, RAM, HDD, EEPROM, and a wired network card.
- [ ] Rack GUI: every server primary and network card on the data bus; drive
      primary on the data bus; relay disabled.
- [ ] Floppy is inserted; the master sees it.
- [ ] 0.3.0 is installed on the master; **Prepare installer** succeeds.
- [ ] Each server is powered on with a sneak-use and appears in Nodes.
- [ ] Rack slot, name, and computer address are recorded.
- [ ] The floppy stays in the drive as a rescue medium.
