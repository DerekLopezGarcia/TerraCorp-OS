# Canonical definition — TerraCorp OS 0.4.9 "Flint"

This is the **single authority** for what TerraCorp OS is, what it contains, and
what each document is allowed to claim. It exists because the design documents
were written at different times against three different products (the 0.3.x rack
cluster, the 0.4.x plant readout, the 0.4.9 line node), and they contradict each
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
| Version | **0.4.9** | `version.lua:8`, `package.json:3` |
| Codename | **Flint** | `version.lua:9` |
| API level | 1 | `version.lua:10` |
| License | MIT | `version.lua:11`, `LICENSE` |
| Platform | Lua 5.3, OpenComputers 1.7.x / 1.8.x, Supersymmetry, MC 1.12.2 + Forge | `AGENTS.md:8-14` |

**Single source of truth for identity is `src/lib/tc/version.lua`.** No other file
may declare a version as fact; they may only quote it.

**Built ≠ published.** 0.4.9 was built and cut on 2026-11-16; **`v0.4.8` is the
last tagged GitHub Release** (`docs/versioning.md:70-71`). Any sentence of the
form "0.4.9 is released/available" is wrong until the tag exists.

**The freeze is deliberate, and it has a consequence.** Leaving 0.4.9 untagged
stops every in-world computer from self-updating: `updater.check` offers an update
only when the installed version is *lower* than the latest release
(`available = compareVersions(current, latest) < 0`, `updater.lua:375`). A machine
stamped `0.4.8` against a `v0.4.8` release therefore sits still, which is the
intent. [`versioning.md`](versioning.md) records the decision, what not to do
while it holds, and the four conditions that must be true before anyone tags
0.4.9. But it means a machine can **run 0.4.9 code while reporting `0.4.8`** — the
live rig does exactly this (§10 records the repository side of the same effect).
So: **a version stamp cannot distinguish the last release from an untagged
build.** `fs.read /lib/tc/version.lua` is not a reliable answer to "what is this
machine running"; a behaviour the old build could not produce is. Whoever writes
a diagnostic or an update flow must design around that, not around the stamp.

**Changelog:** 21 entries, 0.3.21 → 0.4.9, newest last
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

`role` accepts exactly **`desktop`** and **`line`**
(`config.lua:33`). It is read at exactly **one** site: `kernel.lua:635`.
Any other value silently falls back to `desktop` (`config.lua:135-139`).

| | `desktop` (default) | `line` |
|---|---|---|
| Requires a GPU | **yes** (`kernel.lua:741-744`) | no |
| Starts | `tc.plant` → `tc.book` → `tc.plan` → `tc.gate` → `tc.move` → gfx/splash → 11 apps → `ui` → `tc.master` → `tc.flash` → `tc.link` → event loop | `tc.plant` → `tc.report` |
| Apps / UI | 11 apps, windows, taskbar | none |
| Master service | always started, on every desktop | none |
| External link | yes | none |
| Evidence | `kernel.lua:672-901` | `kernel.lua:633-670` |

Release notes (`/var/whatsnew.md`) are written **before** the role split, so a
headless node gets them too (`kernel.lua:629-631`).

**Two different `role` namespaces exist. Do not confuse them:**

- `config.get("role")` — the **OS role**: `desktop` | `line`.
- `registry.role` — a **node record field**: `worker` | `storage` | `node` | `line`
  (`registry.lua:16`), defaulting to `worker` (`registry.lua:81`). The master
  always writes `line` (`master.lua:154,318`). The `worker`/`storage` values are
  rack-era residue; `registry.setRole` has no caller.

## 4. The app set — eleven, no more, no fewer

`APP_IDS` (`kernel.lua:14`), loaded in this order:

```lua
{ "dashboard", "files", "console", "settings", "notes", "update",
  "nodes", "gaia", "lab", "plant", "lines" }
```

| order | id | title | short | icon | iconArt | style |
|---|---|---|---|---|---|---|
| 1 | `dashboard` | System | System | `SYS` | 9×5 | **accent** |
| 2 | `files` | Files | Files | `FIL` | 9×5 | — |
| 3 | `console` | Terminal | Terminal | `TRM` | 9×5 | — |
| 4 | `settings` | Settings | Settings | `SET` | 9×5 | — |
| 5 | `notes` | Notes | Notes | `NTS` | 9×5 | — |
| 6 | `update` | Update | Update | `UPD` | 9×5 | — |
| 7 | `nodes` | Nodes | Nodes | `NTS` | 9×5 | — |
| — | *(8 unused)* | | | | | |
| 9 | `gaia` | GAIA | GAIA | `GAI` | 9×5 | — |
| 10 | `lab` | Lab | Lab | `LAB` | 9×5 | — |
| 11 | `plant` | Plant | Plant | `PLT` | 9×5 | — |
| 12 | `lines` | Lines | Lines | `LIN` | 9×5 | — |

**Facts and rules derived from this table:**

- An app's **id is its filename**; `check.js:142-144` enforces it.
- Every app must ship a 3-cell `icon`, a `short` label and a 9×5 `iconArt`
  (`check.js:145-161`, `AGENTS.md:119-121`). No exceptions, no taskbar-only apps.
- **`notes` and `nodes` both use `NTS`.** On a full tile the 9×5 art and the label
  tell them apart; on a shrunken tile (screen too small for 5-row tiles,
  `ui.lua:668-677`) the two apps draw **identically**. This is a defect, not a
  style choice. `check.js` does not catch it because it validates shape, not
  uniqueness.
- **`order = 8` is unused** — residue of the removed Vault app. Harmless for the
  grid (which sorts) and for F-keys (which are positional, see below), but it
  makes any "orders run 1..11" statement false.
- **F-keys are positional, not by `order`:** `ui.lua:1327-1329` binds `F1`…`F10`
  to the first ten apps *after sorting by `order`*. Today that is
  dashboard…plant (F1…F10). **`lines` is 11th and has no function key.** The UI
  correctly hints `F1-F10` (`ui.lua:820,988`).
- `iconStyle = "accent"` is allowed only on `dashboard` (and only `nil`/"accent"
  pass `check.js:151-153`).
- The app contract is `{ id, title, short, icon, iconArt, iconStyle, order,
  create(ctx) }` plus instance `draw`, `handle`, optional `tick`, optional
  `close`. `architecture.md:155-214` is correct; the short docstring at
  `ui.lua:3-5` is not (it omits `iconArt`/`iconStyle`).

## 5. Modules — 34 under `lib/tc`

All 34 are referenced; none is missing or orphaned. Grouped by what they serve:

**Boot / platform (8):** `vfs`, `config`, `log`, `util`, `text`, `theme`,
`version`, `gfx`.

**Desktop (3):** `ui`, `keys`, `lab`.

**Plant readout and plan (10):** `addr` (physical addresses), `path` (semantic
paths), `driver` (declarative drivers), `stock` (boundary reader), `tank` (fluid
normalisation), `plant` (readout, cache, alarms), `history` (bounded ring),
`book` + `plan` + `line` (recipes, planner, line-program parser).

**Line node / network (7):** `net` (TC1 frames + modem), `naming`, `registry`,
`master`, `report`, `installer`, `flash`.

**Acting layer (3):** `halls`, `gate`, `move`.

**External link (1):** `link`.

**Release (2):** `updater`, `changelog`.

## 6. Data on disk

Config is a serialized Lua table in `/etc/terracorp.cfg`, 16 keys, all written on
every save (`config.lua:9-26,48-71`):

`accent`, `charset`, `clock24`, `splash`, `logLevel`, `name`, `hostname`,
`iconOrder`, `iconLayout`, `role`, `master`, `masterId`, `linkSink`, `linkToken`,
`linkInterval`, `linkControl`.

Two of those are dead: **`masterId` is never read or written** by any code path
(the only `masterId` in `src/` is an `ASSIGN` frame field, `net.lua:24`), and
**`hostname` is read (`kernel.lua:597`) but never written** — Settings has no row
for it. `linkTransport` appears in `status.md:93` and **does not exist** in
`config.lua`, and `config.set` rejects unknown keys, so it could never be stored.

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

### 7.2 The node status contract

```text
TC1 HELLO  id=<address> name=casing v=0.4.9
TC1 STATUS id=<address> name=casing state=online mem=863 disk=420 uptime=612
    alarm=starved:95 stocks=2 more=0
    s1=casing/ingots:744:exact:4.8 s2=casing/casings:5:exact:0.0
```

- **At most 8 stocks per frame** (`report.lua:20 MAX_STOCKS = 8`), keys
  `s1`…`s8` (`report.lua:190`), overflow reported as **`more=<n>`**
  (`report.lua:193`).
  `line-node.md:157-159` claims ten stocks, `off=<n>`, and `others=<n>`: all
  three are wrong.
- Cadence: heartbeat every 30 s plus an immediate frame when an alarm changes or
  a stock disappears. Never per scan — each component call costs ~50 ms of
  server tick (`line-node.md:154-157`, `tests.md` probe answers).
- **There is no token handshake.** The wired modem bus is the boundary
  (`master.lua:9-10`); the frame carries the literal `token=none` only because
  `net.lua:24` requires the field.

### 7.3 The External Link — a closed command set of 25

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
  **There is no item `move` command** — `external-link.md:180` documents one;
  `fs.move` is a file rename.
- `gate.set` answers `desired=<0|1> actual=<0|1>`; `open`/`closed` is a
  documentation error in `plant-service.md:97`.

### 7.4 The bridge and the agent

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

**Install path (line node):** a floppy flashed by the master, containing
`/init.lua`, `/boot`, `/lib`, `/apps`, an `/installer.lua` marker and a generated
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
| payload files | **22** |
| payload bytes | **163.3 KB** |
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

Still open on P3: `line-node.md`'s budget table and the 0.4.9 changelog line still
carry the old numbers, which is a documentation edit (F16).

## 9. Verification gates — real numbers

`npm run` exposes **56** scripts (`package.json:7-64`).

| Gate | Command | What it really checks | Real number |
|---|---|---|---|
| Compile + manifest + icons | `npm run check` | every `.lua` under `src`, `eeprom`, `tools` compiles; manifest matches the tree; each app's icon shape | **71** files, **54** manifest entries |
| Manifest | `npm run manifest` | rewrites `tools/manifest.txt` | 54 |
| Desktop smoke | `npm run sim`, `sim:oc` | fake-component boot | — |
| Screen matrix | `npm run test:screens` | 10 scenarios × 5 resolutions | **50** combinations |
| Link | `npm run test:link` | the closed command set | **46** scenarios |
| Bridge | `npm run test:bridge` | HTTP endpoints + mirror parsing | 20 asserts |
| MCP | `npm run test:mcp` | identity, 9 tools, first answers | 20 asserts |
| Size | `npm run size` | the *intended* 21-file payload against a 512 KB medium / 256 KB target | **155.0 KB** (see §8.1) |
| Others | `test:plant`, `history`, `book`, `field`, `line`, `naming`, `installer`, `report`, `master`, `apps`, `flash`, `fetch`, `install`, `boot`, `faults`, `gaia` | module-level behaviour | ≈706 assertions |

**`check.js` does not validate** icon-code uniqueness or `order` uniqueness —
which is exactly how `NTS`/`NTS` and the `order = 8` gap shipped.

**The screen matrix composition** is `dashboard, desktop, console, files,
settings, notes, updater, nodes, lines, plant` (`test-screens.js:12`) — Lines,
not Vault. 10 × 5 = 50.

The harness is a smoke test, not a substitute for in-game verification
(`AGENTS.md:122-124`, `README.md:231-233`). Two line-node facts remain unverified
in-game: a never-booted computer booting the floppy, and
`computer.setBootAddress()` from `/init.lua` on a plain computer
(`line-node.md:93-105`).

**Baseline run, 2026-11-23** (Node v26.13.1, npm 11.20.0, dependencies installed
with `npm install`): `check` 71 files / 0 errors / manifest 54 · `size` 155.0 KB
(30 % of the medium) · `test:link` 48 scenarios, 0 failures · `sim` and `sim:oc`
clean · `test:screens` 50 combinations, no failures · `test:flash`, `test:installer`,
`test:naming`, `test:report`, `test:master`, `test:apps`, `test:plant`,
`test:history`, `test:book`, `test:field`, `test:line`, `test:gaia`,
`test:mcp`, `test:bridge` all pass.

**Read that baseline carefully: the suite is fully green while F13 is true.** A
green run means "no regression", never "the product works" — the flasher, the
`off` tier and the `halls.tsv` decision are all invisible to it. When a card
claims something is fixed, the evidence must be a test that would have failed
before the fix.

## 10. State of the working tree (read this before trusting any diff)

The folder is **neither a git repository nor a clean copy of upstream.** Compared
against `github.com/DerekLopezGarcia/TerraCorp-OS` at `main` = `7ed69d2`
("Document 0.4.9 and the sidecar transport decision"), everything is byte-identical
**except**:

| File | Change | Status |
|---|---|---|
| `src/lib/tc/net.lua` | `MAX_FRAME` 1024 → `8 * 1024` | unpublished |
| `src/lib/tc/config.lua` | `linkInterval` accepts `>= 0.5` (was `>= 1`) | unpublished |
| `src/lib/tc/link.lua` | `MIN_INTERVAL` 1 → 0.5, new `plantSeconds()`, clamping in `refresh`, `commandStatus`, `commandInterval` | unpublished |
| `tools/bridge/bridge.js` | `MAX_FRAME` 1024 → `8 * 1024`, new `DECIMAL` regex and `isPositiveSeconds()`, `LINK n` accepts a fractional interval for `link.interval` | unpublished |
| `docs/canonical.md` | this file | new, unpublished |
| `package-lock.json` | `version` fields 0.3.20 → 0.4.9 | normalised by `npm install`; the committed lock was stale |

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
- **P5 must account for the fractional interval.** The committed bridge rejects
  `n` as a non-integer, so anything documenting "0.5 s minimum" describes this
  working tree only, and the change has no in-game run behind it.

Conversely, **F01 is upstream, not local**: the published README really does say
"Current version: 0.4.8 Keystone" while `version.lua` says 0.4.9. The
contradictions in this document are therefore mostly committed defects, with a
small unpublished tail.

---

# Part II — The decision register, reconciled

28 decisions (`status.md:38-103`). "Status" is this document's verdict.

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
| 20 | The plant runs on plain computers, not rack servers | **Active** — see the note below |
| 21 | Two namespaces: addresses route, paths search | **Amended by 26** (no gateway until a second hall exists) |
| 22 | Component kinds are plugins; a plugin is data | **Active** (`tc.driver`) |
| 23 | Self-contained readout first (2026-11-15) | **Active** — the pivot that everything after it assumes |
| 24 | Lines are black boxes (2026-11-15) | **Active** |
| 25 | Racks dropped, line nodes instead (2026-11-16) | **Active** — but see its supersession list |
| 26 | The node registry is the DNS (2026-11-16) | **Active** — **contradicted in code**, see below |
| 27 | The sidecar replaces the card, not the protocol | **Active, not built** (0.4.10) |
| 28 | A bus may move stock between named endpoints | **Active, not built** (0.4.11) |

**Three defects in the register itself:**

1. **The heading says "Decisions, 1-27"; the list contains 28** (`status.md:38`
   vs `:95-103`). `roadmap.md`'s copy of the list really does stop at 27
   (`roadmap.md:719-913`). Fix: heading to 1-28, append 28 to `roadmap.md`.
2. **Decision 25 claims to supersede decision 20, but they agree.** 20 says "plain
   computers, not rack servers"; 25 removes the racks. Superseding 20 is wrong;
   25 should only supersede 1, 3–7, 14 (service tiers) and phase F2.
3. **Decision 25 omits 12 and 13**, both of which lose their subject with the
   Vault and the cluster. 12 must be marked moot; 13 must be re-pointed at the
   local book.

**Decision 26 vs the code:** decision 26 says "no gateway, **no `halls.tsv`**",
and `roadmap.md:322` agrees ("`tc.halls` and `/etc/halls.tsv` go with the racks").
But `tc.halls` still ships, `plant.lua:92` loads `/etc/halls.tsv` at every boot,
and `plant.halls` is a live read verb (`link.lua:48`). The docs describe it
accurately; **the code contradicts the decision.** One of the two has to move
(Part III, P6).

---

# Part III — Reconciliation register

75 findings, each with a work package. IDs are stable: cite `F12` in a commit or
a card. Severity: **H** breaks the product or a promise, **M** misleads a reader,
**L** cosmetic.

## P1 — Identity and version (5)

| ID | Sev | Finding | Where |
|---|---|---|---|
| F01 | H | README advertises 0.4.8 "Keystone"; code says 0.4.9 "Flint" | `README.md:7` vs `version.lua:8-9` |
| F02 | H | `blackbox.md` asserts 0.4.8 in a table whose Source column points at the file that disproves it | `blackbox.md:16` |
| F03 | M | `tests.md` has no 0.4.9 section and no 0.4.9 results-log entry | `tests.md:14-38`, `:653-1014` |
| F04 | M | "0.4.9 shipped" is stated as fact while `v0.4.8` is the last tag and the first-boot check is pending | `roadmap.md:501-512` vs `versioning.md:70-71` |
| F05 | L | The sample `HELLO` frame carries `v=0.5.0` | `line-node.md:148` |

## P2 — App contract and desktop facts (7)

| ID | Sev | Finding | Where |
|---|---|---|---|
| F06 | H | `notes` and `nodes` share icon code `NTS`; identical on a shrunken tile; `check` does not catch it | `notes.lua:9`, `nodes.lua:15`, `ui.lua:668-677` |
| F07 | H | README/AGENTS/architecture/blackbox list the 0.4.8 app set: `vault` (gone), no `lines`; `terminal`/`system` given as ids when they are titles | `README.md:13-58,192-194`, `AGENTS.md:26`, `architecture.md:94-95`, `blackbox.md:79-82` |
| F08 | M | `order = 8` unused (Vault residue); docs that count orders are wrong | `gaia.lua:12` … `lines.lua:13` |
| F09 | M | architecture says "F1-F9"; the code binds F1-F10; README says Plant has no function key but Plant *is* F10 and **Lines** has none | `architecture.md:130` vs `ui.lua:1327-1329` |
| F10 | M | "largest height that fits all **ten** apps" — there are 11 | `architecture.md:119-120` |
| F11 | M | README's Nodes key map is pre-0.4.9: `P` is ping not "prepare installer", `F` forget, `I` installer twice; `O`, `S`, `G` are unbound; role cycling does not exist | `README.md:177-179` vs `nodes.lua:300-307` |
| F12 | L | `check.js` validates icon *shape* but not *uniqueness*, and `order` not at all — the gate that should have caught F06/F08 | `check.js:145-164` |

## P3 — Node payload and the floppy (4)

| ID | Sev | Finding | Where |
|---|---|---|---|
| F13 | **H** | **Fixed 2026-11-23.** `flash.lua` copied whole roots (514.2 KB) onto a 512 KB floppy and refused every flash; it now copies `tc.payload` (22 files, 163.3 KB) | `flash.lua:120`, `payload.lua` |
| F14 | H | **Fixed 2026-11-23.** `size.js` gated a list the flasher did not read; flasher, size gate and `check` now share `src/lib/tc/payload.lua` | `tools/payload.js`, `size.js`, `check.js` |
| F15 | H | **Resolved 2026-11-23.** `halls.lua` is in the payload because the plant genuinely needs it; `line-node.md` must drop it from its "excluded" list | `payload.lua:26` vs `line-node.md:51-52` |
| F16 | M | The installer image is still quoted at four sizes: 156 KB, ~129 KB, ~155 KB, 133 KiB — now one measured number exists to replace them | `line-node.md:10,45,69`, `status.md:110`, `README.md:111` |

## P4 — Roles, registry, master (7)

| ID | Sev | Finding | Where |
|---|---|---|---|
| F17 | H | Status frame: docs say 10 stocks, `off=<n>`, `others=<n>`; code caps at 8 with `more=<n>` | `line-node.md:157-159` vs `report.lua:20,190-193` |
| F18 | H | Docs say the registry dropped `role`, `jobs`, `drain`; code still declares and writes them, and `roles` still lists `worker`/`storage` | `line-node.md:168-169` vs `registry.lua:14-16,200-215` |
| F19 | M | `line-node.md` says `tc.master` has a "token"; there is no handshake, the frame carries `token=none` because the field is required | `line-node.md:165-166` vs `master.lua:9-10,157-159` |
| F20 | M | `registry.setRole`, `registry.aggregate`, `registry.rename` have no caller; the Nodes app offers no role cycling although README says it does | `registry.lua:225-268` |
| F21 | M | `masterId` config key is dead; `hostname` is read but never written | `config.lua:16,21`, `kernel.lua:597` |
| F22 | M | Role cycling, jobs and drain remain documented as user-facing in `nodes`/`line-node`/README | `line-node.md:168-178` |
| F23 | L | `line-node.md:89-90` still explains the floppy by reference to `boot/netboot.lua`, a file deleted with the racks | `line-node.md:89-91` |

## P5 — External link contract (9)

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

| ID | Sev | Finding | Where |
|---|---|---|---|
| F33 | H | Heading "Decisions, 1-27" but 28 exist | `status.md:38` vs `:95-103` |
| F34 | H | `roadmap.md`'s decision list stops at 27 | `roadmap.md:719-913` |
| F35 | H | **Fixed 2026-11-23.** Decision 26 says no `halls.tsv`; the plant no longer reads it — the hall is the node's own name. `halls.load`/`save` remain as dead code for P9 | `status.md:84` vs `plant.lua:92`, `link.lua:48` |
| F36 | M | Decision 25 claims to supersede 20, which it agrees with | `status.md:78` |
| F37 | M | Decision 25 does not mark 12 (moot) or 13 (re-pointed) | `status.md:48,74-79` |
| F38 | M | The "Implementation order" still schedules the second hall and lists work that is done | `status.md:233-236` |
| F39 | L | The gateway is called "deferred" in one place and "removed" in another | `status.md:211,251` vs `:84` |

## P7 — Removed features still documented (16)

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
| F56 | M | `test:link` is quoted as 32, 37 and 46 scenarios; the code has **48** since the sub-second floor and the `off` refusal scenarios landed | `tests.md:68,168`, `status.md:133` vs `test-link.js:18-64` |
| F57 | M | Manifest count is quoted as 53 and 56; the tree has 54 | `status.md:110,175`, `versioning.md:88`, `roadmap.md:508` |
| F58 | M | `npm run check` is quoted as 68 files; it checks 71 | `status.md:175` vs `check.js:10-24` |
| F59 | M | The screen matrix is described as including Vault and "runs nine scenarios … 45 combinations"; it is 10 × 5 = 50 with Lines | `tests.md:599-604` vs `test-screens.js:12` |
| F60 | M | `tests.md` is titled "F0 Test Plan" but is the whole 0.2–0.4.9 plan; F0 is one section | `tests.md:1` |
| F61 | L | `tests.md:1016-1026` describes 0.3.1 work as "under development" and "not part of v0.3.0" | `tests.md:1016-1026` |
| F62 | L | F0's checklist still says "needs an in-game retest" under a phase declared closed | `tests.md:1032-1043` vs `:1033` |
| F63 | L | Backlog items 17-20 list the line node, naming, `tc.master` and `size` as future work at 0.4.9, which shipped | `roadmap.md:714-717` vs `:501-512` |
| F64 | L | `README.md:72` still recommends 2 MB, and no document states the 64 MB requirement the readout depends on | `README.md:72` vs `roadmap.md:226`, `tests.md:998` |

## P9 — Dead code and residue (6)

| ID | Sev | Finding | Where |
|---|---|---|---|
| F65 | M | `tc.move` is instantiated into `instance.move` but `move.run` has no caller in `src/`; item `move` is not a link command either, so the acting layer is reachable from nowhere | `kernel.lua:734-739`, `link.lua:34-62` |
| F66 | M | `halls.save()` has no caller: `/etc/halls.tsv` is read every boot and never written by the OS | `halls.lua:195-204` |
| F67 | M | `gate:alarms()` and `gate:status()` have no caller | `gate.lua:253,268` |
| F68 | M | 23 of the 34 declared TC1 verbs are inert cluster/Relay/Vault residue | `net.lua:22-60` |
| F69 | L | `registry.aggregate`, `registry.setRole`, `registry.rename` are exported and uncalled | `registry.lua:225-268` |
| F70 | L | `ui.lua:3-5` documents an app contract without `iconArt`/`iconStyle` | `ui.lua:3-5` |

## P10 — Naming and deferred designs (5)

| ID | Sev | Finding | Where |
|---|---|---|---|
| F71 | M | `names.md` is stamped 0.4.1 and uses `hall1/ore_processing/…` examples while decision 26 makes the node name the path root (`casing/ingots`) | `names.md:3,18,88-93` vs `status.md:80-85` |
| F72 | M | `names.md`'s command surface lists `path.assign`, `driver.reload`, `move`, `gate.set` as if they were verbs; only `gate.set` exists on the link and none of the others is implemented anywhere | `names.md:216-233` |
| F73 | M | `sessions.md` / `terminal-protocol.md` build a remote-terminal model on decision 1, which decision 25 superseded; nothing in the current plan needs them | `sessions.md:1-14`, `terminal-protocol.md:3-33` |
| F74 | M | `terminal-protocol.md` invents "32-bit framing" and cites `docs/net.md`, which does not exist | `terminal-protocol.md:20` |
| F75 | L | `opencomputers.md` keeps a full "Racks and servers" section with no "not used by a line node" note; `research-susy-planner.md` names two different paths for `RecipeDataset` | `opencomputers.md:126-176`, `research-susy-planner.md:34,113` |

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
> ships in a line node.

## Designed, not built

| Slice | What | Doc | Blocked on |
|---|---|---|---|
| 0.4.10 | Sidecar: Forge bridge card + bulk inventory scanner | `sidecar.md` | a mod, not documentation |
| 0.4.11 | Bus: ports, core, metered moves between named endpoints | `bus.md` | 0.4.10 |
| — | Reference dataset (SuSy Factory Flow) | `research-susy-planner.md` | a pinned commit and a schema read |
| — | Multi-hall gateway/DNS | `middleware.md` | **the halls model is gone** (F35) |
| — | Sessions / remote terminals | `sessions.md`, `terminal-protocol.md` | a new decision: decision 1 is superseded |
| — | Second hall, real gate, real transport | `status.md:164-174` | hardware the rig does not have |

`tc.halls`, `tc.gate` and `tc.move` exist and pass `test:field`; their in-game
halves need hardware. Calling them "not built" (three documents do) is wrong;
calling them "shipped" is also wrong. They are **modules built, integration
pending, and now in conflict with decision 26** (F35).

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
