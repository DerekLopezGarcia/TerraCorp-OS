# Line node

Status: **0.4.9, built and harness-tested 2026-11-16.** The line node is the
smallest thing that keeps one production line observable and published. It
replaced the cluster layer: no racks, no provisioning, no Vault, no desktop, no
editor (decision 25).

Built as designed: `tc.naming`, `tc.installer` + `boot/install.lua`, the
`role = "line"` runtime, `tc.report`, `tc.master`, and the Nodes and Lines apps.
`npm run size` holds the installer image at 156 KB of the 512 KB floppy, and
`test:naming`, `test:installer`, `test:report`, `test:master` and `test:apps`
cover it. Two facts are still pending an in-game session: a never-booted computer
booting the floppy, and `setBootAddress` on a plain computer.

## What it does

1. Reads the two boundary stocks of its line and caches the answers: one
   component call per second, none while the line is idle (decisions 23, 24).
2. Raises its own level alarms against that cache — `STARVED`, `FULL`,
   `NO POWER`, `STALE`, `UNBOUND`, `COARSE` — plus `STALLED` and `TREND` from the
   local sample ring.
3. Publishes a `STATUS` frame with its name, its worst alarm and its stocks to
   the master, which owns the merged view and the name table (decision 26).
4. Survives alone. With no master it keeps reading, alarming and writing
   `/var/status/last.tsv`. A dead master is silence on the wire, not a stopped
   line, and the last published state stays readable on its own screen.

## Budget

A floppy holds 512 KB in Supersymmetry ([`opencomputers.md`](opencomputers.md)).
The floppy only carries the **installer**: the payload plus `boot/install.lua`,
about 129 KB, so the image uses a quarter of the medium. The writable side —
`/etc`, the sample ring and the log — lives on the node's HDD, which is why
nothing is ever written back to the floppy and why the ring has room to grow.

| Part | KB |
|---|---|
| `init`, `kernel`, `config`, `log`, `util`, `vfs`, `version`, `text` | 46.6 |
| `addr`, `path`, `driver`, `stock`, `tank`, `plant`, `history` | 55.4 |
| `net` + `tc.report` (status publisher) | 12.1 |
| `tc.naming` (normalise, validate, qualify) | 4.0 |
| status page on a screen, if one exists | 3.0 |
| **payload** | **~121** |
| `boot/install.lua` (copy to HDD, config, boot address, reboot) | ~8 |
| **installer image** | **~129** |

Out, with the size it costs: the desktop (`ui` 38, `gfx` 9, `theme` 3, eleven
apps 138), the cluster (`cluster` 43, `node` 29, `netfetch` 23, `vault` 18,
`provision` 15, `netboot` 14, `jobs` 9, `registry` 7, `pull` 7, the Nodes and
Vault apps 30), the external link (`link` 45.5), the book and planner (`book`
11.6 + `plan` 7.6), the line program (`line` 10.8) and the acting layer (`gate`
8.1, `move` 3.0, `halls` 6.3).

Because the installed node runs from the HDD, the floppy no longer caps what the
node may contain — 121 KB of 512 is a quarter of the medium. The real limits are
RAM and the tick budget, and both say keep it small. If `link` or `gate` earn
their place later, they can join without a redesign; the budget below stays as
the target, not as a ceiling imposed by the medium.

`npm run size` fails when the installer image passes the budget, so "it fits on a
floppy" cannot rot in three releases.

## Boot and install

One floppy installs every computer in the plant, and it never gets written to:

1. Flash the installer medium from the master (decision 26): put a blank floppy
   in a disk drive connected to the master, open **Nodes** and press **I** twice.
   The flasher writes `init.lua`, `boot/`, `lib/` and `apps/` (~155 KB of the
   512 KB floppy), the `/installer.lua` marker that makes `/init.lua` run the
   installer, and `/etc/terracorp.cfg` with `role = "line"`, an empty name (the
   node names itself from its output) and this master's address. It refuses a
   floppy holding foreign data and rewrites a floppy it flashed before.
2. Put the floppy in the new computer and power it on. The BIOS runs `/init.lua`
   from the floppy, which sees `/installer.lua` and runs `boot/install.lua`
   instead of the kernel. The installer copies the payload to the computer's
   first writable HDD, writes the configuration there, sets the boot address to
   that HDD and reboots.
3. The node boots from its own HDD. Pull the floppy out: it was only read, so it
   installs the next computer.

A computer that already holds a node is never replaced by accident: the installer
shows the disk it found and waits for `R` (reinstall, keeping `/etc` and `/var`)
or `C` (cancel), and cancels on the 30-second timeout. Without a screen it cannot
ask, so it refuses and leaves the computer alone. An interrupted install carries
`/var/install-incomplete` on the target and is resumed, never mistaken for a
finished one.

No OpenOS, no `fetch.lua`, no netboot, no EEPROM write, no rack. This is the
local version of what `boot/netboot.lua` does for a rack server, minus the
network: no master has to be up for a computer to become a node.

**Two BIOS facts are on the critical path, and neither is verified in-game:**

1. A computer with no boot address must scan its filesystems and boot the
   floppy's `/init.lua` by itself. Any filesystem can be the boot volume and the
   BIOS executes `/init.lua` from the one it selects, but the scan on a
   never-booted computer is assumed, not measured.
2. `computer.setBootAddress()` must work from `/init.lua` on a plain computer.
   The project knows it is available in the running BIOS and may be absent in the
   1.7.x EEPROM sandbox.

If the first fails, the fallback is the EEPROM manager already in
`eeprom/init.lua`. If the second fails, the installer says so and the operator
sets the boot address once by hand — it never pretends the install completed.

## Identity and naming

| | What it is | Where it lives |
|---|---|---|
| `id` | the computer's component address; routes, never shown | addresses |
| `name` | the root of the node's namespace; this is the DNS | `/etc/terracorp.cfg` |
| `path` | `<name>/<stock>`, what humans and the master see | `/etc/paths.tsv` |

A name must be a **path segment**: `[A-Za-z0-9_-]`, no spaces, no slashes, at
most 24 characters. A name with anything else is normalised once at entry
(`Casing Hall` → `casing-hall`) and never kept in two spellings.

**The node qualifies, the master validates.** The node may write `in` and `out`
in its own `paths.tsv`; what it publishes is already `casing/in` and
`casing/out`. The master checks that the first segment is the name it holds and
merges on that string, so thresholds, `recipes.tsv` and `plan()` on the master
speak exactly the same paths the node reports. No translation table, no gateway.

**The master assigns, the node adopts** (decision 26):

- A node contacts the master with its local name as a proposal. The master
  answers `ASSIGN name=<what it holds>`, registering the proposal when that name
  is free, and suffixing it (`casing-2`) when it is not. The node adopts the
  answer and persists it.
- Renaming from the app is therefore one frame: the node adopts on the next
  `HELLO`, re-qualifies its paths on the following scan, and the master lists the
  thresholds, recipes and line rules that still mention the old prefix.
- A node with no master keeps its local name, so it can be commissioned alone.
  If the operator renames it on the node while a master is present, the master
  wins and the node says so on screen and in `/var/log/tc.log`; the rename is
  never silently reverted without a trace.
- A duplicate name is a `conflict` in the registry, visible in the app, never a
  silent merge of two nodes' stocks.

## Status contract

The wire is the existing `TC1` frame: 1024 bytes, percent-escaped values, and
extra scalar fields allowed so a newer peer adds data without breaking an older
one (see `src/lib/tc/net.lua`).

```text
TC1 HELLO  id=<address> name=casing v=0.5.0
TC1 STATUS id=<address> name=casing state=online mem=863 disk=420 uptime=612
    alarm=starved:95 stocks=2
    s=casing/ingots:744:exact:4.8 s=casing/casings:5:exact:0.0
```

- **Cadence:** a heartbeat every 30 s and an immediate frame when an alarm
  changes or a stock disappears. Never on every scan: each component call costs
  about 50 ms of server tick.
- **Size:** about ten stocks with full paths fit in one frame. Beyond that, a
  second frame carries `off=<n>`; if even that is not enough, the node sends the
  stocks with an alarm and aggregates the rest as `others=<n>`.
- **No master:** exponential backoff, the state stays in `/var/status/last.tsv`,
  and the local screen keeps showing it.

## The master

`tc.master` (~10 KB) replaces `tc.cluster` on the desktop: token, `HELLO`,
`STATUS`, `PING`/`PONG`, `ASSIGN` on rename, upsert into `/var/nodes.tsv`, and
`offline` after the stale window. The registry keeps
`id, name, state, lastSeen, v, mem, disk, stocks, alarms, uptime`; `role`, `jobs`
and `drain` go with the racks.

The **Nodes app is the DNS**. One row per node that talks to the master:

| Row | Detail | Actions |
|---|---|---|
| `name` · `online`/`stale`/`offline`/`conflict` · worst alarm · stock count | its stocks with qualified paths, value, state, rate and age | Rename · Ping · Forget |

Racks being gone, the app loses role cycling, draining, job counts and Vault
usage, and stops depending on `tc.cluster`.

## Not here

History longer than the local ring, the reference dataset, planning at scale and
the MCP agent stay outside the node. The external link, the book, the planner
and the acting layer (`gate`, `move`) are not part of the node payload; a later
slice can bring `gate` back if a real gate exists.

## Verification

Everything above is harness work: fake components for the reader, a fake modem
bus with two nodes and a master for the protocol and the registry, a size gate
for the budget, and the 50-screen matrix for the status page. The one in-game
check that cannot be waived is the bare-computer floppy boot in
[Boot and install](#boot-and-install).
