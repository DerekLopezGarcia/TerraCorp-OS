# MineOS Architecture Reference

This is a source-based study of [IgorTimofeev/MineOS](https://github.com/IgorTimofeev/MineOS)
(MIT), used to compare architecture and UX ideas. TerraCorp OS is not a fork and
does not copy MineOS code.

## Summary

MineOS is a graphical desktop and app manager built on OpenOS/OpenComputers,
not a kernel. It reuses the OpenComputers ecosystem and provides its own module
loader, double-buffered screen library, and GUI widgets. A notable design
choice is broad `xpcall` recovery: errors restore the desktop and display a
diagnostic window instead of leaving a blank screen.

## Boot and modules

MineOS gets the boot filesystem address from EEPROM data, defines `dofile` and
its own cached `require`, and loads libraries in dependency order. It provides
compatibility globals for OpenOS-style programs. TerraCorp instead supports
standard BIOS boot, loads `/lib/tc/*.lua` and `/apps/*.lua` into a restricted
environment, and does not emulate OpenOS.

## Error handling

MineOS wraps the workspace event loop, extracts source path/line/traceback,
redraws, and presents a modal diagnostic with the relevant source. Individual
program launches use the same recovery path. TerraCorp currently uses focused
`pcall` boundaries around app draw/event/tick callbacks and logs to
`/var/log/tc.log`; a modal source viewer is intentionally not part of the small
core.

## Display implementation

MineOS keeps current and pending character/foreground/background arrays, groups
changes by color pair across the screen, then emits `gpu.set` calls. TerraCorp
groups contiguous dirty spans per row and checks GPU return values so rejected
writes can be retried. MineOS does not check those returns. The simpler
row-based approach is adequate for the current local desktop; remote displays
will require measured bandwidth and packed framebuffers.

## Apps and events

MineOS apps are directories containing `Main.lua`, optional icons, and optional
localizations. The system discovers them and integrates returned windows into
its widget tree. TerraCorp apps are individual Lua modules with a fixed
`APP_IDS` list and the `{ id, title, short, order, create(ctx) }` contract.

MineOS has an event scheduler, keyboard-state helpers, nested GUI widgets, and
pointer capture. TerraCorp uses `computer.pullSignal` directly, a flat z-ordered
window list, and a small set of verified keyboard codes.

## Takeaways

- Keep app errors visible and include actionable logs.
- Add per-app resize callbacks only if apps need cached layout state.
- App-directory discovery is optional and should wait until after core testing.
- Do not import MineOS's large GUI library, account/password system, app market,
  localization framework, or OpenOS compatibility layer; these do not match
  TerraCorp's minimal standalone target.

## Source references

- Repository: <https://github.com/IgorTimofeev/MineOS>
- GUI wiki: <https://github.com/IgorTimofeev/MineOS/wiki/GUI-API>
- Studied components: `OS.lua`, `System.lua`, `Screen.lua`, `Event.lua`,
  `Keyboard.lua`, `GUI.lua`, app model, installer, and EFI.
- Study date: 2026-10-23.
