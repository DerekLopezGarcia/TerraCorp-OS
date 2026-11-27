# Canonical definition — TerraCorp OS 0.4.10 "Compass"

This is the **single authority** for what TerraCorp OS is, what it contains, and
what each document is allowed to claim. It exists because the design documents
were written at different times against three different products (the 0.3.x rack
cluster, the 0.4.x plant readout, the 0.4.9 slave node), and they contradict each
other and the code in ~75 places.

Everything below was read out of the working tree on 2026-11-23; every non-obvious
statement carries a `file:line` citation. Where a citation is missing, the claim
is a **decision** (a choice this document makes), not an observation.

This describes **the working tree**, which differs from published `main` in three
source files — read §10 before comparing anything against GitHub.

## How to use this file

**Authority order when two documents disagree:**

1. `docs/canonical.md` (this file) — the reconciliation.
2. The code under `src/` — what actually runs.
3. `docs/status.md` — the decision register and the build ledger.
4. Everything else — supporting material, correctable without ceremony.

If you change the product, change the code, then `docs/status.md`, then this file,
then the specialist doc. Never the other way round.

**What this file is not:** a replacement for `status.md` (the ledger) or
`architecture.md` (the internals). It settles *conflicts*; it does not restate
everything.

---

# Part I — The system as it exists

## 1. Identity

| Field | Value | Source |
|---|---|---|
| Product | TerraCorp OS | `src/lib/tc/version.lua:5` |
| Company (fictional) | TerraCorp Industrial Systems | `version.lua:6` |
| Tagline | Architects of Dawn | `version.lua:7` |
| Version | **0.4.10** | `version.lua:8`, `package.json:3` |
| Codename | **Compass** | `version.lua:9` |
| API level | 1 | `version.lua:10` |
| License | MIT | `version.lua:11`, `LICENSE` |
| Platform | Lua 5.3, OpenComputers 1.7.x / 1.8.x, Supersymmetry, MC 1.12.2 + Forge | `AGENTS.md:8-14` |

**Single source of truth for identity is `src/lib/tc/version.lua`.** No other file
may declare a version as fact; they may only quote it.

**Built and published.** 0.4.10 was built and tagged `v0.4.10` on 2026-11-27 and
published as a GitHub Release the same day. `v0.4.10` is the newest published
release, so a machine below 0.4.10 sees Compass on its next check.

**0.4.9 is the previous release.** It was built on 2026-11-16, tagged `v0.4.9`
on 2026-11-27 and published. A machine below 0.4.9 updates normally on its next
check.

**Changelog:** 22 entries, 0.3.21 → 0.4.10, newest last
(`src/lib/tc/changelog.lua`). 0.4.3 and 0.4.6 have no entry: they were cut under
those numbers and shipped inside 0.4.8's entry. A node updating from ≤ 0.3.20
gets no notes for the versions it skipped (`kernel.lua:443-456`).

## 2. What the product is

One paragraph, and nothing else may contradict it:

> TerraCorp OS is a **local-first plant readout** for Supersymmetry. A computer
> that can see the two **boundary stocks** of a production line reads them,
> caches the answers, evaluates its own level alarms and shows them. One
> desktop computer per plant acts as the **master**: it holds the node registry,
> which is the plant's naming service (DNS), and merges what the nodes publish
> into one view. A node that loses its master keeps reading, alarming and
> showing. Everything outside the game — long history, the recipe dataset,
> planning at scale, an agent — is **optional** and owns only what a node cannot.

**The product is the fourth row; the first three are optional:**

```text
agent (MCP)        decide goals, priorities, what to switch on   [optional]
plant service      long history, dataset, planner, MCP           [optional]
bridge (HTTP)      one POST per interval, closed verb list
OS de planta (OC)  read, cache, alarm, show; gates and setpoints   <- the product
```

**Hard boundaries:**

- **Lines are black boxes.** Only the input and output boundary stocks are read;
  the machines inside are never polled. A jam shows as a stalled boundary delta,
  not as a named machine fault (decision 24).
- **No accounts, no session locking** (`architecture.md:376`).
- **One Unicode code point = one screen cell.** Wide CJK and emoji are not
  supported (`architecture.md:373`, `README.md:242`).
- **A node must be useful alone, offline, on 1 MB** (`AGENTS.md:86`).

## 3. The two runtime roles

`role` accepts **`desktop`**, **`slave`** and the 0.4.9 compatibility alias
**`line`** (`config.lua:33`). `slave` is the product name; `line` stays accepted
so existing volumes keep booting. The value is read at exactly **one** site:
`kernel.lua:635`. Any other value silently falls back to `desktop`
(`config.lua:135-139`).

| | `desktop` (default) | `slave` / `line` |
|---|---|---|
| Requires a GPU | **yes** (`kernel.lua:741-744`) | no |
| Starts | `tc.plant` → `tc.book` → `tc.plan` → `tc.gate` → `tc.move` → gfx/splash → 12 apps → `ui` → `tc.master` → `tc.flash` → `tc.link` → event loop | `tc.plant` → `tc.report` |
| Apps / UI | 12 apps, windows, taskbar | none |
| Master service | always started, on every desktop | none |
| External link | yes | none |
| Evidence | `kernel.lua:672-901` | `kernel.lua:633-670` |

Release notes (`/var/whatsnew.md`) are written **before** the role split, so a
headless node gets them too (`kernel.lua:629-631`).

**One `role` namespace is left. Do not reintroduce the second:**

- `config.get("role")` — the **OS role**: `desktop` | `slave` | `line`
  (`config.lua:33`).
- There is **no** `registry.role` any more. The node registry lost the column with
  F20 (2026-11-23); the master never needed it, and the `worker`/`storage` values
  were rack-era residue that nothing read. `registry.setRole` and
  `registry.aggregate` went with it.

## 4. The app set — twelve, no more, no fewer

`APP_IDS` (`kernel.lua:14`), loaded in this order:

```lua
{ "dashboard", "files", "console", "settings", "notes", "update",
  "nodes", "gaia", "lab", "plant", "lines", "dns" }
```

| order | id | title | short | icon | iconArt | style |
|---|---|---|---|---|---|---|
| 1 | `dashboard` | System | System | `SYS` | 9×5 | **accent** |
| 2 | `files` | Files | Files | `FIL` | 9×5 | — |
| 3 | `console` | Terminal | Terminal | `TRM` | 9×5 | — |
| 4 | `settings` | Settings | Settings | `SET` | 9×5 | — |
| 5 | `notes` | Notes | Notes | `NTS` | 9×5 | — |
| 6 | `update` | Update | Update | `UPD` | 9×5 | — |
| 7 | `nodes` | Nodes | Nodes | `NOD` | 9×5 | — |
| 8 | `gaia` | GAIA | GAIA | `GAI` | 9×5 | — |
| 9 | `lab` | Lab | Lab | `LAB` | 9×5 | — |
| 10 | `plant` | Plant | Plant | `PLT` | 9×5 | — |
| 11 | `lines` | Lines | Lines | `LIN` | 9×5 | — |
| 12 | `dns` | DNS | DNS | `DNS` | 9×5 | — |

**Facts and rules derived from this table:**

- An app's **id is its filename**; `check.js:142-144` enforces it.
- Every app must ship a 3-cell `icon`, a `short` label and a 9×5 `iconArt`
  (`check.js:145-161`, `AGENTS.md:119-121`). No exceptions, no taskbar-only apps.
- **Icon codes and `order` values are unique and contiguous**, and `check.js`
  enforces both since 2026-11-23: a duplicate code makes two apps draw identically
  on a shrunken tile, and a gap in `order` makes the F-key map depend on load
  order. Before this, `notes` and `nodes` both shipped `NTS` and `order = 8` sat
  unused for two releases because nothing checked either.
- **F-keys are positional, not by `order`:** `ui.lua:1327-1329` binds `F1`…`F10`
  to dashboard…plant *after sorting by `order`*. Today that is
  dashboard…plant (F1…F10). **`lines` is 11th and `dns` is 12th; neither has a
  function key.** The UI correctly hints `F1-F10` (`ui.lua:820,988`).
- `iconStyle = "accent"` is allowed only on `dashboard` (and only `nil`/"accent"
  pass `check.js:151-153`).
- The app contract is `{ id, title, short, icon, iconArt, iconStyle, order,
  create(ctx) }` plus instance `draw`, `handle`, optional `tick`, optional
  `close`. `architecture.md:155-214` is correct; the short docstring at
  `ui.lua:3-5` is not (it omits `iconArt`/`iconStyle`).

## 5. Modules — 41 under `lib/tc`

All 41 are referenced; none is missing or orphaned. Grouped by what they serve:

**Boot / platform (8):** `vfs`, `config`, `log`, `util`, `text`, `theme`,
`version`, `gfx`.

**Desktop (3):** `ui`, `keys`, `lab`.

**Plant readout and plan (10):** `addr` (physical addresses), `path` (semantic
paths), `driver` (declarative drivers), `stock` (boundary reader), `tank` (fluid
normalisation), `plant` (readout, cache, alarms), `history` (bounded ring),
`book` + `plan` + `line` (recipes, planner, line-program parser).

**Slave node / network (7):** `net` (TC1 frames + modem), `naming`, `registry`,
`master`, `report`, `installer`, `flash`.

**DNS1 / direct query (6):** `frame` (the shared one-line codec), `value` (the
safe value grammar), `dnsnet` (port 4201 on every modem), `dnsnode` (documents
and executes this node's services), `dnsmaster` (the snapshot catalog), and
`dnsclient` (master route with a direct fallback).

**Acting layer (3):** `halls`, `gate`, `move`.

**External link (1):** `link`.

**Release (3):** `updater`, `changelog`, `payload` (the flashed file list the
size and closure gates share).

## 6. Data on disk

Config is a serialized Lua table in `/etc/terracorp.cfg`, 19 keys, all written on
every save (`config.lua:9-29,51-74`):

`accent`, `charset`, `clock24`, `splash`, `logLevel`, `name`, `hostname`,
`iconOrder`, `iconLayout`, `role`, `master`, `linkSink`, `linkToken`,
`linkInterval`, `linkControl`, `dnsMaster`, `dnsPort`, `dnsTransport`,
`dnsPassword`.

**`hostname` is read (`kernel.lua:594`) but never written** — Settings has no row
for it, so the operator sets it by hand in the configuration file. **No key selects the link transport:** `linkTransport` is a name used in design
notes, is absent from `config.lua`, and `config.set` rejects unknown keys, so it
could never be stored today. DNS1 has its own `dnsTransport`
(`auto`/`wired`/`wireless`), which restricts sends only; it never hides an
inbound frame.

**`/etc` (operator-authored, survives updates):**

| Path | Meaning |
|---|---|
| `/etc/terracorp.cfg` | preferences + role + link settings |
| `/etc/plant.tsv` | which stocks the line has |
| `/etc/stocks.tsv` | stock declarations |
| `/etc/paths.tsv` | local semantic paths |
| `/etc/recipes.tsv`, `/etc/recipe-io.tsv` | the operated book |
| `/etc/lines/*.line` | line programs (data, never code — `tc.line`) |
| `/etc/gates.tsv` | line → gate component/face (`gate.lua:17`) |
| `/etc/halls.tsv` | hall name → computer address (`halls.lua:11`) — **read every boot, never written** |

**`/var` (machine-written):**

| Path | Written by |
|---|---|
| `/var/nodes.tsv` | node registry (`registry.lua`) — **is the DNS** |
| `/var/status/last.tsv` | last published status of a node with no master |
| `/var/plant/history.tsv`, `seen.tsv`, `calibration.tsv` | ring, first-seen, calibration |
| `/var/gates.tsv` | gate setpoints (`gate.lua:18`) |
| `/var/notes.txt` | Notes app |
| `/var/lab/script.lua`, `/var/lab/repl.lua` | Lab buffer and interpreter |
| `/var/log/tc.log` (128 KiB rotate), `/var/log/lab.log` (64 KiB rotate) | logs |
| `/var/version` | last booted build |
| `/var/whatsnew.md` | release notes of every skipped version |
| `/var/update/pending`, `stage/`, `backup/`, `status` | updater |
| `/var/install-incomplete` | interrupted install marker |

**Never touched by the updater** (user data): `/etc/terracorp.cfg`,
`/var/notes.txt`, `/var/nodes.tsv` (`architecture.md:60-73`).

## 7. Protocols

### 7.1 TC1 — the in-world frame

- One line of text: `TC1 <VERB> key=value key=value …`
- Values percent-escape `%`, space, tab, CR, LF, `=` (`net.lua:3-10`).
- Port **4200** (`net.lua:14`).
- **Frame cap — the working tree has moved, deliberately.** Committed `main`
  (7ed69d2) has `net.MAX_FRAME = 1024`. **This working tree has an unpublished
  edit raising it to `8 * 1024` (8192), and made the matching change in
  `tools/bridge/bridge.js`** (§10), so it is not a stray edit: both ends of the
  wire were raised together. Six documents still say "capped at
  `net.MAX_FRAME` = 1024", which is now stale. The 1 KB *send policy* in
  `net.lua:3` is the rule that survived, and it should be the one the documents
  cite; the received frame may now be 8 KB. F27.
- **34 verbs declared, 11 in use:** `ASSIGN`, `CFG`, `CFGACK`, `HELLO`, `LDATA`,
  `LEND`, `LINK`, `LREP`, `PING`, `PONG`, `STATUS`. The other 23 (`ACK`, `LIST`,
  `FETCH`, `DIRS`, `DATA`, `MISS`, `PULL`, `JOB`, `CLAIM`, `GRANT`, `RESULT`,
  `CANCEL`, `DRAIN`, `VDISK`, `VOPEN`, `VDATA`, `VDACK`, `VDONE`, `VERR`,
  `VREAD`, `VLST`, `VDIRS`, `VDEL`) are rack/Relay/Vault residue kept only for
  old peers.

### 7.2 DNS1 — the direct node query

DNS1 is the direct node query, now through **M5** (complete registry, delta
publishes, document edits, state, inbox and the DNS console). It runs beside TC1, on its own
port, so a tablet can ask one node what it offers without going through the
master. The DNS app is the tablet console; the protocol itself is feature-complete.

- One line per frame: `DNS1 <VERB> key=value …` (`dnsnet.lua`). Every modem
  answers on port **4201**. DNS1 is built to reply through the modem that heard
  the request, not through the first wired modem: it caches the first
  `modem_message` string as the receiver for that peer and answers through it,
  and accepts a side name in the same slot. The harness proves the side-name and
  address reply paths; the real first-field semantics are pending S9.
- **Transaction limits:** a request is at most **900 B** (the TC1 send policy),
  a received frame at most **8192 B**, and a value at most **4096 B**. A request
  that would exceed the send limit is refused locally with `too_large`; it is
  never put on the wire.
- **Every request carries `rid`**, eight hex characters generated by the node or
  client, and every reply echoes it. `id` names the sender. A transport also
  drops a repeat of the same `(from, rid)` within five seconds, so a modem that
  delivers an event twice cannot execute a method twice. Replies (`*ACK` and
  `ERR`) are never deduplicated: they are idempotent above this layer, and a
  `PUBLISHACK` sharing a client's first `rid` must not make the relayed request
  look like a duplicate.
- The transport parses the event defensively: it looks for the `DNS1 ` message
  and a numeric port 4201 in the documented
  `(receiverAddress, senderAddress, port, distance, message)` shape or the
  shorter shape some hosts produce. **The real in-game argument order and the
  wireless packet limit are still unverified (S9);** the parse accepts both
  shapes, and the fallback reply path is why a1 is not signed off yet.

The verbs (`dnsnet.VERBS`):

| Verb | Fields | Answer |
|---|---|---|
| `HELLO` | `rid id node proto boot transports` | `HELLOACK rid id proto ver boot transports` |
| `DESCRIBE` | `rid id target` | `DESCRIBEACK rid id body=<value>` |
| `EXEC` | `rid id target method` plus `p=<value>` | `EXECACK rid id ok=true body=<value>` or `ok=false err=<code>` |
| `EDIT` | `rid id target field rev` plus `p=<value>` | `EDITACK rid id ok=true rev=<n>` or `ok=false err=<code> rev=<n> body=<value>` |
| `PUBLISH` | `rid id ver part rev full` plus `p=<value>` | `PUBLISHACK rid id ver part ok` or `ok=false` / `need=full` |
| `CATALOG` | `rid id` plus optional `cursor page` | `CATALOGACK rid id body=<value> stale=<bool>` |
| `WHO` | `rid id` | `WHOACK rid id node proto ver boot` |
| `ERR` | `rid id err` | sent by the transport for an unknown verb |

`target` is `node`, `endpoint:<name>` or `path:<name>`. `HELLOACK.ver` is the
DNS1 protocol version (`2` in M1); the node's own version travels as `node.ver`
in a DESCRIBE snapshot (and in `dns.status`). Values use the `tc.value` grammar:
`nil`, booleans, numbers, quoted strings and tables with integer or string keys,
encoded canonically (integers first, then strings); functions, userdata,
threads, NaN and infinities are refused. The codec never calls `load`, so a
frame cannot execute code while it is being decoded.

A node registers three kinds of thing: components (a component address and a
method list), services (a Lua handler), and paths (a named group of endpoints).
A method is executable only when it is both **documented** and named in that
endpoint's explicit `allow` list. An announced method outside the list answers
`denied` without invoking the component; an unknown method answers
`unknown_method`. `getAllStacks` is the allowed method on
`endpoint:inventory_controller` (and `inventory_controller_2`); `getStackInSlot`
is documented but deliberately denied. `endpoint:dns.status` is a service whose
`status` method returns the node id, name, version, boot id, port, transports,
uptime, snapshot version, published version and publish counters.
`endpoint:plant` is registered when the role owns a plant; it serves `status`,
`alarms` and `snapshot` from the same cache the desktop apps read.
`endpoint:state` is a small persistent key-value store (`get`, `set`, `delete`,
`list`); `endpoint:inbox` is a bounded message queue (`post`, `list`, `take`,
`clear`). Both keep their data in the node's `/var/dns` VFS and survive a
restart. The paths are `path:status` (`dns.status`), `path:inventory` (every
inventory controller, only when one exists) and `path:spike` (`dns.status` +
`inventory_controller`) kept for M0 clients. A path only groups names;
membership is not an extra allow list.

### 7.2.1 The registry index

The index is a **manifest**, not a second copy of every endpoint document. Each
entry carries only the endpoint `name` and its `rev`; `DESCRIBE
endpoint:<name>` returns kind, type, methods, allow list, tags and docs. Keeping
the index small lets a node with many endpoints fit its index in one frame, and
lets a delta publish send only endpoint parts whose `rev` changed.

A node publishes the index first, then endpoint parts. The fields are `ver`
(snapshot version), `part` (`index` or `endpoint:<name>`), `rev` and `full`
(`true` on the first publish, after a boot change, after a master requests
`need=full`, or when the snapshot version moves backwards). The master
acknowledges each part; the node keeps a publish in flight until every part is
acknowledged, retries after 30 s, and counts `full`, `delta`, `heartbeat`,
`resync` and `failed` publishes. A quiet node sends an index-only **heartbeat**
every 45 s, which refreshes `lastSeen` without resending endpoint bodies.

**EDIT** is optimistic. The caller names the `rev` it last read; the node
compares it to the endpoint revision (or, for the `node` target, the snapshot
version). A stale write answers `err=conflict` with the current revision and the
current encoded document, so the console can show both sides and resend. Only
`docs` and `tags` are editable — methods, allow lists and identity stay owned by
the node's code. A successful edit bumps the snapshot and republishes that one
endpoint part. Overrides are saved to `/var/dns/edits.value` and applied when
the endpoint registers after a restart. An edit that would make a part larger
than **800 B** is refused with `too_large` rather than breaking the frame budget.

**EXEC** accepts at most **8 positional arguments** and returns a body of at
most **760 B**; a larger result answers `too_large` before the transport has to
drop a frame, and a non-array `p` answers `bad_args`. Paths return one result
per member, each with its own `ok`/`err`, so one denied member does not hide the
others. The codec is the same `tc.value` grammar: it refuses functions and
never calls `load`.

**STATE** keeps at most **32 keys**, each a `[A-Za-z0-9_.-]` name of at most
32 characters; the encoded store is capped at **4096 bytes**. **INBOX** keeps at
most **32 messages**, each encoded message at most **1024 bytes**, and returns
them oldest first. A full inbox answers `full`; a missing state key or message id answers
`missing`. Both are ordinary services, so a client reaches them with `EXEC
endpoint:state …` or `EXEC endpoint:inbox …`; the node also exposes the same
operations as Lua methods for the local app.


The master's cache is persisted (`dnsmaster.lua`). Each complete node snapshot
is encoded with `tc.value` into `/var/dns/<safe-id>.value`; the master loads the
directory at startup, ignores an entry whose index names endpoints with no
stored part, saves at most every 2 s while dirty, and deletes the file when an
entry is evicted. The master serves only a **complete** snapshot. A newer
version, or a new boot id, replaces an old snapshot; a node silent for **90 s**
is marked stale but is not deleted. A delta whose base is missing, incomplete or
from another boot is answered with `need=full` and the node republishes
everything on its next tick. The catalog pages by node id, defaults to eight
rows and caps at 32; it reports `total`, `page` and `count`, and each node a
`loaded` flag. A client talks to `dnsMaster` when configured; if the master is
silent, `tc.dnsclient` falls back to a direct `WHO` plus a request to the node,
which is the path the tablet uses.

`dnsMaster` is `""` (DNS1 off on this desktop), `"self"` (this desktop is the
master), or a master address (this desktop is a client). A slave node with
`dnsMaster = ""` uses its TC1 `master` address for publishing; with both empty
it still serves DNS1 but logs that it has nowhere to publish. `dnsPort` defaults
to 4201 and `dnsPassword` is a reserved empty placeholder — M5 still has **no
authentication**.

Settings → DNS edits those three keys in place. The mode row cycles Off,
Master and Client; Client needs a full 36-character address; the port accepts
1–65535; the transport cycles `auto`, `wired` and `wireless`. Apply writes
`/etc/terracorp.cfg` through `config.save`, calls `kernel:restartDns()` to close
the old transport and start the new mode without a reboot, and restores the
previous values if the write or the start fails. Master mode replaces the address
field with this computer's full address so a client can be pointed at it. The
status line reports `Master · port 4201 · N nodes`, `Master · port 4201 not open`,
`Client · <short id>` or `Off`. The page exists only on a desktop: a slave has no
Settings window and keeps its installer/configuration publish target. The page is
part of **0.4.10 Compass**; 0.4.9 itself still used the configuration file and a
reboot.

### 7.3 The node status contract

```text
TC1 HELLO  id=<address> name=casing v=0.4.10
TC1 STATUS id=<address> name=casing state=online mem=863 disk=420 uptime=612
    alarm=starved:95 stocks=2 more=0
    s1=casing/ingots:744:exact:4.8 s2=casing/casings:5:exact:0.0
```

- **At most 8 stocks per frame** (`report.lua:20 MAX_STOCKS = 8`), keys
  `s1`…`s8` (`report.lua:190`), overflow reported as **`more=<n>`**
  (`report.lua:193`).
  The old `line-node.md` text claimed ten stocks, `off=<n>` and `others=<n>`:
  all three were wrong.
- Cadence: heartbeat every 30 s plus an immediate frame when an alarm changes or
  a stock disappears. Never per scan — each component call costs ~50 ms of
  server tick (`line-node.md:154-157`, `tests.md` probe answers).
- **There is no token handshake.** The wired modem bus is the boundary
  (`master.lua:9-10`); the frame carries the literal `token=none` only because
  `net.lua:24` requires the field.

### 7.4 The External Link — a closed command set of 25

One POST per interval; `linkControl` decides how far the far side reaches
(`link.lua:64`):

| tier | rank | commands |
|---|---|---|
| **read** (14) | 1 | `status`, `log`, `check`, `fs.list`, `fs.read`, `plant.status`, `plant.snapshot`, `plant.delta`, `plant.alarms`, `plant.book`, `plant.plan`, `plant.history`, `plant.paths`, `plant.halls` |
| **link** (1) | 0 | `link.interval` |
| **write** (9) | 2 | `gate.set`, `fs.write`, `fs.append`, `fs.mkdir`, `fs.remove`, `fs.move`, `app.open`, `app.close`, `reboot` |
| **full** (1) | 3 | `lua` |

- **Tiers:** `linkControl` ∈ `off` | `read` | `write` | `full`, default `off`
  (`config.lua:102-105`), ranked `{ link=0, off=0, read=1, write=2, full=3 }`
  (`link.lua:64`). **`off` means off**: only `link.interval` (tier `link`, rank 0)
  reaches the OS. `read` is a level of its own, `write` adds user data, `full`
  adds the OS tree and `lua`.
  Before 0.4.9 `off` and `read` shared rank 1, so the default silently allowed
  every read command; a machine still carrying `off` and being polled for data
  must be moved to `read`.
- `/init.lua`, `/boot/`, `/lib/`, `/apps/` are **PROTECTED**: writes there need
  `full` (`link.lua:66-77`).
- A command not in the table is rejected `unknown_cmd` (`link.lua:494-496`).
  **There is no item `move` command** — item transfer is designed in
  [`names.md`](names.md) and [`bus.md`](bus.md) and not built; `fs.move` is a
  file rename.
- `gate.set` answers `desired=<0|1> actual=<0|1>`, and `state` is `0`/`1`
  everywhere; `open`/`closed` was a documentation error, fixed 2026-11-23. See
  the command table in [`external-link.md`](external-link.md#command-set-closed).

### 7.5 The bridge and the agent

- `tools/bridge/bridge.js` — HTTP bridge, default port **8787** (`bridge.js:32`),
  endpoints `/link/queue`, `/link/next`, `/link/results`, `/link/mirror`,
  `/link/state`.
- `tools/bridge/mcp.js` — **read-only** MCP server over stdio, **9 tools**:
  `plant_situation`, `stock_query`, `alarm_list`, `history`, `plan`, `path_list`,
  `path_query`, `recipe_query`, `audit_tail`. Every answer names the verb behind
  it; a missing reading is an error, never a zero.
- The bridge and the MCP server are **outside** the game and require Node.js.
  They are not part of the boot volume.

## 8. Install, update, and the floppy

**Update path:** GitHub Releases → `/var/update/stage` → `/boot/apply.lua` before
the kernel starts → rollback on failure (`versioning.md`, `architecture.md:322-339`).
An in-game update installs only the **49** manifest entries under `src/`
(`apply.lua:326`); `eeprom/init.lua` and the four `tools/*.lua` entries are inert
in that path.

**Install path (slave node):** a floppy flashed by the master, containing
`/init.lua`, `/boot`, `/lib`, an `/installer.lua` marker and a generated
`/etc/terracorp.cfg`; `/init.lua` sees the marker and runs `boot/install.lua`
instead of the kernel (`init.lua:107-142`, `flash.lua:17-26`).

### 8.1 The flashed set is an explicit payload (fixed 2026-11-23)

The flasher used to copy whole roots — `ROOTS = { /init.lua, /boot, /lib, /apps }`
= **526,540 B (514.2 KB)** — onto a **524,288 B (512 KB)** floppy, refusing unless
`total - used >= bytes + 8 KB`. **Every flash failed**, deterministically. The
size gate reported 155.0 KB because it measured a hand-written 21-file list the
flasher never read, and `test:flash` was green because its fake master volume
held nine stub files of about 120 B.

The list now lives once, in `src/lib/tc/payload.lua`:

| Quantity | Now |
|---|---|
| payload files | **26** |
| installer image (payload, marker, config) | **237.3 KB** |
| medium | 512 KB floppy, 8 KB margin |
| gate | `npm run size` — 256 KB target, and fails if image + margin exceeds the medium |
| closure | `npm run check` — fails with `PAYLOAD GAP` |

Three gates now agree, which is the whole point:

- `flash.lua` copies exactly `payload.files` and nothing else.
- `size.js` measures that same list (plus the `/installer.lua` marker and the
  generated config), so what it weights is what gets written.
- `check.js` fails when a payload file asks for a module that is in neither
  `payload.files` nor `payload.desktopOnly`. The two lists together are the
  contract.

The desktop UI (`tc.theme`, `tc.gfx`, `tc.ui`, ~51 KB) is now loaded inside the
desktop branch of the kernel, so a headless node no longer carries a screen it
does not have.

**Proof the gate bites:** delete `/lib/tc/plant.lua` from the list and
`npm run check` fails with `PAYLOAD GAP /boot/kernel.lua:631` and `:678`, exit 1.
An earlier version of the gate missed it entirely — it matched `require("tc.x")`
and the kernel calls `pcall(requireModule, "tc.x")`.

P3 is closed: `line-node.md`'s size prose, `status.md:128` and `roadmap.md:515`
now quote the `npm run size` line, and the gate is the single source for all of
them (F16).

## 9. Verification gates — real numbers

`npm run` exposes **58** scripts (`package.json:7-66`).

| Gate | Command | What it really checks | Real number |
|---|---|---|---|
| Compile + manifest + icons + payload | `npm run check` | every `.lua` under `src`, `eeprom`, `tools` compiles; manifest matches the tree; each app's icon shape; the node payload is complete and closed | **80** files, **62** manifest entries, 0 `PAYLOAD GAP` |
| Manifest | `npm run manifest` | rewrites `tools/manifest.txt` | 62 |
| Desktop smoke | `npm run sim`, `sim:oc` | fake-component boot | — |
| Screen matrix | `npm run test:screens` | 10 scenarios × 5 resolutions | **50** combinations |
| Link | `npm run test:link` | the closed command set | **48** scenarios |
| Bridge | `npm run test:bridge` | HTTP endpoints + mirror parsing | 20 asserts |
| MCP | `npm run test:mcp` | identity, 9 tools, first answers | 20 asserts |
| Size | `npm run size` | the payload `payload.files` describes, against a 512 KB medium / 256 KB target | **26 files, 237.3 KB** (see §8.1) |
| Others | `test:plant`, `history`, `book`, `field`, `line`, `naming`, `installer`, `report`, `master`, `apps`, `flash`, `fetch`, `install`, `boot`, `faults`, `gaia`, `dns` | module-level behaviour | ≈706 assertions + 222 DNS1 checks |

**`check.js` does not validate** icon-code uniqueness or `order` uniqueness —
which is exactly how `NTS`/`NTS` and the `order = 8` gap shipped.

**The screen matrix composition** is `dashboard, desktop, console, files,
settings, notes, updater, nodes, lines, plant, dns` (`test-screens.js:12`) —
Lines, not Vault, and the DNS console last. 11 × 5 = 55.

The harness is a smoke test, not a substitute for in-game verification
(`AGENTS.md:122-124`, `README.md:231-233`). Two line-node facts remain unverified
in-game: a never-booted computer booting the floppy, and
`computer.setBootAddress()` from `/init.lua` on a plain computer
(`line-node.md:93-105`).

**Baseline run, 2026-11-24** (Node v26.13.1, npm 11.20.0, dependencies installed
with `npm install`): `check` 80 files / 0 errors / manifest 62 · `size` 26 files,
237.3 KB (46 % of the medium) · `test:link` 48 scenarios, 0 failures · `sim` and
`sim:oc` clean · `test:screens` 55 combinations, no failures · `test:flash`,
`test:installer`, `test:naming`, `test:report`, `test:master`, `test:apps`,
`test:plant`, `test:history`, `test:book`, `test:field`, `test:line`, `test:gaia`,
`test:mcp`, `test:bridge`, `test:dns`, `test:docs` all pass — 27 gates, every
exit code 0.

**Read that baseline carefully.** On 2026-11-23 it was fully green *while F13 was
true*: the flasher wrote 514.2 KB to a 512 KB medium and no gate could see it.
A green run means "no regression", never "the product works". When a card claims
something is fixed, the evidence must be a test that would have failed before the
fix — the payload gate, the `off` tier and the sub-second floor were each proved
that way.

## 10. State of the working tree (read this before trusting any diff)

The folder is a git repository since 2026-11-23, tracking the real upstream:
`main` → `origin/main`. The 0.4.9 release commit is tagged `v0.4.9`; the 0.4.10
release commit is tagged `v0.4.10`. The flash-card work still sits uncommitted
in the working tree.

**0.4.10 Compass** adds the Settings → DNS page and the `slave` role name while
keeping `line` as a compatibility alias. `v0.4.10` is the current tag and GitHub
Release.

The files that were unpublished when this audit started now live in specific
commits:

| File | Change | Status |
|---|---|---|
| `src/lib/tc/net.lua` | `MAX_FRAME` 1024 → `8 * 1024` | committed in `adda7b4` |
| `src/lib/tc/config.lua` | `linkInterval` accepts `>= 0.5`, and `linkControl` accepts `read` | `adda7b4`, `0e34837` |
| `src/lib/tc/link.lua` | `MIN_INTERVAL` 0.5, `plantSeconds()`, clamping; `off` no longer shares a rank with `read` | `adda7b4`, `0e34837` |
| `tools/bridge/bridge.js` | `MAX_FRAME` 8192, `DECIMAL` + `isPositiveSeconds()`, fractional `link.interval` | `adda7b4` |
| `docs/canonical.md` | this file | `189b9df` onwards |
| `package-lock.json` | `version` fields 0.3.20 → 0.4.9 | `78eb68f` |

`node_modules/` is present and gitignored. `.link.token.tmp` (a 16-byte link
token) is **untracked and not covered by `.gitignore`** — it must be ignored
before anyone runs `git add -A`.

The four code edits are one deliberate feature, not drift: **sub-second link
intervals**, changed at both ends of the wire. The OS lowers its floor to 0.5 s
and formats the fractional interval (`plantSeconds`), and the bridge accepts a
fractional `n` for `link.interval` instead of rejecting it as a non-integer. That
is why `link.interval` takes 0.5 s, and it is why `MAX_FRAME` is 8192 here — the
raise was applied to `net.lua` and `bridge.js` together, so it was intentional.

Two consequences:

- **F27 is now a documentation task, not a decision.** 8192 is the intent; the
  six documents that say "capped at 1024" are stale and must cite the 1 KB send
  policy instead.
- **P5 must account for the fractional interval.** Both ends are committed
  (`adda7b4`), covered by `interval_floor` and `test:bridge`, and exercised
  against the live rig — see `tests.md`, "0.4.9 sub-second link intervals".

Conversely, **F01 is upstream, not local**: the published README really does say
"Current version: 0.4.8 Keystone" while `version.lua` says 0.4.9. The
contradictions in this document are therefore mostly committed defects, with a
small unpublished tail.

---

# Part II — The decision register, reconciled

29 decisions (`status.md:38-127`). "Status" is this document's verdict.

| # | Decision | Status |
|---|---|---|
| 1 | System model: app server + terminals | **Superseded by 25** |
| 2 | No accounts | **Active** |
| 3 | Native Remote Terminals | **Superseded by 25** |
| 4–7 | Core apps, 0.3.x split, rack discovery | **Superseded by 25** |
| 8 | Plant readout ships before sessions | **Active** |
| 9 | External link on one machine first; WAN parked | **Active** |
| 10 | TerraCorp is the control plane, not the transport | **Amended by 28** |
| 11 | AE2 is a crafting terminal, not the store | **Active** |
| 12 | Vault holds files, not goods | **Moot** — the Vault is gone (25). The rule survives as: *the OS never stores goods; the world's containers do.* |
| 13 | Recipes are calibrated before trusted | **Active** (subject moved: the book is local) |
| 14 | The long-lived brain lives outside the world | **Amended by 23** |
| 15 | The decision-maker is a local MCP agent, deterministic tools | **Active** |
| 16 | The node is a translator; no cross-hall text | **Amended by 23** (local level thresholds against its own cache are allowed) |
| 17 | Its first job is a DNS: semantic hierarchical paths | **Amended by 26** (node name is the root of the path) |
| 18 | Hardware facts live in the world; a gate's desired state persists | **Active** |
| 19 | Recipes may be imported, never redistributed | **Active** |
| 20 | The plant runs on plain computers, not rack servers | **Active** — 25 removed the rack layer under it; the rule stands |
| 21 | Two namespaces: addresses route, paths search | **Amended by 26** (no gateway; it went with the second hall) |
| 22 | Component kinds are plugins; a plugin is data | **Active** (`tc.driver`) |
| 23 | Self-contained readout first (2026-11-15) | **Active** — the pivot that everything after it assumes |
| 24 | Lines are black boxes (2026-11-15) | **Active** |
| 25 | Racks dropped, slave nodes instead (2026-11-16) | **Active** — supersedes 1, 3–7, 14 and F2, not 20; 12 moot, 13 re-pointed |
| 26 | The node registry is the DNS (2026-11-16) | **Active** — **reconciled by 26-A**: the hall module stays, the file and the gateway are gone |
| 27 | The sidecar replaces the card, not the protocol | **Active, not built** (0.4.11) |
| 28 | A bus may move stock between named endpoints | **Active, not built** (0.4.12) |
| 29 | DNS1 overlays port 4201 and leaves TC1 intact | **Active** — M5 registry, delta publish, EDIT, state, inbox and console; no TC1 verb or byte changed |
| 30 | The headless role is `slave`; `line` is a compatibility alias | **Active (0.4.10)** — new installs write `slave`, 0.4.9 volumes keep booting |

**The register was corrected on 2026-11-23 (F33-F37).** The heading said
"Decisions, 1-27" over 28 entries, `roadmap.md`'s copy stopped at 27, decision 25
claimed to supersede 20 — which asks for exactly the removal 25 performs — and 12
and 13 lost their subject with the Vault. The heading now reads 1-29 and both lists
carry 30; 25 supersedes 1, 3–7, 14 (service tiers) and F2 only; 12 is moot with its
rule kept, and 13 is re-pointed at the local book (`status.md:38`, `:48-54`,
`:79-86`; `roadmap.md:764-770`, `:899-912`, `:948-955`).

**Decision 26 vs the code (closed by 26-A, 2026-11-23):** 26 removed the gateway
and the `/etc/halls.tsv` file, not the merge. `plant.lua:316-321` builds the hall
in memory from the node's own name, `halls.load`, `halls.save` and `halls.PATH` were
deleted in `6236f99`, `halls.lua` still ships because the plant requires it
(`payload.lua:27`), and `plant.halls` stays a read verb (`link.lua:48`).
`roadmap.md:341-343` says the plant no longer loads `/etc/halls.tsv`; `status.md:94-101`
and `roadmap.md:926-933` record the amendment as 26-A.

---

# Part III — Reconciliation register

75 findings, each with a work package. IDs are stable: cite `F12` in a commit or
a card. Severity: **H** breaks the product or a promise, **M** misleads a reader,
**L** cosmetic.

## P1 — Identity and version (5)

**All five fixed 2026-11-23.** README and blackbox say 0.4.9 Flint; the sample
frame carries `v=0.4.9`; roadmap records the 2026-11-27 tag; and `versioning.md`
records the tag and its remaining caveat.

| ID | Sev | Finding | Where |
|---|---|---|---|
| F01 | H | README advertises 0.4.8 "Keystone"; code says 0.4.9 "Flint" | `README.md:7` vs `version.lua:8-9` |
| F02 | H | `blackbox.md` asserts 0.4.8 in a table whose Source column points at the file that disproves it | `blackbox.md:16` |
| F03 | M | `tests.md` has no 0.4.9 section and no 0.4.9 results-log entry | `tests.md:14-38`, `:653-1014` |
| F04 | M | "0.4.9 shipped" is stated as fact while `v0.4.8` is the last tag and the first-boot check is pending | `roadmap.md:501-512` vs `versioning.md:70-71` |
| F05 | L | The sample `HELLO` frame carries `v=0.5.0` | `line-node.md:148` |

## P2 — App contract and desktop facts (7)

**All seven fixed 2026-11-23.** `nodes` got its own code (`NOD`), the `order`
values run 1..11 with no gap, `check.js` now fails on a duplicate code or a gap,
and the four documents that listed the 0.4.8 app set were corrected.

| ID | Sev | Finding | Where |
|---|---|---|---|
| F06 | H | **Fixed.** `nodes` and `notes` shared `NTS`; `nodes` is `NOD` | `nodes.lua:15` |
| F07 | H | **Fixed.** README, AGENTS, architecture and blackbox now list the same eleven ids, with `lines` in and `vault` out | `README.md`, `AGENTS.md:26`, `architecture.md:94`, `blackbox.md:79` |
| F08 | M | **Fixed.** `order` runs 1..11; the 8 gap is closed | `gaia.lua:23`, `lab.lua`, `plant.lua`, `lines.lua` |
| F09 | M | **Fixed.** README says F1-F10 map the first ten ids in `order` and names `lines` as eleventh with no function key; architecture repeats the no-key fact | `README.md`, `architecture.md:132` |
| F10 | M | **Fixed.** "all ten" became eleven | `architecture.md:119` |
| F11 | M | **Fixed.** README's Nodes key map carries every binding in `nodes.lua:300-329` (arrows, PgUp/PgDn, Home/End, `R`/`P`/`F`/`I` twice, Enter/Tab), and `lines` has its own entry | `README.md`, `nodes.lua:300-329` |
| F12 | L | **Fixed.** `check.js` fails on a duplicate icon code, a duplicate order and a missing order; both proved by reverting the fix | `check.js` |

## P3 — Node payload and the floppy (4)

| ID | Sev | Finding | Where |
|---|---|---|---|
| F13 | **H** | **Fixed 2026-11-23.** `flash.lua` copied whole roots (514.2 KB) onto a 512 KB floppy and refused every flash; it now copies `tc.payload` (26 files, 237.3 KB) | `flash.lua:122`, `payload.lua` |
| F14 | H | **Fixed 2026-11-23.** `size.js` gated a list the flasher did not read; flasher, size gate and `check` now share `src/lib/tc/payload.lua` | `tools/payload.js`, `size.js`, `check.js` |
| F15 | H | **Resolved 2026-11-23.** `halls.lua` is in the payload because the plant genuinely needs it; `line-node.md` drops it from its "excluded" list | `payload.lua:27` vs `line-node.md:197-200` |
| F16 | M | **Fixed 2026-11-23.** The installer image is one measured artifact: `npm run size` prints `26 files, 237.3 KB of 256 KB target  (46% of the 512 KB floppy)`, and `line-node.md:43`, `status.md:128` and `roadmap.md:515` carry the same figure | `line-node.md`, `status.md:128`, `roadmap.md:515` |

## P4 — Roles, registry, master (7)

**F17, F18, F19, F20, F21, F22 and F23 fixed 2026-11-23.** The registry is
eleven columns with no `role` column; `masterId` was removed from `config.lua`;
`hostname` stays because the configuration file is hand-editable and the kernel
reads it (`kernel.lua:594`).

| ID | Sev | Finding | Where |
|---|---|---|---|
| F17 | H | **Fixed 2026-11-23.** Status frame docs said 10 stocks, `off=<n>` and `others=<n>`; the code caps at 8 with `more=<n>`, and the docs now say so | `line-node.md:156-160` vs `report.lua:20,190-193` |
| F18 | H | **Fixed 2026-11-23.** The registry is 11 columns: `role`, `jobs` and `drain` are removed, `modem` stays (the master reads it). A 14-column or 8-column file loads by width and is rewritten once at first boot | `line-node.md:172-182`, `registry.lua:14-30,170-210` |
| F19 | M | **Fixed 2026-11-23.** `line-node.md` said `tc.master` had a "token"; there is no handshake — the frame carries `token=none` because `net.lua:24` requires the field | `line-node.md:164-170` vs `master.lua:9-10,157-159` |
| F20 | M | **Fixed 2026-11-23.** `setRole` and `aggregate` are deleted with the `role` column; `rename` stays as the registry's own API; no document offers role cycling | `registry.lua`, `line-node.md:172` |
| F21 | M | **Fixed 2026-11-23.** `masterId` is removed from `config.lua`; `hostname` stays because the file is hand-editable and the kernel reads it | `config.lua:9-25,16`, `kernel.lua:594` |
| F22 | M | **Fixed 2026-11-23.** Role cycling, jobs and drain were documented as user-facing in `nodes`/`line-node`/README; no document offers them now | `line-node.md:172-192` |
| F23 | L | **Fixed 2026-11-23.** `line-node.md` explained the floppy by reference to `boot/netboot.lua`, a file deleted with the racks; the paragraph now explains the local install directly | `line-node.md:62-90` |

## P5 — External link contract (9)

**F24-F32 fixed 2026-11-23.** F32 was closed by documenting the nine MCP tools in
`tools/bridge/README.md`, where someone wiring an agent would look.

| ID | Sev | Finding | Where |
|---|---|---|---|
| F24 | **H** | **Fixed 2026-11-23.** `linkControl = "off"` shared a rank with `read` and so permitted all 14 read commands; `off` now refuses them and `read` is its own level | `link.lua:64`, `config.lua:102`, `gaia.lua:25` |
| F25 | H | `external-link.md` documents an item `move` command that is not in the table and would answer `unknown_cmd` | `external-link.md:180` vs `link.lua:34-62` |
| F26 | M | The same `gate.set` is listed twice with two different response shapes and two different `0.4.6`/`0.4.8` slices | `external-link.md:178-179` |
| F27 | M | The working tree raises `MAX_FRAME` 1024 → 8192 in **both** `net.lua` and `bridge.js` (unpublished), so six documents that say "capped at 1024" are stale. The 1 KB *send policy* is the rule to document | `external-link.md:70`, `sidecar.md:44,88`, `line-node.md:143`, `status.md:87`, `plant-service.md:85` vs `net.lua:15`, `bridge.js:31` |
| F28 | M | `gate.set` state is `open`/`closed` in one doc and `0|1` in another | `plant-service.md:97` vs `external-link.md:261` |
| F29 | M | `status.md:93` cites `linkTransport = "http"`; no such key exists and `config.set` would reject it | `status.md:93` vs `config.lua:9-26` |
| F30 | M | `external-link.md` retires option B "with the racks" and then re-proposes the same transport as phase 3 | `external-link.md:102` vs `:532-534` |
| F31 | L | "Option B" names two different transports (sidecar vs the retired rack path) | `sidecar.md:7-10` vs `external-link.md:99-104` |
| F32 | L | Nine read-only MCP tools are correct; nothing documents them in `README`/`architecture` beyond the 0.4.7 bullet | `tools/bridge/mcp.js:30-110` |

## P6 — Decision register (7)

**All seven fixed 2026-11-23.** At that correction the register read 1-28 in both
files; decision 29 (DNS1) brings it to 1-29. 25 supersedes
only what it removes, 12 and 13 are settled, 26-A reconciles decision 26 with
`plant.lua:316-321`, the implementation order names only outstanding work, and the
gateway is called removed everywhere (`middleware.md:3-10`).

| ID | Sev | Finding | Where |
|---|---|---|---|
| F33 | H | **Fixed 2026-11-23.** The heading reads "Decisions, 1-28" over 28 entries | `status.md:38` |
| F34 | H | **Fixed 2026-11-23.** `roadmap.md`'s decision list carries 28 | `roadmap.md:948-955` |
| F35 | H | **Fixed 2026-11-23.** Decision 26 and 26-A say the file and the gateway are gone while the merge stays; the plant never reads `/etc/halls.tsv`, and `halls.load`/`save`/`PATH` were deleted in `6236f99` | `status.md:94-101` vs `plant.lua:316-321`, `link.lua:48` |
| F36 | M | **Fixed 2026-11-23.** 25 supersedes 1, 3–7, 14 and F2 only; 20 stands, part-amended | `status.md:82-84` |
| F37 | M | **Fixed 2026-11-23.** 12 is marked moot and 13 re-pointed at the local book | `status.md:48-54`, `:79-86` |
| F38 | M | **Fixed 2026-11-23.** The implementation order lists only outstanding work and marks 0.4.1-0.4.9 delivered | `status.md:238-258` |
| F39 | L | **Fixed 2026-11-23.** The gateway is called removed everywhere; `middleware.md` carries the dropped banner and no table row lists it | `status.md:232-236`, `:274-280`, `middleware.md:1-10` |

## P7 — Removed features still documented (16)

**All sixteen fixed 2026-11-23.** README's rack section became "Slave node"; the
retired documents carry a banner at the top saying what replaced them and whether
anything of them survives; `status.md` separates what is current from what was
dropped with 0.3.x; roadmap F5 is marked blocked and F6 re-scoped; and
`/etc/lines.tsv` is corrected to `/etc/gates.tsv` in both places that named it.

| ID | Sev | Finding | Where |
|---|---|---|---|
| F40 | H | README keeps the whole "Rack cluster" section, the Vault feature and `boot/netboot.lua` in the layout | `README.md:31-33,34-36,131-150,192-194` |
| F41 | H | README's dev script list includes `test:cluster` (no such script) and omits every 0.4.x gate | `README.md:205-229` |
| F42 | H | `tests.md` keeps §0.3.0's 17 rack/netboot/Relay/waves/Vault test groups as live | `tests.md:33,342-413,420-500` |
| F43 | H | `relay.md` presents Relay as built and current, with no banner | `relay.md:1-11,92-102` |
| F44 | H | `power.md` builds a whole policy on Relay, rack servers, the Vault pool and standby roles | `power.md:5-7,12,25,68-85,104` |
| F45 | H | `distributed.md` defines the product as app server + terminals + worker/storage roles, with no banner | `distributed.md:4-6,13-16,24-59,124-126` |
| F46 | H | `vault.md` has no dropped banner although the app is gone | `vault.md:1-11,66-74` |
| F47 | M | `status.md`'s "What exists today" lists netboot/Relay/waves/Vault as built, and twice schedules in-game verification of them | `status.md:115-121,200-202,229-231` |
| F48 | M | `status.md:179-182` says the planner is "not wired yet" while `status.md:146-155` says it is built and verified in-game | `status.md:179-182` vs `:146-155` |
| F49 | M | `status.md:164` calls 0.4.8 "harness-only" while the same bullet and `tests.md` record an in-game run | `status.md:164` vs `:171-174` |
| F50 | M | `middleware.md` says removed layers "stay shipped" and dates the gateway to 0.4.3 | `middleware.md:23-28,149` |
| F51 | M | `crafting.md` wires Relay and the worker role into a current diagram | `crafting.md:38,242-248,282` |
| F52 | M | `holo.md` feeds the wall from the cluster, Relay and the Vault pool | `holo.md:4,33-38,61,80` |
| F53 | M | Roadmap F5/F6 still plan placement across racks and "inventory two racks/six nodes" | `roadmap.md:587-611,636-659` |
| F54 | M | Roadmap F4's exit criterion keeps the 64 KB/session cap that the 64 MB change removed | `roadmap.md:587-589` vs `:564-569` |
| F55 | M | `/etc/lines.tsv` is cited for the gate binding; the shipped path is `/etc/gates.tsv` | `recipes.md:158`, `plant-service.md:137` vs `gate.lua:17` |

## P8 — Numbers, gates and the test plan (9)

| ID | Sev | Finding | Where |
|---|---|---|---|
| F56 | M | **Fixed 2026-11-23.** `test:link` was quoted as 32, 37 and 46 scenarios; the code has **48** since the sub-second floor and the `off` refusal scenarios landed | `tests.md` §0.4.2 and §0.4.5, `roadmap.md` §0.4.2, `canonical.md` §9 vs `test-link.js:18-64` |
| F57 | M | **Fixed 2026-11-23.** The manifest count was quoted as 53 and 56; the tree has **55** and every document now says so | `status.md` "What exists today" and "Harness green", `versioning.md` 0.4.7, `roadmap.md` F3.5 |
| F58 | M | **Fixed 2026-11-23.** `npm run check` was quoted as 68 files; it checks **72**, and the documents say so | `status.md` "Harness green", `blackbox.md` "Verification gates" vs `check.js:10-24` |
| F59 | M | **Fixed 2026-11-23.** The screen matrix was described as including Vault and "runs nine scenarios … 45 combinations"; it is 10 × 5 = 50 with Lines | `tests.md` §0.2.0 "desktop shell checks" vs `test-screens.js:12` |
| F60 | M | **Fixed 2026-11-23.** `tests.md` was titled "F0 Test Plan" but is the whole 0.2–0.4.9 plan; F0 is one section | `tests.md:1-4` |
| F61 | L | **Fixed 2026-11-23.** `tests.md` described 0.3.1 work as "under development" and "not part of v0.3.0" | `tests.md` "Post-release work that shipped as 0.3.1 and later" |
| F62 | L | **Fixed 2026-11-23.** F0's checklist still said "needs an in-game retest" under a phase declared closed | `tests.md` "F0 exit checklist", the three post-F0 rows |
| F63 | L | **Fixed 2026-11-23.** Backlog items 17-20 listed the slave node, naming, `tc.master` and `size` as future work at 0.4.9, which shipped | `roadmap.md` backlog rows 17-20, all `0.4.9 · done` |
| F64 | L | **Fixed 2026-11-23.** `README.md` recommended 2 MB; the plant readout needs 64 MB | `README.md` hardware table |

## P9 — Dead code and residue (6)

**Verdict per function, 2026-11-23; re-verified and completed 2026-11-24.** Deleting
everything without a caller would have removed working code whose only sin is that
its hardware does not exist yet, so each one is decided rather than swept:

| Symbol | Verdict |
|---|---|
| `halls.load` / `halls.save` / `halls.PATH` | **Deleted** — the last thing pretending `/etc/halls.tsv` exists |
| `tc.move` (`move.run`) | **Kept, harness-only.** Named by decision 28 and covered by `test:field`; it becomes reachable when the bus (0.4.12) lands or the decision is retired. The kernel loads the module at boot (`kernel.lua:737-739`) so the acting layer is instantiated when the bus lands; `move.run` itself is called only from `tools/harness/field-test.lua` |
| `gate:alarms` / `gate:status` | **Kept, read by the Plant app.** The read half of a gate: `Plant` folds `gate:alarms()` into its alarm panel and shows `gate:status()` in its note line (`plant.lua`), so both have a `src/` caller; a gate has no hardware to report on yet, and deleting these would delete the only statement of what a gate reports |
| `registry.aggregate` / `registry.setRole` | **Deleted** with F20. `role` is gone from the registry (it duplicated the runtime role `config.lua` owns), so there is nothing to set and nothing to count by role |
| `registry.rename` | **Deleted** — no caller in `src/` or `tools/harness/`: the Nodes app renames by upsert and `test:master` exercises `master:rename`, a separate implementation, so the helper was dead code with a false coverage claim |
| 23 inert TC1 verbs | **Kept as accepted legacy.** `net.lua`'s header names decision 25 and lists the 23 inert verbs; deleting verbs from a wire contract turns a clean `unknown verb` into a parser surprise for an old peer |
| `config.masterId` | **Deleted** — no reader, no writer, and the frame field that shares the name is a different thing |
| `addr:firstSeen`, `line.termText`, `net.isModemMessage`, `stock:setPollInterval`, `ui:iconGridWidth` | **Deleted** — five exported helpers with no caller inside or outside their module |
| `updater.releasePaths` / `updater.stageFile` | **Kept, listed.** They are the only code that can stage a release tree onto a node's volume (the staging half of decision 26); no caller yet because staging runs from `boot/apply.lua`. Listed here so this table is the one exception list |
| `ui.lua:3-5` app-contract docstring | **Fixed** — `ui.lua:3-6` now names `iconArt` (a 9×5 pictogram) and `iconStyle` (`nil` or `"accent"`) |

| ID | Sev | Finding | Where |
|---|---|---|---|
| F65 | M | **Fixed 2026-11-24.** `tc.move` is instantiated into `instance.move` at boot and the verdict now says so; `move.run` has no caller in `src/` and is harness-only until the bus lands, which `test:field` covers | `kernel.lua:737-739`, `link.lua:34-62` |
| F66 | M | **Fixed 2026-11-23.** `halls.save()` has no caller: `/etc/halls.tsv` is read every boot and never written by the OS | `halls.lua:195-204` |
| F67 | M | **Fixed 2026-11-24.** `gate:alarms()` and `gate:status()` are read by the Plant app (`plant.lua`: the alarm panel and the note line), so the read half of a gate is no longer unreachable | `gate.lua:253,268` |
| F68 | M | **Fixed 2026-11-24.** 23 of the 34 declared TC1 verbs are inert cluster/Relay/Vault residue; `net.lua`'s header now names decision 25 and lists the 23 | `net.lua:22-60` |
| F69 | L | **Fixed 2026-11-23.** `registry.aggregate` and `registry.setRole` are deleted with the `role` column; `registry.rename` was dead too and is deleted | `registry.lua` |
| F70 | L | **Fixed 2026-11-24.** `ui.lua:3-6` now documents `iconArt` and `iconStyle` alongside the rest of the app contract | `ui.lua:3-6` |

## P10 — Naming and deferred designs (5)

**All five fixed 2026-11-23.** `names.md` is now a dated design record with
`<node>/<stock>` examples and a command surface that says which verbs exist;
`sessions.md` and `terminal-protocol.md` say deferred and why; the terminal
protocol frames are TC1 text; `opencomputers.md`'s rack section is labelled mod
trivia; and the recipe dataset has one path.

| ID | Sev | Finding | Where |
|---|---|---|---|
| F71 | M | `names.md` is stamped 0.4.1 and uses `hall1/ore_processing/…` examples while decision 26 makes the node name the path root (`casing/ingots`) | `names.md:3,18,88-93` vs `status.md:87-92` |
| F72 | M | `names.md`'s command surface lists `path.assign`, `driver.reload`, `move`, `gate.set` as if they were verbs; only `gate.set` exists on the link and none of the others is implemented anywhere | `names.md:216-233` |
| F73 | M | `sessions.md` / `terminal-protocol.md` build a remote-terminal model on decision 1, which decision 25 superseded; nothing in the current plan needs them | `sessions.md:1-14`, `terminal-protocol.md:3-33` |
| F74 | M | `terminal-protocol.md` invents "32-bit framing" and cites `docs/net.md`, which does not exist | `terminal-protocol.md:20` |
| F75 | L | `opencomputers.md` keeps a full "Racks and servers" section with no "not used by a slave node" note; `research-susy-planner.md` names two different paths for `RecipeDataset` | `opencomputers.md:126-176`, `research-susy-planner.md:34,113` |

---

# Part IV — Boundaries

## Removed — do not reintroduce without a new decision

Rack discovery · rack servers · netboot provisioning · Relay · update waves ·
Vault (app, pool, `/var/vault-*`) · `worker` and `storage` roles · rig/drain/jobs
UI · the multi-hall gateway · `halls.tsv` as a live table · remote terminals ·
`tc.cluster`, `tc.node`, `tc.netfetch`, `tc.provision`, `tc.vault`, `tc.pull`,
`tc.jobs`, `boot/netboot.lua`.

Docs that survive as **records**: `cluster.md`, `relay.md`, `vault.md`,
`distributed.md`, `power.md`, `holo.md`, `crafting.md`, `long-distance.md`,
`opencomputers.md` §racks, `middleware.md`. Each must carry the banner
`cluster.md:3-8` already uses:

> **Dropped 2026-11-16 (decision 25).** Kept as the 0.3.x record; nothing here
> ships in a slave node.

## Designed, not built

| Slice | What | Doc | Blocked on |
|---|---|---|---|
| 0.4.11 | Sidecar: Forge bridge card + bulk inventory scanner | `sidecar.md` | a mod, not documentation |
| 0.4.12 | Bus: ports, core, metered moves between named endpoints | `bus.md` | 0.4.11 |
| — | Reference dataset (SuSy Factory Flow) | `research-susy-planner.md` | a pinned commit and a schema read |
| — | Sessions / remote terminals | `sessions.md`, `terminal-protocol.md` | a new decision: decision 1 is superseded |
| — | Second hall, real gate, real transport | `status.md:235-236` | hardware the rig does not have |

`tc.halls`, `tc.gate` and `tc.move` exist and pass `test:field`; their in-game
halves need hardware. Calling them "not built" (three documents do) is wrong;
calling them "shipped" is also wrong. They are **modules built, integration
pending** — and decision 26-A reconciles them with decision 26: the hall module is
the node's own name merged in memory, while the halls file and the gateway are gone.

---

# Part V — How to keep this file true

1. **One authority per topic.** Version: `version.lua`. Decisions: `status.md`.
   Contracts: this file. A doc may quote them, never restate them differently.
2. **Numbers are outputs, not prose.** If `npm run check` prints 71 and 54, no
   document says 68 and 56. Quote the command and its output.
3. **A removed feature gets a banner, not a deletion.** The record is valuable;
   the ambiguity is not.
4. **Every "built" needs a gate.** A slice is built when a `test:*` script covers
   it and `npm run check`, `sim`, `sim:oc` pass; it is *verified* only when
   `tests.md` has an in-game results-log entry.
5. **When a decision and the code disagree, the decision is the intent and the
   code is the defect** — unless the decision is itself stale, in which case a new
   decision amends it explicitly. Never leave the disagreement standing.

*Established 2026-11-23 against the 0.4.9 working tree. 75 findings, 10 work
packages, 3 blocking defects (F13, F24, F35).*
