# F0 Test Plan

F0 exits when the OS has run for 30 minutes without `ERR` log entries, retains
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
npm run test:nodes
npm run test:cluster
npm run test:faults
npm run test:screens
```

The harness models components and a filesystem in memory. Treat it as a smoke
and regression test, not a replacement for the game test.

## 0.3.0 rack and netboot checks

`npm run test:cluster` runs pure Lua module tests under Fengari against fake
filesystem, floppy, and modem components:

1. `TC1` frames encode and decode escaped values, reject missing or duplicate
   fields, reject field names that do not start lowercase, reject oversized
   frames, and reject malformed or non-`TC1` input.
2. The registry loads, merges duplicate IDs, skips malformed lines, defaults an
   invalid role, and saves back to `/var/nodes.tsv`.
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
- Rename a node and cycle its role; verify `/var/nodes.tsv` and the list update.
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
show exactly one window titled Files. `npm run test:screens` runs seven
scenarios (System, desktop, Terminal, Files, Settings, Notes, updater) across
five resolutions (160x50, 120x40, 80x25, 60x20, 40x16), for 35 combinations.
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
4. Run a 30-minute session. Open all seven apps by icon and by F1-F7; verify the
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

Post-release work under development: an interrupted install could leave the
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

## F0 exit checklist

| Criterion | Status |
|---|---|
| All seven apps usable in-game | Tested by user; Terminal input still needs an in-game retest on 0.1.11+ |
| 30-minute session without errors | **Met**: the user ran a clean 30-minute session with no `ERR` entries on the published build (2026-10-26) |
| At least 250 KB free on Tier 2 | **Met**: recorded logs exceed the threshold; CPU/GPU tiers confirmed by the user's session |
| First render within 2 seconds | **Met**: recorded values 1.05 s and 1.25 s are within budget; confirmed in-game |
| Resolution adaptation and GPU retry tests | Verified by `npm run test:screens` and `npm run test:faults` |
| Desktop icons, taskbar, and keyboard selection | `npm run test:desktop` clicks the Files icon and requires exactly one window; `npm run test:screens` covers 35 combinations; reported working in-game on 2026-10-25 |
| Icon layout persists | `npm run test:icon-order` verifies swap, move-to-empty-slot, saving `iconLayout`/`iconOrder`, and loading both formats after boot; confirm in-game across a restart and update |
| About → Update SYSTEM section shows live values | Harness screens pass; confirm values and R refresh in-game |
| Updater detects, stages, installs, and restarts from a stable release | Modern/legacy response paths, full manifest filtering, backup recovery, rollback, and the boot-time applier (including a successful close with no return value) pass in the harness; the 0.1.9 → 0.1.11 repair path and the normal 0.1.11 → 0.2.0 update were confirmed in-game; keep log and pending-file evidence for F0 |
| Notes persist across restarts and updates | `npm run test:notes` verifies `/var/notes.txt`; the 0.2.0 update succeeded in-game, but an explicit notes check was not recorded |
| System uptime advances every second | `npm run test:dashboard-tick` passes; the 0.2.0 desktop was reported working, but per-second uptime was not itemized |
| UI loop requests 30 Hz idle cadence | `npm run test:refresh-rate` verifies the 1/30 s signal wait; actual display cadence must be measured in-game |
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
