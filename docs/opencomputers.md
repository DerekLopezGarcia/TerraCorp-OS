# OpenComputers API Notes

These facts were checked against OpenComputers source/documentation before
implementation. Re-verify them if the target version changes.

## Boot environment

- The BIOS binds a GPU to a screen and executes `/init.lua` from the selected
  boot filesystem using `load`.
- Any filesystem component can be the boot volume.
- The minimal BIOS environment guarantees `component`, `computer`, `load`, and
  standard Lua libraries. It does not provide OpenOS `require`, `event`, `fs`,
  or `shell`.
- `computer.getBootAddress()` / `setBootAddress(address)` are available in the
  running BIOS, but may be absent in the OpenComputers 1.7.x EEPROM sandbox.
  The optional TerraCorp EEPROM manager supplies them using EEPROM data.
- `computer.beep` is available before OpenOS.

## Signals and keyboard

`computer.pullSignal(timeout)` returns signal values directly and may return
`nil` on timeout. Relevant events include `key_down`, `key_up`, `touch`,
`drag`, `drop`, `scroll`, `screen_resized`, `component_added`,
`component_removed`, `modem_message`, `interrupted`, and `shutdown`.

The keyboard signal is `key_down(keyboardAddress, char, code, playerName)`.
`char` is a numeric Unicode code point, or zero when no printable character is
available. Use `code` for arrows and function keys. Touch coordinates start at
1,1 in the upper-left corner. Ctrl/Alt modifiers arrive as their own key events.

Verified scan-code subset:

| Key | Code | Key | Code |
|---|---:|---|---:|
| Esc | `0x01` | Backspace | `0x0E` |
| Tab | `0x0F` | Enter | `0x1C` |
| Space | `0x39` | Home | `0xC7` |
| Up | `0xC8` | Page Up | `0xC9` |
| Left | `0xCB` | Right | `0xCD` |
| End | `0xCF` | Down | `0xD0` |
| Page Down | `0xD1` | Delete | `0xD3` |
| F1-F10 | `0x3B`-`0x44` | | |

## Components and filesystems

- `component.list(kind)` returns an iterator of `(address, kind)` pairs.
- `component.proxy(address)` returns a method table and is preferred for
  repeated component operations.
- `component.invoke(address, method, ...)` is used during minimal boot.
- `computer.energy()` returns stored/maximum energy and may fail on nodes
  without an energy component; call it under `pcall`.
- `computer.totalMemory()` / `freeMemory()` and filesystem `spaceUsed()` /
  `spaceTotal()` return bytes. OpenComputers has no filesystem `space()` method.
- `filesystem.list(path)` returns a table; OpenOS wraps it as an iterator, but
  the TerraCorp VFS works with the table.
- Component filesystem handles are opaque values passed to `read`, `write`, and
  `close`. EOF reads return `nil` without a reason.

## GPU and colors

- `gpu.setResolution` changes the virtual resolution; `gpu.maxResolution()`
  reports the maximum for the bound GPU/screen pair.
- `gpu.set`, `gpu.fill`, and `gpu.copy` write screen cells.
- A GPU binds to one screen at a time. `gpu.getScreen()` reports its bound
  screen on supported versions.
- `setBackground(color, isPaletteIndex)` and `setForeground` treat the color as
  24-bit RGB when `isPaletteIndex` is `nil`/false. Pass `true` for palette
  indexes 0-15.
- Tier 2 screens use the classic Minecraft palette. Tier 3 screens have an
  editable 16-color palette initialized to grayscale plus a fixed 240-color
  palette. TerraCorp sets its 16-color palette to the classic OpenComputers
  colors before drawing.
- GPU `set`/`fill`/`copy` return `true` on success. An energy-related failure
  may return `nil, "not enough energy"`; do not mark a rejected span as drawn.
- `setBackground` / `setForeground` return the previous color, not a success
  boolean.

## Display constraints

- Each Unicode code point occupies one cell. Wide CJK characters and emoji can
  break alignment and are unsupported.
- Lua `#string` counts bytes, not Unicode characters. Use `lib/tc/text.lua` for
  display widths and slices.
- GPU writes are budget/energy constrained. Difference rendering reduces the
  number of direct writes; measure the real target hardware in-game.
