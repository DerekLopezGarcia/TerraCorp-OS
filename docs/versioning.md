# Releases and in-OS updates

TerraCorp OS uses semantic versions (`MAJOR.MINOR.PATCH`) in
`src/lib/tc/version.lua`. Published versions use matching Git tags in the form
`vMAJOR.MINOR.PATCH` and GitHub Releases. The updater only considers the latest
published, non-draft, non-prerelease GitHub Release stable.

## Publishing a release

1. Update `version` in `src/lib/tc/version.lua`.
2. Run the local checks, including `npm run manifest` if Lua files were added
   or removed.
3. Commit the release and create a matching annotated tag, for example:

   ```sh
   git tag -a v0.2.1 -m "TerraCorp OS 0.2.1"
   git push origin main --tags
   ```

4. Push the tag. The GitHub Actions workflow validates the tag/version, runs
   release checks, and creates a stable Release with generated notes. If the
   workflow fails, fix the checks before publishing manually. Do not mark stable
   releases as prereleases or drafts.

The tag must match `version` in `version.lua`. The updater checks this before
installing anything. Release source files and `tools/manifest.txt` are fetched
from the release tag, not from the moving `main` branch.

## Cuts and releases

A **cut** is a bump of `version` in `version.lua` plus its entry in
`src/lib/tc/changelog.lua`. A **release** is a tag. They are not one to one:
work done and tested somewhere else, such as against the local bridge on another
machine, can cut several versions before anything is published, and those cuts
then land in one commit under the tag of the build that finally ships. 0.4.2,
0.4.4, 0.4.5 and 0.4.7 were cut that way and went out with v0.4.8.

The notes stay per cut, so a node that updates still reads everything it
skipped: the kernel writes every entry between `/var/version` and the running
build into `/var/whatsnew.md`. Only tagged versions exist in the history and on
the Releases page, and the one thing the updater enforces is that the running
`version.lua` matches the tag its files came from.

## What the updater does

The Update app's **Check for updates** button queries GitHub's latest-release
API. When a newer stable version is found, **Install &lt;version&gt; and restart**
writes `/var/update/pending` and reboots immediately. The install itself happens
in `src/boot/apply.lua`, which the boot entry point runs before the kernel
starts: it draws its own full-screen progress bar, downloads the files listed
under `src/` in that tagged release, rejects unsafe paths, compiles each Lua
file without executing it, verifies the staged bytes, checks the release tag
against `version.lua`, and only then replaces the installed files. Because it
runs before the desktop, a window or UI failure cannot interrupt an update.

Existing files are moved to `/var/update/backup/<version>` before replacement.
Any failure restores them and starts the previous version; a leftover backup
from an interrupted attempt is restored on the next start instead of blocking
updates. The result is written to `/var/update/status` and shown in Update.

The updater changes only OS files on the boot filesystem. It does not modify
`/etc` settings, user data (including `/var/notes.txt` and `/var/nodes.tsv`),
OpenOS, the BIOS, or the EEPROM. An Internet Card and permission for HTTPS
requests are required. If there is no Internet Card, no stable release,
insufficient disk space, or a download/validation error, the current
installation remains in place.

## Initial stable release

The current build is 0.4.9 Flint, built on 2026-11-16; v0.4.8 remains the latest
published release until v0.4.9 is tagged. 0.4.9 removes the cluster and the Vault
app, so the manifest shrinks from 62 to 53 entries. The updater only adds and
replaces files, so a module left behind on an updated machine is inert: the
kernel no longer loads it. A line node is installed from its floppy, not through
this path ([`line-node.md`](line-node.md)). Earlier versions: 0.4.8 added six
files (`tc.history`, `tc.book`, `tc.plan`, `tc.halls`, `tc.gate`, `tc.move`) and
a manifest of 56. 0.4.1 introduced the
Plant app and the local line-boundary readout: items and fluids, exact or coarse
states, level alarms, and one component call per second. 0.4.2 exposes that
readout over the External Link with `plant.status`, `plant.snapshot`,
`plant.delta` and `plant.alarms`, paged with the existing `LREP`/`LDATA`/`LEND`
slicing. 0.4.4 adds a bounded sample ring per stock
(`/var/plant/history.tsv`), items/min and mB/min, and the `STALLED`/`TREND`
alarms. 0.4.5 adds the operated book (`/etc/recipes.tsv`, `/etc/recipe-io.tsv`,
line rules), `plan()` with bottleneck and shortfall, and calibration exposed as
`plant.book` and `plant.plan`. 0.4.7 adds `plant.history` and `plant.paths` and
the read-only MCP server at `tools/bridge/mcp.js`; the MCP tool files live on
the host, not on the computer, so they are not in the 56-file manifest. 0.4.8
adds the hall registry, gate setpoints/interlocks and move-by-name modules;
their in-game halves need hardware the rig does not have.
Versions through 0.1.6 had Internet Card compatibility issues and rejected
non-`src/` entries in the repository manifest; install 0.1.9 manually from OpenOS
on those. Versions 0.1.7 and 0.1.8 can update to the latest release in-game, but
cannot retry a release that left a backup behind after an interrupted install;
from 0.1.9 the boot-time applier restores such leftovers. Versions 0.1.9 and
0.1.10 treat the filesystem `close` callback's Unit return as a failure, so they
cannot stage any update; replace `/boot/apply.lua` with the 0.1.11 file from
OpenOS (or reinstall) before retrying. 0.1.11 fixes the applier.
The automated tests cover modern and legacy handles, a full repository manifest,
backup recovery, rollback, the boot-time install, and a successful close that
returns no value.
