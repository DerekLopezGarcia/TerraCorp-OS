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
   git tag -a v0.1.4 -m "TerraCorp OS 0.1.4"
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

The About app's **Check for updates** button queries GitHub's latest-release
API. When a newer stable version is found, a second action downloads the Lua
files listed under `src/` in that tagged release. It checks HTTP responses,
rejects unsafe paths, compiles each Lua file without executing it, verifies the
staged bytes, and checks the release tag against `version.lua` before replacing
the installed files. Existing files are moved to `/var/update/backup/<version>`.
The update is not active until the user selects **Restart to finish update**.

The updater changes only OS files on the boot filesystem. It does not modify
`/etc` settings, user data, OpenOS, the BIOS, or the EEPROM. An Internet Card
and permission for HTTPS requests are required. If there is no Internet Card,
no stable release, insufficient disk space, or a download/validation error, the
current installation remains in place.

## Initial stable release

The current build is 0.1.4. Updater builds through 0.1.3 did not wait for the
asynchronous HTTP response before querying its status. Install 0.1.4 manually
from OpenOS on those versions; the updater can then be tested against a later
stable release. The automated tests use a mocked next-patch release.
