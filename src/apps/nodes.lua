-- Nodes: the plant's DNS.
--
-- One row per line node that talks to the master, with the name it answers to.
-- This app is the registry's view and its editor; the master service owns the
-- registry and the wire, so nothing here talks to a component directly.

local keys = require("tc.keys")

local nodes = {}
nodes.__index = nodes

nodes.id = "nodes"
nodes.title = "Nodes"
nodes.short = "Nodes"
nodes.icon = "NOD"
nodes.iconArt = {
  "╔═══════╗",
  "║ name  ║",
  "║ ▪ ▪ ▪ ║",
  "║ ▪ ▪ ▪ ║",
  "╚═══════╝",
}
nodes.order = 7

local function stateColor(colors, state)
  if state == "online" then
    return colors.ok
  elseif state == "stale" then
    return colors.warn
  elseif state == "conflict" then
    return colors.danger
  end
  return colors.dim
end

function nodes.create()
  local self = setmetatable({}, nodes)
  self.index = 1
  self.top = 0
  self.editing = nil
  self.buffer = ""
  self.forgetArmed = nil
  return self
end

function nodes:service(ctx)
  return ctx.kernel.master
end

function nodes:rows(ctx)
  local service = self:service(ctx)
  if not service then
    return {}
  end
  return service:snapshot().nodes
end

function nodes:selected(ctx)
  local rows = self:rows(ctx)
  if #rows == 0 then
    return nil
  end
  self.index = math.max(1, math.min(self.index, #rows))
  return rows[self.index]
end

function nodes:draw(ctx)
  local c = ctx.colors
  local v = ctx.view
  v:clear(" ", c.text, c.deep)

  local service = self:service(ctx)
  if not service then
    v:put(2, 2, "Master service unavailable.", c.danger, c.deep)
    return
  end

  local status = service:status()
  local view = service:snapshot()

  local title = "Node registry"
  v:put(1, 1, title, c.accent, c.deep)
  local counts = string.format("%d online · %d offline", status.online, status.offline)
  if ctx.w >= #title + #counts + 2 then
    v:textRight(ctx.w, 1, counts, status.offline > 0 and c.warn or c.dim, c.deep)
  end
  local wire = string.format("%s · %d frame%s · %d assign%s",
    status.opened and "modem open" or "no modem",
    status.received, status.received == 1 and "" or "s",
    status.assigned, status.assigned == 1 and "" or "s")
  v:put(1, 2, ctx.text.truncate(wire, ctx.w), c.dim, c.deep)

  -- On a short window the detail pane is the first thing to go: the table and
  -- the key hints matter more than the selected node's uptime.
  local compact = ctx.h < 14
  local bodyTop = 4
  local detailRows = compact and 2 or 5
  local bodyBottom = math.max(bodyTop, ctx.h - 1 - detailRows)
  local visible = math.max(1, bodyBottom - bodyTop + 1)
  local rows = view.nodes
  local maximum = math.max(0, #rows - visible)
  self.index = math.max(1, math.min(self.index, math.max(1, #rows)))
  if self.index - 1 > self.top + visible - 1 then
    self.top = self.index - visible
  elseif self.index - 1 < self.top then
    self.top = self.index - 1
  end
  self.top = math.max(0, math.min(self.top, maximum))

  if #rows == 0 then
    v:put(2, bodyTop, "No slave node has reported yet.", c.text, c.deep)
    if not compact then
      v:put(2, bodyTop + 1, "Install a node from its floppy and power it on.", c.dim, c.deep)
    end
  end

  for index = 1, visible do
    local node = rows[self.top + index]
    if not node then
      break
    end
    local selected = (self.top + index) == self.index
    local marker = selected and ">" or " "
    local alarm = node.alarm ~= "" and (":" .. node.alarm:match("^([^:]+)")) or ""
    local text = string.format("%s %-16s %-8s %2d stock%s %s",
      marker, tostring(node.name):sub(1, 16), tostring(node.state),
      node.stocks or 0, (node.stocks or 0) == 1 and "" or "s", alarm)
    local color = selected and c.text or stateColor(c, node.state)
    if selected then
      v:fill(1, bodyTop + index - 1, ctx.w, 1, " ", c.deep, c.panel)
    end
    v:put(1, bodyTop + index - 1, ctx.text.truncate(text, ctx.w), color,
      selected and c.panel or c.deep)
  end

  local node = self:selected(ctx)
  local detail = ctx.h - detailRows
  v:fill(1, detail, ctx.w, 1, " ", c.text, c.panel)
  if node then
    v:put(1, detail, ctx.text.truncate(string.format("%s · %s · v%s · up %s · %s",
      tostring(node.name), tostring(node.id):sub(1, 8), tostring(node.v or "?"),
      ctx.util.humanTime(node.uptime or 0),
      node.age and string.format("%.0fs ago", node.age) or "silent"), ctx.w),
      c.text, c.panel)
    local extra = node.alarm ~= "" and ("alarm " .. node.alarm .. " on " .. tostring(node.alarmPath))
      or "no alarms"
    if not compact then
      v:put(1, detail + 1, ctx.text.truncate(extra, ctx.w),
        node.alarm ~= "" and c.warn or c.dim, c.panel)
    end
  else
    v:put(1, detail, "Select a node.", c.dim, c.panel)
  end

  if self.editing then
    v:fill(1, detail + 2, ctx.w, 1, " ", c.text, c.deep)
    v:put(1, detail + 2, string.format("New name for %s: %s▏", tostring(node and node.name or "?"),
      self.buffer), c.accent, c.deep)
  elseif self.forgetArmed then
    v:put(1, detail + 2, string.format("Press F again to forget %s.", tostring(self.forgetArmed)),
      c.danger, c.deep)
  else
    v:put(1, detail + 2, "↑↓ select · R rename · P ping · F forget · I installer",
      c.dim, c.deep)
  end
end

function nodes:notify(ctx, kind, message)
  ctx.ui:notify(kind, message)
  return true
end

function nodes:startRename(ctx)
  local node = self:selected(ctx)
  if not node then
    return self:notify(ctx, "warn", "No node selected.")
  end
  self.editing = node.id
  self.buffer = tostring(node.name or "")
  self.forgetArmed = nil
  return true
end

function nodes:commitRename(ctx)
  local service = self:service(ctx)
  local id = self.editing
  self.editing = nil
  if not service or not id then
    return true
  end

  local result, reason = service:rename(id, self.buffer)
  if not result then
    local text = reason == "name_taken" and "That name already belongs to another node."
      or reason == "invalid_name" and "A name is lowercase letters, digits, - and _."
      or tostring(reason)
    return self:notify(ctx, "error", text)
  end

  local references = result.references or {}
  if #references > 0 then
    return self:notify(ctx, "warn", string.format(
      "Renamed to %s. %d file%s still mention the old prefix.",
      result.name, #references, #references == 1 and "" or "s"))
  end
  return self:notify(ctx, "info", "Renamed to " .. tostring(result.name) .. ".")
end

function nodes:ping(ctx)
  local service = self:service(ctx)
  local node = self:selected(ctx)
  if not service or not node then
    return self:notify(ctx, "warn", "No node selected.")
  end
  local ok, reason = service:ping(node.id)
  if not ok then
    return self:notify(ctx, "error", "Ping failed: " .. tostring(reason))
  end
  return self:notify(ctx, "info", "Ping sent to " .. tostring(node.name) .. ".")
end

function nodes:forget(ctx)
  local service = self:service(ctx)
  local node = self:selected(ctx)
  if not service or not node then
    return self:notify(ctx, "warn", "No node selected.")
  end
  if self.forgetArmed ~= node.id then
    self.forgetArmed = node.id
    return self:notify(ctx, "warn", "Press F again to forget " .. tostring(node.name) .. ".")
  end
  self.forgetArmed = nil
  local removed, reason = service:forget(node.id)
  if not removed then
    return self:notify(ctx, "error", "Forget failed: " .. tostring(reason))
  end
  self.index = math.max(1, self.index - 1)
  return self:notify(ctx, "info", "Forgot " .. tostring(node.name) .. ".")
end

--- Flash the installer onto the floppy in the drive. Two presses: the first
-- names the medium, the second writes it.
function nodes:installer(ctx)
  local flasher = ctx.kernel.flash
  if not flasher then
    return self:notify(ctx, "error", "The flasher is unavailable.")
  end
  local mediums = flasher:mediums()
  if #mediums == 0 then
    return self:notify(ctx, "warn", "Put a floppy in a disk drive first.")
  end

  local medium = mediums[1]
  if self.flashArmed ~= medium.address then
    self.flashArmed = medium.address
    return self:notify(ctx, "warn", string.format(
      "Press I again to write the installer to %s (%d KB free).",
      tostring(medium.address):sub(1, 8),
      math.floor(((medium.total or 0) - (medium.used or 0)) / 1024)))
  end

  self.flashArmed = nil
  local summary, reason = flasher:write(medium, {})
  if not summary then
    return self:notify(ctx, "error", "Installer not written: " .. tostring(reason))
  end
  return self:notify(ctx, "info", string.format(
    "Installer written to %s: %d files, %d KB.",
    tostring(medium.address):sub(1, 8), summary.files, math.floor(summary.bytes / 1024)))
end

function nodes:handle(ctx, name, a, b)  if name == "scroll" then
    local delta = (tonumber(b) or 0)
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
      return self:commitRename(ctx)
    elseif code == keys.back then
      self.buffer = self.buffer:sub(1, math.max(0, #self.buffer - 1))
      return true
    elseif type(char) == "string" and #char == 1 and char:match("[%w_%-]") then
      if #self.buffer < 24 then
        self.buffer = self.buffer .. char:lower()
      end
      return true
    end
    return true
  end

  if char == "r" then
    return self:startRename(ctx)
  elseif char == "p" then
    return self:ping(ctx)
  elseif char == "f" then
    return self:forget(ctx)
  elseif char == "i" then
    return self:installer(ctx)
  elseif code == keys.up then
    self.index = math.max(1, self.index - 1)
    return true
  elseif code == keys.down then
    self.index = self.index + 1
    return true
  elseif code == keys.pageUp then
    self.index = math.max(1, self.index - 6)
    return true
  elseif code == keys.pageDown then
    self.index = self.index + 6
    return true
  elseif code == keys.home then
    self.index = 1
    return true
  elseif code == keys["end"] then
    self.index = 999
    return true
  end
  self.forgetArmed = nil
  self.flashArmed = nil
  return false
end

function nodes:tick(ctx)
  local service = self:service(ctx)
  if not service then
    return false
  end
  local status = service:status()
  local signature = string.format("%d/%d/%d", status.received, status.online, #service.nodes)
  if self.signature ~= signature then
    self.signature = signature
    return true
  end
  return false
end

function nodes:close()
end

return nodes
