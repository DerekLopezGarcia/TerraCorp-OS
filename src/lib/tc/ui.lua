-- Escritorio: barra superior, dock, ventanas y envío de eventos a las apps.
--
-- Contrato de app (ver docs/arquitectura.md):
--   module = { id, title, order, create(ctx) -> instance }
--   instance = { draw(ctx), handle(ctx, name, ...), close(ctx) }
-- `ctx.view` es una subvista de gfx con coordenadas locales 1..w / 1..h.

local text = require("tc.text")
local util = require("tc.util")
local keys = require("tc.keys")

local ui = {}
ui.__index = ui

local TOP_HEIGHT = 2
local DOCK_HEIGHT = 2
local MIN_WIDTH = 34
local MIN_HEIGHT = 10

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

  self.windows = {}
  self.focus = nil
  self.z = 0
  self.dragging = nil
  self.notice = nil
  self.dirty = true

  self:resize()
  return self
end

function ui:resize()
  self.w = self.gfx.w
  self.h = self.gfx.h
  self.dockTop = self.h - DOCK_HEIGHT + 1
  self.desktopTop = TOP_HEIGHT + 1
  self.desktopBottom = self.dockTop - 1

  for _, win in ipairs(self.windows) do
    self:clampWindow(win)
  end

  self.dirty = true
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

function ui:setFocus(win)
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
  local width = math.min(self.w - 4, math.max(MIN_WIDTH, math.floor(self.w * 0.74)))
  local height = math.min(usable - 1, math.max(MIN_HEIGHT, math.floor(usable * 0.84)))
  local offset = (#self.windows % 5) * 2
  local x = math.floor((self.w - width) / 2) + offset
  local y = self.desktopTop + math.max(0, math.floor((usable - height) / 2)) + offset
  return x, y, width, height
end

function ui:open(id)
  local existing = self:findWindow(id)
  if existing then
    existing.minimized = false
    self:setFocus(existing)
    return existing
  end

  local module = self.apps[id]
  if not module then
    self:notify("warn", "Aplicación desconocida: " .. tostring(id))
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
    self.log.error("no se pudo abrir " .. id .. ": " .. tostring(instance))
    self.windows[#self.windows] = nil
    self:notify("error", "Fallo al abrir " .. win.title)
    self:focusNextWindow()
    return nil
  end

  win.instance = instance
  self.log.info("app abierta: " .. id)
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

  self.log.info("app cerrada: " .. tostring(win.id))
  self.dirty = true
end

function ui:minimize(win)
  if not win then
    return
  end
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
-- Dibujo
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
    hostname = self.kernel.hostname or "TC-NODO"
  end

  local left = hostname .. "  " .. g.bullet .. "  v" .. self.version.version
  self.gfx:put(2, 2, text.truncate(left, self.w - 30), c.text, c.panel)

  local energy = self.kernel:energyPercent()
  local status = string.format("ENERGÍA %3d%%", math.floor(energy))
  local statusColor = c.text
  if energy < 15 then
    statusColor = c.danger
  elseif energy < 40 then
    statusColor = c.warn
  end

  self.gfx:put(self.w - text.width(status) - 1, 2, status, statusColor, c.panel)
end

function ui:drawDock()
  local c = self.colors
  local g = self.glyphs
  local row = self.h - 1

  self.gfx:fill(1, row, self.w, 1, " ", c.dim, c.panel)
  self.gfx:fill(1, self.h, self.w, 1, " ", c.panel, c.bg)
  self.gfx:put(2, self.h, "F1–F5 abrir · Esc minimizar · clic en la barra arrastra la ventana", c.dim, c.bg)

  local column = 2
  for index, module in ipairs(self.order) do
    local label = " " .. index .. " " .. (module.short or module.title) .. " "
    local open = self:findWindow(module.id) ~= nil
    local focused = self.focus and self.focus.id == module.id

    local fg, bg
    if focused then
      fg, bg = c.onAccent, c.accent
    elseif open then
      fg, bg = c.text, c.deep
    else
      fg, bg = c.dim, c.panel
    end

    local width = text.width(label)
    if column + width >= self.w then
      break
    end

    self.gfx:put(column, row, label, fg, bg)
    column = column + width + 1
  end

  local mark = g.mark .. " " .. tostring(#self.windows) .. ((#self.windows == 1) and " ventana" or " ventanas")
  self.gfx:put(self.w - text.width(mark) - 1, row, mark, c.dim, c.panel)
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

  if win.instance and win.instance.draw then
    local ctx = self:context(win)
    local ok, reason = pcall(win.instance.draw, win.instance, ctx)
    if not ok then
      self.log.error("draw " .. win.id .. ": " .. tostring(reason))
      self.gfx:put(win.x + 2, win.y + 2, "Error de dibujo: " .. tostring(reason), c.danger, c.deep)
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
  local y = self.h - DOCK_HEIGHT - 1
  local bg = c.danger
  if self.notice.level == "warn" then
    bg = c.warn
  elseif self.notice.level == "info" then
    bg = c.accent
  end
  self.gfx:put(x, y, label, c.onAccent, bg)
end

function ui:render(force)
  if not force and not self.dirty then
    return 0
  end
  self.dirty = false

  self.gfx:clear(self.colors.bg, self.colors.dim)

  local ordered = {}
  for _, win in ipairs(self.windows) do
    ordered[#ordered + 1] = win
  end
  table.sort(ordered, function(a, b)
    return a.z < b.z
  end)

  for _, win in ipairs(ordered) do
    if not win.minimized then
      self:drawWindow(win)
    end
  end

  if #self.windows == 0 then
    self:drawEmptyState()
  end

  self:drawTopbar()
  self:drawDock()
  self:drawNotice()

  return self.gfx:flush()
end

function ui:drawEmptyState()
  local c = self.colors
  local title = "TERRACORP OS"
  local subtitle = "Planta sin sesión de trabajo. Abre un módulo en el dock."
  local y = self.desktopTop + math.floor((self.desktopBottom - self.desktopTop) / 2) - 2
  self.gfx:put(math.floor((self.w - text.width(title)) / 2) + 1, y, title, c.accent, c.bg)
  self.gfx:put(math.floor((self.w - text.width(subtitle)) / 2) + 1, y + 2, subtitle, c.dim, c.bg)
end

--------------------------------------------------------------------------------
-- Eventos
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
    self.log.error("evento " .. name .. " en " .. win.id .. ": " .. tostring(result))
    self:notify("error", win.title .. ": error interno")
    return false
  end

  if result then
    self.dirty = true
  end
  return result
end

function ui:onTouch(x, y, button)
  if y <= TOP_HEIGHT then
    return
  end

  if y >= self.dockTop then
    if y == self.dockTop then
      self:onDockClick(x)
    end
    return
  end

  local win = self:windowAt(x, y)
  if not win then
    self:setFocus(nil)
    return
  end

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
    self.dragging = { win = win, dx = x - win.x, dy = y - win.y }
    return
  end

  local localX = x - win.x
  local localY = y - win.y - 1
  self:forward(win, "touch", localX, localY, button)
end

function ui:onDrag(x, y, button)
  if self.dragging then
    local win = self.dragging.win
    win.x = util.clamp(x - self.dragging.dx, 1, self.w - win.w + 1)
    win.y = util.clamp(y - self.dragging.dy, 1, self.h - win.h + 1)
    self.dirty = true
    return
  end

  local win = self:windowAt(x, y)
  if win then
    self:forward(win, "drag", x - win.x, y - win.y - 1, button)
  end
end

function ui:onDrop(x, y, button)
  if self.dragging then
    self.dragging = nil
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

function ui:onDockClick(x)
  local column = 2
  for index, module in ipairs(self.order) do
    local label = " " .. index .. " " .. (module.short or module.title) .. " "
    local width = text.width(label)
    if x >= column and x < column + width then
      self:open(module.id)
      return
    end
    column = column + width + 1
  end
end

function ui:onKey(char, code)
  if code == keys.esc then
    self:minimize(self.focus)
    return
  end

  if code then
    for index = 1, math.min(#self.order, 5) do
      if code == keys["F" .. index] then
        self:open(self.order[index].id)
        return
      end
    end
  end

  if self.focus then
    self:forward(self.focus, "key", char, code)
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
    -- `rebindScreen` es un método del kernel: se invoca con `:` para que
    -- `self` sea la instancia y no la tabla del módulo.
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
