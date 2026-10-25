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

The desktop is drawn under the windows. It contains a responsive icon grid and a
one-row taskbar; windows open above the icons.

- Each app declares an `icon` code (`SYS`, `FIL`, `TRM`, `SET`, `NTS`, `INF`)
  and a short label. Icons are single-click targets and are also reachable with
  the keyboard.
- At 60 columns and wider the grid uses two columns on the left, so a window can
  open beside the icons. Narrower screens use three columns and centered
  windows.
- Tile height shrinks from three rows to two or one when the screen is too
  short for the full grid.
- The taskbar lists open windows as chips. Clicking a chip focuses its window;
  clicking the focused chip minimizes it. The focused window is highlighted.
- With no focused window, arrows move the icon selection, Home/End jump to the
  ends, and Enter opens the selected app. F1-F6 always open an app by order.
- The empty-desktop hint is drawn only when no window is open and the grid
  leaves room for it.

## Windows and events

The UI keeps a z-ordered window list, focus, drag state, and the icon selection.

| Event | Handling |
|---|---|
| `touch` | Desktop icon, taskbar chip, window controls/title bar, or focused app |
| `drag` / `drop` | Move window or forward to app |
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
label. `icon` is a short code centered in the icon tile (three characters in the
built-in apps); `order` sets both the F1-F10 shortcut and the grid position.

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
