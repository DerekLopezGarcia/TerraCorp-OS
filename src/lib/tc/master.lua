-- Master side of the line nodes: the node registry is the DNS.
--
-- A line node publishes its status; the master keeps the table of names, assigns
-- the one a node must use, marks a silent node offline and merges what it
-- publishes into a view keyed by path. The registry in `/var/nodes.tsv` is the
-- table the Nodes app shows and edits (decision 26), so this module never keeps
-- a second copy of a name.
--
-- There is no token handshake: the wired modem bus is the boundary, and the
-- installer window that needed a token went with the racks.

local net = require("tc.net")
local naming = require("tc.naming")
local registry = require("tc.registry")

local master = {}
master.__index = master

master.STALE_AFTER = 30

function master.new(options)
  options = options or {}
  local self = setmetatable({}, master)
  self.kernel = options.kernel
  self.vfs = options.vfs
  self.log = options.log
  self.config = options.config
  self.version = options.version or {}
  self.computer = options.computer or computer
  self.component = options.component or component
  self.modem = options.modem or net.newModem({
    component = self.component,
    computer = self.computer,
  })
  self.staleAfter = options.staleAfter or master.STALE_AFTER
  self.nodes = {}
  self.detail = {}
  self.opened = false
  self.received = 0
  self.assigned = 0
  self.lastSave = nil
  return self
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function master:start()
  self.nodes = registry.load(self.vfs)
  -- A reboot invalidates the previous session's uptime: nobody is online yet.
  for _, node in ipairs(self.nodes) do
    node.state = "offline"
    node.lastSeen = 0
  end

  local opened, reason = self.modem:open()
  self.opened = opened == true
  if not self.opened and self.log and self.log.warn then
    self.log:warn("master: no network card (" .. tostring(reason) .. ")")
  end
  return self.opened
end

function master:address()
  return self.computer.address()
end

function master:close()
  if self.modem then
    self.modem:close()
  end
end

function master:save()
  local ok, reason = registry.save(self.vfs, self.nodes)
  if not ok and self.log and self.log.warn then
    self.log:warn("master: could not save the registry: " .. tostring(reason))
  end
  return ok, reason
end

function master:node(id)
  return registry.find(self.nodes, id)
end

--------------------------------------------------------------------------------
-- Names
--------------------------------------------------------------------------------

--- The first free name: the proposal when it is free, else the first free
-- numeric suffix. Two nodes can never share a name, because a shared name would
-- merge two lines' stocks into one branch of the namespace.
function master:uniqueName(proposed, id)
  local base = naming.normalise(proposed) or naming.provisional(id) or "nodo"
  local candidate = base
  local index = 1
  while true do
    local taken = false
    for _, node in ipairs(self.nodes) do
      if node.name == candidate and node.id ~= id then
        taken = true
        break
      end
    end
    if not taken then
      return candidate
    end
    index = index + 1
    local suffix = "-" .. index
    candidate = base:sub(1, math.max(1, naming.MAX_NAME - #suffix)) .. suffix
  end
end

--- The master's own files that mention a name. Shown before a rename, so the
--- operator sees what the new prefix will orphan.
function master:references(name)
  if type(name) ~= "string" or name == "" then
    return {}
  end
  local needle = name .. "/"
  local hits = {}
  local files = {
    "/etc/plant.tsv",
    "/etc/stocks.tsv",
    "/etc/paths.tsv",
    "/etc/recipes.tsv",
    "/etc/recipe-io.tsv",
  }
  local lines = self.vfs.exists("/etc/lines") and self.vfs.list("/etc/lines") or {}
  for _, entry in ipairs(lines or {}) do
    local file = tostring(entry)
    if file:sub(-5) == ".line" then
      files[#files + 1] = "/etc/lines/" .. file
    end
  end
  for _, path in ipairs(files) do
    local text = self.vfs.read(path)
    if type(text) == "string" and text:find(needle, 1, true) then
      hits[#hits + 1] = path
    end
  end
  return hits
end

function master:assign(node, name, remote)
  local target = (type(remote) == "string" and remote ~= "") and remote or node.modem
  if type(target) ~= "string" or target == "" then
    return nil, "no route to the node"
  end
  local ok, reason = self.modem:send(target, "ASSIGN", {
    id = node.id,
    name = name,
    role = "line",
    master = self:address(),
    masterId = self:address(),
    -- The frame contract still requires a token and refuses an empty one. There
    -- is no token handshake left: the wired bus is the boundary.
    token = "none",
  })
  if ok then
    self.assigned = self.assigned + 1
  elseif self.log and self.log.warn then
    self.log:warn("master: could not assign " .. tostring(name) .. ": " .. tostring(reason))
  end
  return ok, reason
end

--- Rename a node from the app. The node adopts the name on its next contact.
-- Returns the outcome plus the master files that still mention the old prefix.
function master:rename(id, name)
  local node = self:node(id)
  if not node then
    return nil, "unknown_node"
  end
  local normalised = naming.normalise(name)
  if not normalised then
    return nil, "invalid_name"
  end
  if normalised == node.name then
    return { name = normalised, unchanged = true, references = {} }
  end
  for _, other in ipairs(self.nodes) do
    if other.id ~= id and other.name == normalised then
      return nil, "name_taken"
    end
  end

  local references = self:references(node.name)
  local previous = node.name
  node.name = normalised
  self:save()
  local assigned = self:assign(node, normalised, node.modem)
  if self.log and self.log.info then
    self.log:info(string.format("master: %s renamed %s -> %s", tostring(id):sub(1, 8),
      tostring(previous), normalised))
  end
  return {
    name = normalised,
    previous = previous,
    assigned = assigned == true,
    references = references,
  }
end

function master:forget(id)
  local removed = registry.remove(self.nodes, id)
  if not removed then
    return nil, "unknown_node"
  end
  self.detail[id] = nil
  self:save()
  return removed
end

function master:ping(id)
  local node = self:node(id)
  if not node then
    return nil, "unknown_node"
  end
  local ok, reason = self.modem:send(node.modem or id, "PING", { id = id })
  return ok, reason
end

--- Push one configuration file to a node. The node checks the name against its
-- own whitelist, writes it and reloads, then answers with a CFGACK.
function master:sendConfig(id, file, body)
  local node = self:node(id)
  if not node then
    return nil, "unknown_node"
  end
  if type(file) ~= "string" or file == "" then
    return nil, "invalid_file"
  end
  if type(body) ~= "string" or body == "" then
    return nil, "empty_body"
  end
  -- The frame limit is 1 KB and the body travels inside it: a file that cannot
  -- fit is refused here instead of being truncated on the wire.
  if #body > 700 then
    return nil, "config_too_large"
  end
  return self.modem:send(node.modem or id, "CFG", {
    id = id,
    file = file,
    body = body,
  })
end

--------------------------------------------------------------------------------
-- Frames from the nodes
--------------------------------------------------------------------------------

--- Unpack the stock fields a node publishes: `s1..s8` as `path:total:state:rate`.
local function unpackStocks(fields, nodeName)
  local stocks = {}
  for index = 1, 8 do
    local value = fields["s" .. index]
    if type(value) == "string" and value ~= "" then
      local name, total, state, rate = value:match("^([^:]+):([^:]+):([^:]+):(.*)$")
      if name then
        stocks[#stocks + 1] = {
          name = name,
          total = tonumber(total) or 0,
          state = state,
          rate = tonumber(rate),
          foreign = not naming.rooted(nodeName, name),
        }
      end
    end
  end
  return stocks
end

--- Handle one modem signal. Returns true when the frame belonged to the master.
function master:handle(name, remote, port, broadcast, message)
  if name ~= "modem_message" then
    return false
  end
  if tonumber(port) ~= net.PORT then
    return false
  end
  local verb, fields = net.decode(message)
  if not verb then
    return false
  end
  if verb == "CFGACK" then
    local node = self:node(fields.id)
    if not node then
      return false
    end
    node.configState = fields.state
    node.configFile = fields.file
    node.lastSeen = self.computer.uptime()
    self.received = self.received + 1
    return true
  end
  if verb ~= "HELLO" and verb ~= "STATUS" and verb ~= "PING" then
    return false
  end
  if type(fields.id) ~= "string" or fields.id == "" or fields.id == self:address() then
    return false
  end

  local now = self.computer.uptime()
  local existing = self:node(fields.id)
  local proposed = naming.normalise(fields.name or "")
  local nodeName
  if existing then
    nodeName = existing.name
  else
    nodeName = self:uniqueName(proposed or fields.id, fields.id)
  end

  local node = registry.upsert(self.nodes, {
    id = fields.id,
    name = nodeName,
    role = "line",
    modem = remote,
    state = "online",
    mem = fields.mem,
    disk = fields.disk,
    lastSeen = now,
    v = fields.v,
    stocks = fields.stocks,
    alarms = fields.alarm and 1 or 0,
    uptime = fields.uptime,
  })
  node.alarm = fields.alarm or ""
  node.alarmPath = fields.alarmPath or ""
  node.detail = unpackStocks(fields, nodeName)
  self.detail[fields.id] = node.detail
  self.received = self.received + 1

  if verb == "PING" then
    self.modem:send(remote, "PONG", { id = fields.id, state = "online" })
  elseif verb == "HELLO" or (proposed and proposed ~= nodeName) then
    -- A new node needs its name; a node whose local name disagrees gets the
    -- master's, which is the rule the operator chose.
    self:assign(node, nodeName, remote)
  end

  self:save()
  return true
end

--------------------------------------------------------------------------------
-- Views
--------------------------------------------------------------------------------

--- Mark silent nodes offline. Returns true when something changed.
function master:tick()
  local now = self.computer.uptime()
  local changed = false
  for _, node in ipairs(self.nodes) do
    if node.state == "online" and now - (node.lastSeen or 0) > self.staleAfter then
      node.state = "offline"
      changed = true
      if self.log and self.log.info then
        self.log:info("master: " .. tostring(node.name) .. " went offline")
      end
    end
  end
  if changed then
    self:save()
  end
  return changed
end

--- The merged view: one row per node, and every stock keyed by its full path, so
-- the planner and the thresholds on the master speak the same strings the node
-- publishes.
function master:snapshot()
  local now = self.computer.uptime()
  local view = { nodes = {}, stocks = {}, online = 0, offline = 0, at = now }
  for _, node in ipairs(self.nodes) do
    local online = node.state == "online"
    if online then
      view.online = view.online + 1
    else
      view.offline = view.offline + 1
    end
    view.nodes[#view.nodes + 1] = {
      id = node.id,
      name = node.name,
      state = node.state,
      age = online and math.max(0, now - (node.lastSeen or now)) or nil,
      v = node.v,
      stocks = node.stocks or 0,
      alarm = node.alarm or "",
      alarmPath = node.alarmPath or "",
      uptime = node.uptime or 0,
      port = node.modem or "",
    }
    for _, stock in ipairs(self.detail[node.id] or {}) do
      view.stocks[#view.stocks + 1] = {
        node = node.name,
        name = naming.qualify(node.name, stock.name),
        total = stock.total,
        state = (not online and "offline") or (stock.foreign and "foreign") or stock.state,
        rate = stock.rate,
        foreign = stock.foreign == true,
      }
    end
  end
  table.sort(view.nodes, function(a, b)
    return tostring(a.name) < tostring(b.name)
  end)
  table.sort(view.stocks, function(a, b)
    return tostring(a.name) < tostring(b.name)
  end)
  return view
end

function master:status()
  local online = 0
  for _, node in ipairs(self.nodes) do
    if node.state == "online" then
      online = online + 1
    end
  end
  return {
    nodes = #self.nodes,
    online = online,
    offline = #self.nodes - online,
    opened = self.opened,
    received = self.received,
    assigned = self.assigned,
    staleAfter = self.staleAfter,
  }
end

return master
