-- Desktop: top bar, desktop icons, taskbar, windows, and app event dispatch.
--
-- App contract (see docs/architecture.md):
--   module = { id, title, short, icon, order, create(ctx) -> instance }
--   instance = { draw(ctx), handle(ctx, name, ...), blur(ctx), close(ctx) }
-- `ctx.view` is a clipped gfx subview with local coordinates 1..w / 1..h.

local text = require("tc.text")
local util = require("tc.util")
local keys = require("tc.keys")

local ui = {}
ui.__index = ui

local TOP_HEIGHT = 2
local TASKBAR_HEIGHT = 1
local MIN_WIDTH = 34
local MIN_HEIGHT = 10

-- Desktop icon grid. Every app draws a 9x5 pictogram (`iconArt`) inside its
-- tile, with the label on the row below. The grid covers the whole desktop:
-- every column and row that fits is a drop slot, even when empty. Rows use no
-- vertical gap so two rows still fit on a 50x16 Tier 1 screen.
local ICON_TILE_WIDTH = 9
local ICON_TILE_HEIGHT = 5
local ICON_CELL_WIDTH = 9
local ICON_GAP_X = 2
local ICON_GAP_Y = 0

-- Saved layouts from 0.2.x used "about"; the app is now "update".
local APP_ALIASES = { about = "update" }

local function resolveAppId(id)
  return APP_ALIASES[id] or id
end

function ui.new(env)
  local self = setmetatable({}, ui)

  self.kernel = env.kernel
  self.gfx = env.gfx
  self.theme = env.theme
  self.log = env.log
  self.config = env.config
  self.version = env.version
  self.util = env.util

  self.glyphs = env.theme.glyphs
  self.colors = env.theme.colors

  self.apps = {}
  self.order = {}
  for _, module in ipairs(env.apps) do
    self.apps[module.id] = module
    self.order[#self.order + 1] = module
  end
  table.sort(self.order, function(a, b)
    return (a.order or 99) < (b.order or 99)
  end)
  self.layout = {}
  self.iconPlacements = self:loadIconPlacements()

  self.windows = {}
  self.focus = nil
  self.z = 0
  self.dragging = nil
  self.dragTestArmed = false
  self.dragTest = nil
  self.notice = nil
  self.dirty = true
  self.iconIndex = 1
  self.iconCols = 1
  self.iconTileHeight = ICON_TILE_HEIGHT
  self.iconPress = nil
  self.iconDrag = nil

  self:resize()
  return self
end

function ui:resize()
  self.w = self.gfx.w
  self.h = self.gfx.h
  self.taskbarTop = self.h - TASKBAR_HEIGHT + 1
  self.desktopTop = TOP_HEIGHT + 1
  self.desktopBottom = self.taskbarTop - 1

  self.iconPress = nil
  self.iconDrag = nil
  self.iconCols = self:iconColumns()

  local tileHeight = ICON_TILE_HEIGHT
  if self:iconRowsFor(tileHeight) < 1 then
    tileHeight = 2
    if self:iconRowsFor(tileHeight) < 1 then
      tileHeight = 1
    end
  end
  self.iconTileHeight = tileHeight
  self.iconRows = math.max(1, self:iconRowsFor(tileHeight))
  self.iconSlotCount = self.iconCols * self.iconRows
  self:buildIconLayout()
  self.iconIndex = util.clamp(self.iconIndex or 1, 1, math.max(1, self.iconSlotCount))

  for _, win in ipairs(self.windows) do
    self:clampWindow(win)
  end

  self.dirty = true
end

function ui:iconColumns()
  local fit = math.floor((self.w - 3 + ICON_GAP_X) / (ICON_CELL_WIDTH + ICON_GAP_X))
  return math.max(1, fit)
end

-- Number of icon rows the desktop can show at the given tile height. Each cell
-- is the tile plus its label row; ICON_GAP_Y separates consecutive rows.
function ui:iconRowsFor(tileHeight)
  local top = self.desktopTop + 1
  local available = self.desktopBottom - top + 1
  local pitch = tileHeight + 1 + ICON_GAP_Y
  return math.floor((available - (tileHeight + 1)) / pitch) + 1
end

-- Saved layouts store positions as `id@slot` so empty cells survive a restart.
-- The older compact `iconOrder` preference is still accepted and migrated.
function ui:loadIconPlacements()
  local placements, seen = {}, {}
  local saved = self.config.get("iconLayout")
  if type(saved) == "string" and saved ~= "" then
    for entry in saved:gmatch("[^,%s]+") do
      local id, slot = entry:match("^(.+)@(%d+)$")
      id = id and resolveAppId(id)
      if id and self.apps[id] and not seen[id] then
        seen[id] = true
        placements[#placements + 1] = { id = id, slot = tonumber(slot) }
      end
    end
  end

  if #placements == 0 then
    local legacy = self.config.get("iconOrder")
    if type(legacy) == "string" then
      for id in legacy:gmatch("[^,%s]+") do
        id = resolveAppId(id)
        if self.apps[id] and not seen[id] then
          seen[id] = true
          placements[#placements + 1] = { id = id }
        end
      end
    end
  end

  -- Keep new apps reachable even when an older layout was saved.
  for _, module in ipairs(self.order) do
    if not seen[module.id] then
      seen[module.id] = true
      placements[#placements + 1] = { id = module.id }
    end
  end
  return placements
end

-- Remember the current positions before a screen resize rebuilds the grid.
function ui:captureIconPlacements()
  local placements = {}
  for index = 1, #self.layout do
    local id = self.layout[index]
    if id then
      placements[#placements + 1] = { id = id, slot = index }
    end
  end
  if #placements > 0 then
    self.iconPlacements = placements
  end
end

-- Build a dense slot array: false marks an empty desktop cell. Slots that no
-- longer fit after a resize are moved to the first free cell instead of being
-- dropped.
function ui:buildIconLayout()
  self:captureIconPlacements()

  local capacity = math.max(1, self.iconSlotCount or 1)
  local layout = {}
  for index = 1, capacity do
    layout[index] = false
  end

  local seen = {}
  for _, placement in ipairs(self.iconPlacements or {}) do
    local slot = placement.slot
    if slot and slot >= 1 and slot <= capacity
      and not layout[slot] and not seen[placement.id] then
      layout[slot] = placement.id
      seen[placement.id] = true
    end
  end

  local function placeMissing(id)
    for index = 1, capacity do
      if not layout[index] then
        layout[index] = id
        seen[id] = true
        return true
      end
    end
    return false
  end

  for _, placement in ipairs(self.iconPlacements or {}) do
    if not seen[placement.id] then
      placeMissing(placement.id)
    end
  end
  for _, module in ipairs(self.order) do
    if not seen[module.id] then
      placeMissing(module.id)
    end
  end

  self.layout = layout
end

function ui:saveIconLayout()
  local order, slots = {}, {}
  for index = 1, #self.layout do
    local id = self.layout[index]
    if id then
      order[#order + 1] = id
      slots[#slots + 1] = id .. "@" .. tostring(index)
    end
  end

  -- `iconOrder` keeps the compact ordering readable by older releases.
  if not self.config.set("iconOrder", table.concat(order, ","))
    or not self.config.set("iconLayout", table.concat(slots, ",")) then
    self:notify("warn", "Could not store the desktop layout.")
    return false
  end
  local ok, reason = self.kernel:saveConfig()
  if not ok then
    self:notify("warn", "Could not save the desktop layout: " .. tostring(reason))
    return false
  end
  self.iconPlacements = nil
  self:captureIconPlacements()
  self:notify("info", "Desktop layout saved.")
  return true
end

function ui:iconGridWidth()
  return self.iconCols * (ICON_CELL_WIDTH + ICON_GAP_X) - ICON_GAP_X
end

function ui:iconRect(index)
  local column = (index - 1) % self.iconCols
  local row = math.floor((index - 1) / self.iconCols)
  local x = 2 + column * (ICON_CELL_WIDTH + ICON_GAP_X)
  local y = self.desktopTop + 1 + row * (self.iconTileHeight + 1 + ICON_GAP_Y)
  return x, y
end

function ui:iconAt(x, y)
  for index = 1, #self.layout do
    if self.layout[index] then
      local ix, iy = self:iconRect(index)
      if x >= ix and x < ix + ICON_CELL_WIDTH
        and y >= iy and y < iy + self.iconTileHeight + 1 then
        return index
      end
    end
  end
  return nil
end

-- Map a pointer position anywhere in the desktop to a grid slot. This lets
-- icons be dragged into any cell on the screen, including empty ones.
function ui:iconIndexAt(x, y)
  local column = math.floor((x - 2) / (ICON_CELL_WIDTH + ICON_GAP_X)) + 1
  column = util.clamp(column, 1, self.iconCols)
  local row = math.floor((y - (self.desktopTop + 1)) / (self.iconTileHeight + 1 + ICON_GAP_Y))
  row = util.clamp(row, 0, math.max(0, self.iconRows - 1))
  return util.clamp(row * self.iconCols + column, 1, self.iconSlotCount)
end

-- Bottom row actually used by an icon. Windows open below this row so the
-- first row of the full-screen grid stays visible while the desktop is empty.
function ui:iconGridBottom()
  local rows = 1
  for index = 1, #self.layout do
    if self.layout[index] then
      rows = math.max(rows, math.floor((index - 1) / self.iconCols) + 1)
    end
  end
  local lastY = self.desktopTop + 1 + (rows - 1) * (self.iconTileHeight + 1 + ICON_GAP_Y)
  return lastY + self.iconTileHeight
end

function ui:moveIcon(delta)
  local nextIndex = self.iconIndex + delta
  while nextIndex >= 1 and nextIndex <= self.iconSlotCount do
    if self.layout[nextIndex] then
      self.iconIndex = nextIndex
      self.dirty = true
      return true
    end
    nextIndex = nextIndex + delta
  end
  return false
end

-- Positional move used by drop: an empty target simply receives the icon, an
-- occupied target swaps places with it, matching desktop icon behavior.
function ui:moveIconTo(target, fromIndex)
  fromIndex = util.clamp(fromIndex or self.iconIndex, 1, self.iconSlotCount)
  target = util.clamp(target, 1, self.iconSlotCount)
  local moving = self.layout[fromIndex]
  if not moving then
    return false
  end
  if target == fromIndex then
    self.iconIndex = fromIndex
    return false
  end

  self.layout[target], self.layout[fromIndex] = moving, self.layout[target] or false
  self.iconIndex = target
  self.dirty = true
  return true
end

function ui:clampWindow(win)
  win.w = util.clamp(win.w, math.min(MIN_WIDTH, self.w - 2), self.w)
  win.h = util.clamp(win.h, math.min(MIN_HEIGHT, self.h - 2), self.h)
  win.x = util.clamp(win.x, 1, math.max(1, self.w - win.w + 1))
  win.y = util.clamp(win.y, 1, math.max(1, self.h - win.h + 1))
end

function ui:notify(level, message)
  self.notice = {
    level = level,
    message = tostring(message),
    expires = self.kernel.uptime() + 6,
  }
  self.dirty = true
end

function ui:markDirty()
  self.dirty = true
end

function ui:armDragTest()
  self.dragTestArmed = true
  self.dragTest = nil
  self:notify("info", "Drag test armed: drag a title bar for 5-10 seconds, then release.")
end

function ui:advanceDrag(now)
  local drag = self.dragging
  if not drag or not drag.transitionDuration or drag.transitionDuration <= 0 then
    return false
  end

  local progress = util.clamp((now - drag.transitionStart) / drag.transitionDuration, 0, 1)
  local win = drag.win
  local x = math.floor(drag.fromX + (drag.targetX - drag.fromX) * progress + 0.5)
  local y = math.floor(drag.fromY + (drag.targetY - drag.fromY) * progress + 0.5)
  if win.x ~= x or win.y ~= y then
    win.x = x
    win.y = y
    if self.dragTest then
      self.dragTest.interpolatedFrames = self.dragTest.interpolatedFrames + 1
    end
    self.dirty = true
  end

  if progress >= 1 then
    drag.transitionDuration = 0
  end
  return true
end

-- Ease the floating icon toward the pointer the same way window dragging eases
-- toward its target. Coordinates stay fractional until drawing so movement is
-- smooth even when drag signals arrive less often than frames.
function ui:advanceIconDrag(now)
  local drag = self.iconDrag
  if not drag or not drag.transitionDuration or drag.transitionDuration <= 0 then
    return false
  end

  local progress = util.clamp((now - drag.transitionStart) / drag.transitionDuration, 0, 1)
  local x = drag.fromX + (drag.targetX - drag.fromX) * progress
  local y = drag.fromY + (drag.targetY - drag.fromY) * progress
  if drag.x ~= x or drag.y ~= y then
    drag.x = x
    drag.y = y
    self.dirty = true
  end

  if progress >= 1 then
    drag.transitionDuration = 0
  end
  return true
end

function ui:findWindow(id)
  for _, win in ipairs(self.windows) do
    if win.id == id then
      return win
    end
  end
  return nil
end

function ui:focusNextWindow()
  local best = nil
  for _, win in ipairs(self.windows) do
    if not win.minimized and (not best or win.z > best.z) then
      best = win
    end
  end
  self:setFocus(best)
end

function ui:blur(win)
  if win and win.instance and win.instance.blur then
    local ok, reason = pcall(win.instance.blur, win.instance, self:context(win))
    if not ok then
      self.log.warn("App blur failed in " .. tostring(win.id) .. ": " .. tostring(reason))
    end
  end
end

function ui:setFocus(win)
  if self.focus and self.focus ~= win then
    self:blur(self.focus)
  end
  if win and win.minimized then
    win.minimized = false
  end
  self.focus = win
  if win then
    self.z = self.z + 1
    win.z = self.z
  end
  self.dirty = true
end

function ui:defaultGeometry()
  local usable = self.desktopBottom - self.desktopTop + 1
  local minWidth = math.min(MIN_WIDTH, self.w - 2)
  local width = math.min(self.w - 4, math.max(minWidth, math.floor(self.w * 0.74)))
  local offset = (#self.windows % 5) * 2
  local x = util.clamp(
    math.floor((self.w - width) / 2) + offset,
    1,
    math.max(1, self.w - width + 1)
  )

  local height = math.min(usable - 1, math.max(MIN_HEIGHT, math.floor(usable * 0.84)))
  local y = self.desktopTop + math.max(0, math.floor((usable - height) / 2))

  -- The icon grid spans the screen. Keep the first row visible by opening the
  -- window below it when the remaining height is still usable.
  local below = self:iconGridBottom() + 1
  local maxBelow = self.desktopBottom - below + 1
  if maxBelow >= MIN_HEIGHT then
    y = below
    height = math.min(height, maxBelow)
  end

  y = util.clamp(y, 1, math.max(1, self.h - height + 1))
  return x, y, width, height
end

function ui:open(id)
  local existing = self:findWindow(id)
  if existing then
    existing.minimized = false
    self:setFocus(existing)
    return existing
  end

  for index, layoutId in ipairs(self.layout) do
    if layoutId == id then
      self.iconIndex = index
      break
    end
  end

  local module = self.apps[id]
  if not module then
    self:notify("warn", "Unknown application: " .. tostring(id))
    return nil
  end

  local x, y, width, height = self:defaultGeometry()
  local win = {
    id = id,
    app = module,
    title = module.title or id,
    x = x,
    y = y,
    w = width,
    h = height,
    z = 0,
    minimized = false,
  }

  self.windows[#self.windows + 1] = win
  self:setFocus(win)

  local ctx = self:context(win)
  local ok, instance = pcall(module.create, ctx)
  if not ok then
    self.log.error("Could not open " .. id .. ": " .. tostring(instance))
    self.windows[#self.windows] = nil
    self:notify("error", "Failed to open " .. win.title)
    self:focusNextWindow()
    return nil
  end

  win.instance = instance
  self.log.info("App opened: " .. id)
  self.dirty = true
  return win
end

function ui:close(win)
  if not win then
    return
  end

  if win.instance and win.instance.close then
    pcall(win.instance.close, win.instance, self:context(win))
  end

  for index = #self.windows, 1, -1 do
    if self.windows[index] == win then
      table.remove(self.windows, index)
    end
  end

  if self.focus == win then
    self.focus = nil
    self:focusNextWindow()
  end

  self.log.info("App closed: " .. tostring(win.id))
  self.dirty = true
end

function ui:minimize(win)
  if not win then
    return
  end
  self:blur(win)
  win.minimized = true
  if self.focus == win then
    self.focus = nil
    self:focusNextWindow()
  end
  self.dirty = true
end

function ui:context(win)
  local contentX = win.x + 1
  local contentY = win.y + 2
  local contentW = math.max(1, win.w - 2)
  local contentH = math.max(1, win.h - 3)

  return {
    ui = self,
    kernel = self.kernel,
    theme = self.theme,
    colors = self.colors,
    glyphs = self.glyphs,
    log = self.log,
    config = self.config,
    version = self.version,
    util = self.util,
    text = text,
    win = win,
    x = contentX,
    y = contentY,
    w = contentW,
    h = contentH,
    view = self.gfx:view(contentX, contentY, contentW, contentH),
  }
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

function ui:drawTopbar()
  local c = self.colors
  local g = self.glyphs

  self.gfx:fill(1, 1, self.w, 1, " ", c.onAccent, c.accent)
  self.gfx:put(2, 1, "TERRACORP", c.onAccent, c.accent)
  self.gfx:put(11, 1, " · " .. self.version.product, c.onAccent, c.accent)

  local clock = util.formatClock(self.config.get("clock24"))
  self.gfx:put(self.w - text.width(clock) - 1, 1, clock, c.onAccent, c.accent)

  self.gfx:fill(1, 2, self.w, 1, " ", c.dim, c.panel)

  local hostname = self.config.get("hostname")
  if hostname == "" then
    hostname = self.kernel.hostname or "TC-NODE"
  end

  local left = hostname .. "  " .. g.bullet .. "  v" .. self.version.version
  self.gfx:put(2, 2, text.truncate(left, self.w - 30), c.text, c.panel)

  local energy = self.kernel:energyPercent()
  local status = string.format("POWER %3d%%", math.floor(energy))
  local statusColor = c.text
  if energy < 15 then
    statusColor = c.danger
  elseif energy < 40 then
    statusColor = c.warn
  end

  self.gfx:put(self.w - text.width(status) - 1, 2, status, statusColor, c.panel)
end

function ui:drawIcon(module, x, y, selected, open)
  local c = self.colors
  local tileX = x + math.floor((ICON_CELL_WIDTH - ICON_TILE_WIDTH) / 2)
  local special = module.iconStyle == "accent"

  local tileBg, tileFg
  if selected then
    tileBg, tileFg = c.text, c.bg
  elseif special then
    tileBg, tileFg = c.accent, c.onAccent
  else
    tileBg, tileFg = c.panel, c.accent
  end

  self.gfx:fill(tileX, y, ICON_TILE_WIDTH, self.iconTileHeight, " ", tileFg, tileBg)

  -- Every app ships a 9x5 pictogram; `npm run check` enforces it. On a screen
  -- too short for a full tile, fall back to the 3-cell code so the icon stays
  -- readable instead of clipping the art.
  local art = module.iconArt
  if self.iconTileHeight == ICON_TILE_HEIGHT
    and type(art) == "table"
    and #art == ICON_TILE_HEIGHT then
    for row = 1, ICON_TILE_HEIGHT do
      local line = art[row]
      if type(line) == "string" then
        self.gfx:put(tileX, y + row - 1, line, tileFg, tileBg)
      end
    end
  else
    local code = module.icon or "APP"
    self.gfx:put(
      tileX + math.floor((ICON_TILE_WIDTH - text.width(code)) / 2),
      y + math.floor(self.iconTileHeight / 2),
      code,
      tileFg,
      tileBg
    )
  end

  local label = text.truncate(module.short or module.title or module.id, ICON_CELL_WIDTH)
  local labelFg = c.dim
  if selected then
    labelFg = c.text
  elseif open then
    labelFg = c.accent
  end
  self.gfx:put(
    x + math.floor((ICON_CELL_WIDTH - text.width(label)) / 2),
    y + self.iconTileHeight,
    label,
    labelFg,
    c.bg
  )
end

-- Outline the slot that will receive the dragged icon. Empty slots get an
-- accent outline; occupied slots keep their own background so the outline never
-- punches a hole through an icon.
function ui:drawIconTarget(index)
  if self.iconTileHeight < 3 or index < 1 or index > self.iconSlotCount then
    return
  end

  local x, y = self:iconRect(index)
  if y + self.iconTileHeight > self.desktopBottom then
    return
  end

  local c = self.colors
  local g = self.glyphs
  local id = self.layout[index]
  local module = id and self.apps[id] or nil
  local bg, fg = c.bg, c.accent
  if module and module.iconStyle == "accent" then
    bg, fg = c.accent, c.onAccent
  elseif module then
    bg = c.panel
  end

  local tileX = x + math.floor((ICON_CELL_WIDTH - ICON_TILE_WIDTH) / 2)
  local inner = ICON_TILE_WIDTH - 2
  self.gfx:put(tileX, y, g.tl .. string.rep(g.h, inner) .. g.tr, fg, bg)
  self.gfx:put(
    tileX,
    y + self.iconTileHeight - 1,
    g.bl .. string.rep(g.h, inner) .. g.br,
    fg,
    bg
  )
  for row = y + 1, y + self.iconTileHeight - 2 do
    self.gfx:put(tileX, row, g.v, fg, bg)
    self.gfx:put(tileX + ICON_TILE_WIDTH - 1, row, g.v, fg, bg)
  end
end

-- While dragging, mark the empty cells of the full-screen grid so the available
-- drop area is visible. Guides are drawn under windows and under the ghost.
function ui:drawIconGuides()
  if not self.iconDrag or self.iconTileHeight < 2 then
    return
  end

  local c = self.colors
  local mark = self.glyphs.dash
  local column = math.floor((ICON_CELL_WIDTH - 1) / 2)
  local row = math.floor(self.iconTileHeight / 2)
  for index = 1, self.iconSlotCount do
    if not self.layout[index] then
      local x, y = self:iconRect(index)
      if y + self.iconTileHeight <= self.desktopBottom then
        self.gfx:put(x + column, y + row, mark, c.line, c.bg)
      end
    end
  end
end

function ui:drawIcons()
  self:drawIconGuides()

  for index, id in ipairs(self.layout) do
    local module = self.apps[id]
    if module and not (self.iconDrag and self.iconDrag.index == index) then
      local x, y = self:iconRect(index)
      if y + self.iconTileHeight <= self.desktopBottom then
        local selected = (self.iconIndex == index and self.focus == nil)
        self:drawIcon(module, x, y, selected, self:findWindow(module.id) ~= nil)
      end
    end
  end

  if self.iconDrag and self.iconDrag.targetIndex then
    self:drawIconTarget(self.iconDrag.targetIndex)
  end
end

function ui:drawIconDrag()
  local drag = self.iconDrag
  if not drag then
    return
  end
  local module = self.apps[drag.id]
  if not module then
    return
  end

  local x = math.floor(drag.x + 0.5)
  local y = math.floor(drag.y + 0.5)
  self:drawIcon(module, x, y, false, self:findWindow(module.id) ~= nil)
end

function ui:drawTaskbar()
  local c = self.colors
  local g = self.glyphs
  local row = self.taskbarTop

  self.gfx:fill(1, row, self.w, 1, " ", c.dim, c.panel)

  local mark = g.mark .. " " .. tostring(#self.windows)
    .. ((#self.windows == 1) and " window" or " windows")
  self.gfx:put(2, row, mark, c.text, c.panel)
  local column = 2 + text.width(mark) + 2

  for _, win in ipairs(self.windows) do
    local label = " " .. text.truncate(win.title, 14) .. " "
    local width = text.width(label)
    if column + width > self.w then
      break
    end

    local fg, bg = c.dim, c.panel
    if self.focus == win then
      fg, bg = c.onAccent, c.accent
    elseif not win.minimized then
      fg, bg = c.text, c.deep
    end

    self.gfx:put(column, row, label, fg, bg)
    column = column + width + 1
  end

  local hint = "F1-F" .. tostring(math.min(#self.order, 10)) .. " or click an icon"
  local hintX = self.w - text.width(hint) - 1
  if hintX > column then
    self.gfx:put(hintX, row, hint, c.dim, c.panel)
  end
end

function ui:drawWindow(win)
  local c = self.colors
  local g = self.glyphs
  local focused = self.focus == win

  local barBg = focused and c.accent or c.panel
  local barFg = focused and c.onAccent or c.text

  self.gfx:box(win.x, win.y + 1, win.w, win.h - 1, {
    glyphs = g,
    fg = focused and c.accent or c.line,
    bg = c.deep,
  })

  self.gfx:fill(win.x, win.y, win.w, 1, " ", barFg, barBg)
  self.gfx:put(win.x + 1, win.y, text.truncate(win.title, win.w - 10), barFg, barBg)
  self.gfx:put(win.x + win.w - 6, win.y, "[-]", barFg, barBg)
  self.gfx:put(win.x + win.w - 3, win.y, "[x]", barFg, barBg)

  -- A failing app must not leave an empty frame or retry the same error every
  -- frame. Show the error and freeze the app after repeated failures.
  if win.broken then
    self.gfx:put(win.x + 2, win.y + 2, "App stopped after repeated errors.", c.danger, c.deep)
    self.gfx:put(win.x + 2, win.y + 3, tostring(win.broken):sub(1, win.w - 4), c.dim, c.deep)
    return
  end

  if win.instance and win.instance.draw then
    local ctx = self:context(win)
    local ok, reason = pcall(win.instance.draw, win.instance, ctx)
    if not ok then
      win.failures = (win.failures or 0) + 1
      self.log.error("draw " .. win.id .. " (" .. win.failures .. "): " .. tostring(reason))
      self.gfx:put(win.x + 2, win.y + 2, "Draw error: " .. tostring(reason), c.danger, c.deep)
      if win.failures >= 3 then
        win.broken = tostring(reason)
        self:notify("error", win.title .. " stopped after draw failures")
      end
    else
      win.failures = 0
    end
  end
end

function ui:drawNotice()
  if not self.notice then
    return
  end

  if self.kernel.uptime() > self.notice.expires then
    self.notice = nil
    return
  end

  local c = self.colors
  local label = " " .. text.truncate(self.notice.message, self.w - 8) .. " "
  local width = text.width(label)
  local x = self.w - width - 2
  local y = self.taskbarTop - 1
  local bg = c.danger
  if self.notice.level == "warn" then
    bg = c.warn
  elseif self.notice.level == "info" then
    bg = c.accent
  end
  self.gfx:put(x, y, label, c.onAccent, bg)
end

function ui:render(force)
  local now = self.kernel:uptime()
  self:advanceDrag(now)
  self:advanceIconDrag(now)
  if not force and not self.dirty then
    return 0
  end
  self.dirty = false

  -- Do not clear the entire framebuffer before drawing. If a section fails,
  -- retain the previous frame rather than leaving a black hole. The desktop
  -- background is drawn explicitly.
  local failures = {}

  local function section(name, fn)
    local ok, reason = pcall(fn)
    if not ok then
      failures[#failures + 1] = name .. ": " .. tostring(reason)
    end
  end

  section("desktop", function()
    self.gfx:fill(
      1,
      self.desktopTop,
      self.w,
      self.desktopBottom - self.desktopTop + 1,
      " ",
      self.colors.dim,
      self.colors.bg
    )
  end)

  section("icons", function()
    self:drawIcons()
  end)

  local ordered = {}
  for _, win in ipairs(self.windows) do
    ordered[#ordered + 1] = win
  end
  table.sort(ordered, function(a, b)
    return a.z < b.z
  end)

  for _, win in ipairs(ordered) do
    if not win.minimized then
      section("window " .. tostring(win.id), function()
        self:drawWindow(win)
      end)
    end
  end

  if #self.windows == 0 then
    section("empty desktop", function()
      self:drawEmptyState()
    end)
  end

  -- Draw the floating icon above windows so a drag remains visible anywhere on
  -- the desktop, just like a dragged window.
  section("icon drag", function()
    self:drawIconDrag()
  end)

  section("top bar", function()
    self:drawTopbar()
  end)
  section("taskbar", function()
    self:drawTaskbar()
  end)
  section("notice", function()
    self:drawNotice()
  end)

  if #failures > 0 then
    self.failures = failures
    self.log.error("render: " .. table.concat(failures, " | "))
    -- Draw a visible warning without depending on a successful full frame.
    pcall(function()
      local strip = " ERROR " .. table.concat(failures, " | ")
      self.gfx:fill(1, self.h, self.w, 1, " ", self.colors.onDanger, self.colors.danger)
      self.gfx:put(1, self.h, text.truncate(strip, self.w), self.colors.onDanger, self.colors.danger)
    end)
  else
    self.failures = nil
  end

  return self.gfx:flush()
end

function ui:drawEmptyState()
  local c = self.colors
  local hint = "Select an icon or press F1-F" .. tostring(math.min(#self.order, 10)) .. "."
  local y = self.desktopBottom - 1
  if y > self:iconGridBottom() then
    self.gfx:put(
      math.floor((self.w - text.width(hint)) / 2) + 1,
      y,
      hint,
      c.dim,
      c.bg
    )
  end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function ui:windowAt(x, y)
  local found = nil
  for _, win in ipairs(self.windows) do
    if not win.minimized
      and x >= win.x and x < win.x + win.w
      and y >= win.y and y < win.y + win.h then
      if not found or win.z > found.z then
        found = win
      end
    end
  end
  return found
end

function ui:forward(win, name, ...)
  if not win or not win.instance or not win.instance.handle then
    return false
  end

  local ctx = self:context(win)
  local ok, result = pcall(win.instance.handle, win.instance, ctx, name, ...)
  if not ok then
    self.log.error("Event " .. name .. " in " .. win.id .. ": " .. tostring(result))
    self:notify("error", win.title .. ": internal error")
    return false
  end

  if result then
    self.dirty = true
  end
  return result
end

function ui:onTouch(x, y, button)
  if y <= TOP_HEIGHT then
    self.iconPress = nil
    self.iconDrag = nil
    return
  end

  if y >= self.taskbarTop then
    self.iconPress = nil
    self.iconDrag = nil
    if y == self.taskbarTop then
      self:onTaskbarClick(x)
    end
    return
  end

  local win = self:windowAt(x, y)
  if not win then
    local icon = self:iconAt(x, y)
    if icon then
      -- Open on drop so the same gesture can also drag the icon. This matches
      -- OpenComputers, where every touch is followed by a drop.
      self.iconPress = { index = icon, x = x, y = y }
      self.iconDrag = nil
      self.iconIndex = icon
      self.dirty = true
    else
      self.iconPress = nil
      self.iconDrag = nil
      self:setFocus(nil)
    end
    return
  end

  self.iconPress = nil
  self.iconDrag = nil
  self:setFocus(win)

  if y == win.y then
    if x >= win.x + win.w - 3 then
      self:close(win)
      return
    end
    if x >= win.x + win.w - 6 and x < win.x + win.w - 3 then
      self:minimize(win)
      return
    end
    local now = self.kernel:uptime()
    self.dragging = {
      win = win,
      dx = x - win.x,
      dy = y - win.y,
      lastSignalAt = now,
      transitionDuration = 0,
    }
    if self.dragTestArmed then
      self.dragTestArmed = false
      self.dragTest = {
        count = 0,
        firstAt = nil,
        lastAt = nil,
        maxGap = 0,
        interpolatedFrames = 0,
      }
    end
    return
  end

  local localX = x - win.x
  local localY = y - win.y - 1
  self:forward(win, "touch", localX, localY, button)
end

function ui:onDrag(x, y, button)
  if self.dragging then
    local metrics = self.dragTest
    if metrics then
      local now = self.kernel:uptime()
      if metrics.lastAt then
        metrics.maxGap = math.max(metrics.maxGap, now - metrics.lastAt)
      else
        metrics.firstAt = now
      end
      metrics.lastAt = now
      metrics.count = metrics.count + 1
    end

    local win = self.dragging.win
    local drag = self.dragging
    local now = self.kernel:uptime()
    self:advanceDrag(now)

    drag.fromX = win.x
    drag.fromY = win.y
    drag.targetX = util.clamp(x - drag.dx, 1, self.w - win.w + 1)
    drag.targetY = util.clamp(y - drag.dy, 1, self.h - win.h + 1)
    drag.transitionStart = now
    drag.transitionDuration = util.clamp(now - drag.lastSignalAt, 1 / 30, 1 / 15)
    drag.lastSignalAt = now
    self.dirty = true
    return
  end

  if self.iconPress then
    local now = self.kernel:uptime()
    local drag = self.iconDrag
    if not drag then
      local startX, startY = self:iconRect(self.iconPress.index)
      drag = {
        id = self.layout[self.iconPress.index],
        index = self.iconPress.index,
        x = startX,
        y = startY,
        fromX = startX,
        fromY = startY,
        targetX = startX,
        targetY = startY,
        offsetX = self.iconPress.x - startX,
        offsetY = self.iconPress.y - startY,
        targetIndex = self.iconPress.index,
        moved = false,
        lastSignalAt = now,
        transitionStart = now,
        transitionDuration = 0,
      }
      self.iconDrag = drag
    end

    local maxX = math.max(2, self.w - ICON_CELL_WIDTH + 1)
    local maxY = math.max(self.desktopTop, self.desktopBottom - self.iconTileHeight)
    drag.fromX = drag.x
    drag.fromY = drag.y
    drag.targetX = util.clamp(x - drag.offsetX, 2, maxX)
    drag.targetY = util.clamp(y - drag.offsetY, self.desktopTop, maxY)
    drag.transitionStart = now
    drag.transitionDuration = util.clamp(now - drag.lastSignalAt, 1 / 30, 1 / 15)
    drag.lastSignalAt = now

    -- Any real movement turns the press into a drag. Returning to the original
    -- slot must not open the app when the button is released.
    if math.abs(x - self.iconPress.x) > 1 or math.abs(y - self.iconPress.y) > 1 then
      drag.moved = true
    end
    local target = self:iconIndexAt(x, y)
    if target ~= drag.index then
      drag.moved = true
    end
    drag.targetIndex = target
    self.dirty = true
    return
  end

  local win = self:windowAt(x, y)
  if win then
    self:forward(win, "drag", x - win.x, y - win.y - 1, button)
  end
end

function ui:onDrop(x, y, button)
  if self.iconDrag then
    local drag = self.iconDrag
    self.iconDrag = nil
    self.iconPress = nil
    local target = self:iconIndexAt(x, y)
    if target and target ~= drag.index then
      self:moveIconTo(target, drag.index)
      self:saveIconLayout()
    elseif not drag.moved then
      -- A tap that emitted a stray drag signal still opens the app.
      self.iconIndex = drag.index
      self:open(drag.id)
    end
    self.dirty = true
    return
  end

  if self.iconPress then
    local press = self.iconPress
    self.iconPress = nil
    local icon = self:iconAt(x, y)
    if icon and icon == press.index then
      self.iconIndex = icon
      self:open(self.layout[icon])
    end
    self.dirty = true
    return
  end

  if self.dragging then
    self:advanceDrag(self.kernel:uptime())
    if self.dragging.transitionDuration and self.dragging.transitionDuration > 0 then
      self.dragging.win.x = self.dragging.targetX
      self.dragging.win.y = self.dragging.targetY
    end
    self.dragging = nil
    local metrics = self.dragTest
    self.dragTest = nil
    if metrics then
      local elapsed = metrics.lastAt and metrics.firstAt and metrics.lastAt - metrics.firstAt or 0
      local rate = elapsed > 0 and (metrics.count - 1) / elapsed or 0
      local report = string.format(
        "Drag test: %d signals, %.1f Hz avg, %.0f ms max gap, %d interpolated frames",
        metrics.count,
        rate,
        metrics.maxGap * 1000,
        metrics.interpolatedFrames
      )
      self.log.info(report)
      self:notify("info", report)
    end
    self.dirty = true
    return
  end

  local win = self:windowAt(x, y)
  if win then
    self:forward(win, "drop", x - win.x, y - win.y - 1, button)
  end
end

function ui:onScroll(x, y, direction)
  local win = self:windowAt(x, y)
  if win then
    self:forward(win, "scroll", x - win.x, y - win.y - 1, direction)
  end
end

function ui:onTaskbarClick(x)
  local g = self.glyphs
  local mark = g.mark .. " " .. tostring(#self.windows)
    .. ((#self.windows == 1) and " window" or " windows")
  local column = 2 + text.width(mark) + 2

  for _, win in ipairs(self.windows) do
    local label = " " .. text.truncate(win.title, 14) .. " "
    local width = text.width(label)
    if column + width > self.w then
      return
    end
    if x >= column and x < column + width then
      if self.focus == win and not win.minimized then
        self:minimize(win)
      else
        self:setFocus(win)
      end
      return
    end
    column = column + width + 1
  end
end

function ui:onKey(char, code)
  -- OpenComputers supplies `char` as a numeric code point (zero when the key
  -- has no text). Apps receive UTF-8 strings instead of the raw event value.
  if type(char) == "number" then
    if char > 0 then
      local ok, value = pcall(utf8.char, char)
      char = ok and value or nil
    else
      char = nil
    end
  elseif type(char) ~= "string" then
    char = nil
  end

  if code == keys.esc then
    if self.focus then
      self:minimize(self.focus)
    end
    return
  end

  if code then
    for index = 1, math.min(#self.order, 10) do
      if code == keys["F" .. index] then
        self:open(self.order[index].id)
        return
      end
    end
  end

  if self.focus then
    self:forward(self.focus, "key", char, code)
    return
  end

  -- With no focused window, the arrow keys move the desktop selection and
  -- Enter opens it. This keeps every app reachable without a touch screen.
  if code == keys.left then
    self:moveIcon(-1)
  elseif code == keys.right then
    self:moveIcon(1)
  elseif code == keys.up then
    self:moveIcon(-self.iconCols)
  elseif code == keys.down then
    self:moveIcon(self.iconCols)
  elseif code == keys.home then
    for index = 1, self.iconSlotCount do
      if self.layout[index] then
        self.iconIndex = index
        self.dirty = true
        break
      end
    end
  elseif code == keys["end"] then
    for index = self.iconSlotCount, 1, -1 do
      if self.layout[index] then
        self.iconIndex = index
        self.dirty = true
        break
      end
    end
  elseif code == keys.enter and self.layout[self.iconIndex] then
    self:open(self.layout[self.iconIndex])
  end
end

function ui:dispatch(name, a, b, c, d, e)
  if name == "touch" then
    self:onTouch(b, c, d)
  elseif name == "drag" then
    self:onDrag(b, c, d)
  elseif name == "drop" then
    self:onDrop(b, c, d)
  elseif name == "scroll" then
    self:onScroll(b, c, d)
  elseif name == "key_down" then
    self:onKey(b, c)
  elseif name == "screen_resized" then
    -- Call the kernel method with `:` so `self` is the kernel instance.
    self.kernel:rebindScreen()
  end
  local _ = a, e
end

function ui:tick()
  for _, win in ipairs(self.windows) do
    if win.instance and win.instance.tick then
      local ok, result = pcall(win.instance.tick, win.instance, self:context(win))
      if not ok then
        self.log.error("tick " .. win.id .. ": " .. tostring(result))
      elseif result then
        self.dirty = true
      end
    end
  end
  self.dirty = true
end

return ui
