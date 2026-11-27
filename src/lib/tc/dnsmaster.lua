-- DNS1 master: the merged catalog and the request relay.
--
-- The master keeps complete node snapshots assembled from PUBLISH parts. It
-- answers CATALOG and DESCRIBE from that cache and forwards EXEC to the node;
-- it never executes component methods itself.
--
-- M1 adds three things to the M0 spike:
--
--   * deltas: a node sends its index plus only the endpoint parts whose
--     revision changed, and the master asks for a full snapshot (`need=full`)
--     when it has no base to apply the delta to;
--   * persistence: complete snapshots are written to /var/dns, so a desktop
--     reboot does not empty the catalog; loaded entries stay marked stale until
--     the node republishes;
--   * catalog totals: CATALOG pages carry `total` and the page size alongside
--     the `next` cursor.
--
-- A node that still speaks the M0 PUBLISH shape has no `full` field; the
-- master treats its index as a full snapshot, which is exactly what M0 sent.

local value = require("tc.value")

local dnsmaster = {}

dnsmaster.PROTOCOL = "DNS1"
dnsmaster.DESCRIBE_PROTO = 2
dnsmaster.STALE_AFTER = 90
dnsmaster.MAX_NODES = 64
dnsmaster.MAX_PAGE = 32
dnsmaster.DEFAULT_PAGE = 8
dnsmaster.EXEC_TIMEOUT = 5
dnsmaster.SAVE_INTERVAL = 2
dnsmaster.STATE_DIR = "/var/dns"

local function nowOf(self)
  if self.computer and type(self.computer.uptime) == "function" then
    local ok, current = pcall(self.computer.uptime, self.computer)
    if ok and type(current) == "number" then
      return current
    end
  end
  return os.time()
end

local master = {}
master.__index = master

local function safeName(id)
  return (tostring(id):gsub("[^%w%-_]", "_"))
end

function dnsmaster.new(opts)
  opts = opts or {}
  local self = setmetatable({}, master)
  self.id = opts.id or "master"
  self.ver = opts.ver or 1
  self.boot = tostring(opts.boot or os.time())
  self.computer = opts.computer or computer
  self.transport = opts.transport
  self.log = opts.log
  self.vfs = opts.vfs
  self.stateDir = opts.stateDir or dnsmaster.STATE_DIR
  self.staleAfter = opts.staleAfter or dnsmaster.STALE_AFTER
  self.saveInterval = opts.saveInterval or dnsmaster.SAVE_INTERVAL
  self.cache = {}
  self.pending = {}
  self.warned = {}
  self.started = nowOf(self)
  self.lastSave = self.started
  self.saveDirty = false
  self.loaded = 0
  self.loadError = nil
  self.stats = { published = 0, full = 0, delta = 0, heartbeat = 0, resync = 0, saved = 0, loaded = 0 }
  self:load()
  return self
end

function master:now()
  return nowOf(self)
end

function master:entries()
  return self.cache
end

function master:publishStats()
  return self.stats
end

local function staleFor(self, entry, now)
  return (now - entry.lastSeen) > self.staleAfter
end

function master:statePath(id)
  return self.stateDir .. "/" .. safeName(id) .. ".value"
end

local function removeFile(self, id)
  if self.vfs and type(self.vfs.remove) == "function" then
    pcall(self.vfs.remove, self.statePath(id))
  end
end

local function removeEntry(self, id)
  self.cache[id] = nil
  removeFile(self, id)
  self.saveDirty = true
end

local function trim(self)
  local count = 0
  for _ in pairs(self.cache) do
    count = count + 1
  end
  while count > dnsmaster.MAX_NODES do
    local oldestId, oldestSeen
    for id, entry in pairs(self.cache) do
      if not oldestSeen or entry.lastSeen < oldestSeen then
        oldestId, oldestSeen = id, entry.lastSeen
      end
    end
    if not oldestId then
      break
    end
    removeEntry(self, oldestId)
    count = count - 1
  end
end

local function endpointNames(index)
  local names = {}
  if type(index) == "table" and type(index.endpoints) == "table" then
    for _, endpoint in ipairs(index.endpoints) do
      if type(endpoint) == "table" and type(endpoint.name) == "string" then
        names[#names + 1] = endpoint.name
      end
    end
  end
  return names
end

local function pathNames(index)
  local names = {}
  if type(index) == "table" and type(index.paths) == "table" then
    for _, path in ipairs(index.paths) do
      if type(path) == "table" and type(path.name) == "string" then
        names[#names + 1] = path.name
      end
    end
  end
  table.sort(names)
  return names
end

local function endpointMap(index)
  local map = {}
  if type(index) == "table" and type(index.endpoints) == "table" then
    for _, endpoint in ipairs(index.endpoints) do
      if type(endpoint) == "table" and type(endpoint.name) == "string" then
        map[endpoint.name] = endpoint
      end
    end
  end
  return map
end

local function publishAck(self, fields, ok, code, need)
  local result = {
    rid = fields.rid,
    id = self.id,
    ver = fields.ver,
    ok = ok and "true" or "false",
  }
  if fields.part then
    result.part = fields.part
  end
  if code then
    result.err = code
  end
  if need then
    result.need = need
  end
  return "PUBLISHACK", result
end

local function touch(self, entry, side, from, now)
  entry.lastSeen = now
  entry.side = side or entry.side
  entry.from = from or entry.from
end

local function applyIndex(self, entry, body, version, boot, side, from, full, now)
  local reset = full or entry.boot ~= boot
  local wasComplete = entry.complete and not reset

  if reset then
    entry.parts = {}
    entry.partRevs = {}
    entry.pending = {}
    entry.complete = false
  end

  entry.index = body
  entry.ver = version
  entry.boot = boot
  entry.name = body.node and body.node.name or entry.name
  entry.loaded = false
  touch(self, entry, side, from, now)

  local present = {}
  local changed = false
  for _, summary in ipairs(body.endpoints or {}) do
    if type(summary) == "table" and type(summary.name) == "string" then
      present[summary.name] = true
      local rev = tonumber(summary.rev) or 0
      if reset or not entry.parts[summary.name]
        or (entry.partRevs[summary.name] or -1) ~= rev then
        entry.pending[summary.name] = true
        changed = true
      end
    end
  end

  -- Drop endpoints the node removed. A pending part that is no longer present
  -- must not keep the snapshot incomplete forever.
  for name in pairs(entry.parts) do
    if not present[name] then
      entry.parts[name] = nil
      entry.partRevs[name] = nil
      entry.pending[name] = nil
    end
  end
  for name in pairs(entry.pending) do
    if not present[name] then
      entry.pending[name] = nil
    end
  end

  -- A delta can arrive while an earlier full publish is still in flight. Keep
  -- any part already expected and not yet received.
  entry.complete = next(entry.pending) == nil
  if self.stats then
    if full then
      self.stats.full = self.stats.full + 1
    elseif wasComplete and not changed then
      -- An unchanged index-only publish is the node's heartbeat.
      self.stats.heartbeat = self.stats.heartbeat + 1
    else
      self.stats.delta = self.stats.delta + 1
    end
  end
  self.saveDirty = true
  return entry
end

local function handlePublish(self, side, from, fields)
  local version = tonumber(fields.ver)
  local body, code = value.decode(fields.p)
  if not version or code or type(body) ~= "table" then
    return publishAck(self, fields, false, "bad_value")
  end

  local part = fields.part
  local now = self:now()

  if part == "index" then
    local nodeBody = body.node
    if type(nodeBody) ~= "table" or type(nodeBody.id) ~= "string"
      or nodeBody.id == "" then
      return publishAck(self, fields, false, "bad_args")
    end
    local id = nodeBody.id
    if fields.id and fields.id ~= "" and fields.id ~= id then
      return publishAck(self, fields, false, "bad_args")
    end
    local boot = tostring(nodeBody.boot or "")
    local entry = self.cache[id]

    -- M0 nodes do not send `full`; their index is a full snapshot.
    local full = fields.full == "true" or fields.full == true or fields.full == nil

    if body.v == nil or tonumber(body.v) ~= version then
      return publishAck(self, fields, false, "bad_value")
    end
    if entry and entry.boot ~= boot and not full then
      return publishAck(self, fields, true, nil, "full")
    end
    if not entry and not full then
      return publishAck(self, fields, true, nil, "full")
    end
    if entry and not full
      and (not entry.index or not entry.complete or entry.boot ~= boot) then
      return publishAck(self, fields, true, nil, "full")
    end
    if entry and not full and version < entry.ver then
      -- A late delta from an older snapshot must not roll the catalog back.
      touch(self, entry, side, from, now)
      return publishAck(self, fields, true)
    end

    if not entry then
      entry = {
        id = id,
        index = nil,
        parts = {},
        partRevs = {},
        pending = {},
        complete = false,
        ver = version,
        boot = boot,
        name = id,
        lastSeen = now,
        side = side,
        from = from,
      }
      self.cache[id] = entry
      trim(self)
    end

    applyIndex(self, entry, body, version, boot, side, from, full, now)
    self.stats.published = self.stats.published + 1
    return publishAck(self, fields, true)
  end

  local endpointName = tostring(part):match("^endpoint:(.+)$")
  if not endpointName then
    return publishAck(self, fields, false, "bad_args")
  end
  local id = fields.id
  if type(id) ~= "string" or id == "" then
    return publishAck(self, fields, false, "bad_args")
  end
  local entry = self.cache[id]
  if not entry or not entry.index then
    return publishAck(self, fields, true, nil, "full")
  end

  local rev = tonumber(body.rev) or tonumber(fields.rev) or 0
  if entry.pending[endpointName] then
    entry.parts[endpointName] = body
    entry.partRevs[endpointName] = rev
    entry.pending[endpointName] = nil
    entry.complete = next(entry.pending) == nil
    touch(self, entry, side, from, now)
    self.saveDirty = true
    return publishAck(self, fields, true)
  end

  if entry.parts[endpointName] then
    if (entry.partRevs[endpointName] or 0) == rev then
      touch(self, entry, side, from, now)
      return publishAck(self, fields, true)
    end
    return publishAck(self, fields, true, nil, "full")
  end

  -- The part is not in the current index, or the index never reached us.
  return publishAck(self, fields, true, nil, "full")
end

function master:catalog(cursor, page)
  local now = self:now()
  page = tonumber(page) or dnsmaster.DEFAULT_PAGE
  page = math.max(1, math.min(dnsmaster.MAX_PAGE, math.floor(page)))

  local ids = {}
  for id, entry in pairs(self.cache) do
    if entry.complete and entry.index then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)

  local start = 1
  if cursor and cursor ~= "" and cursor ~= "-" then
    for index, id in ipairs(ids) do
      if id > cursor then
        start = index
        break
      end
      start = index + 1
    end
  end

  local nodes, staleAny = {}, false
  local last = math.min(#ids, start + page - 1)
  for index = start, last do
    local id = ids[index]
    local entry = self.cache[id]
    local stale = staleFor(self, entry, now)
    staleAny = staleAny or stale
    nodes[#nodes + 1] = {
      id = id,
      name = entry.name or id,
      ver = entry.ver,
      boot = entry.boot,
      lastSeen = entry.lastSeen,
      stale = stale,
      loaded = entry.loaded == true,
      endpoints = endpointNames(entry.index),
      paths = pathNames(entry.index),
    }
  end

  local nextCursor
  if last < #ids then
    nextCursor = ids[last]
  end
  return {
    nodes = nodes,
    next = nextCursor or "-",
    stale = staleAny,
    total = #ids,
    page = page,
    count = #nodes,
  }
end

function master:describe(id, target)
  local entry = self.cache[id]
  if not entry or not entry.complete or not entry.index then
    return nil, "offline"
  end
  if target == "node" or target == nil then
    return entry.index
  end
  local endpoint = target:match("^endpoint:(.+)$")
  if endpoint then
    local part = entry.parts[endpoint]
    if not part then
      return nil, "unknown_target"
    end
    return part
  end
  local path = target:match("^path:(.+)$")
  if path then
    for _, item in ipairs(entry.index.paths or {}) do
      if item.name == path then
        return item
      end
    end
    return nil, "unknown_target"
  end
  return nil, "unknown_target"
end

local function describeAck(self, fields, body, code)
  if code then
    return "DESCRIBEACK", {
      rid = fields.rid,
      id = self.id,
      ok = "false",
      err = code,
    }
  end
  local text, encodeCode = value.encode(body)
  if not text then
    return "DESCRIBEACK", {
      rid = fields.rid,
      id = self.id,
      ok = "false",
      err = encodeCode,
    }
  end
  return "DESCRIBEACK", {
    rid = fields.rid,
    id = self.id,
    ok = "true",
    body = text,
  }
end

local function handleDescribe(self, fields)
  local nodeId = fields.node
  local target = fields.target or "node"
  if not nodeId or nodeId == "" or nodeId == self.id then
    local prefixId, rest = target:match("^node:([^:]+):(.*)$")
    if prefixId then
      nodeId, target = prefixId, rest
    else
      prefixId, rest = target:match("^node:([^:]+)$")
      if prefixId then
        nodeId, target = prefixId, "node"
      end
    end
  end
  if not nodeId or nodeId == "" then
    return describeAck(self, fields, nil, "unknown_target")
  end
  local body, code = self:describe(nodeId, target)
  return describeAck(self, fields, body, code)
end

local function handleCatalog(self, fields)
  local body = self:catalog(fields.cursor, fields.page)
  local text, code = value.encode(body)
  if not text then
    return "CATALOGACK", {
      rid = fields.rid,
      id = self.id,
      body = "nil",
      stale = "true",
      next = "-",
      total = "0",
      err = code,
    }
  end
  return "CATALOGACK", {
    rid = fields.rid,
    id = self.id,
    body = text,
    stale = body.stale and "true" or "false",
    next = body.next,
    total = tostring(body.total),
  }
end

local function findNodeForExec(self, fields)
  local nodeId = fields.node
  if nodeId and nodeId ~= "" and nodeId ~= self.id then
    return nodeId, fields.target
  end
  local prefix, rest = (fields.target or ""):match("^node:([^:]+):(.+)$")
  if prefix then
    return prefix, rest
  end
  return nil, fields.target
end

local function handleExec(self, side, from, fields)
  local nodeId, target = findNodeForExec(self, fields)
  local entry = nodeId and self.cache[nodeId]
  if not entry or not entry.complete then
    return "EXECACK", {
      rid = fields.rid,
      id = self.id,
      ok = "false",
      err = "offline",
    }
  end
  if not self.transport then
    return "EXECACK", {
      rid = fields.rid,
      id = self.id,
      ok = "false",
      err = "offline",
    }
  end

  self.pending[fields.rid] = {
    from = from,
    side = side,
    at = self:now(),
    node = nodeId,
    kind = "EXEC",
  }
  local forward = {
    rid = fields.rid,
    id = self.id,
    target = target,
    method = fields.method,
  }
  if fields.p then
    forward.p = fields.p
  end
  local ok, reason = self.transport:send(nodeId, "EXEC", forward)
  if not ok then
    self.pending[fields.rid] = nil
    return "EXECACK", {
      rid = fields.rid,
      id = self.id,
      ok = "false",
      err = "offline",
    }
  end
  return nil
end

local function handleExecAck(self, fields, from)
  local pending = self.pending[fields.rid]
  if not pending then
    return nil
  end
  self.pending[fields.rid] = nil
  if self.transport then
    local relay = {}
    for key, item in pairs(fields) do
      relay[key] = item
    end
    relay.id = self.id
    local ok, reason = self.transport:send(pending.from, "EXECACK", relay)
    if not ok and self.log and type(self.log.warn) == "function" then
      self.log.warn("DNS1 master: could not relay EXECACK: " .. tostring(reason))
    end
  end
  return nil
end

local function handleEdit(self, side, from, fields)
  local nodeId, target = findNodeForExec(self, fields)
  local entry = nodeId and self.cache[nodeId]
  if not entry or not entry.complete or not self.transport then
    return "EDITACK", {
      rid = fields.rid,
      id = self.id,
      ok = "false",
      err = "offline",
    }
  end
  if type(fields.field) ~= "string" or type(fields.rev) ~= "string" then
    return "EDITACK", {
      rid = fields.rid,
      id = self.id,
      ok = "false",
      err = "bad_args",
    }
  end

  self.pending[fields.rid] = {
    from = from,
    side = side,
    at = self:now(),
    node = nodeId,
    kind = "EDIT",
  }
  local forward = {
    rid = fields.rid,
    id = self.id,
    target = target,
    field = fields.field,
    rev = fields.rev,
  }
  if fields.p then
    forward.p = fields.p
  end
  local ok, reason = self.transport:send(nodeId, "EDIT", forward)
  if not ok then
    self.pending[fields.rid] = nil
    return "EDITACK", {
      rid = fields.rid,
      id = self.id,
      ok = "false",
      err = "offline",
    }
  end
  return nil
end

local function handleEditAck(self, fields, from)
  local pending = self.pending[fields.rid]
  if not pending then
    return nil
  end
  self.pending[fields.rid] = nil
  if self.transport then
    local relay = {}
    for key, item in pairs(fields) do
      relay[key] = item
    end
    relay.id = self.id
    local ok, reason = self.transport:send(pending.from, "EDITACK", relay)
    if not ok and self.log and type(self.log.warn) == "function" then
      self.log.warn("DNS1 master: could not relay EDITACK: " .. tostring(reason))
    end
  end
  return nil
end

function master:onFrame(side, from, verb, fields)
  if verb == "PUBLISH" then
    return handlePublish(self, side, from, fields)
  elseif verb == "CATALOG" then
    return handleCatalog(self, fields)
  elseif verb == "DESCRIBE" then
    return handleDescribe(self, fields)
  elseif verb == "EXEC" then
    return handleExec(self, side, from, fields)
  elseif verb == "EXECACK" then
    return handleExecAck(self, fields, from)
  elseif verb == "EDIT" then
    return handleEdit(self, side, from, fields)
  elseif verb == "EDITACK" then
    return handleEditAck(self, fields, from)
  elseif verb == "WHO" then
    return "WHOACK", {
      rid = fields.rid,
      id = self.id,
      node = self.id,
      name = "master",
      proto = dnsmaster.PROTOCOL,
      ver = dnsmaster.DESCRIBE_PROTO,
      boot = self.boot,
      role = "master",
    }
  elseif verb == "HELLO" then
    return "HELLOACK", {
      rid = fields.rid,
      id = self.id,
      node = "master",
      proto = dnsmaster.PROTOCOL,
      ver = dnsmaster.DESCRIBE_PROTO,
      boot = self.boot,
      transports = self.transport and self.transport:transports() or "wired",
      role = "master",
    }
  end
  return nil
end

function master:save(now)
  if not self.vfs or type(self.vfs.write) ~= "function" then
    return false
  end
  now = now or self:now()
  if type(self.vfs.ensureDir) == "function" then
    local ok, reason = self.vfs.ensureDir(self.stateDir)
    if not ok then
      if self.log and type(self.log.warn) == "function" then
        self.log.warn("DNS1 master: cannot create " .. self.stateDir .. ": " ..
          tostring(reason))
      end
      return false
    end
  end

  local written = 0
  for id, entry in pairs(self.cache) do
    if entry.complete and entry.index then
      local body = {
        index = entry.index,
        parts = entry.parts,
        partRevs = entry.partRevs,
        age = math.max(0, now - entry.lastSeen),
      }
      local text, code = value.encode(body)
      if text then
        local ok, reason = self.vfs.write(self:statePath(id), text)
        if ok then
          written = written + 1
        elseif self.log and type(self.log.warn) == "function" then
          self.log.warn("DNS1 master: could not save " .. id .. ": " .. tostring(reason))
        end
      elseif not self.warned["save:" .. id] then
        self.warned["save:" .. id] = true
        if self.log and type(self.log.warn) == "function" then
          self.log.warn("DNS1 master: snapshot for " .. id ..
            " is too large to persist: " .. tostring(code))
        end
      end
    end
  end

  self.lastSave = now
  self.saveDirty = false
  self.stats.saved = written
  return true
end

function master:load()
  if not self.vfs or type(self.vfs.list) ~= "function" then
    return 0
  end
  local names, listError = self.vfs.list(self.stateDir)
  if not names then
    self.loadError = listError
    return 0
  end

  local now = self:now()
  local loaded = 0
  for _, name in ipairs(names) do
    if type(name) == "string" and name:match("%.value$") then
      local text = self.vfs.read(self.stateDir .. "/" .. name)
      if text then
        local body, code = value.decode(text)
        if not code and type(body) == "table" and type(body.index) == "table"
          and type(body.parts) == "table" then
          local index = body.index
          local node = index.node
          if type(node) == "table" and type(node.id) == "string"
            and node.id ~= "" and safeName(node.id) .. ".value" == name then
            local complete = true
            for _, summary in ipairs(index.endpoints or {}) do
              if type(summary) ~= "table" or type(summary.name) ~= "string"
                or type(body.parts[summary.name]) ~= "table" then
                complete = false
                break
              end
            end
            if complete then
              local partRevs = {}
              for endpointName, part in pairs(body.parts) do
                partRevs[endpointName] = tonumber(part.rev) or 0
              end
              for endpointName, rev in pairs(body.partRevs or {}) do
                partRevs[endpointName] = tonumber(rev) or partRevs[endpointName] or 0
              end
              local age = tonumber(body.age) or (self.staleAfter + 1)
              self.cache[node.id] = {
                id = node.id,
                index = index,
                parts = body.parts,
                partRevs = partRevs,
                pending = {},
                complete = true,
                ver = tonumber(index.v) or 0,
                boot = tostring(node.boot or ""),
                name = node.name or node.id,
                lastSeen = now - math.max(0, age),
                side = nil,
                from = nil,
                loaded = true,
              }
              loaded = loaded + 1
            end
          end
        end
      end
    end
  end

  self.loaded = loaded
  self.stats.loaded = loaded
  trim(self)
  self.saveDirty = false
  return loaded
end

function master:close()
  return self:save()
end

function master:tick(now)
  now = now or self:now()
  for rid, pending in pairs(self.pending) do
    if now - pending.at > dnsmaster.EXEC_TIMEOUT then
      self.pending[rid] = nil
      if self.transport then
        self.transport:send(pending.from,
          pending.kind == "EDIT" and "EDITACK" or "EXECACK", {
          rid = rid,
          id = self.id,
          ok = "false",
          err = "offline",
        })
      end
    end
  end

  if self.saveDirty and now - self.lastSave >= self.saveInterval then
    self:save(now)
  end
end

return dnsmaster
