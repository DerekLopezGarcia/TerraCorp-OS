-- Plant: local line-boundary readout, level alarms and node status.
--
-- The app only reads the plant service cache. It never calls a component from
-- the draw path; the kernel ticks the service once per second with a one-call
-- budget.

local keys = require("tc.keys")

local plant = {}
plant.__index = plant

plant.id = "plant"
plant.title = "Plant"
plant.short = "Plant"
plant.icon = "PLT"
plant.iconArt = {
  "┌───────┐",
  "│ ▄▄ ▄▄ │",
  "│ ██ ██ │",
  "│ █████ │",
  "└───────┘",
}
plant.order = 11

local function mib(bytes)
  return (tonumber(bytes) or 0) / 1048576
end

local function stockColor(colors, state)
  if state == "exact" then
    return colors.ok
  elseif state == "coarse" or state == "stale" then
    return colors.warn
  elseif state == "unbound" then
    return colors.danger
  end
  return colors.dim
end

local function totalText(stock)
  local total = math.floor(tonumber(stock.total) or 0)
  if stock.kind == "fluid" then
    return string.format("%d mB", total)
  end
  return string.format("%d items", total)
end

local function entryText(entry)
  local label = entry.label or entry.key or "?"
  if entry.kind == "fluid" then
    return string.format("%s  %d mB", label, math.floor(tonumber(entry.amount) or 0))
  end
  return string.format("%s  x%d", label, math.floor(tonumber(entry.count) or 0))
end

local function rateText(stock)
  local rate = tonumber(stock.rate)
  if rate == nil then
    return ""
  end
  return string.format("  %+.1f/min", rate)
end

function plant.create()
  local self = setmetatable({}, plant)
  self.top = 0
  self.generation = nil
  return self
end

function plant:service(ctx)
  return ctx.kernel.plant
end

function plant:reload(ctx)
  local service = self:service(ctx)
  if not service then
    ctx.ui:notify("error", "Plant service is unavailable.")
    return true
  end
  local ok, reason = pcall(service.reload, service)
  if ok then
    ctx.ui:notify("info", "Plant reloaded.")
  else
    ctx.ui:notify("error", "Plant reload failed: " .. tostring(reason))
  end
  self.top = 0
  return true
end

function plant:draw(ctx)
  local c = ctx.colors
  local v = ctx.view
  v:clear(" ", c.text, c.deep)

  local service = self:service(ctx)
  if not service then
    v:put(2, 2, "Plant service unavailable.", c.danger, c.deep)
    return
  end

  local snapshot = service:snapshot()
  local status = snapshot.status or {}

  v:put(1, 1, "Plant", c.accent, c.deep)
  local alarmCount = #(snapshot.alarms or {})
  local right = string.format("%d stock%s · %d alarm%s",
    #(snapshot.stocks or {}), #(snapshot.stocks or {}) == 1 and "" or "s",
    alarmCount, alarmCount == 1 and "" or "s")
  v:textRight(ctx.w, 1, right, alarmCount > 0 and c.warn or c.dim, c.deep)

  local memory = status.memory or {}
  local power = status.energy and string.format("%.0f%%", status.energy) or "n/a"
  local line = string.format("%s · v%s · up %s · %.0f/%.0f MB · power %s",
    tostring(ctx.kernel.hostname or "?"),
    tostring(status.version or "?"),
    ctx.util.humanTime(status.uptime or 0),
    mib(memory.used), mib(memory.total), power)
  v:put(1, 2, ctx.text.truncate(line, ctx.w), c.dim, c.deep)

  local cache = status.cacheAge and string.format("%.0fs", status.cacheAge) or "no scan"
  local note = string.format("cache %s · calls %.0f · hist %d%s", cache, status.calls or 0,
    status.historySamples or 0, status.scanning and " · scanning" or "")
  if not snapshot.configured then
    note = "no stocks configured · edit /etc/stocks.tsv and /etc/paths.tsv, then R"
  end
  v:put(1, 3, ctx.text.truncate(note, ctx.w), snapshot.configured and c.dim or c.warn, c.deep)

  local lines = {}
  for _, stock in ipairs(snapshot.stocks or {}) do
    lines[#lines + 1] = {
      text = string.format("%s  %s  %s%s", stock.name, tostring(stock.state or "?"),
        totalText(stock), rateText(stock)),
      color = stockColor(c, stock.state),
    }
    local entries = stock.entries or {}
    if #entries == 0 then
      lines[#lines + 1] = { text = "  (empty)", color = c.dim }
    else
      for _, entry in ipairs(entries) do
        lines[#lines + 1] = { text = "  " .. entryText(entry), color = c.dim }
      end
    end
  end

  local bodyTop = 5
  local footer = ctx.h
  local alarmRows = 0
  if ctx.h >= 18 and alarmCount > 0 then
    alarmRows = math.min(4, alarmCount + 1)
  end
  local bodyBottom = footer - 1 - alarmRows
  local visible = math.max(1, bodyBottom - bodyTop + 1)
  local maximum = math.max(0, #lines - visible)
  self.top = math.max(0, math.min(self.top or 0, maximum))

  for index = 1, visible do
    local item = lines[self.top + index]
    if not item then
      break
    end
    v:put(1, bodyTop + index - 1, ctx.text.truncate(item.text, ctx.w), item.color, c.deep)
  end

  if #lines == 0 then
    v:put(2, bodyTop, "No stocks configured.", c.text, c.deep)
    v:put(2, bodyTop + 1, "Create /etc/stocks.tsv and /etc/paths.tsv.", c.dim, c.deep)
    v:put(2, bodyTop + 2, "Press R to reload.", c.dim, c.deep)
  end

  if alarmRows > 0 then
    local top = footer - alarmRows
    v:fill(1, top, ctx.w, 1, " ", c.text, c.panel)
    v:put(1, top, "ALARMS", c.text, c.panel)
    for index = 1, math.min(alarmCount, alarmRows - 1) do
      local alarm = snapshot.alarms[index]
      local color = alarm.severity == "danger" and c.danger or c.warn
      local text = string.format("%s %s · %s", alarm.code, alarm.source, alarm.message)
      v:put(2, top + index, ctx.text.truncate(text, ctx.w - 2), color, c.deep)
    end
  end

  v:fill(1, footer, ctx.w, 1, " ", c.dim, c.panel)
  v:put(1, footer, "R reload · ↑↓ scroll · " ..
    (status.scanning and "scanning" or "cached"), c.text, c.panel)
end

function plant:move(delta)
  self.top = math.max(0, (self.top or 0) + delta)
  return true
end

function plant:handle(ctx, name, a, b, c)
  if name == "scroll" then
    return self:move((tonumber(c) or 0) > 0 and -1 or 1)
  end
  if name ~= "key" then
    return false
  end
  local char, code = a, b
  if char == "r" then
    return self:reload(ctx)
  elseif code == keys.up then
    return self:move(-1)
  elseif code == keys.down then
    return self:move(1)
  elseif code == keys.pageUp then
    return self:move(-8)
  elseif code == keys.pageDown then
    return self:move(8)
  elseif code == keys.home then
    self.top = 0
    return true
  elseif code == keys["end"] then
    self.top = 9999
    return true
  end
  return false
end

function plant:tick(ctx)
  local service = self:service(ctx)
  if not service then
    return false
  end
  local generation = service.stock.generation
  if self.generation ~= generation then
    self.generation = generation
    return true
  end
  return false
end

function plant:close()
end

return plant
