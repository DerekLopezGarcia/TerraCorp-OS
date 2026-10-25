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
npm run test:dashboard-tick
npm run test:refresh-rate
npm run test:drag-metric
npm run test:updater
npm run test:updater-legacy
npm run test:updater-rollback
npm run test:updater-recover
npm run test:boot-update
npm run test:notes
npm run test:faults
npm run test:screens
```

The harness models components and a filesystem in memory. Treat it as a smoke
and regression test, not a replacement for the game test.

## In-game protocol

1. Install/update from OpenOS using the steps in the README. Do not use
   `--eeprom` for a normal install.
2. Reboot and time startup until the desktop appears.
3. Read `/var/log/tc.log` from TerraCorp's boot volume. Record the `gpu` line's
   resolution/free-memory values and the uptime on `First render OK`.
4. Run a 30-minute session. Open all six apps; in Dashboard, verify uptime
   advances once per second. Check that UI input/render response feels smooth
   at the 30 Hz loop target (the harness cannot measure game-client FPS). In
   Console, try `help`, `ls`, `pwd`, and
   `echo test`. Move/minimize/close windows and change screen resolution from
   OpenOS, then return to TerraCorp.
5. Check the log:

   ```sh
   grep ERR /var/log/tc.log
   ```

   It must return no lines. Record warnings separately.
6. Repeat with Tier 2 CPU/GPU and a Tier 2 screen at 80x25.
7. Install 0.1.9 manually from OpenOS, reboot, then in About press **Install**
   for 0.1.10 and confirm the boot-time progress screen appears before the
   desktop. Confirm the version changes, settings persist, a note written in
   Notes survives, the EEPROM is unchanged, and `/var/update/pending` is gone
   afterwards. Turn the computer off during the progress screen once and verify
   the next start restores the previous version instead of hanging.

## Results log

| Date | Node | CPU / GPU / screen | Resolution | Free KB | First render | 30 min without `ERR` | Notes |
|---|---|---|---|---:|---:|---|---|
| Not recorded | TC-E6C8 | CPU/GPU unknown; screen tier unconfirmed | 80x25 | 1714 | 1.05 s | Not recorded | Log excerpt; occasional GPU span warnings |
| Not recorded | TC-B218 | CPU/GPU unknown; Tier 3 screen | 160x50 | 1279 | 1.25 s | No | User reports a 30-minute session; TerraCorp 0.1.0 log has console keyboard `ERR` entries and later GPU span warnings |

## F0 exit checklist

| Criterion | Status |
|---|---|
| All six apps usable in-game | Tested by user; console input errors still need an in-game retest |
| 30-minute session without errors | Not met in the supplied 0.1.0 log; repeat on the published 0.1.9 build |
| At least 250 KB free on Tier 2 | Recorded logs exceed the threshold; confirm CPU/GPU tier |
| First render within 2 seconds | Recorded values are 1.05 s and 1.25 s; confirm on Tier 2 hardware |
| Resolution adaptation and GPU retry tests | Verified by `npm run test:screens` and `npm run test:faults` |
| Updater detects, stages, installs, and restarts from a stable release | Modern/legacy response paths, full manifest filtering, backup recovery, rollback, and the boot-time applier pass in the harness; real update from 0.1.9 pending |
| Notes persist across restarts and updates | `npm run test:notes` verifies `/var/notes.txt`; confirm in-game after the 0.1.10 update |
| Dashboard uptime advances every second | `npm run test:dashboard-tick` passes; verify in-game |
| UI loop requests 30 Hz idle cadence | `npm run test:refresh-rate` verifies the 1/30 s signal wait; actual display cadence must be measured in-game |
| Window drag signal rate | In-game: Console `dragtest`, drag its title bar for 5-10 seconds, release, then `log 10` |

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
