-- Tests for the harness-only 0.4.3/0.4.6 modules: tc.halls, tc.gate and
-- tc.move. The hardware for a second hall and a real gate is not built, so
-- these cover the logic and leave the in-game run pending.

local halls = require("tc.halls")
local gate = require("tc.gate")
local move = require("tc.move")

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

local function newVfs(files)
  files = files or {}
  return {
    files = files,
    read = function(path)
      return files[path]
    end,
    write = function(path, data)
      files[path] = data
      return true
    end,
    ensureDir = function()
      return true
    end,
  }
end

--------------------------------------------------------------------------------
-- Halls
--------------------------------------------------------------------------------

local hallVfs = newVfs({
  ["/etc/halls.tsv"] = table.concat({
    "# hall\taddress",
    "hall1\taddr-1",
    "hall2\taddr-2",
    "bad name!\taddr-3",
  }, "\n") .. "\n",
})

local registry = halls.load(hallVfs)
equal(#registry.list, 2, "two valid halls load")
equal(#registry.errors, 1, "one invalid hall is reported")
check(registry.configured == true, "the registry is configured")

local here = halls.localHall(registry, "addr-2", "TC-X")
equal(here.name, "hall2", "the local hall resolves by address")
equal(here.isLocal, true, "the local hall is marked local")

local implicit = halls.localHall(halls.new(), "addr-9", "TC-X")
equal(implicit.name, "TC-X", "an implicit hall uses the hostname")
equal(implicit.implicit, true, "the implicit hall is marked")

local merged = halls.merge(registry, {
  ["addr-1"] = {
    age = 5,
    snapshot = {
      stocks = {
        { name = "ore/input", kind = "item", state = "exact", total = 10, entries = {} },
      },
    },
  },
}, { staleAfter = 30 })

equal(merged.online, 1, "one hall is online")
equal(merged.offline, 1, "one hall is offline")
equal(#merged.stocks, 1, "only the online hall contributes stocks")
equal(merged.stocks[1].name, "hall1/ore/input", "the merged stock is prefixed with its hall")
equal(find(merged.halls, function(item) return item.name == "hall2" end).state, "offline",
  "the missing hall is offline, not dropped")

local stale = halls.merge(registry, {
  ["addr-1"] = { age = 60, snapshot = { stocks = {} } },
}, { staleAfter = 30 })
equal(stale.stale, 1, "an old snapshot is stale")
equal(stale.stocks and #stale.stocks, 0, "a stale hall does not pretend to have stocks")

local added = halls.assign(registry, "hall3", "addr-3b")
check(added ~= nil, "a hall can be assigned")
check(halls.save(hallVfs, registry), "the registry saves")
local reloaded = halls.load(hallVfs)
equal(#reloaded.list, 3, "the saved hall reloads")

--------------------------------------------------------------------------------
-- Gates
--------------------------------------------------------------------------------

local gateVfs = newVfs({
  ["/etc/gates.tsv"] = table.concat({
    "# line\tcomponent\tface\tinput\toutput",
    "lv\tcomp-gate\t1\tline/input\tline/output",
    "hv\tcomp-gate2\t2\t\t",
  }, "\n") .. "\n",
})

local gates = gate.new({ vfs = gateVfs })
equal(#gates.order, 2, "two gates load")
equal(#gates.errors, 0, "the gate config is valid")

local setpoint = gates:set("lv", 1)
check(setpoint ~= nil and setpoint.desired == 1, "the setpoint stores one")
check(gateVfs.files["/var/gates.tsv"] ~= nil, "the setpoint is persisted")

local reborn = gate.new({ vfs = gateVfs })
equal(reborn:line("lv").desired, 1, "the setpoint survives a new instance")

local emptyOk, emptyWhy = gates:plan("lv", 1, {
  input = { total = 0, min = 1 },
})
check(emptyOk == nil and emptyWhy == "input_empty", "an empty input refuses to open")

local fullOk, fullWhy = gates:plan("lv", 1, {
  input = { total = 10, min = 1 },
  output = { total = 64, max = 64 },
})
check(fullOk == nil and fullWhy == "output_full", "a full output refuses to open")

check(gates:plan("lv", 1, {
  input = { total = 10, min = 1 },
  output = { total = 0, max = 64 },
}) == true, "a healthy line may open")

local calls = {}
local proxy = {
  setOutput = function(side, state)
    calls[#calls + 1] = { side = side, state = state }
    return true
  end,
}

local applied, actual = gates:reconcile("lv", proxy, {
  input = { total = 10, min = 1 },
  output = { total = 0, max = 64 },
})
check(applied == true and actual == 1, "the gate reconciles its setpoint")
equal(calls[1].side, 1, "the configured face is used")
equal(calls[1].state, 1, "the desired state is written")

for _ = 1, gate.REFUSALS do
  gates:reconcile("lv", proxy, { input = { total = 0, min = 1 } })
end
check(gates.disobedient.lv == true, "three refusals mark the line disobedient")
local alarm = find(gates:alarms(), function(item) return item.code == "DISOBEDIENT LINE" end)
check(alarm ~= nil and alarm.source == "lv", "the disobedient line raises an alarm")

gates:set("lv", 0)
check(gates.disobedient.lv == nil, "a new setpoint clears the disobedient state")
check(gates:plan("hv", 1, {}) == true, "a gate without stocks has no interlock")

local badLine, badLineWhy = gates:set("nope", 1)
check(badLine == nil and badLineWhy == "unknown_line", "an unknown line is refused")
local badState, badStateWhy = gates:set("lv", "maybe")
check(badState == nil and badStateWhy == "bad_state", "an invalid state is refused")

--------------------------------------------------------------------------------
-- Move
--------------------------------------------------------------------------------

local inventories = {
  [1] = {
    { name = "a", damage = 1, size = 64 },
    { name = "b", damage = 0, size = 10 },
    { name = "a", damage = 1, size = 64 },
  },
}
local transfers = {}

local transposer = {
  getAllStacks = function(side)
    return inventories[side] or {}
  end,
  transferItem = function(from, to, slot, amount)
    local stack = inventories[from] and inventories[from][slot]
    local sent = math.min(amount, stack and stack.size or 0)
    transfers[#transfers + 1] = { from = from, to = to, slot = slot, sent = sent }
    if stack then
      stack.size = stack.size - sent
    end
    return true, sent
  end,
}

local result = move.run(transposer, { from = 1, to = 2, key = "a", damage = 1, n = 100 })
equal(result.moved, 100, "100 matching items move")
equal(#result.slots, 2, "two slots were used")
equal(transfers[1].sent, 64, "the first slot gives its stack")
equal(transfers[2].sent, 36, "the second slot gives only the remainder")

local missing = move.run(transposer, { from = 1, to = 2, key = "nope", n = 1 })
equal(missing.moved, 0, "a missing key moves nothing")
equal(missing.reason, "key_not_found", "the missing key is named")

local refused = move.run({
  getAllStacks = function()
    return { { name = "a", damage = 1, size = 64 } }
  end,
  transferItem = function()
    return true, 0
  end,
}, { from = 1, to = 2, key = "a", damage = 1, n = 1 })
equal(refused.reason, "transport_refused", "a refused transport is reported")

local guarded = move.run(transposer, {
  from = 1,
  to = 2,
  key = "a",
  damage = 1,
  n = 1,
  guard = function()
    return false, "output_full"
  end,
})
equal(guarded.reason, "output_full", "the guard can refuse before moving")

local badCount = move.run(transposer, { from = 1, to = 2, key = "a", n = 0 })
equal(badCount.reason, "bad_count", "a zero count is rejected")

return table.concat(failures, "\n")
