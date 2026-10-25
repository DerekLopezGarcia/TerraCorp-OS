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
`/etc` settings, user data (including `/var/notes.txt`), OpenOS, the BIOS, or
the EEPROM. An Internet Card and permission for HTTPS requests are required. If
there is no Internet Card, no stable release, insufficient disk space, or a
download/validation error, the current installation remains in place.

## Initial stable release

The current build is 0.2.3 Glyph; the latest published stable release is 0.2.2
(2026-10-25).
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
