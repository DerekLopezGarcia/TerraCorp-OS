-- Tests for M0 DNS1: frame extraction, value codec, transport, HELLO,
-- DESCRIBE, catalog, EXEC allow/deny, master forwarding and direct fallback.
--
-- Run through tools/harness/test-dns.js. A single in-memory bus connects fake
-- modems; every endpoint has its own queue so `pullSignal` never receives
-- another computer's event.

local frame = require("tc.frame")
local net = require("tc.net")
local value = require("tc.value")
local dnsnet = require("tc.dnsnet")
local dnsnode = require("tc.dnsnode")
local dnsmaster = require("tc.dnsmaster")
local dnsclient = require("tc.dnsclient")

local failures, checked = {}, 0

local function check(condition, message)
  checked = checked + 1
  if not condition then
    failures[#failures + 1] = message
  end
end

local function equal(actual, expected, message)
  checked = checked + 1
  if actual ~= expected then
    failures[#failures + 1] = message ..
      " (got " .. tostring(actual) .. ", expected " .. tostring(expected) .. ")"
  end
end

local function contains(text, needle, message)
  checked = checked + 1
  if type(text) ~= "string" or not text:find(needle, 1, true) then
    failures[#failures + 1] = message .. " (looked for " .. tostring(needle) .. ")"
  end
end

local function findByName(list, name)
  for _, item in ipairs(list or {}) do
    if type(item) == "table" and (item.name == name or item.id == name) then
      return item
    end
  end
  return nil
end

local function countKeys(map)
  local count = 0
  for _ in pairs(map or {}) do
    count = count + 1
  end
  return count
end

--------------------------------------------------------------------------------
-- Frames and values
--------------------------------------------------------------------------------

equal(net.encode("HELLO", { id = "abc" }), "TC1 HELLO id=abc", "TC1 HELLO bytes are stable")
equal(net.encode("STATUS", { state = "ok", id = "abc" }), "TC1 STATUS id=abc state=ok",
  "TC1 fields stay sorted")
equal(net.encode("CFG", { id = "a", file = "x", body = "line 1" }),
  "TC1 CFG body=line%201 file=x id=a", "TC1 escaping is byte-identical")

local verb, fields = net.decode("TC1 STATUS id=abc state=ok")
equal(verb, "STATUS", "TC1 decode verb")
equal(fields.id, "abc", "TC1 decode id")
equal(fields.state, "ok", "TC1 decode state")

local badVerb, badReason = net.decode("TC1 STATUS id=a\nstate=b")
equal(badVerb, nil, "TC1 decode rejects newlines")
equal(badReason, "frame must be one line", "TC1 newline error text")

local frameText = frame.encode("DNS1", dnsnet.VERBS, "WHO", { rid = "00000001", id = "addr" },
  { max = dnsnet.MAX_TX })
equal(frameText, "DNS1 WHO id=addr rid=00000001", "DNS1 frame is sorted")

local whoVerb, whoFields = frame.decode("DNS1", dnsnet.VERBS, frameText,
  { max = dnsnet.MAX_TX })
equal(whoVerb, "WHO", "DNS1 decode verb")
equal(whoFields.rid, "00000001", "DNS1 decode rid")

local encoded = value.encode({ b = 2, a = 1, [3] = "x" })
equal(encoded, '{[3]="x",["a"]=1,["b"]=2}', "value encoding is canonical")

local round = value.decode(encoded)
equal(round[3], "x", "value roundtrip number key")
equal(round.a, 1, "value roundtrip string key")
equal(round.b, 2, "value roundtrip second key")

equal(value.decode(value.encode("a\nb\tc")), "a\nb\tc", "value string escaping")
equal(value.decode(value.encode(nil)), nil, "value nil roundtrip")
equal(value.decode(value.encode(true)), true, "value boolean roundtrip")
local trueTable, trueTableReason = value.decode(value.encode({ ok = true, flag = false }))
equal(trueTableReason, nil, "true followed by a delimiter decodes")
equal(trueTable and trueTable.ok, true, "true value survives a table delimiter")
equal(trueTable and trueTable.flag, false, "false value survives a table delimiter")
local nilText, nilTextReason = value.decode("nil ")
equal(nilText, nil, "nil followed by whitespace decodes")
equal(nilTextReason, nil, "nil followed by whitespace has no error")
local trueText, trueTextReason = value.decode("true ")
equal(trueText, true, "true followed by whitespace decodes")
equal(trueTextReason, nil, "true followed by whitespace has no error")
equal(value.encode(function() end), nil, "functions are rejected")
equal(value.encode(0 / 0), nil, "NaN is rejected")
equal(value.decode("{"), nil, "broken value is rejected")
equal(value.decode("truex"), nil, "trailing value text is rejected")
equal(value.encode(string.rep("x", value.MAX_STRING + 1)), nil, "long strings are rejected")
equal(value.decode(string.rep("x", value.MAX_TOTAL + 1)), nil, "long values are rejected")

local tooDeep = {}
local cursor = tooDeep
for _ = 1, value.MAX_DEPTH + 1 do
  cursor.child = {}
  cursor = cursor.child
end
equal(value.encode(tooDeep), nil, "deep values are rejected")

--------------------------------------------------------------------------------
-- Bus and fakes
--------------------------------------------------------------------------------

local Bus = {}
Bus.__index = Bus

function Bus.new()
  return setmetatable({
    queue = {},
    endpoints = {},
    clock = 1000,
    opened = {},
    sentVia = {},
  }, Bus)
end

function Bus:add(address, dns, side)
  self.endpoints[address] = { dns = dns, side = side }
end

function Bus:send(from, target, port, text)
  if tonumber(port) ~= 4201 then
    return false
  end
  local destination = self.endpoints[target]
  if not destination then
    return false
  end
  self.queue[#self.queue + 1] = {
    dest = target,
    side = destination.side,
    from = from,
    message = text,
  }
  return true
end

function Bus:broadcast(from, port, text)
  if tonumber(port) ~= 4201 then
    return false
  end
  local sent = 0
  for address in pairs(self.endpoints) do
    if address ~= from and self:send(from, address, port, text) then
      sent = sent + 1
    end
  end
  return sent > 0
end

function Bus:pack(event)
  return { true, "modem_message", event.side, event.from, event.port or 4201, 0, event.message }
end

function Bus:dispatch(event)
  local destination = self.endpoints[event.dest]
  if not destination or not destination.dns then
    return false
  end
  return destination.dns:handle(self:pack(event))
end

function Bus:pullSignal(address, timeout)
  for index, event in ipairs(self.queue) do
    if event.dest == address then
      table.remove(self.queue, index)
      return "modem_message", event.side, event.from, event.port or 4201, 0, event.message
    end
  end
  local event = table.remove(self.queue, 1)
  if event then
    self:dispatch(event)
    return nil
  end
  self.clock = self.clock + (tonumber(timeout) or 0)
  return nil
end

function Bus:drain(limit)
  local count, guard = 0, limit or 5000
  while #self.queue > 0 and count < guard do
    local event = table.remove(self.queue, 1)
    self:dispatch(event)
    count = count + 1
  end
  return count
end

function Bus:inject(dest, side, from, port, message)
  self.queue[#self.queue + 1] = {
    dest = dest,
    side = side,
    from = from,
    port = port,
    message = message,
  }
end

local function newComputer(bus, address)
  return {
    address = function()
      return address
    end,
    uptime = function()
      return bus.clock
    end,
    pullSignal = function(timeout)
      return bus:pullSignal(address, timeout)
    end,
  }
end

local function newVfs()
  local vfs = { files = {}, dirs = { ["/var/dns"] = true } }
  function vfs.exists(path)
    return vfs.files[path] ~= nil or vfs.dirs[path] == true
  end
  function vfs.list(path)
    if not vfs.dirs[path] then
      return nil, "not_found"
    end
    local names = {}
    local prefix = path == "/" and "/" or (path .. "/")
    for file in pairs(vfs.files) do
      if file:sub(1, #prefix) == prefix and not file:sub(#prefix + 1):find("/", 1, true) then
        names[#names + 1] = file:sub(#prefix + 1)
      end
    end
    table.sort(names)
    return names
  end
  function vfs.read(path)
    return vfs.files[path]
  end
  function vfs.write(path, data)
    vfs.files[path] = data
    return true
  end
  function vfs.ensureDir(path)
    vfs.dirs[path] = true
    return true
  end
  function vfs.remove(path)
    vfs.files[path] = nil
    return true
  end
  return vfs
end

local INVENTORY = {
  { slot = 1, name = "minecraft:stone", size = 64, maxSize = 64, stackSize = 1, hasTag = false },
  { slot = 2, name = "minecraft:iron_ingot", size = 12, maxSize = 64, stackSize = 1, hasTag = false },
}

local function newComponent(bus, address, side, wired, inventory, modems)
  local inventoryAddress = inventory
  local specs = modems or { { address = address, side = side, wired = wired } }
  local component = {}
  local modemAddresses = {}
  for _, modem in ipairs(specs) do
    modemAddresses[#modemAddresses + 1] = modem.address
  end
  local kinds = {
    modem = modemAddresses,
    inventory_controller = inventoryAddress and { inventoryAddress } or {},
  }

  local function findModem(target)
    for _, modem in ipairs(specs) do
      if target == modem.address or target == modem.side then
        return modem
      end
    end
    return nil
  end

  function component.list(kind)
    local items = kinds[kind] or {}
    local index = 0
    return function()
      index = index + 1
      local item = items[index]
      if item then
        return item, kind
      end
      return nil
    end
  end

  function component.invoke(target, method, ...)
    local modem = findModem(target)
    if modem then
      if method == "isWired" then
        return modem.wired
      elseif method == "open" then
        bus.opened[modem.address] = true
        return true
      elseif method == "close" then
        bus.opened[modem.address] = false
        return true
      elseif method == "send" then
        local to, port, text = ...
        if bus:send(modem.address, to, port, text) then
          bus.sentVia[modem.address] = (bus.sentVia[modem.address] or 0) + 1
          return true
        end
        return false
      elseif method == "broadcast" then
        local port, text = ...
        return bus:broadcast(modem.address, port, text)
      end
    elseif inventoryAddress and target == inventoryAddress then
      if method == "getAllStacks" then
        return INVENTORY
      elseif method == "getStackInSlot" then
        error("getStackInSlot must not be invoked in the M0 matrix")
      end
    end
    return nil, "unknown method"
  end

  return component
end

local function newNode(bus, opts)
  local modems = opts.modems or {
    { address = opts.address, side = opts.side, wired = opts.wired },
  }
  local component = newComponent(bus, opts.address, opts.side, opts.wired, opts.inventory, modems)
  local computer = newComputer(bus, opts.address)
  local transport = dnsnet.new({
    computer = computer,
    component = component,
    nodeId = opts.address,
    transport = opts.transport or "auto",
  })
  local ok, reason = transport:open()
  assert(ok, reason)
  for _, modem in ipairs(modems) do
    bus:add(modem.address, transport, modem.side)
  end

  local node = dnsnode.new({
    id = opts.address,
    name = opts.name or opts.address,
    ver = "0.4.9",
    boot = opts.boot or ("boot-" .. opts.address),
    tags = { "line" },
    docs = "Test line node.",
    transport = transport,
    master = opts.master,
    computer = computer,
    component = component,
    dnsPort = 4201,
    vfs = opts.vfs,
    stateDir = opts.stateDir,
  })
  node:registerStatus()
  if opts.inventory then
    node:registerComponent({
      name = "inventory_controller",
      componentType = "inventory_controller",
      address = opts.inventory,
      tags = { "inventory" },
      docs = "Read-only inventory.",
      allow = { "getAllStacks" },
      methods = {
        getAllStacks = {
          mode = "read",
          description = "Returns every slot.",
          args = {},
          returns = "table",
          examples = { "exec endpoint:inventory_controller getAllStacks" },
        },
        getStackInSlot = {
          mode = "read",
          description = "Returns one slot; documented but not allowed.",
          args = { "slot:number" },
          returns = "table",
          examples = { "exec endpoint:inventory_controller getStackInSlot 1" },
        },
      },
    })
  end
  node:addPath({
    name = "spike",
    members = { "dns.status", "inventory_controller" },
    tags = { "dns", "m0" },
    docs = "Read-only spike path.",
  })

  transport.onFrame = function(side, from, verbName, incoming)
    return node:handle(verbName, incoming)
  end
  return { dns = transport, node = node, computer = computer, component = component }
end

local function newMaster(bus, opts)
  opts = opts or {}
  local address = opts.address or "masterM"
  local component = newComponent(bus, address, "masterSide", true)
  local computer = newComputer(bus, address)
  local transport = dnsnet.new({
    computer = computer,
    component = component,
    nodeId = address,
    transport = "auto",
  })
  local ok, reason = transport:open()
  assert(ok, reason)
  bus:add(address, transport, "masterSide")
  local master = dnsmaster.new({
    id = address,
    ver = "0.4.9",
    boot = "master-boot",
    computer = computer,
    transport = transport,
    vfs = opts.vfs,
    stateDir = opts.stateDir,
  })
  transport.onFrame = function(side, from, verbName, incoming)
    return master:onFrame(side, from, verbName, incoming)
  end
  return { dns = transport, master = master, computer = computer, component = component }
end

local function newClient(bus, opts)
  opts = opts or {}
  local address = opts.address or "clientC"
  local side = opts.side or "clientSide"
  local component = newComponent(bus, address, side, opts.wired ~= false)
  local computer = newComputer(bus, address)
  local transport = dnsnet.new({
    computer = computer,
    component = component,
    nodeId = address,
    transport = "auto",
  })
  local ok, reason = transport:open()
  assert(ok, reason)
  bus:add(address, transport, side)
  local client = dnsclient.new({
    computer = computer,
    net = transport,
    master = opts.master,
    timeout = opts.timeout or 1,
  })
  return { dns = transport, client = client, computer = computer, component = component }
end

--------------------------------------------------------------------------------
-- Transport
--------------------------------------------------------------------------------

local bus = Bus.new()
local masterNode = newMaster(bus)
local nodeA = newNode(bus, {
  address = "addrA",
  side = "modemA",
  wired = true,
  inventory = "invA",
  master = "masterM",
  boot = "bootA",
  name = "Line A",
})
local nodeB = newNode(bus, {
  address = "addrB",
  side = "modemB",
  wired = false,
  inventory = "invB",
  master = "masterM",
  boot = "bootB",
  name = "Line B",
})
-- A node that never publishes: the master has not seen it, so a master-route
-- DESCRIBE gets `err=offline` and the client must ask the node directly.
local nodeC = newNode(bus, {
  address = "addrC",
  side = "modemC",
  wired = true,
  inventory = "invC",
  boot = "bootC",
  name = "Line C",
})

-- A response that does not fit in the 900 B TX budget must come back as
-- `too_large`, not disappear and leave the caller waiting for a timeout.
nodeC.node:registerService({
  name = "big",
  service = "test.big",
  tags = { "test" },
  docs = "Returns a payload larger than one DNS1 frame.",
  allow = { "blob" },
  methods = {
    blob = {
      mode = "read",
      description = "Returns a 1000-byte string.",
      args = {},
      returns = "table",
      examples = { "exec endpoint:big blob" },
    },
  },
  handler = function()
    return { text = string.rep("x", 1000) }
  end,
})

-- A node with two modems: the transport must open 4201 on both and answer
-- through the modem that received the request, whether the event carries its
-- side name or its component address in the first slot.
local nodeD = newNode(bus, {
  address = "addrD",
  name = "Line D",
  boot = "bootD",
  inventory = "invD",
  modems = {
    { address = "modemDW", side = "west", wired = true },
    { address = "modemDX", side = "east", wired = false },
  },
})
local tabletD = newClient(bus, { address = "tabletD", side = "tabletDSide" })
equal(#nodeD.dns.modems, 2, "both modems are opened")
equal(bus.opened["modemDW"], true, "wired modem opened port 4201")
equal(bus.opened["modemDX"], true, "wireless modem opened port 4201")

bus:inject("modemDX", "east", "tabletD", 4201, "DNS1 WHO rid=000000d1 id=tabletD")
bus:drain()
equal(bus.sentVia["modemDX"], 1, "the reply leaves through the ingress side")
equal(bus.sentVia["modemDW"], nil, "the other modem does not answer")

bus:inject("modemDW", "modemDW", "tabletD", 4201, "DNS1 WHO rid=000000d2 id=tabletD")
bus:drain()
equal(bus.sentVia["modemDW"], 1, "the reply also works when the ingress value is an address")

nodeA.node:tick(1000)
nodeB.node:tick(1000)
bus:drain()

check(nodeA.node:version() >= 1, "node A has a snapshot version")
equal(masterNode.master:entries()["addrA"] ~= nil, true, "master cached node A")
equal(masterNode.master:entries()["addrB"] ~= nil, true, "master cached node B")

local catalog = masterNode.master:catalog()
equal(#catalog.nodes, 2, "catalog lists both nodes")
equal(catalog.stale, false, "fresh catalog is not stale")
check(findByName(catalog.nodes, "addrA") ~= nil, "catalog has node A")
equal(findByName(catalog.nodes, "addrA").endpoints[1], "dns.status", "catalog lists endpoints")
equal(findByName(catalog.nodes, "addrA").paths[1], "spike", "catalog lists paths")

local parsed = nodeA.dns:parse({
  "modem_message", "left", "addrC", 4201, 0, "DNS1 WHO rid=1 id=addrC",
})
equal(parsed.side, "left", "parser reads the documented shape")
equal(parsed.from, "addrC", "parser reads the sender")

parsed = nodeA.dns:parse({
  "modem_message", "addrC", "right", 4201, "DNS1 WHO rid=1 id=addrC",
})
equal(parsed.side, "right", "parser tolerates a shortened shape")
equal(parsed.from, "addrC", "short shape keeps the sender")

parsed = nodeA.dns:parse({
  "modem_message", "left", "addrC", 4200, 0, "DNS1 WHO rid=1 id=addrC",
})
equal(parsed.ignored, true, "a DNS1 frame on another port is ignored")

local direct = newClient(bus)
local hello, helloReason = direct.client:request("addrA", "HELLO", {
  node = "addrA",
  proto = "DNS1",
  boot = "bootA",
  transports = "wired",
}, 1, "addrA")
equal(hello and hello.ver, "2", "HELLO returns the protocol version")
equal(hello and hello.boot, "bootA", "HELLO returns bootId")
equal(hello and hello.transports, "wired", "HELLO returns transports")
equal(hello and hello.id, "addrA", "HELLO returns the sender id")
equal(hello and hello.node, "addrA", "HELLO identifies the node id")

local described, describeReason = direct.client:describe("addrA", "node")
check(described ~= nil, "DESCRIBE node works: " .. tostring(describeReason))
equal(described and described.node.id, "addrA", "DESCRIBE returns the node id")
equal(described and described.node.docs, "Test line node.", "DESCRIBE returns node docs")
check(findByName(described and described.endpoints, "inventory_controller") ~= nil,
  "DESCRIBE lists the component endpoint")
check(findByName(described and described.paths, "spike") ~= nil,
  "DESCRIBE lists the spike path")

local endpoint, endpointReason = direct.client:describe("addrA", "endpoint:inventory_controller")
check(endpoint ~= nil, "DESCRIBE endpoint works: " .. tostring(endpointReason))
equal(endpoint and endpoint.kind, "component", "component endpoint kind")
equal(endpoint and endpoint.address, "invA", "component endpoint address")
check(findByName(endpoint and endpoint.methods, "getAllStacks") ~= nil,
  "endpoint documents getAllStacks")
check(findByName(endpoint and endpoint.methods, "getStackInSlot") ~= nil,
  "endpoint documents getStackInSlot")
equal(endpoint and endpoint.allow[1], "getAllStacks", "endpoint allowlist is published")

local status, statusReason = direct.client:describe("addrA", "endpoint:dns.status")
check(status ~= nil, "DESCRIBE dns.status works: " .. tostring(statusReason))
equal(status and status.kind, "service", "dns.status is a service")
check(findByName(status and status.methods, "status") ~= nil, "dns.status documents status")

local stacks, stacksReason = direct.client:exec("addrA", "endpoint:inventory_controller",
  "getAllStacks")
check(stacks ~= nil, "allowed method executes: " .. tostring(stacksReason))
equal(stacks and stacks[1].name, "minecraft:stone", "allowed method returns the inventory")

local denied, deniedReason = direct.client:exec("addrA", "endpoint:inventory_controller",
  "getStackInSlot", { 1 })
equal(denied, nil, "unlisted method is denied")
equal(deniedReason, "denied", "denied error code")

local unknown, unknownReason = direct.client:exec("addrA", "endpoint:inventory_controller",
  "noSuchMethod")
equal(unknown, nil, "unknown method is rejected")
equal(unknownReason, "unknown_method", "unknown_method error code")

local dnsStatus, dnsStatusReason = direct.client:exec("addrA", "endpoint:dns.status", "status")
check(dnsStatus ~= nil, "dns.status executes: " .. tostring(dnsStatusReason))
equal(dnsStatus and dnsStatus.id, "addrA", "dns.status returns the node id")
equal(dnsStatus and dnsStatus.dnsPort, 4201, "dns.status returns the port")
check(dnsStatus.calls >= 2, "dns.status counts executions")

local tooLarge, tooLargeReason = direct.client:exec("addrC", "endpoint:big", "blob")
equal(tooLarge, nil, "an oversized answer is not delivered")
equal(tooLargeReason, "too_large", "an oversized answer returns too_large")

--------------------------------------------------------------------------------
-- Master route, catalog and fallback
--------------------------------------------------------------------------------

local viaMaster = newClient(bus, { address = "clientM", side = "clientMSide", master = "masterM" })
local masterCatalog, masterReason = viaMaster.client:catalog()
check(masterCatalog ~= nil, "client catalog works: " .. tostring(masterReason))
equal(#masterCatalog.nodes, 2, "client catalog has both nodes")

local masterExec, masterExecReason = viaMaster.client:exec("addrA",
  "endpoint:inventory_controller", "getAllStacks")
check(masterExec ~= nil, "master forwards EXEC: " .. tostring(masterExecReason))
equal(masterExec and masterExec[1].name, "minecraft:stone", "forwarded EXEC returns data")

local masterDescribe, masterDescribeReason = viaMaster.client:describe("addrA",
  "endpoint:dns.status")
check(masterDescribe ~= nil, "master serves DESCRIBE: " .. tostring(masterDescribeReason))
equal(masterDescribe and masterDescribe.name, "dns.status", "master describe endpoint name")

bus.clock = bus.clock + 100
local staleCatalog = masterNode.master:catalog()
equal(staleCatalog.stale, true, "catalog marks stale nodes")

local down = newClient(bus, { address = "tabletT", side = "tabletSide", master = "missingMaster" })
local fallback, fallbackReason = down.client:describe("addrA", "endpoint:dns.status")
check(fallback ~= nil, "client falls back to the node when the master is down: " ..
  tostring(fallbackReason))
equal(fallback and fallback.name, "dns.status", "fallback returns node documentation")
local fallbackExec, fallbackExecReason = down.client:exec("addrA",
  "endpoint:inventory_controller", "getAllStacks")
check(fallbackExec ~= nil, "fallback EXEC works: " .. tostring(fallbackExecReason))
equal(fallbackExec and fallbackExec[1].name, "minecraft:stone", "fallback EXEC returns data")

-- The master is up but has no snapshot of addrC: it answers offline, and the
-- client still resolves the node directly.
local viaUp = newClient(bus, { address = "tabletU", side = "tabletUSide", master = "masterM" })
local uncached, uncachedReason = viaUp.client:describe("addrC", "endpoint:dns.status")
check(uncached ~= nil, "client falls back when the master answers offline: " ..
  tostring(uncachedReason))
equal(uncached and uncached.name, "dns.status", "offline fallback returns documentation")
local uncachedExec, uncachedExecReason = viaUp.client:exec("addrC",
  "endpoint:inventory_controller", "getAllStacks")
check(uncachedExec ~= nil, "offline fallback EXEC works: " .. tostring(uncachedExecReason))
equal(uncachedExec and uncachedExec[1].name, "minecraft:stone", "offline fallback EXEC data")

--------------------------------------------------------------------------------
-- Dedupe, ingress reply, foreign ports and errors
--------------------------------------------------------------------------------

local calls = 0
local originalHandle = nodeB.node.handle
nodeB.node.handle = function(self, verbName, incoming)
  if verbName == "WHO" then
    calls = calls + 1
  end
  return originalHandle(self, verbName, incoming)
end
nodeB.dns.onFrame = function(side, from, verbName, incoming)
  return nodeB.node:handle(verbName, incoming)
end

local tablet = newClient(bus, { address = "tabletX", side = "tabletSideX" })
bus:inject("addrB", "modemB", "tabletX", 4201, "DNS1 WHO rid=deadbeef id=tabletX")
bus:drain()
bus:inject("addrB", "modemB", "tabletX", 4201, "DNS1 WHO rid=deadbeef id=tabletX")
bus:drain()
equal(calls, 1, "duplicate (from, rid) is handled once")
equal(nodeB.dns:stats().dup, 1, "duplicate counter increments")

local replyCount = 0
tablet.dns.onFrame = function()
  replyCount = replyCount + 1
  return nil
end
bus:inject("addrA", "modemA", "tabletX", 4201, "DNS1 WHO rid=cafebabe id=tabletX")
bus:drain()
equal(replyCount, 1, "the node answers through the ingress receiver address")

local droppedBefore = nodeA.dns:stats().dropped
bus:inject("addrA", "modemA", "addrC", 4200, "DNS1 WHO rid=1 id=addrC")
bus:drain()
equal(nodeA.dns:stats().dropped, droppedBefore + 1, "foreign port frames are dropped")

local ownDropped = nodeA.dns:stats().dropped
bus:inject("addrA", "modemA", "addrA", 4201, "DNS1 WHO rid=2 id=addrA")
bus:drain()
equal(nodeA.dns:stats().dropped, ownDropped, "own frames are ignored without counting as dropped")

local errorReply = nil
tablet.dns.onFrame = function(_, _, verbName, incoming)
  if verbName == "ERR" then
    errorReply = incoming
  end
  return nil
end
bus:inject("addrA", "modemA", "tabletX", 4201, "DNS1 NOPE rid=12345678 id=tabletX")
bus:drain()
check(errorReply ~= nil, "unknown verb gets an ERR frame")
equal(errorReply and errorReply.err, "unknown_verb", "ERR names the unknown verb")
equal(errorReply and errorReply.rid, "12345678", "ERR echoes the request rid")

local tooLarge, tooLargeReason = direct.client:exec("addrA", "endpoint:dns.status", "status",
  { string.rep("x", 900) })
equal(tooLarge, nil, "oversized request is not sent")
equal(tooLargeReason, "too_large", "oversized request reports too_large")

-- Regression: a fresh client's first rid (00000001) collides with the rid the
-- node used for its first PUBLISH. PUBLISHACK/EXECACK are replies and must not
-- enter the request dedupe table, or the relayed EXEC is silently dropped.
local relayBus = Bus.new()
newMaster(relayBus)
local relayNode = newNode(relayBus, {
  address = "addrR",
  side = "modemR",
  wired = true,
  inventory = "invR",
  master = "masterM",
  boot = "bootR",
  name = "Line R",
})
relayNode.node:tick(1000)
relayBus:drain()
local relayClient = newClient(relayBus, {
  address = "tabletR",
  side = "tabletRSide",
  master = "masterM",
})
local relayResponse, relayReason, relayVerb = relayClient.client:request("masterM", "EXEC", {
  node = "addrR",
  target = "endpoint:dns.status",
  method = "status",
  p = value.encode({}),
}, 1, "masterM")
check(relayResponse ~= nil, "first relayed EXEC survives the publish rid collision: " ..
  tostring(relayReason))
equal(relayVerb, "EXECACK", "relayed EXEC answers with EXECACK")
equal(relayResponse and relayResponse.ok, "true", "relayed EXEC is accepted")
equal(relayNode.dns:stats().dup, 0, "the node did not dedupe the relayed EXEC")

--------------------------------------------------------------------------------
-- M1: complete registry, delta publish, heartbeat, resync and persistence
--------------------------------------------------------------------------------

local m1Bus = Bus.new()
local m1Vfs = newVfs()
local m1Master = newMaster(m1Bus, { vfs = m1Vfs })
local m1Node = newNode(m1Bus, {
  address = "addrM1",
  side = "modemM1",
  wired = true,
  inventory = "invM1",
  master = "masterM",
  boot = "bootM1",
  name = "Line M1",
  vfs = m1Vfs,
})
local plantReads = 0
m1Node.node:registerPlant({
  status = function()
    plantReads = plantReads + 1
    return { id = "plant-1", memory = 72, energy = 94, stock = 3, alarms = 1 }
  end,
  alarms = function()
    return { { level = "warn", code = "low_energy" } }
  end,
  snapshot = function()
    return { stocks = { iron = 12 }, rates = { iron = 0.5 } }
  end,
})
m1Node.node:addPath({
  name = "all",
  members = { "dns.status", "plant", "inventory_controller" },
  tags = { "dns", "m1" },
  docs = "Every endpoint this node publishes.",
})
m1Node.node:tick(1000)
m1Bus:drain()

local m1Entry = m1Master.master:entries()["addrM1"]
check(m1Entry ~= nil and m1Entry.complete, "M1 node publishes a complete snapshot")
equal(m1Master.master:publishStats().full, 1, "the first publish is full")
equal(countKeys(m1Entry and m1Entry.parts), 3, "full publish carries every endpoint part")
check(m1Entry.parts["plant"] ~= nil, "the plant endpoint part reached the master")
check(findByName(m1Entry.index.endpoints, "plant") ~= nil, "index advertises the plant endpoint")
check(findByName(m1Entry.index.paths, "all") ~= nil, "index advertises the complete path")
local plantSummary = findByName(m1Entry.index.endpoints, "plant")
equal(m1Entry.parts["plant"].rev, plantSummary and plantSummary.rev,
  "endpoint revisions are published with the summary")

local m1Client = newClient(m1Bus, {
  address = "m1client",
  side = "m1clientSide",
  master = "masterM",
})
local plantStatus, plantStatusReason = m1Client.client:exec("addrM1", "endpoint:plant", "status")
check(plantStatus ~= nil, "plant status executes: " .. tostring(plantStatusReason))
equal(plantStatus and plantStatus.energy, 94, "plant status returns the local readout")
equal(plantReads, 1, "the service handler runs once")
local plantAlarms, plantAlarmsReason = m1Client.client:exec("addrM1", "endpoint:plant", "alarms")
check(plantAlarms ~= nil, "plant alarms execute: " .. tostring(plantAlarmsReason))
equal(plantAlarms and plantAlarms[1].code, "low_energy", "plant alarms return local alarms")
local plantSnapshot, plantSnapshotReason = m1Client.client:exec("addrM1", "endpoint:plant",
  "snapshot")
check(plantSnapshot ~= nil, "plant snapshot executes: " .. tostring(plantSnapshotReason))
equal(plantSnapshot and plantSnapshot.stocks.iron, 12, "plant snapshot returns stocks")
local plantUnknown, plantUnknownReason = m1Client.client:exec("addrM1", "endpoint:plant",
  "noSuchMethod")
equal(plantUnknown, nil, "plant rejects an unknown method")
equal(plantUnknownReason, "unknown_method", "plant unknown method error")

local partsBefore = countKeys(m1Entry.parts)
m1Node.node:registerService({
  name = "extra",
  service = "extra",
  tags = { "test" },
  docs = "Endpoint registered after the first publish.",
  methods = {
    ping = {
      mode = "read",
      description = "Returns a ping.",
      args = {},
      returns = "table",
    },
  },
  allow = { "ping" },
  handler = function()
    return { pong = true }
  end,
})
m1Bus.clock = 1001
m1Node.node:tick(1001)
m1Bus:drain()

m1Entry = m1Master.master:entries()["addrM1"]
check(m1Entry.complete, "delta publish completes the snapshot")
equal(m1Master.master:publishStats().delta, 1, "the second publish is a delta")
equal(countKeys(m1Entry.parts), partsBefore + 1, "delta sends only the new endpoint part")
check(m1Entry.parts["extra"] ~= nil, "the delta part reached the master")
equal(m1Node.node:status().publish.delta, 1, "the node counts one delta")
local extra, extraReason = m1Client.client:exec("addrM1", "endpoint:extra", "ping")
check(extra ~= nil, "delta endpoint executes: " .. tostring(extraReason))
equal(extra and extra.pong, true, "delta endpoint handler runs")

-- A quiet node sends an index-only heartbeat before the 90 s stale window.
m1Bus.clock = 1045
m1Node.node:tick(1045)
m1Bus:drain()
equal(m1Master.master:publishStats().heartbeat, 0, "heartbeat waits for HEARTBEAT_AFTER")
m1Bus.clock = 1046
m1Node.node:tick(1046)
m1Bus:drain()
equal(m1Master.master:publishStats().heartbeat, 1, "a quiet node sends an index heartbeat")
equal(countKeys(m1Entry.parts), partsBefore + 1, "heartbeat does not resend endpoint parts")
equal(m1Master.master:entries()["addrM1"].lastSeen, 1046, "heartbeat refreshes lastSeen")

-- The master loses the base snapshot: its ACK asks for a full publish, and the
-- node resends every part on the next tick.
m1Master.master.cache["addrM1"] = nil
m1Node.node:bump()
m1Bus.clock = 1047
m1Node.node:tick(1047)
m1Bus:drain()
equal(m1Node.node:status().publish.resync, 1, "a missing base requests a resync")
check(m1Node.node.forceFull, "the node arms a full publish after need=full")
m1Node.node:tick(1048)
m1Bus:drain()
m1Entry = m1Master.master:entries()["addrM1"]
check(m1Entry ~= nil and m1Entry.complete, "resync restores a complete snapshot")
equal(countKeys(m1Entry.parts), partsBefore + 1, "resync resends every endpoint part")
equal(m1Node.node:status().publish.full, 2, "the node counts two full publishes")

-- Catalog pages report total, page size and the cursor.
local m2Node = newNode(m1Bus, {
  address = "addrM2",
  side = "modemM2",
  wired = true,
  master = "masterM",
  boot = "bootM2",
  name = "Line M2",
})
m2Node.node:tick(1048)
m1Bus:drain()
local page1 = m1Master.master:catalog(nil, 1)
equal(page1.total, 2, "catalog reports the total before paging")
equal(page1.page, 1, "catalog echoes the page size")
equal(page1.count, 1, "catalog returns one node per page")
equal(page1.next, "addrM1", "catalog cursor names the last returned node")
local page2 = m1Master.master:catalog(page1.next, 1)
equal(page2.count, 1, "second catalog page has one node")
equal(page2.nodes[1].id, "addrM2", "second catalog page has the next node")
equal(page2.next, "-", "last catalog page ends the cursor")

-- Persistence: write complete snapshots, reload them into a new master, and
-- describe a part from the restored cache.
check(m1Master.master:save(1048), "master saves its cache")
check(m1Vfs.files["/var/dns/addrM1.value"] ~= nil, "cache file is written under /var/dns")
local loadedMaster = dnsmaster.new({
  id = "masterL",
  computer = m1Master.computer,
  vfs = m1Vfs,
})
equal(loadedMaster.loaded, 2, "a new master loads both snapshots")
local loadedEntry = loadedMaster:entries()["addrM1"]
check(loadedEntry ~= nil and loadedEntry.complete, "loaded entry is complete")
check(loadedEntry.loaded, "loaded entry is marked loaded")
local loadedPlant, loadedPlantReason = loadedMaster:describe("addrM1", "endpoint:plant")
check(loadedPlant ~= nil, "loaded master serves DESCRIBE: " .. tostring(loadedPlantReason))
equal(loadedPlant and loadedPlant.kind, "service", "loaded describe returns the endpoint")
local loadedCatalog = loadedMaster:catalog(nil, 8)
equal(loadedCatalog.total, 2, "loaded catalog has both nodes")
check(loadedCatalog.nodes[1].loaded, "catalog exposes the loaded flag")

-- Turning the master Off closes it; back On must reload the same cache.
check(m1Master.master:close(), "stopping the master saves its cache")
local offAndBack = dnsmaster.new({
  id = "addrM1",
  transport = m1Bus,
  vfs = m1Vfs,
  now = function() return 1049 end,
})
equal(offAndBack:catalog(nil, 8).total, 2,
  "a master started after Off reloads the catalog")
check(offAndBack:describe("addrM1", "endpoint:plant") ~= nil,
  "the reloaded master still serves a node document")
offAndBack:close()

--------------------------------------------------------------------------------
-- M2: EDIT with revisions, conflicts and resync
--------------------------------------------------------------------------------

local extraDoc, extraDocReason = m1Client.client:describe("addrM1", "endpoint:extra")
check(extraDoc ~= nil, "EDIT reads the current endpoint: " .. tostring(extraDocReason))
local extraRev = extraDoc.rev
local edited, editedReason = m1Client.client:edit("addrM1", "endpoint:extra", "docs",
  "Edited through DNS1.", extraRev)
check(edited ~= nil and edited.ok, "EDIT applies when the revision matches: " ..
  tostring(editedReason))
check(edited.rev > extraRev, "EDIT returns the new revision")
equal(m1Node.node.endpoints.extra.docs, "Edited through DNS1.", "the endpoint document changed")
equal(m1Node.node.editStats.applied, 1, "the node counts one applied edit")

-- The stale write is rejected and carries the current document for a resync.
local conflict = m1Client.client:edit("addrM1", "endpoint:extra", "docs",
  "Late write.", extraRev)
check(conflict ~= nil, "EDIT conflict is answered")
equal(conflict.ok, false, "stale EDIT is refused")
equal(conflict.err, "conflict", "stale EDIT reports a conflict")
equal(conflict.rev, edited.rev, "conflict returns the current revision")
check(conflict.body ~= nil, "conflict carries the current endpoint")
equal(conflict.body and conflict.body.docs, "Edited through DNS1.",
  "conflict body is the current document")
equal(m1Node.node.endpoints.extra.docs, "Edited through DNS1.", "conflict does not overwrite")
equal(m1Node.node.editStats.conflict, 1, "the node counts one conflict")

m1Bus.clock = 1049
m1Node.node:tick(1049)
m1Bus:drain()
m1Entry = m1Master.master:entries()["addrM1"]
equal(m1Entry.parts["extra"].docs, "Edited through DNS1.", "EDIT republishes the endpoint delta")
equal(m1Entry.parts["extra"].rev, edited.rev, "the delta carries the new revision")
local afterEdit, afterEditReason = m1Client.client:describe("addrM1", "endpoint:extra")
check(afterEdit ~= nil, "DESCRIBE after EDIT: " .. tostring(afterEditReason))
equal(afterEdit.docs, "Edited through DNS1.", "the master serves the edited document")

local tagsEdit, tagsReason = m1Client.client:edit("addrM1", "endpoint:extra", "tags",
  { "edited", "m2" }, edited.rev)
check(tagsEdit ~= nil and tagsEdit.ok, "tags are editable: " .. tostring(tagsReason))
equal(m1Node.node.endpoints.extra.tags[2], "m2", "tags are replaced")
local badTags, badTagsReason = m1Client.client:edit("addrM1", "endpoint:extra", "tags",
  { "ok", 5 }, tagsEdit.rev)
check(badTags ~= nil, "invalid tags are answered: " .. tostring(badTagsReason))
equal(badTags.ok, false, "invalid tags are rejected")
equal(badTags.err, "bad_value", "invalid tags report bad_value")
local unknownField = m1Client.client:edit("addrM1", "endpoint:extra", "methods", {},
  tagsEdit.rev)
equal(unknownField.err, "unknown_field", "methods are not editable")
local tooLarge = m1Client.client:edit("addrM1", "endpoint:plant", "docs",
  string.rep("x", 500), m1Node.node.endpointRevs["plant"])
equal(tooLarge.err, "too_large", "an edit that would not fit a frame is rejected")
check(#m1Node.node.endpoints.plant.docs < 500, "a rejected edit leaves the document alone")

-- The node document uses the snapshot revision.
local nodeDocsEdit = m1Client.client:edit("addrM1", "node", "docs", "Line docs edited.",
  m1Node.node:status().snapshot)
check(nodeDocsEdit ~= nil and nodeDocsEdit.ok, "the node document is editable")
equal(m1Node.node.docs, "Line docs edited.", "the node document changed")
local nodeConflict = m1Client.client:edit("addrM1", "node", "docs", "Stale node.",
  m1Node.node:status().snapshot - 1)
equal(nodeConflict.err, "conflict", "a stale node revision conflicts")

-- Edits survive a node restart when the kernel passes the VFS.
check(m1Vfs.files["/var/dns/edits.value"] ~= nil, "EDIT writes an override file")
local restored = dnsnode.new({
  id = "addrM1",
  name = "Line M1",
  ver = "0.4.9",
  boot = "boot-restored",
  vfs = m1Vfs,
  computer = m1Node.computer,
})
restored:registerService({
  name = "extra",
  service = "extra",
  tags = { "test" },
  docs = "Code default.",
  methods = { ping = { mode = "read", description = "Ping.", args = {}, returns = "table" } },
  allow = { "ping" },
  handler = function()
    return { pong = true }
  end,
})
equal(restored.endpoints.extra.docs, "Edited through DNS1.", "an override is applied on restart")
equal(restored.endpoints.extra.tags[2], "m2", "tags survive a restart")
equal(restored.docs, "Line docs edited.", "the node document survives a restart")

--------------------------------------------------------------------------------
-- M3: EXEC frame-safe arguments and results
--------------------------------------------------------------------------------

m1Node.node:registerService({
  name = "echo",
  service = "echo",
  tags = { "test" },
  docs = "Echo service.",
  methods = {
    echo = { mode = "read", description = "Echo.", args = { "..." }, returns = "table" },
  },
  allow = { "echo" },
  handler = function(_, args)
    return { n = #args, first = args[1] }
  end,
})
local echo, echoReason = m1Client.client:exec("addrM1", "endpoint:echo", "echo", { "a", "b" })
check(echo ~= nil, "EXEC passes positional arguments: " .. tostring(echoReason))
equal(echo and echo.n, 2, "the handler receives both arguments")
equal(echo and echo.first, "a", "argument order is preserved")
local tooMany, tooManyReason = m1Client.client:exec("addrM1", "endpoint:echo", "echo",
  { 1, 2, 3, 4, 5, 6, 7, 8, 9 })
equal(tooMany, nil, "EXEC rejects too many arguments")
equal(tooManyReason, "bad_args", "too many arguments report bad_args")

m1Node.node:registerService({
  name = "big",
  service = "big",
  tags = { "test" },
  docs = "Returns a body too large for one frame.",
  methods = {
    get = { mode = "read", description = "Large body.", args = {}, returns = "table" },
  },
  allow = { "get" },
  handler = function()
    return { text = string.rep("x", 900) }
  end,
})
local big, bigReason = m1Client.client:exec("addrM1", "endpoint:big", "get")
equal(big, nil, "EXEC rejects a result that does not fit one frame")
equal(bigReason, "too_large", "an oversized result reports too_large before the wire")

--------------------------------------------------------------------------------
-- M4: STATE and INBOX
--------------------------------------------------------------------------------

m1Node.node:registerState()
m1Node.node:registerInbox()
local stateSet, stateSetReason = m1Client.client:exec("addrM1", "endpoint:state", "set",
  { "mode", "eco" })
check(stateSet ~= nil, "STATE set succeeds: " .. tostring(stateSetReason))
local stateGet = m1Client.client:exec("addrM1", "endpoint:state", "get", { "mode" })
equal(stateGet and stateGet.found, true, "STATE get finds the key")
equal(stateGet and stateGet.value, "eco", "STATE get returns the value")
local stateList = m1Client.client:exec("addrM1", "endpoint:state", "list")
equal(stateList and stateList.keys[1], "mode", "STATE list returns keys")
local badState, badStateReason = m1Client.client:exec("addrM1", "endpoint:state", "set",
  { "bad key!", 1 })
equal(badState, nil, "STATE rejects an invalid key")
equal(badStateReason, "bad_args", "an invalid key reports bad_args")
local stateDelete = m1Client.client:exec("addrM1", "endpoint:state", "delete", { "mode" })
equal(stateDelete and stateDelete.removed, true, "STATE delete removes the key")
local missingState = m1Client.client:exec("addrM1", "endpoint:state", "get", { "mode" })
equal(missingState and missingState.found, false, "a missing key reports found=false")

m1Client.client:exec("addrM1", "endpoint:state", "set", { "restart", "kept" })
check(m1Vfs.files["/var/dns/state.value"] ~= nil, "STATE writes its file")
local stateRestored = dnsnode.new({
  id = "addrM1",
  vfs = m1Vfs,
  boot = "boot-state",
  computer = m1Node.computer,
})
equal(stateRestored.stateData.restart, "kept", "STATE survives a restart")

local post1 = m1Client.client:exec("addrM1", "endpoint:inbox", "post", { "first" })
check(post1 ~= nil and post1.id, "INBOX post returns an id")
local post2 = m1Client.client:exec("addrM1", "endpoint:inbox", "post", { "second" })
local inboxList = m1Client.client:exec("addrM1", "endpoint:inbox", "list", { 10 })
equal(inboxList and #inboxList.messages, 2, "INBOX list returns both messages")
local taken = m1Client.client:exec("addrM1", "endpoint:inbox", "take", { post1.id })
equal(taken and taken.found, true, "INBOX take finds the message")
equal(taken and taken.message, "first", "INBOX take returns the message")
equal(m1Vfs.files["/var/dns/inbox.value"] ~= nil, true, "INBOX writes its file")
local cleared = m1Client.client:exec("addrM1", "endpoint:inbox", "clear")
equal(cleared and cleared.cleared, 1, "INBOX clear reports the count")
local empty = m1Client.client:exec("addrM1", "endpoint:inbox", "list", {})
equal(empty and #empty.messages, 0, "INBOX is empty after clear")

-- Both services must fit one publish frame alongside a normal registry.
local statePart = value.encode(m1Node.node:snapshot().endpoints.state)
local inboxPart = value.encode(m1Node.node:snapshot().endpoints.inbox)
check(#statePart < 800, "the state endpoint fits one frame (" .. #statePart .. " B)")
check(#inboxPart < 800, "the inbox endpoint fits one frame (" .. #inboxPart .. " B)")
m1Bus.clock = 1050
m1Node.node:tick(1050)
m1Bus:drain()
local covered = m1Master.master:entries()["addrM1"]
check(covered ~= nil and covered.parts.state ~= nil, "STATE publishes as a delta part")
check(covered ~= nil and covered.parts.inbox ~= nil, "INBOX publishes as a delta part")

--------------------------------------------------------------------------------
-- Result
--------------------------------------------------------------------------------

if #failures > 0 then
  return table.concat(failures, "\n")
end
return "dns: " .. tostring(checked) .. " checks passed"
