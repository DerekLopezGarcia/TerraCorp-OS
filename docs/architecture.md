# Architecture

## Boot sequence

```text
OpenComputers BIOS or optional EEPROM manager
  -> boot-volume /init.lua
  -> /boot/kernel.lua
  -> mount the boot filesystem as the VFS
  -> load core modules from /lib/tc
  -> read /etc/terracorp.cfg and draw the splash
  -> create the desktop and load /apps modules
  -> process computer.pullSignal events
```

The boot volume contains the contents of `src/`: `init.lua` at its root and the
kernel under `/boot`. Standard BIOS boot does not require the custom EEPROM
manager.

## Layers

| Layer | Runtime path | Responsibility |
|---|---|---|
| Entry point | `/init.lua` | Find the boot volume, load the kernel, bind the GPU |
| Kernel | `/boot/kernel.lua` | VFS, module loader, services, event loop |
| Core | `/lib/tc/` | Version, utilities, text, logging, configuration, theme, graphics, UI, updater |
| Apps | `/apps/*.lua` | App-specific UI and behavior |

TerraCorp does not use OpenOS `require`, `event`, `fs`, or `shell`. The kernel
loads modules with `load(source, "=/path", "t", env)` into a sandbox containing
standard Lua libraries, `component`, `computer`, and the kernel's own `require`.

## Virtual filesystem

The VFS wraps the boot-volume `filesystem` component and normalizes failures:

```text
vfs.read(path) -> string | nil, reason
vfs.write(path, data) / vfs.append(path, data)
vfs.exists(path) / vfs.isDirectory(path) / vfs.size(path) -> bytes
vfs.list(path) -> sorted list | nil, reason
vfs.ensureDir(path) / vfs.remove(path) / vfs.rename(from, to)
vfs.space() -> used, total in KB (component values are bytes)
```

Component calls are protected where a disconnected disk could otherwise crash
the OS. OpenComputers `filesystem.list` returns a table; the VFS also accepts an
iterator for compatibility.

## Preferences

`/etc/terracorp.cfg` stores a serialized Lua table loaded in an empty
environment. The updater never writes this file, so settings and the desktop
layout survive updates. `iconLayout` holds comma-separated `id@slot` pairs and
preserves empty cells; `iconOrder` keeps the compact app order so older releases
can still read the layout. `""` in either key means the built-in `order`
sequence. On boot the UI keeps every ID that still maps to an installed app,
drops unknown IDs, honors saved slots that fit the screen, and places newly
installed or out-of-range apps in the first free cell.

`iconLayout` and `iconOrder` are migrated in place. The 0.2.x app `about` is now
`update`, so the UI maps `about` to `update` when loading either key. An existing
desktop therefore keeps Update in its old slot without rewriting the user's file
until the next drag saves the layout.

## Framebuffer and rendering

`gfx` keeps flat character/foreground/background arrays plus the last-rendered
state. `flush()` compares rows, groups adjacent dirty cells with matching
colors, and sends each run with one `gpu.set` call. Rejected GPU writes remain
dirty and are retried.

The palette is initialized for T3 screens. GPU colors are sent as palette
indices with the explicit palette flag. A resolution/GPU change recreates the
framebuffer and forces a complete redraw.

Apps draw only through `ctx.view`, a clipped subview whose coordinates are local
to the app window.

## Desktop shell

The desktop is drawn under the windows. It contains a responsive full-screen icon
grid and a one-row taskbar; windows are drawn over the grid.

- Every app declares a 3-cell `icon` code (`SYS`, `FIL`, `TRM`, `SET`, `NTS`,
  `UPD`) and a 9x5 `iconArt` pictogram. The desktop tile is 9 cells wide and 5
  rows tall, with the `short` label on the row below. `npm run check` rejects an
  app without a registered ID, a 3-cell code, a label, or five 9-cell art rows,
  so an app cannot ship without a visible desktop icon.
- The grid covers every column that fits the screen width and every row that
  fits above the taskbar. All cells are drop slots, including empty ones. Tiles
  use no vertical gap so two rows fit on a 50x16 Tier 1 screen.
- Pictograms are ASCII/CP437 box-drawing art: System is a computer monitor,
  Terminal a command window, Settings a gear, Notes a dog-eared page, Files a
  folder, and Update a down arrow above a disk.
- Positions come from `iconLayout` (`id@slot`) in `/etc/terracorp.cfg`.
  Dropping on an empty cell moves the icon there; dropping on an occupied cell
  swaps the two icons. Dropping saves the layout. If the saved layout is empty,
  incomplete, or still uses the older compact `iconOrder`, the UI starts from
  the apps' `order` values and appends missing apps in the first free cells.
- A dragged icon is rendered as a floating tile above the windows and eases
  toward the pointer on the 30 Hz frame loop, matching window dragging. Empty
  grid cells show a dim guide and the target cell gets an accent outline while
  the icon is in motion.
- An app may set `iconStyle = "accent"` to draw its tile with the accent
  background (System uses this). The art is drawn in the inverse color, so the
  tile is highlighted without an inset box.
- Tile height shrinks from five rows to two or one when the screen cannot fit
  even one full row. On a reduced tile the app's 3-cell `icon` code is drawn
  instead of the 9x5 art so nothing is clipped; the label stays on the row below.
- An open window is indicated by the accent-colored icon label; the tile itself
  does not change.
- Windows open below the lowest occupied icon row when at least the minimum
  window height remains; otherwise they open centered. This keeps the first row
  visible on an uncluttered desktop without blocking icons that were moved lower.
- The taskbar lists open windows as chips. Clicking a chip focuses its window;
  clicking the focused chip minimizes it. The focused window is highlighted.
- With no focused window, arrows move the icon selection, Home/End jump to the
  first/last occupied cell, and Enter opens the selected app. F1-F6 always open
  an app by `order`, independent of the grid arrangement.
- The empty-desktop hint is drawn only when no window is open and the grid
  leaves room for it.

## Windows and events

The UI keeps a z-ordered window list, focus, drag state, and the icon selection.

| Event | Handling |
|---|---|
| `touch` | Desktop icon, taskbar chip, window controls/title bar, or focused app. An icon press is remembered until `drop`. |
| `drag` / `drop` | Move a window, drag the pressed icon across the full-screen grid, or forward to an app. A drop without movement opens the pressed icon; a drop that moves or swaps icons saves the layout. |
| `scroll` | Forward to app under pointer |
| `key_down` | Global Esc/F1-F6; arrows/Home/End/Enter when no window is focused; otherwise the focused app |
| `screen_resized` | Rebind GPU and resize UI |
| `interrupted` | Ignored so Ctrl+Alt+C does not terminate the OS |

OpenComputers supplies keyboard characters as numeric Unicode code points; the
UI converts them to UTF-8 strings before forwarding them to apps. App callbacks
run inside `pcall`; failures are logged and shown without terminating the
desktop.

## App contract

```lua
local app = {
  id = "example",
  title = "Example",
  short = "Example",
  icon = "EXA",
  iconArt = {
    "         ",
    "         ",
    "         ",
    "         ",
    "         ",
  },
  iconStyle = nil, -- "accent" opts into the highlighted tile
  order = 6,
}

function app.create(ctx)
  return setmetatable({}, { __index = app })
end

function app:draw(ctx)
  ctx.view:clear(" ", ctx.colors.text, ctx.colors.deep)
  ctx.view:put(1, 1, "Hello from " .. ctx.kernel.hostname,
    ctx.colors.accent, ctx.colors.deep)
end

function app:handle(ctx, name, a, b, c)
  return false
end

function app:tick(ctx)
  return false
end

-- Focus left the window (another app opened or it was minimized).
function app:blur(ctx)
end

function app:close(ctx)
end

return app
```

The context includes `ui`, `kernel`, `theme`, `colors`, `glyphs`, `log`,
`config`, `version`, `util`, `text`, `win`, geometry, and `view`. Do not cache
`ctx.view` between calls. Register an app ID in `APP_IDS` in the kernel.

`title` is the window title and taskbar label. `short` is the desktop icon
label. `iconArt` is the 9x5 desktop pictogram: five strings of exactly nine
display cells each, drawn inside the tile. `icon` is a three-cell code used only
when the tile must shrink below five rows; keep it as the compact fallback.
`order` sets the F1-F10 shortcut and the initial grid position. Saved
`iconLayout` positions override the initial grid position but never the
shortcut. `iconStyle = "accent"` draws the tile with the accent background.

## Power and known limits

`kernel:energyPercent()` returns 100 if the computer does not report energy.
`kernel:poweroff(reboot)` is the only code path allowed to call
`computer.shutdown`.

- One screen cell per Unicode code point; wide CJK characters and emoji are not
  supported.
- No modem-based distributed messaging yet.
- No accounts or session locking.
- Windows can be moved but not resized with the pointer.
- Terminal history and in-memory logs do not survive reboot; warnings/errors are
  persisted in `/var/log/tc.log`.
