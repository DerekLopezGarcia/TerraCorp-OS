# TerraCorp OS — Agent Guide

This is a personal project. Keep project context in this repository; do not put
it in the neXacom memory.

## Project

TerraCorp OS is a Lua desktop OS for OpenComputers in the Supersymmetry
modpack (Minecraft 1.12.2 + Forge). It runs on player-owned computers and does
not modify or redistribute Supersymmetry or Susy-Core.

- Runtime: Lua 5.3; no build step.
- OpenComputers: 1.7.x API verified; 1.8.x is a target.
- Use the display's native resolution (tested from 40x16 to 160x50).
- Product UI, source comments, and documentation are in English.
- License: MIT.

## Layout

```text
src/                  boot volume
  init.lua            entry point; finds the volume and loads the kernel
  boot/kernel.lua     VFS, module loader, services, event loop
  lib/tc/*.lua        core libraries, display, UI, updater
  apps/*.lua          system, files, terminal, settings, notes, about
eeprom/init.lua       optional boot manager
tools/install.lua     OpenOS installer
tools/fetch.lua       OpenOS repository downloader
tools/manifest.txt    files copied by fetch.lua
tools/harness/        Node.js simulation and tests
docs/                 architecture, testing, roadmap, release notes
```

## Commands

```sh
npm install
npm run check
npm run manifest       # required after adding/removing Lua files
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
npm run test:install
npm run test:fetch
npm run test:boot
npm run test:faults
npm run test:screens
npm run measure
```

In OpenOS, bootstrap with `wget .../tools/fetch.lua /tmp/fetch.lua`, run
`lua /tmp/fetch.lua`, then run `./install.lua /home/TerraCorp-OS` from the
downloaded tools directory. Normal installation sets the boot volume; do not
write the EEPROM unless explicitly required.

## Architecture and conventions

- Keep the core useful on one offline node with 1 MB; optional features should
  remain outside the boot-critical path.
- Follow the current phase and exit criteria in `docs/roadmap.md`.
- The kernel owns module loading. `tc.*` maps to `/lib/tc/*.lua`; `apps.*` maps
  to `/apps/*.lua`. Do not depend on OpenOS `require`, `event`, `fs`, or `shell`.
- Apps use `{ id, title, short, icon, order, create(ctx) }`; instances provide
  `draw`, `handle`, optional `tick`, and optional `close`. An app may set
  `iconStyle = "accent"` for a highlighted desktop tile. UI calls methods with
  `:` so `self` is the app instance.
- The desktop grid spans the whole screen. Persist icon positions as
  `iconLayout = "id@slot,..."` and keep `iconOrder` as the compact order for
  older releases; empty slots are valid. `npm run test:icon-order` covers swap,
  move-to-empty, persistence, and legacy loading.
- Apps draw only through `ctx.view`; its coordinates are local and clipped.
- Use `theme.colors` and `theme.glyphs`; use `ctx.text` for display widths.
- Only `kernel:poweroff` may call `computer.shutdown`.
- Do not add runtime dependencies. Keep Lua files UTF-8 without a BOM.

## Hard rules

- Do not push commits; the user publishes changes. Commit only with explicit
  approval.
- Do not modify `node_modules/`.
- Verify every OpenComputers API against `docs/opencomputers.md`; document
  unverified behavior as pending.
- Harness fakes must match the real API. In particular, `filesystem.list`
  returns a table and disk space is reported in bytes by `spaceUsed` and
  `spaceTotal`.
- Keep `tools/manifest.txt` synchronized. `npm run check` verifies it.
- Before considering a change complete, run `npm run check`, `npm run sim`, and
  `npm run sim:oc`, plus focused tests for the changed feature.

## Verified implementation details

- `computer.pullSignal` is the raw event API; OpenOS `event` is unavailable.
- OpenComputers `key_down` supplies a numeric Unicode code point (zero when
  absent) and a separate scan code. The UI normalizes it to UTF-8 for apps.
- `filesystem.list` returns a Lua table; `spaceUsed` and `spaceTotal` return
  bytes.
- `gpu.setBackground` and `gpu.setForeground` require `true` to interpret a
  value as a palette index. T3 screens begin with an editable grayscale palette;
  TerraCorp initializes it to the classic OpenComputers colors.
- `gpu.set`, `fill`, and `copy` return `true` on success and may return
  `nil, "not enough energy"` on failure. Failed framebuffer spans must remain
  dirty and be retried.
- The EEPROM sandbox in OpenComputers 1.7.x may lack boot-address functions;
  the optional custom boot manager supplies them. Standard BIOS boot does not
  require that manager.
- The local harness does not measure in-game memory or wall-clock boot time.
  Use `/var/log/tc.log` and the F0 protocol for those results.

## Versioning and updates

Use semantic versions in `src/lib/tc/version.lua`, matching Git tags
`vMAJOR.MINOR.PATCH`. The updater reads the latest stable GitHub Release and
downloads only the tagged `src/` files. See `docs/versioning.md`.
