# Line node

Status: **0.4.9, built and harness-tested 2026-11-16.** The line node is the
smallest thing that keeps one production line observable and published. It
replaced the cluster layer: no racks, no provisioning, no Vault, no desktop, no
editor (decision 25).

Built as designed: `tc.naming`, `tc.installer` + `boot/install.lua`, the
`role = "line"` runtime, `tc.report`, `tc.master`, and the Nodes and Lines apps.
`npm run size` holds the installer image at 161.0 KB of the 512 KB floppy, and
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
The floppy only carries the **installer**: the payload plus `boot/install.lua`
and the `/installer.lua` marker. The writable side — `/etc`, the sample ring and
the log — lives on the node's HDD, which is why nothing is ever written back to
the floppy and why the ring has room to grow.

**The payload is a list, not a directory.** `src/lib/tc/payload.lua` names the
files a node carries; `flash.lua` copies exactly that list, `npm run size`
measures it, and `npm run check` fails with `PAYLOAD GAP` if one of those files
asks for a module the list does not carry. Measured on 2026-11-23:

```text
$ npm run size
  22 files, 161.0 KB of 256 KB target  (32% of the 512 KB floppy)
```

The desktop is genuinely out: `tc.theme`, `tc.gfx` and `tc.ui` (about 51 KB) load
only inside the desktop branch of the kernel, and the eleven apps (138 KB) and
`tc.link` (47 KB) are not in the list at all. Before this, the flasher walked
whole roots and wrote 514.2 KB — more than the medium — while the size gate
measured a different, hand-written set and reported 155 KB.

Because the installed node runs from the HDD, the floppy no longer caps what the
node may contain — 163 KB of 512 is a third of the medium. The real limits are
RAM and the tick budget, and both say keep it small. If `link` or `gate` earn
their place later, they can join without a redesign; the budget below stays as
the target, not as a ceiling imposed by the medium.

`npm run size` holds the installer image inside its budget of the 512 KB floppy,
and `npm run check` holds the payload closed, so "it fits on a floppy" cannot rot
in three releases.

## Boot and install

One floppy installs every computer in the plant, and it never gets written to:

1. Flash the installer medium from the master (decision 26): put a blank floppy
   in a disk drive connected to the master, open **Nodes** and press **I** twice.
   The flasher writes the payload named in `/lib/tc/payload.lua` (22 files,
   about 163 KB of the 512 KB floppy), the `/installer.lua` marker that makes `/init.lua` run the
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

No OpenOS, no `fetch.lua`, no netboot, no EEPROM write, no rack. What
`boot/netboot.lua` did for a rack server, this does locally, minus the network: no
master has to be up for a computer to become a node.

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

The wire is the existing `TC1` frame. Frames are sent under the **1 KB send
policy** (`net.lua:3`), and the receive guard is `net.MAX_FRAME = 8192`; values
are percent-escaped, and extra scalar fields are allowed so a newer peer adds
data without breaking an older one (see `src/lib/tc/net.lua`).

```text
TC1 HELLO  id=<address> name=casing v=0.4.9
TC1 STATUS id=<address> name=casing state=online mem=863 disk=420 uptime=612
    alarm=starved:95 stocks=2
    s=casing/ingots:744:exact:4.8 s=casing/casings:5:exact:0.0
```

- **Cadence:** a heartbeat every 30 s and an immediate frame when an alarm
  changes or a stock disappears. Never on every scan: each component call costs
  about 50 ms of server tick.
- **Size:** **eight** stocks with full paths fit in one frame
  (`report.MAX_STOCKS = 8`), as `s1`…`s8`. Anything past that is reported as
  `more=<n>` — the tail is dropped from that frame, never silently renamed. There
  is no `off=` continuation and no `others=` bucket; a node with more than eight
  stocks needs a second frame to be designed, not a second field.
- **No master:** exponential backoff, the state stays in `/var/status/last.tsv`,
  and the local screen keeps showing it.

## The master

`tc.master` (~10 KB) replaces `tc.cluster` on the desktop: `HELLO`, `STATUS`,
`PING`/`PONG`, `ASSIGN` on rename, upsert into `/var/nodes.tsv`, and `offline`
after the stale window. **There is no token handshake** — the wired modem bus is
the boundary (`master.lua:9-10`), and the frame carries the literal `token=none`
only because `net.lua:24` requires the field.

The registry writes **eleven** columns (`registry.lua:14`): `id`, `name`,
`state`, `mem`, `disk`, `lastSeen`, `v`, `modem`, `stocks`, `alarms`, `uptime`.
`modem` stays because the master needs a stored address to reach a node that has
gone quiet (`master.lua:147,193,221,243`). The three rack-era columns — `role`
(which duplicated the runtime role `config.lua` owns), `jobs` and `drain` — were
removed in 0.4.9 (F20): nothing read them.

A file written before that carries fourteen columns, and the 0.3.x shape has
eight. `registry.load` decodes both by width and rewrites the file once in the
current shape, so an upgraded machine **migrates at its first boot** and keeps
its names and modem addresses. A row of an unknown width is skipped rather than
guessed at, because reading the wrong columns would store a wrong record.

The **Nodes app is the DNS**. One row per node that talks to the master:

| Row | Detail | Actions |
|---|---|---|
| `name` · `online`/`stale`/`offline`/`conflict` · worst alarm · stock count | its stocks with qualified paths, value, state, rate and age | Rename · Ping · Forget |

Racks being gone, the app has no role cycling, no draining, no job counts and no
Vault usage, and does not depend on `tc.cluster`.

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
