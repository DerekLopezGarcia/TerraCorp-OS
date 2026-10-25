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
The screen emits `touch` when the button is pressed and `drop` when it is
released; a release without movement still produces a `drop`. Movement between
them produces `drag` signals. Desktop icons therefore open on `drop`, so the same
gesture can drag an icon instead of opening it.

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

## Racks and servers

Verified against `master-MC1.12` (1.8.x) and the pack's 1.8.9a build.

- A rack holds four mountables: servers, Terminal Servers, and mountable disk
  drives. A server runs only while installed in a rack.
- The rack GUI exposes five internal buses: **Top**, **Bottom**, **Left**,
  **Right**, and **Back**. The front face has no bus. The labels are relative to
  the rack's front, so "Left" is the side to the player's left when facing the
  front.
- Each mountable has one primary connection (thick dot) and up to three
  secondary connections (slim dots). The primary allows component access. The
  secondary only passes network messages. Clicking a dot toggles it.
- Relay mode is off by default. It relays messages between the rack's side buses
  only; it does not expose components across buses. Leave it off for a cluster.
- A rack is not a component. There is no rack address; discovery must use its
  mountables.
- A server's mountable node is its machine node. Its internal components,
  including its HDD filesystem, stay `Visibility.Neighbors`, so another computer
  on the bus cannot read the server's disks or use its internal components.
- Network cards are the only `RackBusConnectable` components. A server's network
  card appears as a secondary connection; its modem messages cross the bus, but
  the card itself is not exposed as a component.
- The mountable disk drive sets the floppy filesystem to `Visibility.Network`,
  so the master and every server on the same side bus can see the floppy. This
  is the netboot path: a server with no boot address boots the floppy's
  `/init.lua`.
- Server power-on is a sneak-use on the front face. Normal use opens the server
  GUI. There is no API to start another server, and servers do not auto-start
  after a world reload.
- Tier limits (one CPU per server):

| Server | CPU | RAM | HDD | Component Bus | Cards | EEPROM |
|---|---|---|---|---|---|---|
| Tier 1 | 1x Tier 2 | 2x Tier 2 | 2x Tier 2 | 1x Tier 2 | 2x Tier 2 | 1 |
| Tier 2 | 1x Tier 3 | 3x Tier 3 | 3x Tier 3 | 2x Tier 3 | 2x Tier 2 + 1x Tier 3 | 1 |
| Tier 3 | 1x Tier 3 | 4x Tier 3 | 4x Tier 3 | 3x Tier 3 | 2x Tier 2 + 2x Tier 3 | 1 |

- A CPU alone provides 8/12/16 component slots (Tier 1/2/3); a component bus
  adds 8/12/16 more. A Tier 2 CPU is enough for a network card and the rack
  floppy, so a component bus is optional for a basic node.
- RAM comes in half tiers (1, 1.5, 2, 2.5, 3, 3.5). The driver reports
  `item tier / 2`, so a 3.5 module counts as tier 3 and fits a Tier 3 server;
  the six sizes are 192, 256, 384, 512, 768, and 1024 KB.
- Component buses raise the component limit but are **not** `RackBusConnectable`:
  they do not join the rack bus and do not expose a server's HDDs to the master.
  Only the network card's connections cross the bus.
- A floppy holds 512 KB in Supersymmetry, enough for the TerraCorp runtime. The
  pack allows 8192-byte network packets; the rack's built-in switch is tier 1.
  When relay mode is enabled, the switch relays one packet per five ticks with a
  queue of 20; same-bus packets do not cross the switch.

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
- OpenComputers documents screen resolution and color depth, but no fixed
  screen refresh rate in Hz. The screen retains its text buffer until changed;
  visible updates are subject to the Minecraft client's render rate and GPU
  operation budget. TerraCorp requests a 1/30-second idle signal wait to target
  30 loop iterations per second; this is not a guarantee of 30 visible frames,
  and input signals can wake the loop sooner. The 10 Hz figure in the
  distributed design is only a proposed network traffic cap.
