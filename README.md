# TerraCorp OS

A Lua desktop operating system for **OpenComputers**, designed for the
**Supersymmetry** modpack (Minecraft 1.12.2 + Forge). TerraCorp OS runs on the
player's computers; it does not modify or redistribute Susy-Core.

Current version: **0.4.9 Flint** (`src/lib/tc/version.lua` is the only source of
that fact; it is built and **deliberately untagged** — see
[`docs/versioning.md`](docs/versioning.md)). It boots into a desktop shell with
eleven apps, persists settings, notes and the desktop icon layout, and logs
errors. One desktop computer is the master: its node registry, `/var/nodes.tsv`,
is the plant's naming service and the Nodes app is its view and editor. Each
production line runs a line node that reads its own boundary stocks and publishes
to the master over a wired modem. Local simulations cover the OpenComputers API
contract; in-game testing is tracked in [`docs/tests.md`](docs/tests.md). The
authoritative definition of the whole system is
[`docs/canonical.md`](docs/canonical.md).

## Features

- Draggable desktop pictograms on a full-screen grid, a one-row taskbar, and
  movable/minimizable windows.
- **System:** node, memory, power, devices, storage, and system log. Its desktop
  monitor icon uses an accent-filled tile to stand out from the other apps.
- **Files:** browse the boot volume, view sizes, and preview text files with a
  scrollable pager.
- **Terminal:** built-in shell (`ls`, `cd`, `cat`, `lua`, `log`, `open`,
  `theme`, etc.).
- **Settings:** accent color, character set, clock format, boot splash, and log level.
- **Notes:** a persistent multi-line scratchpad stored at `/var/notes.txt`.
- **Lab:** write and run Lua against the live OS, or keep an interpreter session
  whose names survive between lines; output and errors are kept at
  `/var/log/lab.log`.
- **Update:** version details, a SYSTEM section (memory, storage, screen,
  devices, boot volume, address), a GitHub Releases updater, and release
  notes in /var/whatsnew.md after an update.
- **Nodes:** the plant's naming service. One row per line node that talks to the
  master — the name it answers to, its state, its worst alarm and its stocks —
  stored in `/var/nodes.tsv`. The app is the registry's view and editor.
- **Lines:** control over what a line watches. Edits the level thresholds of the
  selected line in the master's `/etc/plant.tsv` and pushes the file to the node,
  so the node keeps evaluating its own alarms with the same numbers. It never
  invents a stock: stocks are declared on the node.
- **Plant:** a local readout of line-boundary stocks: items and fluids, exact or
  coarse states, level alarms and node status. One component call per second;
  none while the line is idle.
- **Plant mirror:** the same readout over the External Link
  (`plant.status`, `plant.snapshot`, `plant.delta`, `plant.alarms`), paged when
  a reply exceeds one frame, with the bridge keeping the last parsed reply of
  each kind.
- **Plant history:** a bounded ring per stock with items/min and mB/min,
  `STALLED` and `TREND` alarms, and a ring that survives a reboot.
- **Plant book:** the operated recipes in `/etc/recipes.tsv` and
  `/etc/recipe-io.tsv`, line rules as recipes, `plan()` with bottleneck and
  shortfall, and declared/verified/suspect calibration.
- **Read-only MCP:** a stdio server next to the bridge exposes the situation,
  stocks, alarms, history, plan, paths, recipes and the audit tail to an agent,
  citing the verb behind every number.
- **Halls, gates and move (harness-only):** a hall registry with a merged,
  prefixed view; gate setpoints with local interlocks and `DISOBEDIENT LINE`;
  bounded transfer by item name. The second hall, the gate and the transport
  are not built yet, so the in-game run is pending.
- **GAIA:** the external link. Shows whether the link to an outside agent is
  armed, edits the sink and token, and sets how far the far side can reach
  (`off`, `read`, `write`, `full`). `off` really is off: only the interval knob
  answers. See [`docs/external-link.md`](docs/external-link.md).
- Difference-based framebuffer rendering.
- No OpenOS runtime dependency: TerraCorp loads its own modules and filesystem.

## Requirements

| Component | Minimum | Recommended |
|---|---|---|
| Minecraft / Forge | 1.12.2 | 1.12.2 |
| Modpack | Supersymmetry | Supersymmetry |
| OpenComputers | 1.7.x | 1.8.x |
| CPU | Tier 2 | Tier 3 |
| Screen | Tier 2 (80x25) | Tier 3 (up to 160x50) |
| Disk | 1 MB free | 2 MB |
| Memory | 1 MB | 64 MB for the plant readout |

The desktop uses the screen's actual resolution and adapts from 40x16 to
160x50. The icon grid covers the full desktop width and height; windows open
below the lowest occupied icon row when the remaining height is usable, and
centered otherwise. Every app icon fits on the smallest supported screen; the
screen gate renders the desktop at 40x16. Below 80x25, System cards are
compressed.

## Installation

The boot volume contains the contents of `src/`. OpenComputers BIOS runs
`/init.lua` from the selected boot volume; a custom EEPROM program is not
required.

1. Boot OpenOS with an Internet Card and download the repository:

   ```lua
   wget https://raw.githubusercontent.com/DerekLopezGarcia/TerraCorp-OS/main/tools/fetch.lua /tmp/fetch.lua
   lua /tmp/fetch.lua
   ```

   This downloads the source, EEPROM template, and tools to `/home/TerraCorp-OS`.
2. Run the installer under OpenOS:

   ```lua
   cd /home/TerraCorp-OS/tools
   ./install.lua /home/TerraCorp-OS
   ```

   The installer selects a writable, empty TerraCorp volume with at least 1 MB
   free. To select one explicitly, pass its filesystem address (shown by
   `components`) before `--yes`.
3. Reboot. The installer sets the boot volume; it does not need to write the
   EEPROM. **Do not use `--eeprom` unless you intentionally want to replace the
   BIOS.**

### Offline installer floppy

A 512 KiB floppy is large enough for the OpenOS fetch bundle (about 133 KiB). In
OpenOS, connect and format the floppy, find its mount under
`/mnt`, then download the bundle directly onto it:

```lua
wget https://raw.githubusercontent.com/DerekLopezGarcia/TerraCorp-OS/main/tools/fetch.lua /tmp/fetch.lua
lua /tmp/fetch.lua /mnt/<floppy-mount>
```

On later installs or repairs, insert the floppy and run:

```lua
lua /mnt/<floppy-mount>/tools/install.lua /mnt/<floppy-mount>
```

The installer can update an existing TerraCorp boot volume while preserving
settings. It does not need Internet and does not write the EEPROM. If it finds
multiple eligible target volumes, provide the TerraCorp filesystem address as
the final argument.

## Line node

Each production line gets one ordinary computer running `role = "line"`: it reads
the two boundary stocks, caches the answers, raises its own level alarms and
publishes its status to the master over a wired modem. It has no desktop and
needs no GPU, and it keeps reading, alarming and writing `/var/status/last.tsv`
with no master in reach.

The master flashes a floppy with the node payload — an explicit list of files, not
the whole runtime — and that medium installs one computer after another, because
it is only ever read.

The rack cluster that 0.3.x built (rack discovery, netboot provisioning, Relay,
update waves and the Vault pool) was **removed in 0.4.9** (decision 25). The
documents that describe it are kept as the 0.3.x record and say so at the top.

See [`docs/line-node.md`](docs/line-node.md) for the payload, the installer, the
naming rules and the status contract, and
[`docs/canonical.md`](docs/canonical.md) for the authoritative definition of the
whole system.

## Controls

- **Desktop:** click an icon once to open its app. Drag an icon to any cell on
  the full-screen grid; dropping on an empty cell moves it there and dropping on
  another icon swaps the two. The floating pictogram follows the pointer
  smoothly, like a dragged window. The new layout is saved on release and
  restored after a reboot or update. With no window focused, the arrow keys move
  the selection, Home/End jump to the ends, and Enter opens the selected app.
  F1-F10 open the first ten apps in `order` (dashboard through plant); `lines` is
  eleventh and has no function key, so it opens from its icon or with `open lines`
  in the Terminal. Esc minimizes the focused window.
- **Taskbar:** click a window chip to focus it; clicking the focused chip
  minimizes it.
- **Windows:** drag the title bar, `[-]` minimizes, `[x]` closes.
- **System:** readings refresh every two seconds; R samples immediately.
- **Files:** arrows select, Enter opens, Backspace goes up, R reloads.
- **Terminal:** type commands and press Enter; `help` lists commands.
- **Settings:** click a value to cycle it.
- **Notes:** type to edit; Enter starts a line and saves. PgUp/PgDn scroll,
  arrows/Home/End move the cursor, and clicking a line places the cursor.
  Losing focus also saves.
- **Update:** R refreshes the SYSTEM section. **Check for updates** queries
  GitHub Releases; **Install** downloads and installs before the desktop starts,
  on its own progress screen, and rolls back if anything fails. Requires an
  Internet Card. Saved 0.2.x layouts that name the old `about` app migrate to
  `update` in place.
- **Nodes:** arrows select a node, PgUp/PgDn jump six rows, Home/End jump to the
  first or last node, `I` pressed twice flashes the installer medium, `R` renames,
  `P` pings it and `F` forgets it. Enter commits a rename and Tab cancels it.
- **Lines:** arrows select a line, and the threshold editor pushes `/etc/plant.tsv`
  to the node it belongs to.
- **0.1.9 and 0.1.10 updater repair:** those builds reject the filesystem's
  successful `close` (which returns no value) while staging, so an in-game update
  stops with `could not stage ... (nil)`. From OpenOS, replace `/boot/apply.lua`
  on the TerraCorp volume with the 0.1.11 file, or reinstall from OpenOS. Settings
  and `/var/notes.txt` are preserved either way.

## Repository layout

```text
src/                  boot-volume contents
  init.lua            entry point; also runs the installer and a pending update
  boot/kernel.lua     filesystem, services, module loader, event loop
  boot/install.lua    line node installer, run from the flashed medium
  boot/apply.lua      boot-time update applier
  lib/tc/             core libraries, display, UI, plant readout, link, line node
  lib/tc/payload.lua  the files a line node carries (the flash and size contract)
  apps/               dashboard, files, console, settings, notes, update, nodes,
                      gaia, lab, plant, lines
eeprom/init.lua       optional boot manager (not required for normal installs)
tools/                OpenOS installer, downloader, and manifest
tools/bridge/         HTTP bridge, link client, and the read-only MCP server
tools/harness/        local Node.js simulation and tests
docs/                 architecture, testing, roadmap, and release documentation
```

## Development

No build step is required. With Node.js 20+:

```sh
npm install
npm run check        # Lua compiles, manifest, app icons, node payload closure
npm run manifest     # rewrite tools/manifest.txt after adding or removing a file
npm run size         # the node installer image against the 512 KB medium
npm run test:docs    # every number a document quotes still equals its command
npm run sim
npm run sim:oc
npm run test:desktop
npm run test:icon-order
npm run test:screens
npm run test:faults
npm run test:boot
npm run test:install
npm run test:fetch
npm run test:notes
npm run test:nodes
npm run test:apps
npm run test:plant
npm run test:line
npm run test:history
npm run test:book
npm run test:link
npm run test:bridge
npm run test:mcp
npm run test:field
npm run test:naming
npm run test:installer
npm run test:flash
npm run test:report
npm run test:master
npm run test:gaia
npm run test:updater
npm run test:updater-legacy
npm run test:updater-rollback
npm run test:updater-recover
npm run test:boot-update
```

`npm run` also exposes focused `sim:*` runs for a single app. The complete
contract, including what each gate really checks and the numbers it prints, is in
[`docs/canonical.md`](docs/canonical.md) §9.

The harness uses in-memory components and is a smoke test, not a replacement
for in-game testing. See [`docs/tests.md`](docs/tests.md) for the F0 protocol and
[`docs/versioning.md`](docs/versioning.md) for publishing GitHub Releases.

Where the plan currently stands — decisions, what is built, what is only
designed, and what blocks what — is kept in [`docs/status.md`](docs/status.md).

## Design notes

- The OS must remain useful on one offline node with 1 MB of storage.
- Colors use the OpenComputers palette; the T3 palette is initialized at boot.
- One Unicode code point occupies one screen cell; wide CJK characters and emoji
  are not supported.
- TerraCorp is a fictional megacorporation focused on human continuity and
  expansion beyond the Earth-Luna system. See [`docs/teracorp-lore.md`](docs/teracorp-lore.md).
- The plant's route to the bridge is decided to move from the Internet Card to a
  small Forge mod: a bridge card plus a bulk inventory scanner. See
  [`docs/sidecar.md`](docs/sidecar.md). The same mod is where a metered bus for
  moving stock between named endpoints would live ([`docs/bus.md`](docs/bus.md)).

## License and credits

MIT; see [`LICENSE`](LICENSE). The target environment is
[Supersymmetry](https://github.com/SymmetricDevs/Supersymmetry) and its
[Susy-Core](https://github.com/SymmetricDevs/Susy-Core). Neither is modified or
redistributed by this project.
