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

The current build is 0.4.8 Keystone, built on 2026-11-15; v0.4.1 remains the
latest published release until v0.4.8 is tagged. Versions through 0.4.1 update
in place: 0.4.8 adds six files (`tc.history`, `tc.book`, `tc.plan`, `tc.halls`,
`tc.gate`, `tc.move`), so the manifest grows to 56 files and the updater creates
them. 0.4.1 introduced the Plant app and the local line-boundary readout: items
and fluids, exact or coarse states, level alarms, and one component call per
second. 0.4.2 exposes that readout over the External Link with `plant.status`,
`plant.snapshot`, `plant.delta` and `plant.alarms`, paged with the existing
`LREP`/`LDATA`/`LEND` slicing. 0.4.4 adds a bounded sample ring per stock
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
