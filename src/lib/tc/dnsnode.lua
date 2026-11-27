-- DNS1 node registry: components, services, paths, DESCRIBE and EXEC.
--
-- M0 keeps the registry in memory. A component method is only executable when
-- the endpoint declares a non-empty `allow` and the method is listed there; a
-- method that is announced but not allowed returns `denied` without invoking
-- anything, and a method that is not announced at all returns
-- `unknown_method`.

local value = require("tc.value")

local dnsnode = {}

dnsnode.PROTOCOL = "DNS1"
dnsnode.PROTO_VERSION = 2
dnsnode.RETRY_AFTER = 30
-- The master marks a node stale after 90 s; a heartbeat keeps a quiet node in
-- the catalog without republishing endpoint bodies.
dnsnode.HEARTBEAT_AFTER = 45
-- An endpoint part plus its frame overhead must fit one DNS1 frame (900 B).
-- EDIT validates the encoded part before accepting a document, so a large
-- description can never make the node unpublishable.
dnsnode.MAX_EDIT_PART = 800
dnsnode.MAX_EDIT_DOCS = 1024
dnsnode.MAX_EDIT_TAGS = 12
dnsnode.MAX_EDIT_TAG_LEN = 40
dnsnode.EDIT_FILE = "edits.value"
-- EXEC accepts at most this many positional arguments and returns a body that
-- fits one frame with its envelope. Both limits are checked before the
-- transport has to drop a frame.
dnsnode.MAX_ARGS = 8
dnsnode.MAX_RESULT = 760
dnsnode.STATE_FILE = "state.value"
dnsnode.INBOX_FILE = "inbox.value"
dnsnode.MAX_STATE_KEYS = 32
dnsnode.MAX_STATE_KEY = 32
dnsnode.MAX_INBOX = 32
dnsnode.MAX_INBOX_MESSAGE = 1024

local function nowOf(self)
  if self.computer and type(self.computer.uptime) == "function" then
    local ok, valueNow = pcall(self.computer.uptime, self.computer)
    if ok and type(valueNow) == "number" then
      return valueNow
    end
  end
  return os.time()
end

local function copyList(list)
  local result = {}
  if type(list) == "table" then
    for _, item in ipairs(list) do
      result[#result + 1] = item
    end
  end
  return result
end

local function normalizeAllow(allow)
  local list, set = {}, {}
  if type(allow) == "table" then
    for key, item in pairs(allow) do
      local name = type(key) == "string" and key or item
      if type(name) == "string" and name ~= "" and not set[name] then
        set[name] = true
        list[#list + 1] = name
      end
    end
  end
  table.sort(list)
  return list, set
end

local function normalizeMethods(methods)
  local list, map = {}, {}
  if type(methods) ~= "table" then
    return list, map
  end

  local function add(name, descriptor)
    if type(name) ~= "string" or name == "" or map[name] then
      return
    end
    descriptor = type(descriptor) == "table" and descriptor or {}
    local item = {
      name = name,
      mode = descriptor.mode or "read",
      description = descriptor.description or "",
      args = copyList(descriptor.args),
      returns = descriptor.returns or "",
      examples = copyList(descriptor.examples),
    }
    list[#list + 1] = item
    map[name] = item
  end

  for key, item in pairs(methods) do
    if type(key) == "number" then
      if type(item) == "string" then
        add(item, {})
      elseif type(item) == "table" and type(item.name) == "string" then
        add(item.name, item)
      end
    else
      add(key, item)
    end
  end
  table.sort(list, function(left, right)
    return left.name < right.name
  end)
  return list, map
end

local node = {}
node.__index = node

local function normalizeOverride(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local result = {}
  if type(raw.docs) == "string" then
    result.docs = raw.docs
  end
  if type(raw.tags) == "table" then
    result.tags = copyList(raw.tags)
  end
  if result.docs == nil and result.tags == nil then
    return nil
  end
  return result
end

-- Edits are local to the node and survive a reboot when the kernel passes a
-- VFS. They are applied when the endpoint registers, because code owns the
-- endpoint list and the override only changes its documentation.
local function loadEdits(self)
  if not self.vfs or type(self.vfs.read) ~= "function" then
    return
  end
  local text = self.vfs.read(self.stateDir .. "/" .. dnsnode.EDIT_FILE)
  if type(text) ~= "string" then
    return
  end
  local body = value.decode(text)
  if type(body) ~= "table" then
    return
  end
  local nodeOverride = normalizeOverride(body.node)
  if nodeOverride then
    if nodeOverride.docs then
      self.docs = nodeOverride.docs
    end
    if nodeOverride.tags then
      self.tags = copyList(nodeOverride.tags)
    end
    self.overrides.node = nodeOverride
  end
  if type(body.endpoints) == "table" then
    for name, raw in pairs(body.endpoints) do
      if type(name) == "string" then
        local override = normalizeOverride(raw)
        if override then
          self.overrides.endpoints[name] = override
        end
      end
    end
  end
end

local function applyEndpointOverride(self, endpoint)
  local override = self.overrides.endpoints[endpoint.name]
  if not override then
    return
  end
  if override.docs then
    endpoint.docs = override.docs
  end
  if override.tags then
    endpoint.tags = copyList(override.tags)
  end
end

local function validStateKey(key)
  return type(key) == "string" and #key > 0 and #key <= dnsnode.MAX_STATE_KEY
    and key:match("^[%w_%-%.]+$") ~= nil
end

local function loadState(self)
  if not self.vfs or type(self.vfs.read) ~= "function" then
    return
  end
  local text = self.vfs.read(self.stateDir .. "/" .. dnsnode.STATE_FILE)
  if type(text) ~= "string" then
    return
  end
  local body = value.decode(text)
  if type(body) ~= "table" then
    return
  end
  local count = 0
  for key, item in pairs(body) do
    if validStateKey(key) and count < dnsnode.MAX_STATE_KEYS then
      self.stateData[key] = item
      count = count + 1
    end
  end
end

local function loadInbox(self)
  if not self.vfs or type(self.vfs.read) ~= "function" then
    return
  end
  local text = self.vfs.read(self.stateDir .. "/" .. dnsnode.INBOX_FILE)
  if type(text) ~= "string" then
    return
  end
  local body = value.decode(text)
  if type(body) ~= "table" then
    return
  end
  for _, item in ipairs(body.messages or {}) do
    if type(item) == "table" and type(item.id) == "string" and #self.inboxData < dnsnode.MAX_INBOX then
      self.inboxData[#self.inboxData + 1] = item
      local number = tonumber(item.id)
      if number and number > self.inboxCounter then
        self.inboxCounter = number
      end
    end
  end
end

function dnsnode.new(opts)
  opts = opts or {}
  assert(type(opts.id) == "string" and opts.id ~= "", "dnsnode requires an id")
  local self = setmetatable({}, node)
  self.id = opts.id
  self.name = opts.name or opts.id
  self.ver = opts.ver or 1
  self.boot = tostring(opts.boot or os.time())
  self.tags = copyList(opts.tags)
  self.docs = opts.docs or ""
  self.transport = opts.transport
  self.master = opts.master
  self.computer = opts.computer or computer
  self.dnsPort = opts.dnsPort or 4201
  self.component = opts.component or component
  self.log = opts.log
  self.vfs = opts.vfs
  self.stateDir = opts.stateDir or "/var/dns"
  self.overrides = { endpoints = {} }
  self.editStats = { applied = 0, conflict = 0, rejected = 0, failed = 0 }

  self.endpoints = {}
  self.paths = {}
  self.endpointRevs = {}
  self.snapshotVersion = 0
  self.calls = 0
  self.started = nowOf(self)
  self.dirty = true
  self.awaiting = false
  self.publishedVer = nil
  self.publishedBoot = nil
  self.publishedRevs = {}
  self.pendingParts = {}
  self.ackedParts = {}
  self.lastPublishedAt = 0
  self.forceFull = true
  self.publishAt = 0
  self.warned = {}
  self.ridCounter = 0
  self.ridGenerator = opts.ridGenerator
  self.publishStats = { full = 0, delta = 0, heartbeat = 0, resync = 0, failed = 0 }
  self.stateData = {}
  self.inboxData = {}
  self.inboxCounter = 0
  loadEdits(self)
  loadState(self)
  loadInbox(self)
  return self
end

function node:now()
  return nowOf(self)
end

local function warnOnce(self, key, message)
  if self.warned[key] then
    return
  end
  self.warned[key] = true
  if self.log and type(self.log.warn) == "function" then
    self.log.warn(message)
  end
end

function node:bump()
  self.snapshotVersion = self.snapshotVersion + 1
  self.dirty = true
end

function node:registerComponent(opts)
  opts = opts or {}
  local name = opts.name
  assert(type(name) == "string" and name ~= "", "component endpoint requires a name")
  local methods, methodMap = normalizeMethods(opts.methods)
  local allow, allowSet = normalizeAllow(opts.allow)
  local endpoint = {
    name = name,
    kind = "component",
    type = opts.componentType or name,
    address = opts.address,
    ver = opts.ver or 1,
    tags = copyList(opts.tags),
    docs = opts.docs or "",
    methods = methods,
    methodMap = methodMap,
    allow = allow,
    allowSet = allowSet,
    component = true,
  }
  self.endpoints[name] = endpoint
  applyEndpointOverride(self, endpoint)
  self:bump()
  self.endpointRevs[name] = self.snapshotVersion
  return endpoint
end

function node:registerService(opts)
  opts = opts or {}
  local name = opts.name
  assert(type(name) == "string" and name ~= "", "service endpoint requires a name")
  local methods, methodMap = normalizeMethods(opts.methods)
  local allow, allowSet = normalizeAllow(opts.allow)
  local endpoint = {
    name = name,
    kind = "service",
    type = opts.service or name,
    ver = opts.ver or 1,
    tags = copyList(opts.tags),
    docs = opts.docs or "",
    methods = methods,
    methodMap = methodMap,
    allow = allow,
    allowSet = allowSet,
    handler = opts.handler,
    component = false,
  }
  self.endpoints[name] = endpoint
  applyEndpointOverride(self, endpoint)
  self:bump()
  self.endpointRevs[name] = self.snapshotVersion
  return endpoint
end

function node:registerStatus()
  local methods = {
    status = {
      mode = "read",
      description = "Returns DNS1 status",
      args = {},
      returns = "table",
      examples = { "exec dns.status status" },
    },
  }
  return self:registerService({
    name = "dns.status",
    service = "dns.status",
    tags = { "dns", "status" },
    docs = "DNS1 status service",
    methods = methods,
    allow = { "status" },
    handler = function()
      return self:status()
    end,
  })
end

--- Publish the node's local plant readout. The service is optional: a node
-- without a plant service simply never calls this.
function node:registerPlant(plant)
  if not plant or type(plant.status) ~= "function" then
    return nil
  end
  local methods = {
    status = {
      mode = "read",
      description = "Memory, energy, link, stock and alarms.",
      args = {},
      returns = "table",
    },
    alarms = {
      mode = "read",
      description = "Local level alarms.",
      args = {},
      returns = "table",
    },
    snapshot = {
      mode = "read",
      description = "Stocks, rates, alarms and status.",
      args = {},
      returns = "table",
    },
  }
  return self:registerService({
    name = "plant",
    service = "plant",
    tags = { "plant", "readout" },
    docs = "Local plant readout. Reads the same cache the desktop apps use.",
    methods = methods,
    allow = { "alarms", "snapshot", "status" },
    handler = function(method)
      if method == "status" then
        return plant:status()
      elseif method == "alarms" then
        return plant:alarms()
      elseif method == "snapshot" then
        return plant:snapshot()
      end
      return nil, "unknown_method"
    end,
  })
end

function node:registerState()
  local methods = {
    get = { mode = "read", description = "Read.", args = { "key" }, returns = "table" },
    list = { mode = "read", description = "Keys.", args = {}, returns = "table" },
    set = { mode = "write", description = "Write.", args = { "key", "value" }, returns = "table" },
    delete = { mode = "write", description = "Remove.", args = { "key" }, returns = "table" },
  }
  return self:registerService({
    name = "state",
    service = "state",
    tags = { "state", "storage" },
    docs = "Node key-value store.",
    methods = methods,
    allow = { "delete", "get", "list", "set" },
    handler = function(method, args)
      if method == "get" then
        local item, code = self:stateGet(args[1])
        if item == nil and code ~= "missing" then
          return nil, code
        end
        return { found = item ~= nil, value = item }
      elseif method == "list" then
        return { keys = self:stateKeys() }
      elseif method == "set" then
        local ok, code = self:stateSet(args[1], args[2])
        if not ok then
          return nil, code
        end
        return { ok = true }
      elseif method == "delete" then
        local removed, code = self:stateDelete(args[1])
        if removed == nil then
          return nil, code
        end
        return { removed = removed }
      end
      return nil, "unknown_method"
    end,
  })
end

function node:registerInbox()
  local methods = {
    post = { mode = "write", description = "Post.", args = { "message" }, returns = "table" },
    list = { mode = "read", description = "List.", args = { "limit" }, returns = "table" },
    take = { mode = "write", description = "Take.", args = { "id" }, returns = "table" },
    clear = { mode = "write", description = "Clear.", args = {}, returns = "table" },
  }
  return self:registerService({
    name = "inbox",
    service = "inbox",
    tags = { "inbox", "messages" },
    docs = "Node message queue.",
    methods = methods,
    allow = { "clear", "list", "post", "take" },
    handler = function(method, args)
      if method == "post" then
        local id, code = self:inboxPost(args[1])
        if not id then
          return nil, code
        end
        return { id = id }
      elseif method == "list" then
        return { messages = self:inboxList(args[1]) }
      elseif method == "take" then
        local message, code = self:inboxTake(args[1])
        if message == nil and code ~= "missing" then
          return nil, code
        end
        return { found = message ~= nil, message = message }
      elseif method == "clear" then
        local count, code = self:inboxClear()
        if count == nil then
          return nil, code
        end
        return { cleared = count }
      end
      return nil, "unknown_method"
    end,
  })
end

function node:addPath(opts)
  opts = opts or {}
  local name = opts.name
  assert(type(name) == "string" and name ~= "", "path requires a name")
  local members = {}
  for _, member in ipairs(copyList(opts.members)) do
    members[#members + 1] = tostring(member):gsub("^endpoint:", "")
  end
  table.sort(members)
  self.paths[name] = {
    name = name,
    members = members,
    tags = copyList(opts.tags),
    docs = opts.docs or "",
  }
  self:bump()
  return self.paths[name]
end

function node:status()
  return {
    id = self.id,
    name = self.name,
    ver = self.ver,
    boot = self.boot,
    dnsPort = self.dnsPort,
    transports = self:transports(),
    uptime = math.floor(self:now() - self.started),
    calls = self.calls,
    snapshot = self.snapshotVersion,
    published = self.publishedVer,
    publish = {
      full = self.publishStats.full,
      delta = self.publishStats.delta,
      heartbeat = self.publishStats.heartbeat,
      resync = self.publishStats.resync,
      failed = self.publishStats.failed,
      awaiting = self.awaiting,
    },
    edits = {
      applied = self.editStats.applied,
      conflict = self.editStats.conflict,
      rejected = self.editStats.rejected,
    },
  }
end

function node:transports()
  if self.transport and type(self.transport.transports) == "function" then
    local text = self.transport:transports()
    if text and text ~= "" then
      return text
    end
  end
  return "none"
end

function node:version()
  return self.snapshotVersion
end

function node:endpoints()
  return self.endpoints
end

local function endpointPart(endpoint, rev)
  local part = {
    name = endpoint.name,
    kind = endpoint.kind,
    type = endpoint.type,
    ver = endpoint.ver,
    rev = rev or 0,
    tags = endpoint.tags,
    docs = endpoint.docs,
    allow = endpoint.allow,
    methods = endpoint.methods,
  }
  if endpoint.address then
    part.address = endpoint.address
  end
  return part
end

local function endpointSummary(endpoint, rev)
  -- The index is a manifest: a name and the revision of the part that holds the
  -- endpoint document. Keeping only these two fields keeps the whole index in
  -- one DNS1 frame as a node grows; DESCRIBE endpoint:<name> returns the rest.
  return {
    name = endpoint.name,
    rev = rev or 0,
  }
end

function node:indexPart()
  local endpointNames, pathNames = {}, {}
  for name in pairs(self.endpoints) do
    endpointNames[#endpointNames + 1] = name
  end
  table.sort(endpointNames)
  for name in pairs(self.paths) do
    pathNames[#pathNames + 1] = name
  end
  table.sort(pathNames)

  local endpoints, paths = {}, {}
  for _, name in ipairs(endpointNames) do
    endpoints[#endpoints + 1] = endpointSummary(self.endpoints[name], self.endpointRevs[name])
  end
  for _, name in ipairs(pathNames) do
    local path = self.paths[name]
    paths[#paths + 1] = {
      name = path.name,
      members = path.members,
    }
  end

  return {
    v = self.snapshotVersion,
    node = {
      id = self.id,
      name = self.name,
      ver = self.ver,
      boot = self.boot,
      proto = dnsnode.PROTOCOL,
      transports = self:transports(),
      tags = self.tags,
      docs = self.docs,
    },
    endpoints = endpoints,
    paths = paths,
  }
end

function node:snapshot()
  local endpoints = {}
  for name, endpoint in pairs(self.endpoints) do
    endpoints[name] = endpointPart(endpoint, self.endpointRevs[name])
  end
  return {
    index = self:indexPart(),
    endpoints = endpoints,
    version = self.snapshotVersion,
  }
end

local function encodeBody(body)
  local text, code = value.encode(body)
  if not text then
    return nil, code
  end
  return text
end

local function errorReply(self, fields, code, ref)
  return "ERR", {
    rid = fields.rid,
    id = self.id,
    err = code,
    ref = ref,
  }
end

local function invokeEndpoint(self, endpoint, method, args)
  if not endpoint.methodMap[method] then
    return nil, "unknown_method"
  end
  if not endpoint.allowSet[method] then
    return nil, "denied"
  end

  local ok, result, code
  if endpoint.component then
    if not endpoint.address or not self.component
      or type(self.component.invoke) ~= "function" then
      return nil, "unsupported"
    end
    self.calls = self.calls + 1
    ok, result = pcall(self.component.invoke, endpoint.address, method, table.unpack(args))
  else
    if type(endpoint.handler) ~= "function" then
      return nil, "unsupported"
    end
    self.calls = self.calls + 1
    ok, result, code = pcall(endpoint.handler, method, args)
  end
  if not ok then
    return nil, "internal"
  end
  if result == nil and code then
    return nil, code
  end
  return result
end

local function describe(self, target)
  if target == "node" then
    return self:indexPart()
  end
  local endpoint = target:match("^endpoint:(.+)$")
  if endpoint then
    if not self.endpoints[endpoint] then
      return nil, "unknown_target"
    end
    return endpointPart(self.endpoints[endpoint], self.endpointRevs[endpoint])
  end
  local path = target:match("^path:(.+)$")
  if path then
    if not self.paths[path] then
      return nil, "unknown_target"
    end
    return self.paths[path]
  end
  return nil, "unknown_target"
end

local function execute(self, fields)
  local target, method = fields.target, fields.method
  if type(target) ~= "string" or type(method) ~= "string" then
    return { rid = fields.rid, id = self.id, ok = false, err = "bad_args" }
  end

  local args = {}
  if fields.p and fields.p ~= "" then
    local decoded, code = value.decode(fields.p)
    if not decoded and code then
      return { rid = fields.rid, id = self.id, ok = false, err = "bad_args" }
    end
    if type(decoded) ~= "table" then
      return { rid = fields.rid, id = self.id, ok = false, err = "bad_args" }
    end
    local count = 0
    for key in pairs(decoded) do
      if type(key) ~= "number" or decoded[key] == nil then
        return { rid = fields.rid, id = self.id, ok = false, err = "bad_args" }
      end
      count = count + 1
    end
    if count > dnsnode.MAX_ARGS then
      return { rid = fields.rid, id = self.id, ok = false, err = "bad_args" }
    end
    args = decoded
  end

  local function one(endpointName)
    local endpoint = self.endpoints[endpointName]
    if not endpoint then
      return { ok = false, error = "unknown_target" }
    end
    local result, code = invokeEndpoint(self, endpoint, method, args)
    if code then
      return { ok = false, error = code }
    end
    return { ok = true, value = result }
  end

  local endpointName = target:match("^endpoint:(.+)$")
  if endpointName then
    local result = one(endpointName)
    if not result.ok then
      return { rid = fields.rid, id = self.id, ok = false, err = result.error }
    end
    local body, code = encodeBody(result.value)
    if not body then
      return { rid = fields.rid, id = self.id, ok = false, err = code }
    end
    if #body > dnsnode.MAX_RESULT then
      return { rid = fields.rid, id = self.id, ok = false, err = "too_large" }
    end
    return { rid = fields.rid, id = self.id, ok = true, body = body }
  end

  local pathName = target:match("^path:(.+)$")
  if pathName then
    local path = self.paths[pathName]
    if not path then
      return { rid = fields.rid, id = self.id, ok = false, err = "unknown_target" }
    end
    local members = {}
    for _, member in ipairs(path.members) do
      local result = one(member)
      result.endpoint = member
      members[#members + 1] = result
    end
    local body, code = encodeBody({ members = members })
    if not body then
      return { rid = fields.rid, id = self.id, ok = false, err = code }
    end
    if #body > dnsnode.MAX_RESULT then
      return { rid = fields.rid, id = self.id, ok = false, err = "too_large" }
    end
    return { rid = fields.rid, id = self.id, ok = true, body = body }
  end

  return { rid = fields.rid, id = self.id, ok = false, err = "unknown_target" }
end

local function validTags(tags)
  if type(tags) ~= "table" then
    return false
  end
  local count = 0
  for key, item in pairs(tags) do
    if type(key) ~= "number" or type(item) ~= "string" or item == ""
      or #item > dnsnode.MAX_EDIT_TAG_LEN then
      return false
    end
    count = count + 1
  end
  return count <= dnsnode.MAX_EDIT_TAGS
end

function node:saveEdits()
  if not self.vfs or type(self.vfs.write) ~= "function" then
    return false
  end
  if type(self.vfs.ensureDir) == "function" then
    local ok = self.vfs.ensureDir(self.stateDir)
    if not ok then
      return false, "state_dir"
    end
  end
  local text, code = value.encode({
    node = self.overrides.node,
    endpoints = self.overrides.endpoints,
  })
  if not text then
    return false, code
  end
  local ok, reason = self.vfs.write(self.stateDir .. "/" .. dnsnode.EDIT_FILE, text)
  if not ok then
    return false, reason
  end
  return true
end

local function writeStateFile(self, name, body)
  if not self.vfs or type(self.vfs.write) ~= "function" then
    return true
  end
  if type(self.vfs.ensureDir) == "function" then
    local ok = self.vfs.ensureDir(self.stateDir)
    if not ok then
      return false, "state_dir"
    end
  end
  local text, code = value.encode(body)
  if not text then
    return false, code
  end
  if #text > 4096 then
    return false, "too_large"
  end
  local ok, reason = self.vfs.write(self.stateDir .. "/" .. name, text)
  if not ok then
    return false, reason
  end
  return true
end

function node:saveState()
  return writeStateFile(self, dnsnode.STATE_FILE, self.stateData)
end

function node:saveInbox()
  return writeStateFile(self, dnsnode.INBOX_FILE, { messages = self.inboxData })
end

local function sortedKeys(map)
  local keys = {}
  for key in pairs(map) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

function node:stateSet(key, value)
  if not validStateKey(key) then
    return nil, "bad_args"
  end
  if value == nil then
    return nil, "bad_args"
  end
  local had = self.stateData[key]
  self.stateData[key] = value
  local ok, reason = self:saveState()
  if not ok then
    self.stateData[key] = had
    return nil, reason or "state_write"
  end
  return true
end

function node:stateGet(key)
  if not validStateKey(key) then
    return nil, "bad_args"
  end
  local value = self.stateData[key]
  if value == nil then
    return nil, "missing"
  end
  return value
end

function node:stateDelete(key)
  if not validStateKey(key) then
    return nil, "bad_args"
  end
  local had = self.stateData[key]
  if had == nil then
    return false
  end
  self.stateData[key] = nil
  local ok, reason = self:saveState()
  if not ok then
    self.stateData[key] = had
    return nil, reason or "state_write"
  end
  return true
end

function node:stateKeys()
  return sortedKeys(self.stateData)
end

function node:inboxPost(message)
  if message == nil then
    return nil, "bad_args"
  end
  if #self.inboxData >= dnsnode.MAX_INBOX then
    return nil, "full"
  end
  self.inboxCounter = self.inboxCounter + 1
  local item = {
    id = tostring(self.inboxCounter),
    at = os.time(),
    message = message,
  }
  self.inboxData[#self.inboxData + 1] = item
  local ok, reason = self:saveInbox()
  if not ok then
    table.remove(self.inboxData)
    self.inboxCounter = self.inboxCounter - 1
    return nil, reason or "inbox_write"
  end
  return item.id
end

function node:inboxList(limit)
  limit = tonumber(limit) or 20
  if limit < 1 then
    limit = 1
  elseif limit > dnsnode.MAX_INBOX then
    limit = dnsnode.MAX_INBOX
  end
  local messages = {}
  for index = 1, math.min(limit, #self.inboxData) do
    local item = self.inboxData[index]
    messages[index] = { id = item.id, at = item.at, message = item.message }
  end
  return messages
end

function node:inboxTake(id)
  if type(id) ~= "string" or id == "" then
    return nil, "bad_args"
  end
  for index, item in ipairs(self.inboxData) do
    if item.id == id then
      table.remove(self.inboxData, index)
      local ok, reason = self:saveInbox()
      if not ok then
        table.insert(self.inboxData, index, item)
        return nil, reason or "inbox_write"
      end
      return item.message
    end
  end
  return nil, "missing"
end

function node:inboxClear()
  local count = #self.inboxData
  local previous = self.inboxData
  self.inboxData = {}
  local ok, reason = self:saveInbox()
  if not ok then
    self.inboxData = previous
    return nil, reason or "inbox_write"
  end
  return count
end

local function conflictReply(self, rev, body)
  local response = {
    id = self.id,
    ok = "false",
    err = "conflict",
    rev = tostring(rev),
  }
  local text = encodeBody(body)
  if text then
    response.body = text
  end
  return response
end

-- EDIT is optimistic: the caller names the revision it read, and a stale
-- revision returns the current document instead of overwriting a newer edit.
-- Only documentation and tags are editable; methods, allow and identity stay
-- owned by the node's code.
local function edit(self, fields)
  local target = fields.target
  local field = fields.field
  local expected = tonumber(fields.rev)
  if type(target) ~= "string" or type(field) ~= "string" or not expected then
    self.editStats.rejected = self.editStats.rejected + 1
    return { rid = fields.rid, id = self.id, ok = "false", err = "bad_args" }
  end
  if field ~= "docs" and field ~= "tags" then
    self.editStats.rejected = self.editStats.rejected + 1
    return { rid = fields.rid, id = self.id, ok = "false", err = "unknown_field" }
  end
  if not fields.p then
    self.editStats.rejected = self.editStats.rejected + 1
    return { rid = fields.rid, id = self.id, ok = "false", err = "bad_value" }
  end
  local newValue, decodeCode = value.decode(fields.p)
  if decodeCode then
    self.editStats.rejected = self.editStats.rejected + 1
    return { rid = fields.rid, id = self.id, ok = "false", err = "bad_value" }
  end
  if field == "docs" then
    if type(newValue) ~= "string" or #newValue > dnsnode.MAX_EDIT_DOCS then
      self.editStats.rejected = self.editStats.rejected + 1
      return { rid = fields.rid, id = self.id, ok = "false", err = "bad_value" }
    end
  elseif not validTags(newValue) then
    self.editStats.rejected = self.editStats.rejected + 1
    return { rid = fields.rid, id = self.id, ok = "false", err = "bad_value" }
  end

  local endpointName = target:match("^endpoint:(.+)$")
  if endpointName then
    local endpoint = self.endpoints[endpointName]
    if not endpoint then
      self.editStats.rejected = self.editStats.rejected + 1
      return { rid = fields.rid, id = self.id, ok = "false", err = "unknown_target" }
    end
    local current = self.endpointRevs[endpointName] or 0
    if expected ~= current then
      self.editStats.conflict = self.editStats.conflict + 1
      local reply = conflictReply(self, current, endpointPart(endpoint, current))
      reply.rid = fields.rid
      return reply
    end

    local oldDocs, oldTags = endpoint.docs, endpoint.tags
    if field == "docs" then
      endpoint.docs = newValue
    else
      endpoint.tags = copyList(newValue)
    end
    local candidateRev = self.snapshotVersion + 1
    local text = encodeBody(endpointPart(endpoint, candidateRev))
    if not text or #text > dnsnode.MAX_EDIT_PART then
      endpoint.docs, endpoint.tags = oldDocs, oldTags
      self.editStats.rejected = self.editStats.rejected + 1
      return { rid = fields.rid, id = self.id, ok = "false", err = "too_large" }
    end

    self:bump()
    self.endpointRevs[endpointName] = self.snapshotVersion
    local override = self.overrides.endpoints[endpointName] or {}
    override[field] = field == "tags" and copyList(newValue) or newValue
    self.overrides.endpoints[endpointName] = override
    self:dirtySave()
    self.editStats.applied = self.editStats.applied + 1
    return {
      rid = fields.rid,
      id = self.id,
      ok = "true",
      rev = tostring(self.endpointRevs[endpointName]),
    }
  end

  if target == "node" then
    if expected ~= self.snapshotVersion then
      self.editStats.conflict = self.editStats.conflict + 1
      local reply = conflictReply(self, self.snapshotVersion, self:indexPart())
      reply.rid = fields.rid
      return reply
    end
    local oldDocs, oldTags = self.docs, self.tags
    if field == "docs" then
      self.docs = newValue
    else
      self.tags = copyList(newValue)
    end
    local text = encodeBody(self:indexPart())
    if not text or #text > dnsnode.MAX_EDIT_PART then
      self.docs, self.tags = oldDocs, oldTags
      self.editStats.rejected = self.editStats.rejected + 1
      return { rid = fields.rid, id = self.id, ok = "false", err = "too_large" }
    end
    self:bump()
    local override = self.overrides.node or {}
    override[field] = field == "tags" and copyList(newValue) or newValue
    self.overrides.node = override
    self:dirtySave()
    self.editStats.applied = self.editStats.applied + 1
    return {
      rid = fields.rid,
      id = self.id,
      ok = "true",
      rev = tostring(self.snapshotVersion),
    }
  end

  self.editStats.rejected = self.editStats.rejected + 1
  return { rid = fields.rid, id = self.id, ok = "false", err = "unknown_target" }
end

function node:dirtySave()
  self.dirty = true
  local ok, reason = self:saveEdits()
  if not ok and reason and self.log and type(self.log.warn) == "function" then
    warnOnce(self, "edit-save", "DNS1 node: could not save edits: " .. tostring(reason))
  end
end

--- Handle one DNS1 request. Returns the response verb and fields, or nil.
function node:handle(verb, fields)
  if verb == "HELLO" then
    return "HELLOACK", {
      rid = fields.rid,
      id = self.id,
      node = self.id,
      name = self.name,
      proto = dnsnode.PROTOCOL,
      ver = dnsnode.PROTO_VERSION,
      boot = self.boot,
      transports = self:transports(),
    }
  elseif verb == "WHO" then
    return "WHOACK", {
      rid = fields.rid,
      id = self.id,
      node = self.id,
      name = self.name,
      proto = dnsnode.PROTOCOL,
      ver = dnsnode.PROTO_VERSION,
      boot = self.boot,
    }
  elseif verb == "DESCRIBE" then
    local body, code = describe(self, fields.target or "")
    if not body then
      return errorReply(self, fields, code, "DESCRIBE")
    end
    local text, encodeCode = encodeBody(body)
    if not text then
      return errorReply(self, fields, encodeCode, "DESCRIBE")
    end
    return "DESCRIBEACK", {
      rid = fields.rid,
      id = self.id,
      body = text,
    }
  elseif verb == "EXEC" then
    return "EXECACK", execute(self, fields)
  elseif verb == "EDIT" then
    return "EDITACK", edit(self, fields)
  elseif verb == "PUBLISHACK" then
    if fields.ok == "true" or fields.ok == true then
      if fields.need == "full" then
        -- The master lost the base snapshot (restart, eviction, or a gap in
        -- the parts). Republish everything on the next tick.
        self.awaiting = false
        self.forceFull = true
        self.publishStats.resync = self.publishStats.resync + 1
        return nil
      end
      local ver = tonumber(fields.ver)
      if ver and ver ~= self.snapshotVersion then
        return nil
      end
      local part = fields.part
      if part then
        self.ackedParts[part] = true
      else
        -- A master built before M1 does not echo the part. Treat its ACK as
        -- covering the whole attempt.
        for pending in pairs(self.pendingParts) do
          self.ackedParts[pending] = true
        end
      end
      for pending in pairs(self.pendingParts) do
        if not self.ackedParts[pending] then
          return nil
        end
      end
      self.publishedVer = ver or self.snapshotVersion
      self.publishedBoot = self.boot
      self.publishedRevs = {}
      for name, rev in pairs(self.endpointRevs) do
        self.publishedRevs[name] = rev
      end
      self.pendingParts = {}
      self.ackedParts = {}
      self.dirty = false
      self.awaiting = false
      self.forceFull = false
      self.lastPublishedAt = self:now()
    else
      self.awaiting = false
      self.forceFull = true
      self.publishStats.failed = self.publishStats.failed + 1
    end
    return nil
  end
  return nil
end

function node:nextRid()
  if type(self.ridGenerator) == "function" then
    return self.ridGenerator()
  end
  self.ridCounter = self.ridCounter + 1
  return string.format("%08x", self.ridCounter)
end

--- Publish the snapshot. The first publish after boot (or after a master asks
-- for a resync) is full; later publishes send the index plus only the endpoint
-- parts whose revision changed. A heartbeat index every HEARTBEAT_AFTER keeps a
-- quiet node in the master's catalog without resending endpoint bodies.
function node:tick(now)
  if not self.transport or not self.master or self.master == "" then
    return
  end
  now = now or self:now()
  local version = self.snapshotVersion
  local heartbeatDue = self.lastPublishedAt > 0
    and (now - self.lastPublishedAt) >= dnsnode.HEARTBEAT_AFTER
  local clean = not self.dirty
    and self.publishedVer == version
    and self.publishedBoot == self.boot
  if clean and not heartbeatDue then
    return
  end
  if self.awaiting and now - self.publishAt < dnsnode.RETRY_AFTER then
    return
  end

  local snapshot = self:snapshot()
  local full = self.forceFull
    or self.publishedVer == nil
    or self.publishedBoot ~= self.boot
    or version < (self.publishedVer or -1)

  local names = {}
  for name in pairs(snapshot.endpoints) do
    names[#names + 1] = name
  end
  table.sort(names)

  local parts = {
    { part = "index", body = snapshot.index, rev = version },
  }
  if full then
    for _, name in ipairs(names) do
      parts[#parts + 1] = {
        part = "endpoint:" .. name,
        body = snapshot.endpoints[name],
        rev = self.endpointRevs[name] or 0,
      }
    end
  else
    for _, name in ipairs(names) do
      if not self.publishedRevs[name]
        or self.publishedRevs[name] ~= self.endpointRevs[name] then
        parts[#parts + 1] = {
          part = "endpoint:" .. name,
          body = snapshot.endpoints[name],
          rev = self.endpointRevs[name] or 0,
        }
      end
    end
  end

  if full then
    self.publishStats.full = self.publishStats.full + 1
  elseif #parts > 1 then
    self.publishStats.delta = self.publishStats.delta + 1
  else
    self.publishStats.heartbeat = self.publishStats.heartbeat + 1
  end

  local versionText = tostring(version)
  local function sendPart(part, body, rev)
    local text, code = value.encode(body)
    if not text then
      warnOnce(self, "publish-encode:" .. part,
        "DNS1: cannot encode PUBLISH " .. part .. ": " .. tostring(code))
      return false
    end
    local ok, reason = self.transport:send(self.master, "PUBLISH", {
      rid = self:nextRid(),
      id = self.id,
      ver = versionText,
      part = part,
      rev = tostring(rev or 0),
      full = full and "true" or "false",
      p = text,
    })
    if not ok then
      warnOnce(self, "publish-send:" .. part,
        "DNS1: PUBLISH " .. part .. " failed: " .. tostring(reason))
      return false
    end
    return true
  end

  self.pendingParts = {}
  self.ackedParts = {}
  for _, item in ipairs(parts) do
    if not sendPart(item.part, item.body, item.rev) then
      self.awaiting = true
      self.publishAt = now
      self.publishStats.failed = self.publishStats.failed + 1
      return
    end
    self.pendingParts[item.part] = true
  end

  self.awaiting = true
  self.publishAt = now
end

return dnsnode
