-- Rack nodes: discovered servers, provisioning, and the node registry.
--
-- The master owns the cluster service; this app is a window onto it. It can
-- arm the netboot installer, watch a node install, ping a silent server, rename
-- a node, and change its assigned role. Everything shown here comes from
-- /var/nodes.tsv and the live cluster state.

local keys = require("tc.keys")

local nodes = {}
nodes.__index = nodes

nodes.id = "nodes"
nodes.title = "Nodes"
nodes.short = "Nodes"
nodes.icon = "NOD"
nodes.iconArt = {
  "┌───────┐",
  "│ ███ • │",
  "│ ███ • │",
  "│ ███ • │",
  "└───────┘",
}
nodes.order = 7

local ROLES = { "worker", "storage", "node" }

local function kilobytes(value)
  local number = tonumber(value) or 0
  if number < 0 then
    number = 0
  end
  return number
end

local function humanKB(value)
  local number = kilobytes(value)
  if number >= 1048576 then
    return string.format("%.1fG", number / 1048576)
  elseif number >= 1024 then
    return string.format("%dM", math.floor(number / 1024 + 0.5))
  end
  return string.format("%dK", math.floor(number + 0.5))
end

local function stateColor(colors, state)
  if state == "online" then
    return colors.ok
  end
  return colors.dim
end

local function tail(value)
  local last
  for line in tostring(value or ""):gmatch("[^\r\n]+") do
    if line:match("%S") then
      last = line
    end
  end
  return last
end

local function clock(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

function nodes.create()
  local self = setmetatable({}, nodes)
  self.hits = {}
  self.selectedId = nil
  self.top = 0
  self.editor = nil
  self.editId = nil
  return self
end

function nodes:cluster(ctx)
  return ctx.kernel.cluster
end

function nodes:list(ctx)
  local cluster = self:cluster(ctx)
  return cluster and cluster:nodesList() or {}
end

function nodes:selectedIndex(ctx)
  local list = self:list(ctx)
  for index, node in ipairs(list) do
    if node.id == self.selectedId then
      return index, node
    end
  end
  if list[1] then
    self.selectedId = list[1].id
    return 1, list[1]
  end
  return nil, nil
end

function nodes:selected(ctx)
  local index, node = self:selectedIndex(ctx)
  local _ = index
  return node
end

-- Compact screens keep two summary rows and spend the rest on the node list.
-- Taller screens add an installer log row and two-line node cards.
function nodes:layout(ctx)
  local twoLine = ctx.h >= 12 and ctx.w >= 54
  local listTop = ctx.h >= 10 and 4 or 3
  local listBottom = ctx.h - 1
  local perNode = twoLine and 2 or 1
  local visible = math.max(1, math.floor((listBottom - listTop + 1) / perNode))
  return {
    twoLine = twoLine,
    listTop = listTop,
    listBottom = listBottom,
    perNode = perNode,
    visible = visible,
  }
end

function nodes:ensureVisible(ctx)
  local list = self:list(ctx)
  local layout = self:layout(ctx)
  local index = self:selectedIndex(ctx) or 1
  local top = self.top or 0

  if index <= top then
    top = index - 1
  elseif index > top + layout.visible then
    top = index - layout.visible
  end

  self.top = math.max(0, math.min(top, math.max(0, #list - layout.visible)))
end

function nodes:notify(ctx, level, message)
  ctx.ui:notify(level, message)
end

function nodes:prepare(ctx)
  local cluster = self:cluster(ctx)
  if not cluster then
    return self:notify(ctx, "error", "Cluster service is unavailable.")
  end

  local ok, message = cluster:prepareInstaller()
  if ok then
    self:notify(ctx, "info", message)
  else
    self:notify(ctx, "warn", tostring(message or "Could not prepare the installer."))
  end
end

function nodes:stop(ctx)
  local cluster = self:cluster(ctx)
  if not cluster then
    return self:notify(ctx, "error", "Cluster service is unavailable.")
  end

  local ok, message = cluster:stopInstaller()
  self:notify(ctx, ok and "warn" or "error", tostring(message))
end

function nodes:startRename(ctx)
  local node = self:selected(ctx)
  if not node then
    return self:notify(ctx, "warn", "Select a node first.")
  end

  self.editId = node.id
  self.editor = node.name
  return true
end

function nodes:commitRename(ctx)
  if not self.editor then
    return false
  end

  local cluster = self:cluster(ctx)
  local id = self.editId
  local name = self.editor
  self.editor = nil
  self.editId = nil

  if not cluster then
    return self:notify(ctx, "error", "Cluster service is unavailable.")
  end

  local ok, message = cluster:rename(id, name)
  if ok then
    self:notify(ctx, "info", tostring(message))
  else
    self:notify(ctx, "warn", tostring(message or "Could not rename the node."))
  end
  return true
end

function nodes:cancelRename()
  if not self.editor then
    return false
  end
  self.editor = nil
  self.editId = nil
  return true
end

function nodes:editKey(ctx, char, code)
  if code == keys.enter then
    return self:commitRename(ctx)
  elseif code == keys.tab then
    return self:cancelRename()
  elseif code == keys.back then
    self.editor = ctx.text.slice(self.editor, 1, math.max(0, ctx.text.width(self.editor) - 1))
    return true
  end

  if char and #char > 0 and not char:match("^%c$") then
    if ctx.text.width(self.editor) < 24 then
      self.editor = self.editor .. char
    end
    return true
  end
  return true
end

function nodes:cycleRole(ctx)
  local node = self:selected(ctx)
  if not node then
    return self:notify(ctx, "warn", "Select a node first.")
  end

  local cluster = self:cluster(ctx)
  if not cluster then
    return self:notify(ctx, "error", "Cluster service is unavailable.")
  end

  local nextRole = ROLES[1]
  for index, role in ipairs(ROLES) do
    if role == node.role then
      nextRole = ROLES[index % #ROLES + 1]
      break
    end
  end

  local ok, message = cluster:setRole(node.id, nextRole)
  if ok then
    self:notify(ctx, "info", tostring(message))
  else
    self:notify(ctx, "warn", tostring(message or "Could not change the role."))
  end
end

function nodes:ping(ctx)
  local node = self:selected(ctx)
  if not node then
    return self:notify(ctx, "warn", "Select a node first.")
  end

  local cluster = self:cluster(ctx)
  if not cluster then
    return self:notify(ctx, "error", "Cluster service is unavailable.")
  end

  local ok, message = cluster:ping(node.id)
  if ok then
    self:notify(ctx, "info", "Ping sent to " .. tostring(node.name) .. ".")
  else
    self:notify(ctx, "warn", tostring(message or "Could not ping the node."))
  end
end

function nodes:refresh(ctx)
  local cluster = self:cluster(ctx)
  if not cluster then
    return self:notify(ctx, "error", "Cluster service is unavailable.")
  end

  local ok, message = cluster:refreshNodes()
  if ok then
    self:notify(ctx, "info", tostring(message))
  else
    self:notify(ctx, "warn", tostring(message or "Could not refresh the nodes."))
  end
end

function nodes:armUpdate(ctx)
  local cluster = self:cluster(ctx)
  if not cluster then
    return self:notify(ctx, "error", "Cluster service is unavailable.")
  end

  local ok, message = cluster:armUpdate()
  if ok then
    self:notify(ctx, "info", tostring(message))
  else
    self:notify(ctx, "warn", tostring(message or "Could not arm the update."))
  end
end

function nodes:forget(ctx)
  local node = self:selected(ctx)
  if not node then
    return self:notify(ctx, "warn", "Select a node first.")
  end
  if node.state ~= "offline" then
    return self:notify(ctx, "warn", "Only offline nodes can be forgotten.")
  end

  local cluster = self:cluster(ctx)
  if not cluster then
    return self:notify(ctx, "error", "Cluster service is unavailable.")
  end

  local ok, message = cluster:forget(node.id)
  if ok then
    self.selectedId = nil
    self:notify(ctx, "info", tostring(message))
  else
    self:notify(ctx, "warn", tostring(message or "Could not forget the node."))
  end
end

function nodes:move(ctx, delta)
  local list = self:list(ctx)
  if #list == 0 then
    return false
  end

  local index = self:selectedIndex(ctx) or 1
  index = math.max(1, math.min(#list, index + delta))
  self.selectedId = list[index].id
  self:ensureVisible(ctx)
  return true
end

function nodes:drawInstaller(ctx, installer, row)
  local c = ctx.colors
  local v = ctx.view
  local update = self:cluster(ctx) and self:cluster(ctx):updateState() or nil

  if update and update.active and update.phase ~= "ready" then
    local label
    if update.phase == "checking" then
      label = "Checking for the latest release..."
    elseif update.phase == "downloading" then
      label = string.format(
        "Downloading %s %d/%d for the nodes",
        tostring(update.latest),
        update.files or 0,
        update.total or 0
      )
    else
      label = "Update running"
    end
    v:put(1, row, ctx.text.truncate(label, ctx.w), c.warn, c.deep)
    return
  end

  if update and update.active and update.phase == "ready" and update.remaining > 0
    and (not installer or not installer.active) then
    local label = string.format(
      "Update %s offered to %d node(s) · %s",
      tostring(update.target),
      update.sent or 0,
      clock(update.remaining)
    )
    v:put(1, row, ctx.text.truncate(label, ctx.w), c.warn, c.deep)
    return
  end

  if not installer or not installer.active then
    v:put(1, row, "Installer idle · Prepare to start", c.dim, c.deep)
    return
  end

  local who = installer.lastName and (" · " .. installer.lastName) or ""
  local label = string.format(
    "Installer armed %s · %d files%s",
    clock(installer.remaining),
    tonumber(installer.files) or 0,
    who
  )
  v:put(1, row, ctx.text.truncate(label, ctx.w), c.warn, c.deep)
end

function nodes:drawLog(ctx, installer, row)
  local c = ctx.colors
  local v = ctx.view

  if not installer or not installer.active then
    v:put(1, row, "Insert a floppy, then prepare the installer.", c.dim, c.deep)
    return
  end

  local line = tail(installer.log)
  if line then
    v:put(1, row, ctx.text.truncate("Log: " .. line, ctx.w), c.dim, c.deep)
  else
    v:put(1, row, "Waiting for a server to netboot...", c.dim, c.deep)
  end
end

function nodes:drawNode(ctx, node, selected, x, y, width, twoLine, servable)
  local c = ctx.colors
  local v = ctx.view

  local fg = selected and c.onSelected or c.text
  local bg = selected and c.selected or c.deep
  local detailFg = selected and c.onSelected or c.dim

  v:fill(1, y, ctx.w, twoLine and 2 or 1, " ", fg, bg)

  local marker = selected and ctx.glyphs.arrow or " "
  local state = tostring(node.state or "offline")
  local stateFg = selected and c.onSelected or stateColor(c, state)
  local right = state
  if width >= 40 then
    right = tostring(node.role or "worker") .. " · " .. state
  end

  local nameWidth = math.max(1, width - ctx.text.width(right) - 3)
  local name = ctx.text.truncate(tostring(node.name or node.id:sub(1, 8)), nameWidth)
  v:put(x, y, marker .. " " .. name, fg, bg)
  v:textRight(width, y, right, stateFg, bg)

  if twoLine then
    local version = ""
    if node.v and node.v ~= "" then
      version = " · v" .. tostring(node.v)
      if servable and node.v ~= servable then
        version = version .. " (update)"
      end
    end
    local detail = string.format(
      "%s · %s RAM · %s disk%s",
      tostring(node.role or "worker"),
      humanKB(node.mem),
      humanKB(node.disk),
      version
    )
    if width >= 66 and node.modem and node.modem ~= "" then
      detail = detail .. " · " .. tostring(node.modem):sub(1, 8)
    end
    v:put(2, y + 1, ctx.text.truncate(detail, width - 1), detailFg, bg)
  end
end

function nodes:drawEditor(ctx)
  local c = ctx.colors
  local v = ctx.view

  v:fill(1, ctx.h - 1, ctx.w, 1, " ", c.dim, c.panel)
  v:put(1, ctx.h - 1, "Enter saves · Tab cancels", c.text, c.panel)
  v:fill(1, ctx.h, ctx.w, 1, " ", c.onAccent, c.accent)
  v:put(1, ctx.h, ctx.text.truncate("Name: " .. self.editor .. "_", ctx.w), c.onAccent, c.accent)
end

function nodes:drawButtons(ctx, installer, node)
  local c = ctx.colors
  local v = ctx.view

  local lead = installer and installer.active and "Stop" or "Prepare"
  local actions = {
    { label = lead, method = lead == "Stop" and "stop" or "prepare" },
    { label = "Refresh", method = "refresh" },
    { label = "Update", method = "armUpdate" },
    { label = "Rename", method = "startRename" },
    { label = "Role", method = "cycleRole" },
    { label = "Ping", method = "ping" },
    { label = "Forget", method = "forget" },
  }

  local x = 1
  for _, action in ipairs(actions) do
    local label = " " .. action.label .. " "
    local width = ctx.text.width(label)
    if x + width - 1 > ctx.w then
      break
    end

    local method = action.method
    local enabled = true
    if method == "startRename" or method == "cycleRole" or method == "ping" then
      enabled = node ~= nil
    elseif method == "forget" then
      enabled = node ~= nil and node.state == "offline"
    end

    local fg, bg = c.onAccent, c.accent
    if not enabled then
      fg, bg = c.dim, c.panel
    else
      self.hits[#self.hits + 1] = {
        x = x,
        y = ctx.h,
        w = width,
        h = 1,
        method = method,
      }
    end
    v:put(x, ctx.h, label, fg, bg)
    x = x + width + 1
  end
end

function nodes:draw(ctx)
  local c = ctx.colors
  local v = ctx.view
  local cluster = self:cluster(ctx)
  local list = self:list(ctx)
  local layout = self:layout(ctx)
  local installer = cluster and cluster:installerState() or nil
  local summary = cluster and cluster:summary() or nil

  v:clear(" ", c.text, c.deep)
  self.hits = {}

  v:put(1, 1, "Rack nodes", c.accent, c.deep)
  local servable = cluster and select(2, cluster:serveTree()) or nil
  local stale = 0
  if servable then
    for _, node in ipairs(list) do
      if node.state == "online" and node.v and node.v ~= "" and node.v ~= servable then
        stale = stale + 1
      end
    end
  end
  if summary then
    local right = string.format("%d/%d up", summary.online, summary.total)
    local color = c.dim
    if summary.total > 0 then
      color = summary.online == summary.total and c.ok or c.warn
    end
    if stale > 0 then
      right = string.format("%s · %d to update", right, stale)
      color = c.warn
    end
    v:textRight(ctx.w, 1, right, color, c.deep)
  end

  if not cluster then
    v:put(1, 2, "Cluster service unavailable.", c.danger, c.deep)
  else
    self:drawInstaller(ctx, installer, 2)
    if layout.listTop > 3 then
      self:drawLog(ctx, installer, 3)
    end
  end

  self:selectedIndex(ctx)
  self:ensureVisible(ctx)

  if #list == 0 then
    local row = layout.listTop
    v:put(2, row, "No nodes registered yet.", c.text, c.deep)
    if row + 1 <= layout.listBottom then
      v:put(2, row + 1, "Prepare a floppy, then start each server.", c.dim, c.deep)
    end
    if row + 2 <= layout.listBottom then
      v:put(2, row + 2, "The installer window lasts ten minutes.", c.dim, c.deep)
    end
  else
    local first = (self.top or 0) + 1
    local last = math.min(#list, first + layout.visible - 1)
    for index = first, last do
      local node = list[index]
      local y = layout.listTop + (index - first) * layout.perNode
      self:drawNode(
        ctx,
        node,
        node.id == self.selectedId,
        1,
        y,
        ctx.w,
        layout.twoLine,
        servable
      )
    end
  end

  if self.editor then
    self:drawEditor(ctx)
  else
    self:drawButtons(ctx, installer, self:selected(ctx))
  end
end

function nodes:handleTouch(ctx, x, y)
  for _, hit in ipairs(self.hits) do
    if x >= hit.x and x < hit.x + hit.w and y >= hit.y and y < hit.y + hit.h then
      self[hit.method](self, ctx)
      return true
    end
  end

  local layout = self:layout(ctx)
  if y >= layout.listTop and y <= layout.listBottom then
    local offset = math.floor((y - layout.listTop) / layout.perNode)
    local index = (self.top or 0) + offset + 1
    local node = self:list(ctx)[index]
    if node then
      self.selectedId = node.id
      self:ensureVisible(ctx)
      return true
    end
  end

  return false
end

function nodes:handle(ctx, name, a, b, c)
  if name == "touch" then
    return self:handleTouch(ctx, a, b)
  end

  if name == "scroll" then
    return self:move(ctx, (tonumber(c) or 0) > 0 and -1 or 1)
  end

  if name ~= "key" then
    return false
  end

  local char, code = a, b
  if self.editor then
    return self:editKey(ctx, char, code)
  end

  local layout = self:layout(ctx)
  if code == keys.up then
    return self:move(ctx, -1)
  elseif code == keys.down then
    return self:move(ctx, 1)
  elseif code == keys.pageUp then
    return self:move(ctx, -layout.visible)
  elseif code == keys.pageDown then
    return self:move(ctx, layout.visible)
  elseif code == keys.home then
    local list = self:list(ctx)
    if list[1] then
      self.selectedId = list[1].id
      self:ensureVisible(ctx)
      return true
    end
  elseif code == keys["end"] then
    local list = self:list(ctx)
    if list[#list] then
      self.selectedId = list[#list].id
      self:ensureVisible(ctx)
      return true
    end
  end

  if char == "p" then
    self:prepare(ctx)
    return true
  elseif char == "s" then
    self:stop(ctx)
    return true
  elseif char == "f" then
    self:refresh(ctx)
    return true
  elseif char == "u" then
    self:armUpdate(ctx)
    return true
  elseif char == "r" then
    self:startRename(ctx)
    return true
  elseif char == "o" then
    self:cycleRole(ctx)
    return true
  elseif char == "g" then
    self:ping(ctx)
    return true
  elseif char == "x" then
    self:forget(ctx)
    return true
  end

  return false
end

return nodes
