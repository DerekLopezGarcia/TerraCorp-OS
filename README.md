# TerraCorp OS

A Lua desktop operating system for **OpenComputers**, designed for the
**Supersymmetry** modpack (Minecraft 1.12.2 + Forge). TerraCorp OS runs on the
player's computers; it does not modify or redistribute Susy-Core.

Current version: **0.2.2 Drift**. The prototype boots into a desktop shell with
six apps, persists settings, notes, and the desktop icon layout, and logs errors.
Local simulations cover the OpenComputers API contract; in-game testing is
tracked in [`docs/tests.md`](docs/tests.md).

## Features

- Draggable desktop icons on a full-screen grid, a one-row taskbar, and
  movable/minimizable windows.
- **System:** node, memory, power, devices, storage, and system log. Its desktop
  icon uses an accent-filled tile to stand out from the other apps.
- **Files:** browse the boot volume, view sizes, and preview text files.
- **Terminal:** built-in shell (`ls`, `cd`, `cat`, `log`, `open`, `theme`, etc.).
- **Settings:** accent color, character set, clock format, boot splash, and log level.
- **Notes:** a persistent multi-line scratchpad stored at `/var/notes.txt`.
- **About:** version details, a SYSTEM section (memory, storage, screen,
  devices, boot volume, address), corporate lore, and a GitHub Releases updater.
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
| Memory | 1 MB | 2 MB |

The desktop uses the screen's actual resolution and adapts from 40x16 to
160x50. The icon grid covers the full desktop width and height; windows open
below the lowest occupied icon row when the remaining height is usable, and
centered otherwise. Below 80x25, System cards are compressed.

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

A 512 KiB floppy is large enough for the current installer bundle (about
133 KiB). In OpenOS, connect and format the floppy, find its mount under
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

## Controls

- **Desktop:** click an icon once to open its app. Drag an icon to any cell on
  the full-screen grid; dropping on an empty cell moves it there and dropping on
  another icon swaps the two. The floating icon follows the pointer smoothly,
  like a dragged window. The new layout is saved on release and restored after a
  reboot or update. With no window focused, the arrow keys move the selection,
  Home/End jump to the ends, and Enter opens the selected app. F1-F6 open the six
  apps directly; Esc minimizes the focused window.
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
- **About:** R refreshes the SYSTEM section. **Check for updates** queries
  GitHub Releases; **Install** downloads and installs before the desktop starts,
  on its own progress screen, and rolls back if anything fails. Requires an
  Internet Card.
- **0.1.9 and 0.1.10 updater repair:** those builds reject the filesystem's
  successful `close` (which returns no value) while staging, so an in-game update
  stops with `could not stage ... (nil)`. From OpenOS, replace `/boot/apply.lua`
  on the TerraCorp volume with the 0.1.11 file, or reinstall from OpenOS. Settings
  and `/var/notes.txt` are preserved either way.

## Repository layout

```text
src/                  boot-volume contents
  init.lua            entry point
  boot/kernel.lua     filesystem, services, module loader, event loop
  lib/tc/             core libraries, graphics, UI, and updater
  apps/               system, files, terminal, settings, notes, about
eeprom/init.lua       optional boot manager (not required for normal installs)
tools/                OpenOS installer, downloader, and manifest
tools/harness/        local Node.js simulation and tests
docs/                 architecture, testing, roadmap, and release documentation
```

## Development

No build step is required. With Node.js 20+:

```sh
npm install
npm run check
npm run manifest
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
npm run test:install
npm run test:fetch
npm run test:boot
npm run test:faults
npm run test:screens
```

The harness uses in-memory components and is a smoke test, not a replacement
for in-game testing. See [`docs/tests.md`](docs/tests.md) for the F0 protocol and
[`docs/versioning.md`](docs/versioning.md) for publishing GitHub Releases.

## Design notes

- The OS must remain useful on one offline node with 1 MB of storage.
- Colors use the OpenComputers palette; the T3 palette is initialized at boot.
- One Unicode code point occupies one screen cell; wide CJK characters and emoji
  are not supported.
- TerraCorp is a fictional megacorporation focused on human continuity and
  expansion beyond the Earth-Luna system. See [`docs/teracorp-lore.md`](docs/teracorp-lore.md).

## License and credits

MIT; see [`LICENSE`](LICENSE). The target environment is
[Supersymmetry](https://github.com/SymmetricDevs/Supersymmetry) and its
[Susy-Core](https://github.com/SymmetricDevs/Susy-Core). Neither is modified or
redistributed by this project.
