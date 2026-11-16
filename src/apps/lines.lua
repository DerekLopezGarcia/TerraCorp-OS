-- Lines: control over what a line watches.
--
-- The app reads the master's merged view, edits the level thresholds of the
-- selected line in the master's /etc/plant.tsv, and pushes that file to the node
-- so the node keeps evaluating its own alarms with the same numbers (decision
-- 23). It never invents a stock: stocks are declared on the node.

local keys = require("tc.keys")

local lines = {}
lines.__index = lines

lines.id = "lines"
lines.title = "Lines"
lines.short = "Lines"
lines.icon = "LIN"
lines.iconArt = {
  "┌─┬─┬─┬─┐",
  "│ │ │ │ │",
  "├─┼─┼─┼─┤",
  "│ │ │ │ │",
  "└─┴─┴─┴─┘",
}
lines.order = 12
lines.PATH = "/etc/plant.tsv"

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Parse /etc/plant.tsv. Unknown or malformed rows are skipped here: the node is
-- the authority on whether its own file is valid, and the master reports what
-- the app can edit.
local function parseThresholds(text)
  local map = {}
  for raw in (text or ""):gmatch("[^\r\n]+") do
    local value = trim(raw:gsub("#.*$", ""))
    if value ~= "" then
      local name, minText, maxText, expect, trendText =
        value:match("^(%S+)%s+(%S+)%s*(%S*)%s*(%S*)%s*(%S*)$")
      local minimum = tonumber(minText)
      if name and minimum then
        map[name] = {
          min = minimum,
          max = tonumber(maxText) or 0,
          flow = expect == "flow",
          trend = tonumber(trendText),
        }
      end
    end
  end
  return map
end

local function serializeThresholds(map)
  local names = {}
  for name in pairs(map) do
    names[#names + 1] = name
  end
  table.sort(names)
  local rows = { "# TerraCorp: line level thresholds (stock min max flow|idle [trend%])" }
  for _, name in ipairs(names) do
    local item = map[name]
    local row = string.format("%s\t%d\t%d\t%s", name,
      math.floor(tonumber(item.min) or 0),
      math.floor(tonumber(item.max) or 0),
      item.flow and "flow" or "idle")
    if tonumber(item.trend) then
      row = row .. "\t" .. tostring(math.floor(item.trend))
    end
    rows[#rows + 1] = row
  end
  return table.concat(rows, "\n") .. "\n"
end

function lines.create()
  local self = setmetatable({}, lines)
  self.index = 1
  self.top = 0
  self.thresholds = {}
  self.loaded = false
  self.editing = nil
  self.buffer = ""
  self.message = nil
  return self
end

function lines:service(ctx)
  return ctx.kernel.master
end

function lines:load(ctx)
  local vfs = ctx.kernel.vfs
  local text = vfs and vfs.read(lines.PATH) or nil
  self.thresholds = parseThresholds(text)
  self.loaded = true
  return self.thresholds
end

function lines:rows(ctx)
  local service = self:service(ctx)
  if not service then
    return {}
  end
  return service:snapshot().stocks
end

function lines:selected(ctx)
  local rows = self:rows(ctx)
  if #rows == 0 then
    return nil
  end
  self.index = math.max(1, math.min(self.index, #rows))
  return rows[self.index]
end

function lines:thresholdFor(name)
  local item = self.thresholds[name]
  if not item then
    item = { min = 0, max = 0, flow = true, trend = nil }
    self.thresholds[name] = item
  end
  return item
end

function lines:draw(ctx)
  local c = ctx.colors
  local v = ctx.view
  v:clear(" ", c.text, c.deep)

  local service = self:service(ctx)
  if not service then
    v:put(2, 2, "Master service unavailable.", c.danger, c.deep)
    return
  end
  if not self.loaded then
    self:load(ctx)
  end

  local view = service:snapshot()
  local title = "Lines"
  v:put(1, 1, title, c.accent, c.deep)
  local counts = string.format("%d line%s · %d stock%s",
    #view.nodes, #view.nodes == 1 and "" or "s",
    #view.stocks, #view.stocks == 1 and "" or "s")
  if ctx.w >= #title + #counts + 2 then
    v:textRight(ctx.w, 1, counts, c.dim, c.deep)
  end
  v:put(1, 2, ctx.text.truncate("min / max / flow per stock · S saves and pushes to the node", ctx.w),
    c.dim, c.deep)

  local bodyTop = 4
  local bodyBottom = math.max(bodyTop, ctx.h - 3)
  local visible = math.max(1, bodyBottom - bodyTop + 1)
  local rows = view.stocks
  local maximum = math.max(0, #rows - visible)
  self.index = math.max(1, math.min(self.index, math.max(1, #rows)))
  if self.index - 1 > self.top + visible - 1 then
    self.top = self.index - visible
  elseif self.index - 1 < self.top then
    self.top = self.index - 1
  end
  self.top = math.max(0, math.min(self.top, maximum))

  if #rows == 0 then
    v:put(2, bodyTop, "No stocks reported yet.", c.text, c.deep)
    v:put(2, bodyTop + 1, "A line node publishes its two boundary stocks.", c.dim, c.deep)
  end

  for index = 1, visible do
    local stock = rows[self.top + index]
    if not stock then
      break
    end
    local selected = (self.top + index) == self.index
    local threshold = self:thresholdFor(stock.name)
    local text = string.format("%s %-22s %8d %-8s min %-6d max %-6d %s",
      selected and ">" or " ", tostring(stock.name):sub(1, 22),
      math.floor(tonumber(stock.total) or 0), tostring(stock.state),
      math.floor(threshold.min or 0), math.floor(threshold.max or 0),
      threshold.flow and "flow" or "idle")
    if selected then
      v:fill(1, bodyTop + index - 1, ctx.w, 1, " ", c.deep, c.panel)
    end
    local color = selected and c.text or (stock.state == "offline" and c.dim or c.text)
    v:put(1, bodyTop + index - 1, ctx.text.truncate(text, ctx.w), color,
      selected and c.panel or c.deep)
  end

  local footer = ctx.h - 1
  if self.editing then
    v:fill(1, footer, ctx.w, 1, " ", c.accent, c.deep)
    v:put(1, footer, string.format("%s %s: %s▏", self.editing.field, self.editing.name,
      self.buffer), c.accent, c.deep)
  elseif self.message then
    v:put(1, footer, ctx.text.truncate(self.message, ctx.w), c.warn, c.deep)
  else
    v:put(1, footer, "↑↓ select · M min · X max · T flow · S save+push · R reload",
      c.dim, c.deep)
  end
end

function lines:startEdit(ctx, field)
  local stock = self:selected(ctx)
  if not stock then
    return true
  end
  local threshold = self:thresholdFor(stock.name)
  self.editing = { name = stock.name, field = field }
  self.buffer = tostring(math.floor(tonumber(threshold[field]) or 0))
  self.message = nil
  return true
end

function lines:commitEdit(ctx)
  local editing = self.editing
  self.editing = nil
  if not editing then
    return true
  end
  local value = tonumber(self.buffer)
  if not value or value < 0 then
    self.message = "That is not a number."
    return true
  end
  local threshold = self:thresholdFor(editing.name)
  threshold[editing.field] = math.floor(value)
  self.message = string.format("%s %s = %d (unsaved)", editing.name, editing.field,
    math.floor(value))
  return true
end

function lines:toggleFlow(ctx)
  local stock = self:selected(ctx)
  if not stock then
    return true
  end
  local threshold = self:thresholdFor(stock.name)
  threshold.flow = not threshold.flow
  self.message = string.format("%s is now %s", stock.name,
    threshold.flow and "flow" or "idle")
  return true
end

function lines:save(ctx)
  local service = self:service(ctx)
  local vfs = ctx.kernel.vfs
  if not service or not vfs then
    return true
  end
  local body = serializeThresholds(self.thresholds)
  local ok, reason = vfs.write(lines.PATH, body)
  if not ok then
    self.message = "Could not write " .. lines.PATH .. ": " .. tostring(reason)
    return true
  end

  local stock = self:selected(ctx)
  local view = service:snapshot()
  local target = nil
  if stock then
    for _, node in ipairs(view.nodes) do
      if node.name == stock.node then
        target = node
      end
    end
  end
  if not target then
    self.message = "Saved locally; no node selected to push to."
    return true
  end

  local pushed, pushReason = service:sendConfig(target.id, "plant.tsv", body)
  if not pushed then
    self.message = "Saved; push failed: " .. tostring(pushReason)
  else
    self.message = string.format("Saved and pushed to %s.", target.name)
  end
  return true
end

function lines:handle(ctx, name, a, b)
  if name == "scroll" then
    local delta = tonumber(b) or 0
    self.index = math.max(1, self.index + (delta < 0 and 1 or -1))
    return true
  end
  if name ~= "key" then
    return false
  end
  local char, code = a, b

  if self.editing then
    if code == keys.esc then
      self.editing = nil
      return true
    elseif code == keys.enter then
      return self:commitEdit(ctx)
    elseif code == keys.back then
      self.buffer = self.buffer:sub(1, math.max(0, #self.buffer - 1))
      return true
    elseif type(char) == "string" and #char == 1 and char:match("%d") then
      if #self.buffer < 9 then
        self.buffer = self.buffer .. char
      end
      return true
    end
    return true
  end

  if code == keys.up then
    self.index = math.max(1, self.index - 1)
  elseif code == keys.down then
    self.index = self.index + 1
  elseif code == keys.pageUp then
    self.index = math.max(1, self.index - 6)
  elseif code == keys.pageDown then
    self.index = self.index + 6
  elseif char == "m" then
    return self:startEdit(ctx, "min")
  elseif char == "x" then
    return self:startEdit(ctx, "max")
  elseif char == "t" then
    return self:toggleFlow(ctx)
  elseif char == "s" then
    return self:save(ctx)
  elseif char == "r" then
    self:load(ctx)
    self.message = "Reloaded " .. lines.PATH
  else
    return false
  end
  return true
end

function lines:tick(ctx)
  local service = self:service(ctx)
  if not service then
    return false
  end
  local status = service:status()
  local signature = string.format("%d/%d", status.received, status.online)
  if self.signature ~= signature then
    self.signature = signature
    return true
  end
  return false
end

function lines:close()
end

return lines
