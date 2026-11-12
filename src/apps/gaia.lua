-- GAIA: the external link to the operator's agent.
--
-- Shows whether the link is armed, where it points and how far the far side can
-- reach, and edits the sink and token in place. The protocol lives in
-- lib/tc/link.lua; the design is docs/external-link.md.

local keys = require("tc.keys")

local gaia = {}
gaia.__index = gaia

gaia.id = "gaia"
gaia.title = "GAIA"
gaia.short = "GAIA"
gaia.icon = "GAI"
gaia.iconArt = {
  "  ▄███▄  ",
  " ██▀█▀██ ",
  "██▀▀█▀▀██",
  " ██▄█▄██ ",
  "  ▀███▀  ",
}
gaia.order = 9

local TIERS = { "off", "write", "full" }
local INTERVALS = { 5, 10, 15, 30 }

local function masked(value)
  if value == nil or value == "" then
    return ""
  end
  return string.rep("*", math.min(#value, 12))
end

function gaia.create()
  local self = setmetatable({}, gaia)
  self.hits = {}
  self.editing = nil
  self.draft = ""
  return self
end

function gaia:configKey(field)
  return field == "sink" and "linkSink" or "linkToken"
end

function gaia:startEdit(ctx, field)
  self.editing = field
  self.draft = tostring(ctx.config.get(self:configKey(field)) or "")
end

function gaia:commit(ctx)
  local key = self:configKey(self.editing)
  local value = self.draft
  self.editing = nil
  self.draft = ""

  if not ctx.config.set(key, value) then
    ctx.ui:notify("warn", "Could not store " .. key)
    return
  end
  ctx.kernel:saveConfig()
  if ctx.kernel.link then
    ctx.kernel.link:refresh()
  end
  ctx.ui:notify("info", key .. " saved")
end

function gaia:cycleTier(ctx)
  local current = ctx.config.get("linkControl")
  local nextIndex = 1
  for index, value in ipairs(TIERS) do
    if value == current then
      nextIndex = (index % #TIERS) + 1
      break
    end
  end
  ctx.config.set("linkControl", TIERS[nextIndex])
  ctx.kernel:saveConfig()
  if ctx.kernel.link then
    ctx.kernel.link:refresh()
  end
  ctx.ui:notify("info", "Control set to " .. TIERS[nextIndex])
end

function gaia:cycleInterval(ctx)
  ctx.config.cycle("linkInterval", INTERVALS)
  ctx.kernel:saveConfig()
  if ctx.kernel.link then
    ctx.kernel.link:refresh()
  end
  ctx.ui:notify("info", "Interval updated")
end

function gaia:button(ctx, x, y, label, action)
  local c = ctx.colors
  local value = " " .. label .. " "
  local width = ctx.text.width(value)
  ctx.view:put(x, y, value, c.onAccent, c.accent)
  self.hits[#self.hits + 1] = { x = x, y = y, w = width, h = 1, action = action }
  return x + width + 1
end

function gaia:drawField(ctx, row, field, label)
  local c = ctx.colors
  local v = ctx.view
  local editing = self.editing == field
  local raw = ctx.config.get(self:configKey(field)) or ""
  local shown = editing and self.draft or (field == "token" and masked(raw) or raw)

  v:put(2, row, string.format("%-6s", label), c.dim, c.deep)

  local inner = math.max(8, ctx.w - 12)
  if ctx.text.width(shown) > inner then
    shown = ctx.text.slice(shown, 1, inner)
  end
  local box = "[" .. shown .. string.rep(" ", inner - ctx.text.width(shown)) .. "]"
  local background = editing and c.panel or c.deep
  v:put(9, row, box, editing and c.text or c.dim, background)

  self.hits[#self.hits + 1] = {
    x = 9,
    y = row,
    w = inner + 2,
    h = 1,
    action = function(context)
      self:startEdit(context, field)
    end,
  }
end

function gaia:draw(ctx)
  local c = ctx.colors
  local g = ctx.glyphs
  local v = ctx.view

  v:clear(" ", c.text, c.deep)
  self.hits = {}

  v:put(1, 1, "GAIA · external link", c.text, c.deep)

  local link = ctx.kernel.link
  local report = link and link.report and link:report()

  if not link then
    v:put(1, 2, "Link module unavailable on this build.", c.dim, c.deep)
    return
  end

  local state = "disabled"
  local stateColor = c.dim
  if report.enabled then
    state = "armed every " .. tostring(report.interval) .. "s"
    stateColor = c.accent
  end
  v:put(1, 2, "State: " .. state, stateColor, c.deep)

  self:drawField(ctx, 4, "sink", "Sink")
  self:drawField(ctx, 5, "token", "Token")

  local row = 7
  v:put(2, row, "Control", c.dim, c.deep)
  local x = 11
  for _, tier in ipairs(TIERS) do
    local label = tier
    if report.control == tier then
      label = "[" .. tier .. "]"
    end
    x = self:button(ctx, x, row, label, function(context)
      self:cycleTier(context)
    end)
    if x + 4 > ctx.w then
      break
    end
  end

  row = row + 1
  if row <= ctx.h - 4 then
    v:put(2, row, "Interval", c.dim, c.deep)
    self:button(ctx, 11, row, tostring(report.interval) .. "s", function(context)
      self:cycleInterval(context)
    end)
  end

  row = row + 2
  if row <= ctx.h - 3 then
    local pending = tostring(report.queued)
    local failures = tostring(report.failures)
    v:put(2, row, "Pending replies: " .. pending .. " · failures: " .. failures, c.dim, c.deep)
  end

  row = row + 1
  if row <= ctx.h - 2 then
    local last = report.lastCommand or "none yet"
    v:put(2, row, "Last command: " .. tostring(last), c.dim, c.deep)
  end

  row = row + 1
  if report.problem and row <= ctx.h - 1 then
    v:put(2, row, "Problem: " .. tostring(report.problem), c.dim, c.deep)
  end

  if ctx.h >= 2 then
    v:hline(1, ctx.h - 1, ctx.w, g.h, c.panel, c.deep)
    local help = "Click a field to edit · Enter saves · Esc cancels"
    v:put(1, ctx.h, ctx.text.slice(help, 1, ctx.w), c.dim, c.deep)
  end
end

function gaia:handle(ctx, name, a, b)
  if name == "key" then
    if self.editing then
      if b == keys.enter then
        self:commit(ctx)
        return true
      elseif b == keys.esc then
        self.editing = nil
        self.draft = ""
        return true
      elseif b == keys.back then
        self.draft = self.draft:sub(1, -2)
        return true
      elseif type(a) == "string" and a ~= "" then
        self.draft = self.draft .. a
        return true
      end
      return true
    end
    return false
  end

  if name ~= "touch" then
    return false
  end

  for _, hit in ipairs(self.hits) do
    if a >= hit.x and a < hit.x + hit.w and b == hit.y then
      hit.action(ctx)
      return true
    end
  end
  return false
end

function gaia:close()
  self.editing = nil
  self.draft = ""
end

return gaia
