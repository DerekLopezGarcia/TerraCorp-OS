# Architecture

## Boot sequence

```text
OpenComputers BIOS or optional EEPROM manager
  -> boot-volume /init.lua
  -> /boot/kernel.lua
  -> mount the boot filesystem as the VFS
  -> load core modules from /lib/tc
  -> read /etc/terracorp.cfg and draw the splash
  -> desktop role: create the desktop and load /apps modules
     node role: start the headless node loop instead
  -> process computer.pullSignal events
```

A rack server that carries no boot address starts from the provisioning floppy
instead. The stock BIOS runs `/init.lua` from the floppy, which loads
`/boot/netboot.lua`; that script installs the runtime from `/payload` onto the
first HDD, writes the node configuration, sets the HDD boot address, and
reboots. The installed node then follows the normal boot sequence in `node`
role. See [`cluster.md`](cluster.md).

The boot volume contains the contents of `src/`: `init.lua` at its root and the
kernel under `/boot`. Standard BIOS boot does not require the custom EEPROM
manager.

## Layers

| Layer | Runtime path | Responsibility |
|---|---|---|
| Entry point | `/init.lua` | Find the boot volume, load the kernel, bind the GPU |
| Kernel | `/boot/kernel.lua` | VFS, module loader, services, event loop |
| Core | `/lib/tc/` | Version, utilities, text, logging, configuration, theme, graphics, UI, updater, cluster |
| Apps | `/apps/*.lua` | App-specific UI and behavior, including the Nodes app |

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
until the next drag saves the layout. The node registry at `/var/nodes.tsv` is
user data like `/var/notes.txt`: the updater never replaces it.

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
  `UPD`, `NOD`, `VLT`, `GAI`, `LAB`) and a 9x5 `iconArt` pictogram. The desktop
  tile is 9 cells wide and 5 rows tall, with the `short` label on the row below.
  `npm run check` rejects an app without a registered ID, a 3-cell code, a
  label, or five 9-cell art rows, so an app cannot ship without a visible
  desktop icon.
- The grid covers every column that fits the screen width and every row that
  fits above the taskbar. All cells are drop slots, including empty ones. Tiles
  use no vertical gap so three rows fit on a 40x16 Tier 1 screen.
- Pictograms are ASCII/CP437 box-drawing art: System is a computer monitor,
  Terminal a command window, Settings a gear, Notes a dog-eared page, Files a
  folder, Update a down arrow above a disk, and Nodes a stacked rack.
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
- Tile height shrinks from five rows to three, two, or one when the screen
  cannot fit every app. The UI chooses the largest height that fits all ten
  apps, then draws the app's 3-cell `icon` code instead of the 9x5 art so nothing
  is clipped; the label stays on the row below.
- An open window is indicated by the accent-colored icon label; the tile itself
  does not change.
- Windows open below the lowest occupied icon row when at least the minimum
  window height remains; otherwise they open centered. This keeps the first row
  visible on an uncluttered desktop without blocking icons that were moved lower.
- The taskbar lists open windows as chips. Clicking a chip focuses its window;
  clicking the focused chip minimizes it. The focused window is highlighted.
- With no focused window, arrows move the icon selection, Home/End jump to the
  first/last occupied cell, and Enter opens the selected app. F1-F9 always open
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
| `key_down` | Global Esc/F1-F10; arrows/Home/End/Enter when no window is focused; otherwise the focused app |
| `key_up` | Forwarded to the focused app so it can drop a modifier it was tracking |
| `clipboard` | The Minecraft clipboard, forwarded to the focused app as `paste`; apps decide what to do with it |
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
`kernel.require(id)` returns the kernel's cached module instance, so an app can
load a core module (`tc.lab`) without reading it from the boot volume again.

`title` is the window title and taskbar label. `short` is the desktop icon
label. `iconArt` is the 9x5 desktop pictogram: five strings of exactly nine
display cells each, drawn inside the tile. `icon` is a three-cell code used only
when the tile must shrink below five rows; keep it as the compact fallback.
`order` sets the F1-F10 shortcut and the initial grid position. Saved
`iconLayout` positions override the initial grid position but never the
shortcut. `iconStyle = "accent"` draws the tile with the accent background.

## Lab and script execution

The Lab app (`/apps/lab.lua`) has three tabs. It edits `/var/lab/script.lua` and
runs it against the live OS. `tc.lab` compiles the buffer with
`load(source, "=/var/lab/script.lua",
"t", env)` in a fresh environment per run: the standard libraries, `print`
(captured), `kernel`, `vfs`, `component`, `computer`, `log`, `config`, `text`,
`util`, `theme`, `version`, `ui`, and `kernel.require`. It is a test tool, not a
sandbox boundary: a script can reach anything the desktop can.

Every run is appended to `/var/log/lab.log` (rotated at 64 KB, newest half
kept), with a `=== time · path · ok|error · ms` header, the captured lines, and
an `!` error line. The Output tab shows the same record, seeded from the log at
open. Ctrl+R runs, Ctrl+S saves, and Ctrl+L empties the log and the panes.
Files previews the log like any other text file.

### The interpreter

The Lua tab is a second consumer of the same environment builder, with the
opposite lifecycle: one environment stays alive for every line, so a name
assigned on one line is there on the next. That is the difference between a
scratchpad and a notebook, and the two do not mix — a script run stays fresh on
purpose, or a script could start working because of state left by an earlier
session.

- Enter evaluates. A line that leaves a block open (`for`, `if`, `function`)
  switches the prompt to `... ` and keeps accumulating until the block closes.
- Like the OpenOS interpreter, a line is tried as `return <line>` first and as a
  statement second, so `component.list()` prints its table while `a = 1` still
  assigns. `=expr` skips the statement fallback and is the explicit form; the
  two disagree only for a line that is both a valid statement and a valid
  expression, such as a bare call.
- Results are shown with strings quoted and tables keyed by sorted key, elided
  at depth two and ten entries, so one result stays inside the transcript
  budget. A top-level table puts one entry per line. Numbers, booleans and nil
  print as themselves.
- The transcript and the output pane wrap long lines at the pane width instead
  of clipping them, so a component listing or a long string is readable in
  full. The input cell still clips horizontally to keep the caret visible.
- Arrow up and down walk the submitted lines. `Reset` drops every name in the
  active session.
- Sessions are named environments: `:new work` starts one, `:use main` switches
  back, `:list` names them with the active one marked `*`, `:drop` forgets one
  (the last cannot go), `:reset` and `:clear` act on the current session, and
  `:help` lists them. Each session keeps its own names, history and transcript.
- State is memory, not a file: Lua state is closures, coroutines and userdata,
  so it cannot be written to disk and reloaded, and nothing is replayed on
  boot. What survives is the log, which names the session in every header
  (`repl@work`); a session's environment lives until `:reset` or the reboot.
- The registry hangs off the `tc.lab` module, which the kernel caches, so
  closing the window keeps every session. `Ctrl+L` empties all transcripts
  without touching an environment.
- Every submission is appended to the same log with a `=== time · repl@name ·
  ok|error · ms` header, the submitted lines with a `>` prefix, and the
  captured output.
- A cell can hold several lines: `Shift+Enter` (or `Ctrl+Enter`) splits the line
  at the caret and keeps the indentation, and plain `Enter` runs the whole cell
  as one chunk.
- The Lab's `component` is the base API plus OpenOS's `component.gpu` sugar: a
  real method always wins, anything else is resolved as a component kind to the
  primary proxy and cached until the next run. `component.primary(kind)` is the
  explicit form and `component.refresh()` drops that cache.

### Clipboard

`clipboard(keyboard, value, player)` is queued by OpenComputers when the player
presses Insert or the middle mouse button (see `docs/opencomputers.md`). The
desktop forwards it to the focused app as `paste`:

- The Lab inserts it at the caret, keeping the line breaks: it is how a script
  gets into the game without typing it. The Terminal flattens newlines into
  spaces so a pasted command can be read back before Enter.
- The other direction only exists inside the OS. `Shift+arrows` walk a selection
  over the Lab pane text, `Ctrl+C` copies it to a clipboard held on `tc.lab`,
  and `Ctrl+V` pastes that into the input. OpenComputers never reads text back
  from a computer, so there is no way to put something on the Minecraft
  clipboard; getting text out of the game needs a transport, not a key.
- `Ctrl` and `Shift` arrive as their own key events and are held until `key_up`
  is routed back to the app; the mod does not resend them for every key. A held
  `Shift` therefore extends a selection across several arrows and opens several
  `Shift+Enter` lines. Typing a printable key clears a Ctrl that never reported
  its release; `blur` clears both.

The Terminal command `lua` opens that tab; `lua <file>` runs a script by path
without opening the app. Bare `lua` used to run `/var/lab/script.lua`, which is
now the editor's buffer only.

Scripts and interpreted lines run on the desktop event loop. There is no
preemption and no instruction budget, so a runaway loop blocks the node until it
reboots; keep test code bounded.

## Cluster

The kernel reads `role` from `/etc/terracorp.cfg`. `desktop` starts the UI and
`cluster` service; `node` skips GPU setup and starts the headless runtime.

The cluster is the in-game half of a two-layer plant: the nodes read components
and hold gates; a **plant service** outside the game owns the recipe book, the
planner, the history and the panel ([`plant-service.md`](plant-service.md)). The
only bridge between them is the external link (`docs/external-link.md`), one
polling computer at a time.

| Module | Responsibility |
|---|---|
| `tc.net` | `TC1` text framing, validation, percent escaping, modem transport |
| `tc.registry` | `/var/nodes.tsv` load/save, merging, state and role updates |
| `tc.provision` | Floppy safety/capacity checks, payload copy, install guard, config serialization |
| `tc.cluster` | Master modem, installer window, HELLO/ASSIGN, ACK/STATUS/PONG, offline tracking |
| `tc.node` | Node boot loop, identity adoption, STATUS and PING/PONG, runtime ASSIGN |
| `boot.netboot` | Floppy installer: HELLO/ASSIGN, first-HDD copy, boot-address write, ACK, reboot |

The kernel forwards `modem_message` signals to the cluster before the desktop
sees them. A node never requires a GPU, but if a screen is present it may show a
small status page. The installer window is gated by both a token and a
ten-minute expiry on the master, so a stale floppy cannot overwrite a node that
already has a valid install. The floppy also writes `/var/install-incomplete`
before copying and removes it only after a complete install; a retry may
overwrite an incomplete target, but never a finished one.

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
