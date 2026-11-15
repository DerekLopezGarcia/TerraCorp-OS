-- Tests for the 0.4.1 local plant readout: tc.addr, tc.path, tc.driver,
-- tc.stock, tc.tank and tc.plant. Run through tools/harness/test-plant.js.
--
-- The fake rig mirrors the in-game casing hall: two boundary crates, one
-- transport pipe, one tank and one missing member. Every component call is
-- counted so the one-call-per-tick budget and the idle-zero rule are visible.

local clock = 100
local components = {
  { address = "comp-ingot", kind = "transposer" },
  { address = "comp-case", kind = "transposer" },
  { address = "comp-pipe", kind = "transposer" },
  { address = "comp-tank", kind = "transposer" },
}

local proxies = {
  ["comp-ingot"] = {
    getInventoryName = function(side)
      return "gregtech:machine", side
    end,
    getInventorySize = function(side)
      return 2, side
    end,
    getAllStacks = function(side)
      return {
        { name = "gregtech:meta_ingot", damage = 113, size = 8, label = "Titanium Ingot", hasTag = false },
        { name = "minecraft:air", damage = 0, size = 0, label = "Air", hasTag = false },
        { name = "minecraft:air", damage = 0, size = 0, label = "Air", hasTag = false },
      }, side
    end,
  },
  ["comp-case"] = {
    getInventoryName = function(side)
      return "gregtech:machine", side
    end,
    getInventorySize = function(side)
      return 3, side
    end,
    getAllStacks = function(side)
      return {
        { name = "gregtech:machine_casing", damage = 4, size = 2, label = "EV Machine Casing", hasTag = false },
        { name = "gregtech:machine_casing", damage = 3, size = 1, label = "HV Machine Casing", hasTag = false },
      }, side
    end,
  },
  ["comp-pipe"] = {
    getInventoryName = function(side)
      return "gregtech:item_pipe_large", side
    end,
    getInventorySize = function(side)
      return 1, side
    end,
    getAllStacks = function(side)
      return {}, side
    end,
  },
  ["comp-tank"] = {
    getTankCount = function(side)
      return 1, side
    end,
    getFluidInTank = function(side, index)
      if index == 1 then
        return {
          { name = "water", label = "Water", amount = 1000, capacity = 1024, hasTag = false },
        }, side
      end
      return {}, side
    end,
  },
}

component = {
  list = function(kind)
    local index = 0
    return function()
      repeat
        index = index + 1
      until not components[index] or not kind or components[index].kind == kind
      local item = components[index]
      if item then
        return item.address, item.kind
      end
    end
  end,
  proxy = function(address)
    return proxies[address]
  end,
  type = function(address)
    if address == "comp-tank" then
      return "transposer"
    end
    return "transposer"
  end,
  methods = function(address)
    return { getInventoryName = true, getAllStacks = true, getTankCount = true }
  end,
  doc = function(address, method)
    return "doc " .. tostring(method)
  end,
}

computer = {
  address = function()
    return "node-1"
  end,
  uptime = function()
    return clock
  end,
}

local files = {
  ["/etc/paths.tsv"] = table.concat({
    "casing/ingots\tnode-1:comp-ingot:1\tsingle",
    "casing/casings\tnode-1:comp-case:1\tsingle",
    "casing/pipe\tnode-1:comp-pipe:1\tsingle",
    "casing/tank\tnode-1:comp-tank:1\tsingle",
    "casing/missing\tnode-1:comp-missing:1\tsingle",
  }, "\n") .. "\n",
  ["/etc/stocks.tsv"] = table.concat({
    "casing/ingots\titem",
    "casing/casings\titem",
    "casing/pipe\titem",
    "casing/tank\tfluid",
    "casing/missing\titem",
  }, "\n") .. "\n",
  ["/etc/plant.tsv"] = table.concat({
    "casing/ingots\t10\t0",
    "casing/casings\t0\t2",
  }, "\n") .. "\n",
}

local vfs = {
  read = function(path)
    return files[path]
  end,
  exists = function(path)
    return files[path] ~= nil
  end,
  write = function(path, data)
    files[path] = data
    return true
  end,
  ensureDir = function(path)
    return true
  end,
}

local addr = require("tc.addr")
local path = require("tc.path")
local driver = require("tc.driver")
local stock = require("tc.stock")
local plant = require("tc.plant")

local failures = {}
local function fail(message)
  failures[#failures + 1] = message
end

local function check(condition, message)
  if not condition then
    fail(message)
  end
end

local function equal(actual, expected, message)
  if actual ~= expected then
    fail(message .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
  end
end

local function find(list, predicate)
  for _, item in ipairs(list or {}) do
    if predicate(item) then
      return item
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Addresses
--------------------------------------------------------------------------------

local record = addr.parse("node-1:comp-ingot:1")
check(record ~= nil, "parse a full address")
if record then
  equal(record.node, "node-1", "parsed node")
  equal(record.component, "comp-ingot", "parsed component")
  equal(record.face, 1, "parsed face")
  equal(addr.format(record), "node-1:comp-ingot:1", "format address")
end

local short = addr.parse("comp-ingot:2")
check(short ~= nil and short.node == "node-1" and short.face == 2, "short address uses the local node")
check(addr.parse("node-1:comp-ingot:6") == nil, "face 6 is rejected")

local scanner = addr.new({ vfs = vfs })
local records = scanner:scan("transposer")
equal(#records, 4, "scan finds the four transposers")
if records[1] then
  check(records[1].first_seen ~= nil, "scan records first_seen")
end
check(files["/var/plant/seen.tsv"] ~= nil, "first_seen is persisted")

local proxy = addr.proxy(record)
check(proxy ~= nil, "local address resolves a proxy")
local remote, remoteWhy = addr.proxy(addr.parse("node-2:comp-ingot:1"))
check(remote == nil and remoteWhy == "remote node", "remote node is rejected")

--------------------------------------------------------------------------------
-- Paths
--------------------------------------------------------------------------------

check(path.valid("hall1/ore_processing"), "valid path")
check(not path.valid("/hall1"), "leading slash rejected")
check(not path.valid("hall1//tanks"), "empty segment rejected")
check(path.matches("hall1/*/tanks", "hall1/ore/tanks"), "single wildcard")
check(not path.matches("hall1/*/tanks", "hall1/ore/x/tanks"), "single wildcard is one segment")
check(path.matches("**/grinders", "grinders"), "double wildcard matches zero segments")
check(path.matches("**/grinders", "hall1/ore/grinders"), "double wildcard matches depth")
check(path.matches("*", "one"), "wildcard matches one segment")

local registry = path.new()
path.assign(registry, "a/b", "node-1:comp-ingot:1", "single")
path.assign(registry, "a/b", "node-1:comp-case:1", "single")
local entry, why = path.resolve(registry, "a/b")
check(entry == nil and why == "cardinality_mismatch", "two members on a single path")
path.assign(registry, "a/b", "node-1:comp-case:1", "pool")
entry = path.resolve(registry, "a/b")
check(entry ~= nil and entry.cardinality == "pool" and #entry.members == 2, "pool resolves")

local loaded, loadErrors = path.load(vfs)
check(#loadErrors == 0 and #path.list(loaded) == 5, "paths load from /etc/paths.tsv")

--------------------------------------------------------------------------------
-- Drivers
--------------------------------------------------------------------------------

local drivers = driver.new()
check(driver.faceKind("gregtech:machine") == "inventory", "machine face is inventory")
check(driver.faceKind("gregtech:item_pipe_large") == "transfer", "pipe face is transport")
check(driver.faceKind("gregtech:drum_tungstensteel") == "tank", "drum face is tank")
check(driver.faceKind("weird:block") == "unknown", "unknown face kind")

local transposer = driver.get(drivers, "transposer")
check(transposer ~= nil, "transposer descriptor")
local inventory = transposer.capabilities.inventory
local faceName = driver.invoke(proxies["comp-ingot"], inventory.name, { side = 1 })
equal(faceName, "gregtech:machine", "descriptor invokes a plain proxy function")
equal(driver.number("1,234,567"), 1234567, "formatted energy string normalizes")
equal(driver.number(42), 42, "plain number passes through")

local dump = driver.dump("comp-ingot")
check(dump ~= nil and #dump.methods >= 1 and dump.methods[1].doc ~= nil, "driver.dump returns methods and docs")

--------------------------------------------------------------------------------
-- Stocks
--------------------------------------------------------------------------------

local reader = stock.new({ vfs = vfs, addr = addr.new({ vfs = vfs }), pollInterval = 10 })
equal(#reader.stocks, 5, "five stocks load")

for _ = 1, 10 do
  reader:tick(clock)
end

local snapshot = reader:snapshot()
equal(reader.calls, 9, "one component call per tick for the whole scan")

local ingots = find(snapshot.stocks, function(item) return item.name == "casing/ingots" end)
check(ingots ~= nil, "ingot stock present")
if ingots then
  equal(ingots.state, "exact", "ingot stock is exact")
  equal(ingots.total, 8, "ingot total")
  equal(#ingots.entries, 1, "air slots are skipped")
  if ingots.entries[1] then
    equal(ingots.entries[1].label, "Titanium Ingot", "item label")
    equal(ingots.entries[1].damage, 113, "item damage")
    equal(ingots.entries[1].count, 8, "item count")
  end
end

local casings = find(snapshot.stocks, function(item) return item.name == "casing/casings" end)
if casings then
  equal(casings.state, "exact", "casing stock is exact")
  equal(casings.total, 3, "two casing types aggregate")
  equal(#casings.entries, 2, "two casing entries")
end

local pipe = find(snapshot.stocks, function(item) return item.name == "casing/pipe" end)
if pipe then
  equal(pipe.state, "unbound", "a pipe is not a stock")
  check(tostring(pipe.error):find("transport", 1, true) ~= nil, "pipe error names transport")
end

local missing = find(snapshot.stocks, function(item) return item.name == "casing/missing" end)
if missing then
  equal(missing.state, "unbound", "missing component is unbound")
end

local fluid = find(snapshot.stocks, function(item) return item.name == "casing/tank" end)
if fluid then
  equal(fluid.kind, "fluid", "tank stock kind")
  equal(fluid.state, "exact", "tank stock is exact")
  equal(fluid.total, 1000, "tank total in mB")
end

local callsAfterScan = reader.calls
for _ = 1, 3 do
  reader:tick(clock + 1)
end
equal(reader.calls, callsAfterScan, "idle stock makes zero component calls")

local delta = reader:delta(snapshot.generation)
check(delta.resync ~= true and #delta.changes == 0, "current cursor is not a resync")
local oldDelta = reader:delta(0)
check(oldDelta.resync == true and oldDelta.snapshot ~= nil, "old cursor asks for a resync")

--------------------------------------------------------------------------------
-- Plant alarms and status
--------------------------------------------------------------------------------

local stored, maximum = 100, 100
local kernel = {
  energy = function()
    return stored, maximum
  end,
  memory = function()
    return 1024, 4096
  end,
  link = nil,
}

local service = plant.new({
  kernel = kernel,
  vfs = vfs,
  version = { version = "0.4.1" },
  pollInterval = 10,
})

for _ = 1, 10 do
  service:tick()
end

local alarms = service:alarms()
local byCode = {}
for _, alarm in ipairs(alarms) do
  byCode[alarm.code] = (byCode[alarm.code] or 0) + 1
end
check((byCode.STARVED or 0) == 1, "STARVED alarm for the low ingot stock")
check((byCode.FULL or 0) == 1, "FULL alarm for the casing stock")
check((byCode.UNBOUND or 0) == 2, "UNBOUND alarms for the pipe and the missing member")
check((byCode["NO POWER"] or 0) == 0, "no power alarm while energy is full")

stored = 5
service:evaluate(clock)
byCode = {}
for _, alarm in ipairs(service:alarms()) do
  byCode[alarm.code] = (byCode[alarm.code] or 0) + 1
end
check((byCode["NO POWER"] or 0) == 1, "NO POWER alarm below 15 percent")

service.stock.stocks[1].updatedAt = clock - 100
service:evaluate(clock)
byCode = {}
for _, alarm in ipairs(service:alarms()) do
  byCode[alarm.code] = (byCode[alarm.code] or 0) + 1
end
check((byCode.STALE or 0) == 1, "STALE alarm for an old cache")

local plantSnapshot = service:snapshot()
equal(plantSnapshot.status.version, "0.4.1", "plant status version")
equal(plantSnapshot.configured, true, "plant is configured")
check(plantSnapshot.status.cacheAge ~= nil, "plant status cache age")

service:stop()
check(files["/var/plant/seen.tsv"] ~= nil, "plant stop persists first_seen")

return table.concat(failures, "\n")
