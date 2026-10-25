# TerraCorp OS

A Lua desktop operating system for **OpenComputers**, designed for the
**Supersymmetry** modpack (Minecraft 1.12.2 + Forge). TerraCorp OS runs on the
player's computers; it does not modify or redistribute Susy-Core.

Current version: **0.1.3 Foundry**. The prototype boots, provides five apps,
persists settings, and logs errors. Local simulations cover the OpenComputers
API contract; in-game testing is tracked in [`docs/tests.md`](docs/tests.md).

## Features

- Desktop, dock, and movable/minimizable windows.
- **Dashboard:** node, memory, power, devices, storage, and system log.
- **Files:** browse the boot volume, view sizes, and preview text files.
- **Console:** built-in shell (`ls`, `cd`, `cat`, `log`, `open`, `theme`, etc.).
- **Settings:** accent color, character set, clock format, boot splash, and log level.
- **About:** version details and a GitHub Releases updater.
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
160x50. Below 80x25, dashboard cards are compressed.

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

## Controls

- **Dock:** click Dashboard, Files, Console, Settings, or About.
- **Keyboard:** F1-F5 open the corresponding app; Esc minimizes the focused window.
- **Windows:** drag the title bar, `[-]` minimizes, `[x]` closes.
- **Files:** arrows select, Enter opens, Backspace goes up, R reloads.
- **Console:** type commands and press Enter; `help` lists commands.
- **Settings:** click a value to cycle it.
- **Updater:** open About, check for updates, install a published stable release,
  then restart to apply it. Requires an Internet Card.

## Repository layout

```text
src/                  boot-volume contents
  init.lua            entry point
  boot/kernel.lua     filesystem, services, module loader, event loop
  lib/tc/             core libraries, graphics, UI, and updater
  apps/               dashboard, files, console, settings, about
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
npm run test:dashboard-tick
npm run test:refresh-rate
npm run test:updater
npm run test:updater-rollback
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
