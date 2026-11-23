# Test plan and in-game results

This is the whole test plan, from the F0 exit protocol through every slice up to
0.4.9. F0 is the first section, not the whole document: it exits when the OS has
run for 30 minutes without `ERR` log entries, retains
at least 250 KB free on a Tier 2 node, and reaches its first render within 2
seconds in Supersymmetry. The updater must also detect and install a published
stable GitHub Release while preserving settings and leaving the BIOS/EEPROM
untouched.

## Local harness results

The Fengari/Lua 5.3 harness verifies execution and the OpenComputers API
contract. It does not measure in-game wall-clock boot time or memory use.

```sh
npm run check
npm run sim
npm run sim:oc
npm run test:desktop
npm run test:icon-order
npm run test:dashboard-tick
npm run test:refresh-rate
npm run test:drag-metric
npm run test:updater
npm run test:updater-legacy
npm run test:updater-rollback
npm run test:updater-recover
npm run test:boot-update
npm run test:notes
npm run test:lab
npm run test:files-scroll
npm run test:release-notes
npm run test:nodes
npm run test:faults
npm run test:screens
npm run test:line
npm run test:plant
```

The harness models components and a filesystem in memory. Treat it as a smoke
and regression test, not a replacement for the game test.

## 0.4.1 Plant readout checks

`npm run test:plant` loads the six plant modules and runs the casing hall
against fake components. It requires:

1. `tc.addr` parses `node:component:face`, records `first_seen`, rejects a
   remote node, and persists `/var/plant/seen.tsv`.
2. `tc.path` matches `*`/`**`, rejects unsafe names, and reports
   `cardinality_mismatch` for two members under `single`.
3. `tc.driver` classifies a machine face as inventory, a pipe as transport and a
   drum as tank; descriptor calls are dot-style proxy functions and
   `driver.dump` returns methods with docs.
4. The stock scan costs one component call per tick: the five-stock hall uses
   **9 calls**, an eight-ingot crate is `exact`, a pipe is `unbound` with a
   transport reason, a missing member is `unbound`, a tank reports **1000 mB**,
   and three idle ticks make **zero** calls.
5. The plant raises `STARVED`/`FULL` from `/etc/plant.tsv`, `NO POWER` below
   15%, `STALE` for an old cache, and reports version/cache age in `status`.

`node tools/harness/simulate.js plant --strict` opens the eleventh app from the
Terminal and requires the empty-configuration message. `npm run test:screens`
runs the `plant` scenario at five resolutions (50 combinations total).

## 0.4.2 mirror checks

`npm run test:link` now runs **32 scenarios**. The eleven plant scenarios use a
fake plant service shaped like `tc.plant` and require:

1. `plant.status` carries the format line, version, hall, energy, stock and
   alarm counts, the stock revision and the link tier.
2. `plant.snapshot` carries the input stock, its entries, the alarms and the
   configuration errors; a label with a space is escaped as `%20`, and the
   `LREP` size equals the reassembled body.
3. `hall=other` answers `unknown_hall`; `stocks=casing/casings` keeps exactly
   one stock and drops the other.
4. A **40-stock snapshot is larger than 1 KB**, spans several `LDATA` frames,
   starts at offset 0, reassembles to the declared size, and keeps the last
   stock and its label intact.
5. `plant.delta` answers `resync=0 changes=0` for the current revision,
   `resync=1 reason=stale_cursor` plus `snapshot_begin` and a full snapshot for
   an old cursor, and `reason=no_cursor` on the first call.
6. `plant.alarms` carries the alarm record and its escaped message;
   `since=1001` filters out an alarm last seen at 1000.
7. Without a plant service, all verbs answer `plant_unavailable`.

`npm run test:bridge` starts the real bridge on a free port, queues the two
verbs, and posts complete `LREP`/`LDATA`/`LEND` results. It requires:

1. The help text names `/link/mirror`, and both queued verbs are delivered.
2. The mirror parses the snapshot: revision, hall, ten stocks across pages, the
   last stock, the decoded `Test Item 1` label, and the decoded alarm message.
3. The status reply is parsed separately; a plain `status` body does not
   replace it, and a truncated plant body does not replace the last good
   snapshot.
4. `/link/state` reports two mirrored kinds for the node.

`tc.stock` also gained `revision`: an idle scan still increments `generation`
but leaves `revision` unchanged, which `test:plant` verifies. That is what lets
a mirror keep its cursor across idle polls.

## 0.4.4 history checks

`npm run test:history` loads `tc.history` against a fake clock and filesystem.
It requires:

1. 1000 samples at ten-second intervals produce **60 items/min** over a 120 s
   window, and the ring stops at **720 samples** per stock.
2. A second instance reads the same file and yields the same rate: the ring
   survives a reboot, not just a page reload.
3. With `maxSamples = 10` and `maxLines = 20`, the file stays at **21 lines or
   fewer** after 100 scans, so compaction bounds it.
4. Eight samples with an unchanged total raise **`STALLED`** for a stock marked
   `flow`; the same stock without `flow` stays quiet.
5. A window at 60/min followed by one at 6/min reports **-90%** and raises
   **`TREND`** with the percentage in the message.
6. Malformed lines are skipped, a missing file is an empty ring, and a stock
   without samples has no rate.

`npm run test:plant` also checks the extended `/etc/plant.tsv` line
(`<stock> <min> <max> [flow|idle] [trend%]`), that the plant surfaces
`STALLED` from history, that `plant.snapshot` carries the rate, and that
`status.historySamples` matches the ring. `npm run test:link` checks that the
snapshot body carries `rate`, `trend` and `rate_span`.

## 0.4.5a line parser checks

`npm run test:line` loads `src/lib/tc/line.lua` in Fengari and parses
`tools/harness/fixtures/casing.line` plus malformed input. It requires:

1. the casing file has four rules (`lv`/`mv`/`hv`/`ev`), the two stock lists,
   `ticks 50` and the EV casing limit of 64;
2. each rule's item key, damage and quantity, and its `ruleText` form
   (`in 8 item gregtech:meta_ingot@324 = out 1 item gregtech:machine_casing@1`);
3. a multi-term rule with three inputs (including `1000 fluid water`) and two
   outputs (including `500 fluid steam`);
4. CRLF, BOM, comments, an item without `@` (damage 0) and an empty file;
5. errors for missing `in`/`out`, duplicate rule, zero or fractional quantity,
   bad kind, unknown directive, bad limit, bad stock and an oversize file.

The parser is data-only: it never executes the file (decision 22).

## 0.4.5b book and planner checks

`npm run test:book` loads `tc.book` and `tc.plan` over a fake book with three
recipes and a casing line program. It requires:

1. The book loads **five** recipes (three TSV recipes + two line rules) with no
   errors, and the higher-priority TSV recipe wins over the line rule for the
   same EV casing.
2. A **three-step chain** (casing ← plate ← ingot) plans with the plate step as
   the bottleneck: `0.0125` targets/s and **80 s** for one casing, because the
   plate step has two machines but needs eight crafts per casing.
3. `shortfall` matches a hand count: one casing needs 16 ore, the stock has 10,
   **6 are missing**. For 200 casings: 1600 plates and 3200 ore, **3190
   missing**.
4. Calibration: a measured ratio of **1.25** turns `casing_ev` `suspect`, the
   plan warns and uses 10 plates (20 ore); **1.05** is `verified` and clears the
   warning. Calibration is written to `/var/plant/calibration.tsv`.
5. A line-only book plans the EV rule by name (`line/casing/ev`) and reports
   its own shortfall.
6. A cycle A→B→A stops after the pair with a `cycle` warning; a 50% output adds
   `rng_chain` and needs two crafts for one expected item; an empty book returns
   `empty_book` and an unknown IO recipe is a load error.
7. **200 three-step plans stay under one second** in the harness.

`npm run test:link` adds five scenarios (`plant.book`, `plant.book_one`,
`plant.book_unknown`, `plant.plan`, `plant.plan_bad`), for **37** total. They
require the book body with recipes and IO, the single-recipe lookup, the plan
body with steps, bottleneck, shortfall and warnings, and the named errors for
an unknown recipe and a zero quantity.

## 0.4.7 MCP checks

`npm run test:mcp` starts the real bridge on a free port, starts
`tools/bridge/mcp.js` over stdio, seeds the mirror with a status, a snapshot and
an empty alarm list, and runs a fake node that answers the queued verbs. It
requires:

1. `initialize` names `terracorp-plant`, and `tools/list` returns **nine**
   tools.
2. **Question 1 — how is the plant?** `plant_situation` names `casing/ingots`,
   cites **744**, reports **0 alarms**, and ends with the verbs behind the
   answer.
3. **Question 2 — how much titanium?** `stock_query name=casing/ingots` returns
   `Titanium Ingot x192` and `Steel Ingot x552`; an unknown name answers
   `No stock matches casing/nope`, not zero.
4. **Question 3 — what does 100 casings need?** `plan` answers
   `Bottleneck: casing_ev` and `missing 592`, with the `plant.plan` source.
5. `alarm_list` says `No active alarms` when the list is empty.
6. `history` returns `rate 2.5/min` and the two samples; `path_list` reports
   names and member counts without addresses; `path_query` filters.
7. `recipe_query recipe=casing_ev` names the assembler and lists
   `in 8 item gregtech:meta_ingot@113`; `audit_tail` returns the log tail.
8. A tool that cannot read returns an error with the reason; it never returns
   an invented number.

The MCP reads the cached mirror when it is fresh and queues one verb when it is
not, so the test covers both paths. `tools/bridge/plant.js` parses both bodies;
`test:bridge` keeps the mirror parser honest.

## 0.4.3/0.4.6 hall, gate and move checks

`npm run test:field` loads `tc.halls`, `tc.gate` and `tc.move` against fake
files, a fake transposer and an in-memory registry. It requires:

1. `halls` builds a one-row registry from the node's own name. The
   `/etc/halls.tsv` table is gone (decision 26), so the test asserts the
   registry it builds instead of a table on disk.
2. `halls.merge` prefixes stocks with the hall name, counts the missing hall as
   **offline** and an old snapshot as **stale**, and drops neither.
3. `gate.set` persists the desired state in `/var/gates.tsv`; a new instance
   restores it.
4. The interlocks refuse an empty input (`input_empty`) and a full output
   (`output_full`), allow a healthy line, and write the configured face through
   the proxy.
5. Three refusals raise **`DISOBEDIENT LINE`**; a new setpoint clears it.
6. `move.run` moves **64 + 36 = 100** matching items across two slots, reports
   `key_not_found`, `transport_refused`, a guard refusal and `bad_count`, and
   caps at 512 per call.

The second hall, the gate and the transport are not built. These tests are the
evidence for the logic; the in-game run is **pending** and will be added when
the hardware exists.

## Documentation gate

`npm run test:docs` reads the tree and every Markdown document, then compares
each claim it finds with the command behind it. It measures the numbers by
running `check`, `size` and `test:link` (not by repeating their arithmetic), so
a document cannot be right while the tree is wrong or the other way round.

It fails when:

- a document quotes a manifest, check, payload-size or link-scenario number
  that the gate prints differently;
- a document names a retired thing — the hall table, the rack test suite,
  netboot, the planned transport key, the old status overflow key, the old
  eight-versus-ten stock cap — as if it were current. A line that says the thing
  was removed, dropped, planned or never existed is fine: that is how this
  project retires a feature;
- a document counts the app tiles as ten, or names the Vault, while `kernel.lua`
  lists eleven ids and no Vault.

The finding ledger (`canonical.md`), the roadmap and the deferred designs
(`bus.md`, `sidecar.md`, `plant-service.md`) are exempt from the vocabulary rule:
their job is to discuss removed and planned things, and the ledger would have no
substance without naming what was wrong.

Proved both ways on 2026-11-23: changing `manifest is 55 files` to 54, and the
installer size to the old 163.3 KB, each fails the gate with the file and the
number; restoring them exits 0.

## 0.3.33 external link checks

`npm run test:link` covers the closed command set against a fake Internet Card.
Two things changed with in-game evidence behind them:

- `commandWrite` used to call the VFS with the instance as the first argument
  (`self.vfs.write(self.vfs, path, data)`). The real module defines
  `vfs.write(path, data)`, so in-game the card opened a table as a path and every
  `fs.write`/`fs.append` answered `write_failed`; the fake VFS accepted the extra
  argument, so the gate passed while the game failed. The fake now uses the same
  dot-style signatures as `src/lib/tc/vfs.lua`, and `write_ok` would catch it.
- `link.interval` (`n` in 1–60) changes the polling cadence from the bridge and
  persists it. `interval` queues a bad value and a good one and requires
  `bad_interval` then `interval=1s`, with `instance.interval == 1` and one config
  save; it runs with `linkControl = off` on purpose, because the tier is allowed
  at every level.
- `lua` runs a chunk in the Lab environment and returns its captured output.
  `lua` requires `print(6*7)` to answer `42` under `full`; `lua_error` requires a
  failing chunk to answer `ok` with an `error:` line; `lua_refused` requires
  `needs_full_control` under `write`. The fake Lab only provides `print` and a
  few globals, so the check is on the link's dispatch, not on the Lab.

## 0.3.32 release notes checks

`npm run test:release-notes` runs three boots against a seeded `/var/version`:

1. `notes_many` starts from `0.3.29` and requires `/var/whatsnew.md` to contain
   sections for `0.3.30`, `0.3.31`, `0.3.32` and `0.3.33` — every release
   skipped — and not `0.3.29` itself. It also requires the
   `What's new: /var/whatsnew.md` notice on screen and `/var/version` rewritten
   to the running build.
2. `notes_one` starts from the previous release: only the current section.
3. `notes_same` starts from the running build: no notes file at all.

The bootstrap write path is covered by `boot-update` too: the applier records
the replaced version in `/var/version`, which is what gives the kernel a range
on the first updated build.

## 0.3.21 Lab and Files scrolling checks

`npm run test:lab` opens Lab with a seeded `/var/lab/script.lua` at 160x50,
types `-- probe` into the editor, clicks `[ Run ]`, and requires:

1. `/var/lab/script.lua` contains the typed comment, so the editor saved the
   buffer before running it.
2. `/var/log/lab.log` has a `=== ` run header and the script's `print` output.
3. The Output tab renders that output and the footer reports `run 1 · ok`.

The second scenario, `lab_error`, seeds a script that prints `lab ok` and then
calls `error("boom")`; the run must log `! line 2: boom` and report
`run 1 · error`. `lab_editor` checks that the Script tab loads the file and
renders typed text with line numbers. `lua_command` types `lua
/var/lab/script.lua` in the Terminal and requires the same script to run and
print through `/var/log/lab.log`.

`lab_repl` types bare `lua` in the Terminal and requires the Lab to open on the
interpreter tab. It then assigns `count = 6` on one line, evaluates
`= count * 7` on the next, and types a `for` block across three lines. It then
switches to a second session (`:new work`) and back (`:use main`). Passing means
the environment survived between submissions (the `42` can only come from the
earlier line), a block stayed open until `end` closed it, a new session started
empty (`type(count)` is `nil`), switching back restored `count` (`count + 1` is
`7`), `:list` marked the active session, every record reached
`/var/log/lab.log` under its session name, and the prompt came back.

It also submits `type(1)` with no `=` and requires `"number"` in the log: the
interpreter tries the line as an expression first, like OpenOS, so a bare call
prints. `= { answer = 42 }` must show `["answer"]=42`, which covers the sorted
table display and its elision. `=type(collectgarbage)` must print `"nil"`: the
client sandbox does not expose `collectgarbage`, and the harness hides it so the
tests match the game.

`lab_wrap` submits `= string.rep("Z", 200)` and requires all 200 characters on
screen across at least three rows: a result wider than the pane must wrap, not
run off the right edge.

`lab_mouse_select` presses on the first script line, drags to the third, copies
with `Ctrl+C`, switches to the Lua tab, pastes with `Ctrl+V` and runs the cell.
The log must contain the dragged `for` line and the `lab ok  10` output, so the
mouse selection, the clipboard and the paste path are all covered. The copy and
paste chords carry `\3` and `\22` as their text, which is what some clients
report for Ctrl+C and Ctrl+V.

`lab_blank_line` presses Enter on an empty interpreter cell and requires the
prompt plus a `  .. ` continuation row: the cell opens a line instead of doing
nothing. No record may reach `/var/log/lab.log`, because an empty Enter is not a
submission.

`lab_continue` types `function snake()`, presses Enter and types `return 1`.
The screen must show `...  function snake()` over `  .. return 1`: an open
block keeps its text in the cell and continues on a new line.

`lab_history` submits `x = 1`, then a two-line `y = 2` / `z = 3` entry. Two Ups
must land on `lua> x = 1`: the first recalls the block as one entry, the second
moves to the entry before it.

The same scenario covers the later fixes: `Shift+Enter` keeps two lines in one
record, a held `Shift` keeps adding lines across two Enters (the modifier is
only released by `key_up`), an open `= 300 +` waits for the next line instead
of failing on the leading `=`, `=type(component.gpu)` works without a space
after `=` (it used to compile as the name `returncomponent`), a `clipboard`
signal pastes text into the cell, `component.gpu` resolves to the primary
component, and `Shift+Home`, a second shifted `Up`, `Ctrl+C` and `Ctrl+V`
round-trip a two-line span into the input (`lua> === ...` over `  .. > z = 12`
on screen).

`console_paste` opens the Terminal, sends a `clipboard` signal with
`echo pegado`, and requires the line to appear in the input and to run on Enter.

`npm run test:files-scroll` opens Files over a 160-line `/scroll.txt`, tabs
focus into the preview, pages down, and requires `scroll line 160` on screen. A
preview that only draws its first page cannot pass.

## 0.3.0 rack and netboot checks

> **Historical.** The cluster layer — rack discovery, netboot, Relay, waves and
> the Vault app — was removed in 0.4.9 (decision 25), and with it the
> `test:cluster` suite this section used to name. The record stays because the
> checks describe how the protocol and provisioning were proved at the time.

The `test:cluster` suite used to run pure Lua module tests under Fengari against fake
filesystem, floppy, and modem components:

1. `TC1` frames encode and decode escaped values, reject missing or duplicate
   fields, reject field names that do not start lowercase, reject oversized
   frames, and reject malformed or non-`TC1` input.
2. The registry loads, merges duplicate IDs, skips malformed lines and rows of an
   unknown width, and saves back to `/var/nodes.tsv`. A fourteen-column file and
   the eight-column 0.3.x file both load their fields correctly and are rewritten
   in the eleven-column shape at that first boot.
3. Provisioning fills a floppy with `/init.lua`, `/payload`, and `/install.log`,
   rejects a floppy that holds foreign data, and refuses a payload that does not
   fit in 512 KB.
4. The install guard accepts an empty HDD, refuses a finished TerraCorp install,
   accepts one that carries `/var/install-incomplete`, and removes the marker
   only after a complete copy.
5. The master answers `HELLO` with `ASSIGN` only while the installer window is
   armed, names the node, persists the assignment, marks a silent node offline,
   pings it, and accepts a later `STATUS`.
6. A node persists a runtime `ASSIGN`, adopts a replacement master from `PING`,
   sends `PONG` to the pinging master, and ignores a stale token.
7. The classic netboot installer completes a full run against a hand-built
   payload floppy: picks the first HDD, copies the runtime, sends `ACK`, and
   sets the boot address only after a complete copy; a refused target disk
   leaves the boot address alone.
8. Re-arming reuses a same-version bootstrap, a full legacy payload floppy is
   converted, a broken readiness marker is rebuilt, the master registers a
   node only from a verified `STATUS`, refresh pings every known node, forget
   drops a node from the registry, and a node that fails the boot check stays
   silent.
9. The pull installer (`netfetch`) completes a full provisioning run against
   fake hardware: it loads `tc.net` from the floppy, pulls the runtime over
   `LIST`/`FETCH`, writes the node configuration, and sets the boot address
   only after the copy completes.
10. The master refuses the filesystem root and paths outside the runtime tree
    with `MISS`, answers directory listings while serving, and `armUpdate`
    falls back to the master's own version when no release check is
    available, offering `PULL` to the known nodes.
11. A node stages a `PULL` update under `/var/update/stage/<version>/` with
    the `source=master` marker for the boot-time applier, and `STATUS`
    records the node version in the registry (legacy 8-column files still
    load).
12. The Relay queue passes framing for all six verbs; the publisher grants
    the first claim, drops stale-token results, re-offers expired leases
    within the retry budget, fails past-TTL jobs, cancels with a broadcast,
    and a fresh publisher resumes and re-offers the queued journal after a
    restart. The worker claims known tasks only, runs a granted `fs.check`
    to `done`, keeps the drain flag, stops claiming while draining, and
    forgets expired claims. `cluster:drainNode` sends `DRAIN`, and the
    registry persists the `jobs` and `drain` columns (older files load).
13. Node updates run in waves: the first wave offers `PULL` to half of the
    remaining nodes only, a wave advances on target versions, offline nodes,
    or the wave window, the next wave follows, and the update completes with
    a per-node count.
14. The Vault pool passes framing for its ten verbs; the node gateway joins
    only spare disks to the pool, stores a written file under `vault/<path>`
    with part-file rename, aborts out-of-order writes cleaning the part file,
    answers `VREAD` slices with the total size, and removes on `VDEL`. The
    master registers disks from `VDISK`, stores files chunk by chunk with the
    index persisted across restarts, lists the virtual namespace, assembles
    reads into the cache, deletes after node confirmation, and reports usage
    per disk. The index is backed up to a pool disk when it changes, and a
    fresh master with an empty index restores it from that backup.
15. The Vault app opens from its desktop icon, shows the namespace with
    per-file sizes and pool usage, and renders without errors at every
    simulated resolution.
16. The hybrid installer floppy (0.3.6): `prepare` with `payload = true`
    writes the bootstrap plus the full runtime under `/payload` with its own
    `.ready` marker, reuses a same-version payload floppy, and verifies every
    copied file (byte-identical read-back and `.lua` compilation). Without
    `payload` the bootstrap-only layout is unchanged.
17. Node-driven updates (0.3.6): a `STATUS` reporting a version older than
    the staged `/var/nodeupdate` tree earns an automatic `PULL` offer, sent
    once per staged version, and only when `nodeAutoUpdate` is enabled.

`npm run test:nodes` runs the Nodes app in the desktop harness with a fake
floppy, rack drive, and wired modem. It presses F7, verifies the rack list, and
presses P to prepare the installer. The strict pass requires `Rack nodes`,
`Installer armed`, and `/payload/.ready` on the fake floppy.

Manual in-game checks for 0.3.0:

- Build the master and rack as described in [`cluster.md`](cluster.md). The
  master's card is wired; the rack relay is disabled; power and data use
  different faces.
- Insert a formatted floppy, open Nodes with F7, and press **Prepare installer**.
  The floppy contains `/init.lua`, `/payload`, and `/install.log`; the window
  shows a countdown.
- Sneak-right-click one unprovisioned server. It boots the floppy, appears in
  Nodes as installing, then reboots into its HDD and reports online with its
  memory and disk.
- Start a second server on the same cable. It gets its own name and address;
  both remain listed after a master reboot and after an OS update.
- Confirm `/var/install-incomplete` is gone from the node after the install, and
  that the server's EEPROM and `/etc/terracorp.cfg` on the master are untouched.
- Remove power from one node (or let it go offline); Nodes marks it offline
  after the grace period and a **Ping** sends a frame once it returns.
- Rename a node; verify `/var/nodes.tsv` and the list update. (Role cycling is
  gone with the `role` column — F20.)
- Press **Prepare** again with the same floppy: it arms instantly, reuses the
  bootstrap, and the notification says the payload is already there.
- Press **Refresh**: every node with a modem is pinged and returns online via
  `PONG`; a node that stays silent goes offline after the grace period.
- Select an offline node and press **Forget**: it disappears from the list and
  `/var/nodes.tsv` no longer holds it.
- Power off a server while it shows "Pulling the runtime over the network..."
  and power it on again: it must boot the floppy once more instead of the
  half-written HDD, and the install completes on the second run.
- A server whose system disk is incomplete must never appear in Nodes; only a
  node that booted its HDD and passed the boot check shows up.
- Press **Update** with no newer release available: the master falls back to
  its own version, offers `PULL` to the nodes, and each node pulls, stages,
  reboots, and reports the same version again.
- Publish a newer release, press **Update**: the Nodes line shows the
  download progress, the nodes pull, reboot through the boot applier, and
  come back online reporting the new version on their cards.
- Select an online worker and press **Drain** (or key `d`): the header gains
  "· 1 drain" and the card shows "· drain". Queue a **Check**: no worker
  claims it and the queued count stays until the retry budget fails it.
  Press **Undrain**: the flag clears and the next job is claimed. The flag
  survives a node reboot.
- Queue a **Check** and watch the header: "· 1q/0g" while queued, "· 0q/1g"
  while a worker runs it, then the log records
  `Job <id> (fs.check) done: ok`.
- With two or more nodes online, press **Update**: the line shows
  "Update <v> · wave 1 · 0/2 updated · 1 queued" and only the first half
  receives `PULL` — the rest stays online. As each node reports the new
  version (or the 120 s wave window passes), the next wave starts, and the
  line ends with "Update <v> finished · 2/2 node(s) updated". The rack never
  reboots all at once.
- Vault: open the **Vault** app (desktop icon, F8): it lists the namespace
  with sizes and shows pool usage top-right. Copy a small file to
  `/var/vault-in/`, press **P**, Enter on it → the header usage grows and the
  master log records `Stored /<name> (N B)`. Back in the pool (P), Enter on
  the file fetches it and shows the preview; **S** saves a copy to
  `/var/vault-out/`. **D** deletes it. From the Terminal:
  `vault` (usage per disk), `vls`, `vput <file>`, `vget <path>`,
  `vrm <path>`. Nodes shows "Pool X/Y KB · N file(s) · M disk(s)" when idle.
- Vault index backup: store a file, wait ~2 minutes (the master writes
  `/vault/.backup/index.tsv` to the first pool disk), then wipe the master's
  `/var/vault/index.tsv` and reboot the master — after a node reports its
  disks, the log records "Vault index restored from the pool backup" and the
  file is browsable again.
- Hybrid installer floppy (0.3.6): with `nodeFloppyPayload = true`, arm the
  installer and confirm the floppy holds `/init.lua`, `/net.lua`,
  `/ready.txt`, `/payload/` with the runtime, and `/payload/.ready`. Power on
  a server **with the master's installer window NOT armed**: after 60 s it
  must install offline from the payload, name itself `TC-XXXX`, reboot into
  its HDD, and appear in Nodes once the master pings it (it adopts the master
  from a `PING`/`PULL`). Then power on another server with the window armed:
  it must still prefer the network pull path.
- Node-driven updates (0.3.6): stage a release for the nodes (press
  **Update** once), then power-cycle one node without arming anything — the
  node must report its old version, receive `PULL` once, stage, reboot
  through the applier, and come back on the staged version. Verify the
  master offered it only once (log line "offering staged <v>").
- Tick rate (0.3.6): run `tps` in the Terminal right after boot — it reports
  "sampling the site clock (first reading in ~10 s)"; ~10 s later it prints
  "Site tick rate: N TPS". Compare with `/forge tps` in the server chat:
  TerraCorp's estimate should be within ~1 TPS. The System card shows
  "Site N TPS" in its detail once the first window completes. Confirm
  `computer.realTime` behaves as wall-clock seconds in-game (pending).

## 0.2.3 desktop pictogram checks

`npm run test:icon-order` runs six scenarios at 160x50:

1. Drag Files onto the System cell and drop. Files must swap into the first
   slot, open from there, and `/etc/terracorp.cfg` must keep both the compact
   `iconOrder = "files,dashboard,console,settings,notes,update"` and the matching
   `iconLayout` with `files@1`.
2. Seed that preference before boot and require the first cell to open Files,
   proving the saved order still loads.
3. Drag Files onto an empty cell on row 3 (slot 32), then click it. The folder
   art and `Files` label must render at the new position, the app must open, and
   the saved `iconLayout` must contain `files@32`.
4. Seed the row-3 layout before boot and require that same empty-cell position
   to open Files after restart.
5. Open Files, drag System over the window, and hold it there. The floating
   monitor art and its label must be drawn above the window content.
6. Seed a 0.2.2 layout that names `about@6`, click slot 6, and require the
   Update window to open. This proves the saved `about` alias migrates in place.

`npm run check` also enforces the app contract: every `src/apps/*.lua` file must
be registered in `APP_IDS`, declare a 3-cell `icon`, a `short` label, a valid
`iconStyle`, and five `iconArt` rows of exactly nine display cells. The gate was
tested by shortening one art row and confirming a non-zero exit.

Manual in-game checks for 0.2.3:

- Each desktop tile shows its pictogram: monitor (System), console window
  (Terminal), gear (Settings), dog-eared page (Notes), folder (Files), and a down
  arrow over a disk (Update).
- System keeps the accent-filled tile; its art uses the inverse color and has no
  inset box.
- Drag each icon over an open window. The floating art follows the pointer
  smoothly and is not clipped by the window.
- Drop on an empty cell and on another icon. The first moves it; the second
  swaps. Labels stay centered under the art.
- Restart and update from 0.2.2: positions, including empty gaps, are restored;
  Update appears in the old About slot; settings and `/var/notes.txt` are
  unchanged.
- F1-F6 still open apps by their fixed order, and F6 opens Update.
- At 50x16 all six pictograms fit in two rows above the taskbar.

## 0.2.2 full-screen icon grid checks

`npm run test:icon-order` runs five scenarios at 160x50:

1. Drag Files onto the System cell and drop. Files must swap into the first
   slot, open from there, and `/etc/terracorp.cfg` must keep both the compact
   `iconOrder = "files,dashboard,console,settings,notes,about"` and a matching
   `iconLayout` with `files@1`.
2. Seed that preference before boot and require the first cell to open Files,
   proving the saved order still loads.
3. Drag Files onto an empty cell on row 3 (slot 32), then click it. The `FIL`
   tile must render at the new position, the app must open, and the saved
   `iconLayout` must contain `files@32`.
4. Seed the row-3 layout before boot and require that same empty-cell position
   to open Files after restart.
5. Open Files, drag System over the window, and hold it there. The floating tile
   and its label must be drawn above the window content.

Manual in-game checks for 0.2.2:

- The desktop shows drop slots across the full width and height, not just a
  left-hand strip.
- Drag an icon: a floating tile follows the pointer smoothly (not a series of
  jumps), the target cell is outlined, and the icon lands in the cell under the
  pointer.
- Drop an icon on an empty cell and on another icon. The first moves it; the
  second swaps the two. Clicking without dragging still opens the app.
- Restart the computer and update to a later build: positions, including empty
  gaps, are restored, and `/var/notes.txt` is unchanged.
- F1-F6 still open apps by their fixed order after positions change.

## 0.2.1 desktop layout checks

`npm run test:icon-order` runs two scenarios in 0.2.1. The first drags the Files
icon onto the System cell, opens the first cell, and requires Files to open and
`/etc/terracorp.cfg` to contain
`iconOrder = "files,dashboard,console,settings,notes,about"`. The second seeds
that same preference before boot and requires the first cell to open Files,
proving the saved order is loaded.

Manual in-game checks for 0.2.1:

- Drag an icon onto another cell; the dragged icon is inserted at that position
  and a `Desktop layout saved.` notice appears. Clicking without dragging still
  opens the app.
- Restart the computer: the new order remains.
- Update to 0.2.1 (or a later build): the order and other settings remain, and
  `/var/notes.txt` is unchanged.
- System shows the accent-filled `SYS` tile with an inset box at 80x25 and
  wider; the box is omitted when the grid is compressed.
- F1-F6 still open apps by their fixed order after the grid is rearranged.

## 0.2.0 desktop shell checks

`npm run test:desktop` clicks the Files icon and requires the final screen to
show exactly one window titled Files. `npm run test:screens` runs nine
scenarios (System, desktop, Terminal, Files, Settings, Notes, updater, Nodes,
Vault) across five resolutions (160x50, 120x40, 80x25, 60x20, 40x16), for 45
combinations. The list now includes Plant, for fifty combinations. GAIA has its
own gate, `npm run test:gaia`, because the screen
matrix does not open it.
Each combination must adopt the requested resolution, finish without errors,
and paint visible content.

Manual in-game checks add what the harness cannot prove:

- A single click on each icon opens its app; no double click is needed.
- F1-F6 still open the six apps, and with no focused window the arrows move the
  icon selection and Enter opens it.
- The taskbar chip focuses its window; clicking the focused chip minimizes it.
- About shows live SYSTEM values and R resamples them.
- The two-column icon strip and window placement look correct at 80x25 and
  above; the three-column layout is usable at 40x16.

## In-game protocol

1. Install/update from OpenOS using the steps in the README. Do not use
   `--eeprom` for a normal install.
2. Reboot and time startup until the desktop appears.
3. Read `/var/log/tc.log` from TerraCorp's boot volume. Record the `gpu` line's
   resolution/free-memory values and the uptime on `First render OK`.
4. Run a 30-minute session. Open all eleven apps by icon and the first ten by
   F1-F10 (Plant is the eleventh); verify the
   desktop selection, Enter-to-open, and taskbar chips. Drag two icons to swap
   their cells, restart, and confirm the order remains. In System, verify uptime
   advances once per second and readings refresh every two seconds. In Update,
   check the SYSTEM values and press R. Check that UI input/render response feels
   smooth at the 30 Hz loop target (the harness cannot measure game-client FPS).
   In Terminal, try `help`, `ls`, `pwd`, and `echo test`. Move/minimize/close
   windows and change screen resolution from OpenOS, then return to TerraCorp.
5. Check the log:

   ```sh
   grep ERR /var/log/tc.log
   ```

   It must return no lines. Record warnings separately.
6. Repeat with Tier 2 CPU/GPU and a Tier 2 screen at 80x25.
7. Updater: from a 0.1.9 or 0.1.10 install, copy the 0.1.11
   `src/boot/apply.lua` onto the TerraCorp volume as `/boot/apply.lua` (do not
   reinstall the whole tree). Reboot, then in Update press **Install** for 0.1.11
   and confirm the boot-time progress screen appears before the desktop. Confirm
   the version changes, settings persist, a note written in Notes survives, the
   EEPROM is unchanged, and `/var/update/pending` is gone afterwards. Turn the
   computer off during the progress screen once and verify the next start
   restores the previous version instead of hanging. That repair path was
   validated in-game. The normal 0.1.11 → 0.2.0 update was also confirmed
   in-game on 2026-10-25.

## Results log

| Date | Node | CPU / GPU / screen | Resolution | Free KB | First render | 30 min without `ERR` | Notes |
|---|---|---|---|---:|---:|---|---|
| Not recorded | TC-E6C8 | CPU/GPU unknown; screen tier unconfirmed | 80x25 | 1714 | 1.05 s | Not recorded | Log excerpt; occasional GPU span warnings |
| Not recorded | TC-B218 | CPU/GPU unknown; Tier 3 screen | 160x50 | 1279 | 1.25 s | No | User reports a 30-minute session; TerraCorp 0.1.0 log has console keyboard `ERR` entries and later GPU span warnings |

0.2.0 Grid: all local harness gates pass. On 2026-10-25 the user confirmed that
the 0.1.11 → 0.2.0 in-game update and the desktop shell worked without problems.
Node, resolution, memory, first-render, and 30-minute log figures were not
itemized; F0 is closed per the exit checklist below.

0.2.1 Mosaic: all local harness gates pass, including `test:icon-order` (drag,
save, and reload) and the 35-combination screen matrix. Published as
[`v0.2.1`](https://github.com/DerekLopezGarcia/TerraCorp-OS/releases/tag/v0.2.1)
on 2026-10-25. In-game drag/persistence, the accent System icon, and the
0.2.0 → 0.2.1 update are pending.

0.2.2 Drift: all local harness gates pass, including five icon-layout scenarios
(swap, saved swap, empty-cell move on row 3, saved empty-cell position, and the
floating tile above a window) and the 35-combination screen matrix. Published as
[`v0.2.2`](https://github.com/DerekLopezGarcia/TerraCorp-OS/releases/tag/v0.2.2)
on 2026-10-25. The user confirmed the in-game behavior worked well. Grid,
drag-smoothness, and memory figures were not itemized. F0 is closed; see the
exit checklist below.

0.2.3 Glyph: all local harness gates pass, including six icon-layout scenarios
and the app-icon contract gate. Published as
[`v0.2.3`](https://github.com/DerekLopezGarcia/TerraCorp-OS/releases/tag/v0.2.3)
on 2026-10-25. Pictogram rendering, drag smoothness over windows, the
`about` → `update` migration, and small layouts confirmed working by the user
in-game on 2026-10-26.

0.3.0 Rack: all local harness gates pass, including the cluster protocol,
registry, provisioning, install-guard, master/nodes, netboot integration, Nodes
scenario, seven-app screen matrix, and the existing installer, boot, downloader,
updater, and GPU-fault suites. Published as
[`v0.3.0`](https://github.com/DerekLopezGarcia/TerraCorp-OS/releases/tag/v0.3.0)
on 2026-10-26. The in-game rack build, floppy netboot, two-node online state, and
post-update registry persistence are pending confirmation.

0.3.x cluster verified in-game on 2026-10-26 (Supersymmetry): first node
provisioned end to end — hybrid bootstrap floppy (payload on floppy), node
installed onto the disk with the most free space, passed the boot check, and
came online as TC-N1 (worker, 4M RAM/disk, v0.3.10). Relay verified in-game:
Check queued (`1q/0g` → `0q/1g` → `done: ok`), Drain/Undrain gates claiming,
and the drain flag persisted across a node reboot. Releases 0.3.6–0.3.10 fixed
the found issues: offline payload fallback when the pull fails, every-floppy
preparation with address logging, pinned `nodeFloppyAddress`, disk selection
by most free space, and KB units in the space error. Still pending: second
node, update waves with two nodes, Vault in-game, RAID block probe, and the
clean 30-minute log.

0.3.22 address volatility verified by hand in-game on 2026-11-14 (0.3.22,
`census()` between edits, one Adapter on a crate):

- Breaking and re-placing the same crate on the same face kept its address.
- Changing that face to another container kind produced a new address.
- Removing and re-placing the Adapter regenerated every face.
- A Storage Drawer on a free face did not appear at all.
- A native OpenComputers component is the other case: its address is its own
  placement id, so breaking and re-placing it always changes it.

See [`names.md`](names.md#adapter-faces-are-derived-not-minted) for what this
means for `tc.addr` and the registry.

0.3.x Transposer face matrix (in-game 2026-11-14): the six faces of one
Transposer answered `getInventoryName` / `getInventorySize` with
`minecraft:hopper` 5, `minecraft:chest` 27, `gregtech:machine` 90,
`storagedrawers:basicdrawers` 2, `nil` "no inventory", and
`gregtech:item_pipe_small` 1. After the rig was rebuilt, the same five
containers answered on different faces — hopper 0, drawer 1, machine 2, chest 3,
empty 4, pipe 5 — which is what made `dump1(1, 3)` report `invalid slot`: face 1
is the two-slot drawer now, not the chest. The Transposer sees drawers the
Adapter does not, and reports pipes as one-slot inventories; both are recorded in
[`crafting.md`](crafting.md#the-sensing-requirement-the-load-bearing-dependency)
and [`drivers.md`](drivers.md#closed-capability-vocabulary).

Transposer read cost measured in the same session: 200 `getStackInSlot` calls
took 10,000 ms and 50 `getAllStacks` calls took 2,549 ms, both ~50 ms per call
with `clock=uptime` — one server tick per host call whatever the payload.
`computer.realTime` is `nil` on this build, so `clock()` fell back to `uptime`.
`getAllStacks` documents `function(side:number):userdata`, but the Lua side is a
table: `all[1]` is a stack, `pairs` lists the wrapper's methods, and `count()` /
`getAll()` give the length and the array (`getAll` returns a plain table). The
chest came back as `count 27`, `#getAll() 27`, and 448 items summed over the
seven stacks with a name: the array has one entry per slot, empty slots are
empty tables, so the reader skips entries without `name`.

0.3.x Tanks (in-game 2026-11-15, two GregTech drums on one Transposer): the
tank API is the same shape as the inventory one, with a side. `getTankCount(side)`
reported `1` on the two drum faces and `0` on the four empty ones — no error for
"no tank". Capacity came back **1,024,000 mB** per drum and one held **11,000 mB**
of water. `getFluidInTank(side)` returns an **array** of tank descriptions, so
the reader takes `[1]`; each entry is
`amount=11000 capacity=1024000 hasTag=false label=Water name=water` — the fluid
key is the Forge registry name (`water`), the label is only for display, and
`hasTag` marks NBT variants. That answers the identifier-format item for fluids
in [`telemetry.md`](telemetry.md#in-game-verification-checklist). Cost is again
**50 ms per call** (100 `getTankLevel` calls = 5,000 ms).
`transferFluid(from, to, count)` returns `true, moved` (mB, `false, 0` when
nothing moves) and pauses the transfer at 16 buckets per second: 1,000 mB moved
between the two drums and back, with `getTankLevel` reflecting each step.

The Adapter half is answered too (same session, after the block was wired and
the **Tank Controller** upgrade fitted): the Adapter does **not** appear as an
`adapter` component. `component.list()` shows a `tank_controller` component for
the upgrade plus one `drum_tungstensteel` component per drum — the drums expose
only `getCover`, `slot` and `type` (GregTech's machine API), so tank reads go
through `tank_controller`. It answered exactly like the Transposer: tanks on
faces 2 and 3, capacity 1,024,000 mB each, 14,000 mB of water on face 3, the
same `name=water label=Water amount=14000 capacity=1024000 hasTag=false` entry,
and 50 ms per call. The two paths are interchangeable for a stock reader, and
the component kind to register is `tank_controller`, not `adapter`.

0.3.x Energy (in-game 2026-11-15, Adapter on a Power Substation controller and on
an energy block, one Transposer on an energy hatch): the Adapter exposes
`power_substation` with `getStored`, `getCapacity`, `getAverageInLastSec`,
`getAverageOutLastSec`, `getPassiveDrain` and `getMaintenanceProblems` — exactly
the methods GT 2.8.10's own OpenComputers driver declares, minus
`getNumMaintenanceProblems`. **The two size reads come back as formatted
strings**, not numbers: `getStored()` = `"261,015,954,464"` and `getCapacity()` =
`"83,010,348,331,692,982,263"`. The capacity exceeds a signed 64-bit integer, so
GT formats a BigInteger; the reader must strip commas, and anything above 2^53
is approximate in a Lua double, which matters for percentage maths but not for
"is it full".

The energy block read through the same adapter is `infinite_energy` (the jar's
`gregtech.machine.infinite_energy`, the **Infinite GT Energy Unit Emitter**, a
creative block) and returns numbers: stored 69, capacity 420, output voltage
2,097,152, amperage 64, `getOutputPerSec` 2,684,354,560 = voltage × amperage ×
20. Both paths cost 50 ms per call. A Transposer next to the energy block saw
**no inventory or tank** on that face; the only inventory it found in the rig was
the Adapter block itself (`opencomputers:adapter`, 1 slot, its upgrade slot).

The substation's own hatches are asymmetric (same session). The **input** hatch
(`substation_hatch_input_64a_uhv`) exposes the full container API with plain
numbers: stored 0, capacity **2,147,483,648** (a 2^31 EU buffer), input
2,097,152 V × 64 A, `perSec` 0 while idle, 50 ms per call. The **output** hatch
(`substation_hatch_output_64a_uhv`) exposes only `getCover`, `slot` and `type` —
no energy methods at all — so a reader has to target the input hatch; the output
one is invisible to the driver on that face.

0.3.x Coarse redstone (in-game 2026-11-15, Storage Drawers with a Redstone
Upgrade, one Redstone I/O on the drawer, a second drawer on the same Transposer
as the sink): the upgrade emits a **proportional 0–15 for total storage**, not
the vanilla comparator curve. Sweeping 64 sponges out of a 2-slot basic drawer
and back gave a symmetric, monotonic ladder: 0 items → 0, 64 and 128 → 1, 192
and 256 → 2, 320 and 384 → 3, 448 → 4. That is `round(15 × fill / capacity)`
with a capacity in the 1,650–1,920 range (≈112 items per level, so a full drawer
should read 15); a vanilla comparator would have said 7 at 448. Coarse mode is
therefore usable for "half full / nearly full", not for counts.

Two rig facts from the same sweep. A computer's **Redstone Card only reads its
own six sides**: the drawer touched the Adapter and the Transposer, so the card
saw 0 on every side; a **Redstone I/O** block against the drawer, cabled to the
computer, is what reads it (face 3 in this rig). And `transferItem` is
`transferItem(from, to, count[, sourceSlot[, sinkSlot]])` — the fourth argument
is a slot **integer**, not a boolean: passing `true` raises `bad argument #4
(integer expected, got boolean)`. Between the two drawers it moved **64 items per
call even when asked for 192**, so `move` has to loop once per stack.

The **Redstone Control** Adapter (`rsio`) is a third path, with ports 0–7 instead
of sides. A Redstone Port reading the same drawer fed port 0, and `getInput(0)`
mirrored the ladder exactly (4 → 3 → 4 across a 64-item move). `registerEvent(1)`
delivered `rs_change, <address>, 0, 3` to `computer.pullSignal` on the change, so
this channel can be event-driven with no polling; the OpenComputers Redstone I/O
also signals, as `redstone_changed, <address>, <side>, <value>`.

0.4.0 Probe (in-game 2026-11-15). The 0.3.32 → 0.3.33 update ran in-world and
wrote `/var/whatsnew.md` with a single section, which closed the 0.3.32 feature.
The External Link then answered `status`, `log`, `fs.read`, `fs.write`,
`link.interval` and `lua` at a 1 s cadence, and `lua` is what made the rest of
the session possible: every probe above ran as a short chunk over the bridge
instead of from the Lab. Items, fluids, energy and coarse redstone are answered
here and in [`telemetry.md`](telemetry.md#in-game-verification-checklist); a
multiblock tank and one working machine remain, to be measured during 0.4.1 and
0.4.4.

Stack shape read from the drawer (face 1, slot 2) and the chest (face 3, slots
1..7): `name`, `damage`, `size`, `label`, `maxSize`, `maxDamage`, `hasTag`;
`tag` only appears when `hasTag` is true. The drawer held 128
`threng:material` (damage 23, "Flux-Plated Iron Ingot"); the chest held seven
stacks of 64 `gregtech:item_pipe_small` (damage 23, "Small Cobalt Item Pipe").

0.4.0 memory configuration (in-game 2026-11-15). The client's
`config/opencomputers/settings.conf` was edited to scale the six `ramSizes` by
32 (level 1 = 6 MB, level 6 = 32 MB); `maxTotalRam` was already `67108864`
bytes (64 MB), the same value as the server config. A full game restart was
required. The 0.4.0 computer then answered `status` with
`memory=863KB/65536KB` (version 0.4.0, uptime 585 s, 18 components); the log
held only repeated `cluster: no network card installed` warnings, no `ERR`
entries. The cap is per Lua machine: a top module is 32 MB, a Tier 1 module is
6 MB, and any combination above 64 MB is clamped. The `supersymmetry-local`
server config was not changed; on a dedicated server that file would have to
match. This is the premise behind decision 23 (F3 is local first).

0.4.1 first hall (in-game 2026-11-15). The first rig built for the local
readout: five Transposers, each with a `gregtech:machine` on face 1 and the same
`gregtech:item_pipe_large` on face 2. Three are GT crates of 144 slots; the other
two are an HV assembler (10 slots) and an HV bender (3 slots). One crate
(`502a3776…`) held 64 `gregtech:meta_ingot` damage 113 (Titanium Ingot); the
rest were empty. Empty GT-crate slots answer `minecraft:air` with `size=0`, not
an empty table — see [`crafting.md`](crafting.md#the-sensing-requirement-the-load-bearing-dependency).
The pipe is a 1-slot `gregtech:item_pipe_large` and must be classified as
transport, not stock. **For the line model only the input (`502a3776…`) and
output (`05be29b9…`) Transposers are boundary sensors; the bender/assembler
Transposers are debug-only (decision 24).** There is no Adapter on the rig, so
`getProgress`/`getMaxProgress`/`getEUt` remain unreadable; the line does not need
them: its rate comes from the boundary deltas. The line runs titanium
ingot → bender (circuit 1) → plate → assembler (circuit 8) → EV machine casing. The first `transferItem` from
the crate (face 1) to the large pipe (face 2) answered `true, 0`: the pipe was
not routed to the bender yet. After the pipe was connected to the bender, the
same call answered `true, 1`, a batch of 8 answered `true, 8`, the bender
auto-output the plates to the assembler, and the assembler produced
`gregtech:machine_casing` (damage 4) in the output crate. Eight ingots make one
casing; 48 ingots remained after two casings. A GT pipe is a valid sink **when
its network has a destination**; a disconnected pipe returns 0, not an error.
The four casing tiers were then produced from 8 ingots each: Steel → LV
(metadata 1), Aluminium → MV (2), Stainless Steel → HV (3), Titanium → EV (4).
The output crate held 2 EV, 1 HV, 1 LV and 1 MV; ULV (wrought iron) was not in
the crate. RecipeViewer's dataset agrees on the circuit (8), the 8 plates and
the material-to-tier mapping; see [`recipes.md`](recipes.md#machine-casings-assembler-circuit-8).

0.4.1 Plant readout (in-game 2026-11-15). The 0.4.1 tree was installed directly
over the 0.4.0 installation (backup in `/var/plant-backup`) and the computer
booted `version=0.4.1`, `memory=925KB/65536KB`, 15 components. The Plant app
opened from the link (`app.open plant`) and its `draw` returned **true** with
zero window failures. The live snapshot:

- `casing/ingots` — **exact**, 744 items, four keys: Titanium 192, Stainless
  Steel 184, Steel 184, Aluminium 184.
- `casing/casings` — **exact**, 5 items, four keys: 2 EV, 1 HV, 1 LV, 1 MV.
- No alarms at minimum 8 / maximum 64.

With `/etc/plant.tsv` temporarily at minimum 800, the alarm read `STARVED
casing/ingots · 744 below minimum 800`; restoring minimum 8 cleared it. Idle:
`calls=6, nextScan=5.1s`, and after three seconds `calls=6` — **zero component
calls between scans**. The log after the 0.4.1 boot had no new `ERR`; the only
`ERR` is the pre-fix Plant draw from the previous boot, fixed in the installed
app.

0.4.2 mirror (in-game 2026-11-15). The 0.4.2 files (`tc.link`, `tc.stock`,
`version`, `changelog`) were copied over the 0.4.1 install, verified byte for
byte with a checksum, and the computer rebooted to `version=0.4.2`,
`memory=943KB/65536KB`, 15 components. All four verbs answered over the link:

- `plant.status` — 415 bytes: `codename=Mirror`, `hall=TC-2907`,
  `revision=3`, `alarms=0`, `link_control=full`.
- `plant.snapshot` — **1232 bytes**, seven `LDATA` slices, reassembled with the
  declared size: `casing/ingots` exact 1128 (Aluminium 568, Titanium 192,
  Stainless Steel 184, Steel 184) and `casing/casings` exact 5.
- `plant.delta cursor=3` — `resync=0 changes=0`, 74 bytes.
- `plant.delta cursor=1` — `resync=1 reason=stale_cursor` plus
  `snapshot_begin` and the full 1308-byte snapshot.
- `plant.alarms` — `count=0`, 49 bytes.

The bridge parsed each completed reply: `GET /link/mirror` returned the status,
snapshot and delta entries with the stock names, decoded labels and counts.
The real snapshot is **larger than 1 KB**, so the paging criterion is met by the
production body, not only by the harness fixture.

Bridge-down check: with the Plant window open, the bridge process was killed,
the world ran for **50 seconds**, and a new bridge was started. The node
re-registered on its next poll; `uptime` moved from 130 s to 215 s (no reboot),
`generation` from 11 to 16 (five scans), `revision` stayed 3 (the stock had not
changed), `calls` from 54 to 85, both stocks still exact (1128 and 5), zero
alarms, and the Plant window still reported **0 failures**. The link is a
reader: losing the bridge neither stops the scan nor clears the cache.

0.4.4 history (in-game 2026-11-15). The 0.4.4 files were installed over 0.4.2
(backup in `/var/history-backup`) and the computer booted `version=0.4.4`,
`memory=957KB/65536KB`, 15 components. Findings:

- The sandbox `os.time()` is **frozen** (it stayed at `908247.6` while uptime
  advanced 204 s → 220 s), and the log's `os.date` timestamps repeat
  `12:17:27`. The ring therefore stamps samples with
  `base + computer.uptime()`; `base` continues from the newest persisted
  sample, so timestamps are monotonic across a reboot and offline time is not
  counted as a stall.
- After 95 s of uptime the ring held **6 samples per stock** and
  `/var/plant/history.tsv` existed. The snapshot reported `rate=0.000`,
  `rate_span=133` for both stocks (idle), and the Plant window drew with
  **0 failures**.
- With `/etc/plant.tsv` temporarily at `casing/casings 0 64 flow 50`, the
  alarm read **`STALLED casing/casings · no movement in 65s`** while both
  stocks stayed `exact` (1128 and 5). Restoring the original line cleared it
  to zero alarms.
- Reboot persistence: the ring went from **18 samples** (9 per stock) before
  the reboot to **34** after it, `base=144`, the newest sample at `t=243.35`,
  and the file held **69 lines**. The ring is bounded and survived the restart.

`TREND` was verified with synthetic samples (60/min → 6/min, **-90%**), not
in-game: the rig is idle and moving ingots to create two real rates would
change the stock the user keeps.

0.4.5 book and plan (in-game 2026-11-15). The 0.4.5 files were copied over 0.4.4
(backup in `/var/plan-backup`), the casing book and line program were written to
`/etc`, and the computer booted `version=0.4.5`, `memory=1034KB/65536KB`, 15
components. The log read `Recipe book: 5 recipes, 0 errors` (one TSV recipe and
the four line rules). Results:

- `plant.book` — **1745 bytes**, four `LDATA` slices: `casing_ev` (priority 10,
  assembler, 50 ticks) plus `line/casing/{lv,mv,hv,ev}` with their item terms.
- `plant.plan target=item gregtech:machine_casing@4 qty=100` — one step
  (`casing_ev`), **98 crafts** (100 minus 2 EV in stock), **4900 s**, bottleneck
  `casing_ev`, rate `0.020408` targets/s. Shortfall: **784 titanium ingots
  needed, 192 in stock, 592 missing** — the hand count.
- A synthetic three-step book (casing ← plate ← ingot) was written to `/etc`
  temporarily; the plan produced **3 steps** with `plate_ti` as the bottleneck
  and **1000 plans ran in under 0.05 s** (`computer.uptime` delta `0.0`). The
  real book was restored immediately and planned again correctly.
- Calibration: `book:calibrate("casing_ev", 1.25)` and the line rule at the
  same ratio both became `suspect`; the plan warned `suspect_recipe`, used
  **1.25** and raised the need to **980 ingots (788 missing)**. Restoring
  `1.0` returned both to `verified` and the plan to 592 missing.
  `/var/plant/calibration.tsv` held the expected rows.
- `/lib/tc/book.lua`, `plan.lua`, `link.lua` and `kernel.lua` were verified
  byte for byte after the copy; no new `ERR` appeared in the log.

The planner reads the cached stock snapshot and makes no component call, which
is why 1000 plans stay under the uptime resolution.

0.4.7 MCP (in-game 2026-11-15). The 0.4.7 `tc.link` was copied over 0.4.5
(backup in `/var/mcp-backup`) and the computer booted `version=0.4.7`,
`memory=1065KB/65536KB`, 15 components. `plant.history stock=casing/ingots n=3`
returned **279 samples**, rate `0.000`, `rate_span=129`, and the last three at
`t=4131.6, 4146.7, 4161.8`; `plant.paths` returned the two casing paths, both
`single`, 1 member, bound. The MCP server then answered the three posed
questions from `.link/`:

1. **How is the plant?** `plant_situation` → `TerraCorp 0.4.7 at TC-2907`,
   `2 stocks, 0 alarms`, `casing/ingots exact 1128 items`, `casing/casings
   exact 5 items`, with `source: plant.status + plant.snapshot + plant.alarms`.
2. **How much titanium?** `stock_query name=casing/ingots` → `Titanium Ingot
   x192 (damage 113)` beside Aluminium 568, Stainless Steel 184 and Steel 184,
   with the snapshot receive time.
3. **What does 100 casings need?** `plan` → `Bottleneck: casing_ev (0.0204
   targets/s), 4900 s`, 98 crafts, `need 784, have 192, missing 592`, with the
   `plant.plan` source.

The nine tools listed in `tools/list`, and the server identified itself as
`terracorp-plant 0.4.7`. No answer used a number that was not in a tool result.

0.4.8 field modules (in-game 2026-11-15). The 0.4.8 files were copied over 0.4.7
(backup in `/var/keystone-backup`) and the computer booted `version=0.4.8`,
`memory=1120KB/65536KB`, 15 components. The log read `Recipe book: 5 recipes, 0
errors` and **`Gates: 0 lines, 0 errors`**. Results:

- `plant.status` — `hall=TC-2907`, `halls=1`, `history_samples=822`: the ring
  kept growing across the updates.
- `plant.halls` — one online hall, `hall name=TC-2907 state=online stocks=2`,
  and the merged stocks `TC-2907/casing/ingots` exact 1128 and
  `TC-2907/casing/casings` exact 5. The prefix is the hall, as designed.
- `gate.set line=lv state=1` — `unknown_line`, because `/etc/gates.tsv` has no
  gate yet. The refusal is safe: no component call, no write to the world.
- The MCP server identified as `terracorp-plant 0.4.8` and answered the three
  questions again from the updated build (1128 exact, 592 missing, bottleneck
  0.0204 targets/s).

The actual second hall, gate reconciliation and move are **pending hardware**:
`npm run test:field` covers the hall merge, interlocks and transfer logic.

Post-release work that shipped as 0.3.1 and later: an interrupted install could leave the
EEPROM pointed at a half-written disk (the boot address is now set after a
complete copy), re-preparing an already prepared floppy rewrote it (same
versions are now reused), the node list kept failed installs (nodes now join
only after a verified `STATUS` following the boot integrity check), and Nodes
gained global **Refresh**, per-node **Forget**, and master-driven **Update**
actions. The floppy now carries only a pull bootstrap (`netfetch.lua` +
`tc.net`): the slave fetches the runtime from the master over `LIST`/`FETCH`,
the master stages the latest GitHub release for its nodes before offering
updates, and node versions are tracked in the registry. These changes are not
part of the published v0.3.0 release.

0.4.9 sub-second link intervals (in-game 2026-11-23). Driven from a workstation
through the bridge on the Pterodactyl node (`http://100.74.31.102:8787` over
Tailscale, `linkControl = "full"`), against the computer that was already
running: node `81dd02d0-91ef-4c9b-8b22-273979f1e637`, uptime 191,070 s before the
first command, `memory=1072KB/32768KB`, 13 components. Nothing was rebooted.

- `fs.read /etc/terracorp.cfg` — the rig runs `linkSink =
  "http://100.74.31.102:8787"`, `linkInterval = 5`, `linkControl = "full"`.
- `fs.read /lib/tc/config.lua` — the rig's own copy reads
  `if key == "linkInterval" then return type(value) == "number" and value >= 0.5`,
  so the 0.5 s floor is live on that machine, not only in the harness.
- `link.interval n=0.5` — `state=ok`, **`interval=0.5s`**. The reply keeps the
  fraction, which only `plantSeconds` produces; 0.4.8's formatter would have
  shown a whole second.
- `link.interval n=5` — `interval=5s`, and `/etc/terracorp.cfg` reads
  `linkInterval = 5` again. The cadence was restored.
- `link.interval n=9999` — no answer within 60 s, consistent with the value being
  capped at 60 s and the next exchange simply falling outside the window. Not a
  proof of the cap; the harness covers it (`interval_max`).

What this does and does not settle:

- **Settled in-game:** both ends accept a fractional interval — the bridge queued
  the frame, the OS applied it and reported `0.5s` — and the value round-trips
  back to the configured 5 s.
- **The stamp on that rig is deliberate.** `version.lua` says `0.4.8 "Keystone"`
  although `config.lua` and `link.lua` carry the 0.4.9 code, because 0.4.9 is
  intentionally **not tagged** in the repository. `updater.check` offers an
  update only when the installed version is lower than the latest GitHub Release
  (`available = compareVersions(current, latest) < 0`, `src/lib/tc/updater.lua:375`),
  so stamping the rig `0.4.9` while the newest release is `v0.4.8` would leave it
  claiming to be ahead of GitHub. Holding the stamp at 0.4.8 keeps every OC quiet
  until a real tag exists. **The rig is the 0.4.9 code, frozen at the 0.4.8
  label on purpose.**
- The consequence to keep in mind when diagnosing: **a stamp cannot distinguish
  the release from an untagged build.** `fs.read /lib/tc/version.lua` is not a
  reliable answer to "what is this machine running"; a behaviour the old build
  could not produce is. That is the gap behind F01, and this rig is the reason it
  matters in practice rather than in theory.
- `fs.read /lib/tc/link.lua` did not answer within 60 s — 47 KB needs many
  exchanges and the result is posted on a later one. The floor constant was
  therefore confirmed through observable behaviour, not by reading that file.

Harness for the same change: `npm run test:link` is 48 scenarios (the new
`interval_floor` asserts `interval=0.5s` and `instance.interval == 0.5`, and
`off_refuses_read` asserts a read command is refused at `off`), and
`npm run test:bridge` asserts a fractional `n` is accepted for `link.interval`
and still refused for `fs.read`. Both fail when the change is reverted.

## F0 exit checklist

| Criterion | Status |
|---|---|
| All seven apps usable in-game | Tested by the user. A terminal-input retest on 0.1.11+ is a post-F0 follow-up, not an open F0 item |
| 30-minute session without errors | **Met**: the user ran a clean 30-minute session with no `ERR` entries on the published build (2026-10-26) |
| At least 250 KB free on Tier 2 | **Met**: recorded logs exceed the threshold; CPU/GPU tiers confirmed by the user's session |
| First render within 2 seconds | **Met**: recorded values 1.05 s and 1.25 s are within budget; confirmed in-game |
| Resolution adaptation and GPU retry tests | Verified by `npm run test:screens` and `npm run test:faults` |
| Desktop icons, taskbar, and keyboard selection | `npm run test:desktop` clicks the Files icon and requires exactly one window; `npm run test:screens` covers 50 combinations; reported working in-game on 2026-10-25 |
| Icon layout persists | `npm run test:icon-order` verifies swap, move-to-empty-slot, saving `iconLayout`/`iconOrder`, and loading both formats after boot; confirm in-game across a restart and update |
| About → Update SYSTEM section shows live values | Harness screens pass; confirm values and R refresh in-game |
| Updater detects, stages, installs, and restarts from a stable release | Modern/legacy response paths, full manifest filtering, backup recovery, rollback, and the boot-time applier (including a successful close with no return value) pass in the harness; the 0.1.9 → 0.1.11 repair path and the normal 0.1.11 → 0.2.0 update were confirmed in-game; keep log and pending-file evidence for F0 |
| Notes persist across restarts and updates | `npm run test:notes` verifies `/var/notes.txt`; the 0.2.0 update succeeded in-game, but an explicit notes check was not recorded |
| System uptime advances every second | `npm run test:dashboard-tick` passes; the 0.2.0 desktop was reported working. Per-second uptime was never itemized; that is a post-F0 follow-up |
| UI loop requests 30 Hz idle cadence | `npm run test:refresh-rate` verifies the 1/30 s signal wait; actual display cadence is a post-F0 follow-up: measure it in-game when a rig is free |
| Window drag signal rate | In-game: Terminal `dragtest`, drag its title bar for 5-10 seconds, release, then `log 10` |

## Black-screen diagnostics

The boot log is opened before GPU initialization. The last trace identifies the
stage reached:

| Last trace | Likely stage |
|---|---|
| No log | BIOS, EEPROM, or boot-volume selection |
| `Booting ...` | Before GPU setup |
| `splash` | Splash rendering or module loading |
| `gpu ...` | Resolution setup or first frame |
| `First render` without `First render OK` | First-frame error; inspect following `ERR` entries |
| `First render OK` | OS rendered; investigate selected screen, power, and display connection |
