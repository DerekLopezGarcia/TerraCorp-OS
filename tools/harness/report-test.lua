-- Tests for tc.report: the line node's status publisher.
--
-- Run through tools/harness/test-report.js. Everything is fake except the
-- module under test: a modem that records frames, a plant that hands out the
-- snapshot the test wants, and a clock the test moves by hand.

local net = require("tc.net")
local report = require("tc.report")

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

--------------------------------------------------------------------------------
-- Fakes
--------------------------------------------------------------------------------

local ADDRESS = "line-0001"

local function newComputer()
  local state = { clock = 1000 }
  state.computer = {
    address = function()
      return ADDRESS
    end,
    uptime = function()
      return state.clock
    end,
    totalMemory = function()
      return 65536
    end,
    freeMemory = function()
      return 64536
    end,
    pullSignal = function()
      return nil
    end,
  }
  function state.advance(seconds)
    state.clock = state.clock + seconds
  end
  return state
end

local function newComponent(opts)
  opts = opts or {}
  local state = { sent = {}, broadcasts = {}, opened = false, port = nil, drawn = {} }
  local addresses = { modem = "modem-1", gpu = "gpu-1", screen = "screen-1" }
  if opts.noModem then
    addresses.modem = nil
  end
  if opts.noScreen then
    addresses.gpu = nil
    addresses.screen = nil
  end

  state.component = {
    list = function(kind)
      local address = addresses[kind]
      local served = false
      return function()
        if served or not address then
          return nil
        end
        served = true
        return address, kind
      end
    end,
    invoke = function(address, method, ...)
      local args = table.pack(...)
      if address == "modem-1" then
        if method == "isWired" then
          return true
        elseif method == "open" then
          state.opened = true
          state.port = args[1]
          return true
        elseif method == "close" then
          state.opened = false
          return true
        elseif method == "send" then
          state.sent[#state.sent + 1] = { to = args[1], port = args[2], frame = args[3] }
          return true
        elseif method == "broadcast" then
          state.broadcasts[#state.broadcasts + 1] = { port = args[1], frame = args[2] }
          return true
        end
        return nil, "unknown modem method " .. tostring(method)
      end
      if address == "gpu-1" then
        if method == "getResolution" then
          return true, 60, 20
        elseif method == "set" or method == "fill" or method == "bind"
          or method == "setForeground" or method == "setBackground" then
          state.drawn[#state.drawn + 1] = { method = method, text = args[3] }
          return true
        end
        return nil, "unknown gpu method " .. tostring(method)
      end
      return nil, "unknown component"
    end,
  }
  return state
end

local function newVfs()
  local vfs = { files = {}, dirs = {} }
  function vfs.exists(path)
    return vfs.files[path] ~= nil or vfs.dirs[path] == true
  end
  function vfs.ensureDir(path)
    vfs.dirs[path] = true
    return true
  end
  function vfs.write(path, data)
    vfs.files[path] = data
    return true
  end
  function vfs.read(path)
    return vfs.files[path]
  end
  return vfs
end

local function newConfig(values)
  local data = values or {}
  return {
    data = data,
    get = function(key)
      return data[key]
    end,
    set = function(key, value)
      data[key] = value
      return true
    end,
    save = function()
      return true
    end,
  }
end

local function newPlant(stocks, alarms)
  local plant = { stocks = stocks or {}, alarms = alarms or {} }
  function plant:snapshot()
    local stocksCopy, alarmsCopy = {}, {}
    for index, stock in ipairs(self.stocks) do
      stocksCopy[index] = stock
    end
    for index, alarm in ipairs(self.alarms) do
      alarmsCopy[index] = alarm
    end
    return { stocks = stocksCopy, alarms = alarmsCopy }
  end
  function plant:tick()
    return false
  end
  function plant:stop()
    return true
  end
  return plant
end

local function newReport(opts)
  opts = opts or {}
  local computer = opts.computer or newComputer()
  local component = opts.component or newComponent(opts.componentOptions)
  return report.new({
    kernel = {
      memory = function()
        return 1000, 65536
      end,
      storage = function()
        return 200, 4096
      end,
    },
    vfs = opts.vfs or newVfs(),
    log = {
      info = function() end,
      warn = function() end,
      debug = function() end,
    },
    config = opts.config or newConfig({}),
    version = { version = "0.4.9" },
    plant = opts.plant or newPlant(),
    computer = computer.computer or computer,
    component = component.component,
  }), computer, component
end

local function decodeSent(entry)
  local verb, fields = net.decode(entry.frame)
  return verb, fields
end

--------------------------------------------------------------------------------
-- Identity: configured, guessed, provisional
--------------------------------------------------------------------------------

do
  local publisher, computer = newReport({ config = newConfig({ name = "Casing Hall" }) })
  publisher:start()
  equal(publisher.name, "casing-hall", "a configured name is normalised")
  equal(publisher.provisional, false, "a configured name is not provisional")
  equal(computer, computer, "the clock is available")
end

do
  local vfs = newVfs()
  local config = newConfig({})
  local plant = newPlant({
    { name = "casing/ingots", total = 744, state = "exact", entries = { { label = "Titanium Ingot" } } },
    { name = "casing/casings", total = 5, state = "exact", entries = { { label = "EV Machine Casing" } } },
  })
  local publisher = newReport({ config = config, plant = plant, vfs = vfs })
  publisher:start()
  equal(publisher.name, "ev-machine-casing", "the name is guessed from the output stock label")
  equal(config.data.name, "ev-machine-casing", "the guess is persisted in the configuration")
  equal(publisher.provisional, false, "a guessed name is a real name")
end

do
  local config = newConfig({})
  local publisher = newReport({ config = config })
  publisher:start()
  equal(publisher.name, "nodo-line0001", "without a stock the name is provisional from the address")
  equal(publisher.provisional, true, "the provisional name is marked as such")
  equal(config.data.name, nil, "a provisional name is never persisted")
end

--------------------------------------------------------------------------------
-- What goes on the wire
--------------------------------------------------------------------------------

do
  local publisher, _, component = newReport({ config = newConfig({ name = "casing" }) })
  publisher:start()
  equal(#component.sent, 0, "without a master nothing is addressed to anyone")
  equal(#component.broadcasts, 1, "without a master the node broadcasts")
  local verb, fields = decodeSent(component.broadcasts[1])
  equal(verb, "HELLO", "the first frame is a HELLO")
  equal(fields.id, ADDRESS, "the HELLO carries the address")
  equal(fields.name, "casing", "the HELLO carries the name")
end

do
  local plant = newPlant({
    { name = "casing/ingots", total = 744, state = "exact", rate = 4.8 },
    { name = "casing/casings", total = 5, state = "exact", rate = 0 },
  }, { { key = "STARVED:casing/ingots", code = "STARVED", source = "casing/ingots", message = "744 below 800", first = 1000 } })

  local publisher, _, component = newReport({
    config = newConfig({ name = "casing", master = "master-1" }),
    plant = plant,
  })
  publisher:start()
  equal(#component.broadcasts, 0, "with a master the node does not broadcast")
  equal(#component.sent, 1, "with a master the node sends a frame")
  equal(component.sent[1].to, "master-1", "the frame goes to the master")
  local verb, fields = decodeSent(component.sent[1])
  equal(verb, "STATUS", "the frame is a STATUS")
  equal(fields.stocks, "2", "the frame counts the stocks")
  contains(fields.alarm, "STARVED:", "the worst alarm travels with the status")
  contains(fields.s1, "casing/ingots:744:exact:4.80", "the stock field carries path, total, state and rate")
end

do
  -- Twelve stocks with long names cannot all fit in one frame: the tail is
  -- dropped and the count of omitted stocks travels instead.
  local stocks = {}
  for index = 1, 12 do
    stocks[index] = {
      name = "casing/very-long-stock-name-number-" .. tostring(index) .. "/suffix",
      total = index,
      state = "exact",
    }
  end
  local publisher, _, component = newReport({
    config = newConfig({ name = "casing", master = "master-1" }),
    plant = newPlant(stocks),
  })
  publisher:start()
  local entry = component.sent[1]
  check(entry ~= nil, "the oversized status still goes out")
  check(entry and #entry.frame <= net.MAX_FRAME, "the frame respects the 1 KB limit")
  local verb, fields = decodeSent(entry)
  equal(verb, "STATUS", "the trimmed frame is still a STATUS")
  check(tonumber(fields.more or "0") > 0, "the frame says how many stocks did not fit")
  check(fields.s1 ~= nil, "the first stock still travels")
end

--------------------------------------------------------------------------------
-- Cadence, alarms and backoff
--------------------------------------------------------------------------------

do
  local plant = newPlant({ { name = "casing/casings", total = 5, state = "exact" } })
  local publisher, computer, component = newReport({
    config = newConfig({ name = "casing", master = "master-1" }),
    plant = plant,
  })
  publisher:start()
  equal(#component.sent, 1, "start publishes once")

  computer.advance(1)
  publisher:tick()
  equal(#component.sent, 1, "a quiet tick publishes nothing")

  plant.alarms = { { key = "FULL:casing/casings", code = "FULL", source = "casing/casings", message = "full", first = 1001 } }
  computer.advance(1)
  publisher:tick()
  equal(#component.sent, 2, "an alarm change publishes immediately")

  computer.advance(publisher.heartbeat)
  publisher:tick()
  equal(#component.sent, 3, "the heartbeat publishes on schedule")
end

do
  local publisher, computer = newReport({
    config = newConfig({ name = "casing", master = "master-1" }),
    componentOptions = { noModem = true },
  })
  publisher:start()
  equal(publisher.opened, false, "without a card the publisher reports it")
  equal(publisher.failed, 1, "the first publish fails")
  equal(publisher.retry, report.RETRY_MIN, "the first retry waits the minimum")

  local firstRetry = publisher.retry
  computer.advance(firstRetry)
  publisher:tick()
  equal(publisher.failed, 2, "the second publish fails too")
  equal(publisher.retry, firstRetry * 2, "the retry doubles")

  for _ = 1, 6 do
    computer.advance(publisher.retry)
    publisher:tick()
  end
  equal(publisher.retry, report.RETRY_MAX, "the retry is capped")
end

--------------------------------------------------------------------------------
-- The master assigns the name and the node adopts it
--------------------------------------------------------------------------------

do
  local config = newConfig({ name = "local-name", master = "master-1" })
  local publisher, _, component = newReport({ config = config })
  publisher:start()
  equal(publisher.name, "local-name", "the node starts with its local name")

  local handled = publisher:handle("ASSIGN", {
    id = ADDRESS,
    name = "Assigned Name",
    master = "master-9",
  }, "master-1")
  check(handled, "the assignment is handled")
  equal(publisher.name, "assigned-name", "the assigned name wins and is normalised")
  equal(config.data.name, "assigned-name", "the adopted name is persisted")
  equal(publisher.master, "master-9", "the assignment can move the master address")

  local before = #component.sent
  publisher:publish("after assign")
  equal(#component.sent, before + 1, "the next frame goes out")
  equal(component.sent[#component.sent].to, "master-9", "the frame goes to the assigned master")
  local verb, fields = decodeSent(component.sent[#component.sent])
  equal(verb, "STATUS", "the frame is a STATUS once a master is known")
  equal(fields.name, "assigned-name", "the frame carries the adopted name")
end

do
  local publisher = newReport({ config = newConfig({ name = "casing" }) })
  publisher:start()
  check(not publisher:handle("ASSIGN", { id = "someone-else", name = "x" }, nil),
    "another node's assignment is ignored")
  check(not publisher:handle("STATUS", { id = ADDRESS }, nil), "a status frame is ignored")
end

--------------------------------------------------------------------------------
-- The state file and the page
--------------------------------------------------------------------------------

do
  local vfs = newVfs()
  local publisher = newReport({ config = newConfig({ name = "casing", master = "master-1" }), vfs = vfs })
  publisher:start()
  local state = vfs.files["/var/status/last.tsv"]
  check(state ~= nil, "the last published status is written to disk")
  contains(state, "id\t" .. ADDRESS, "the state file carries the address")
  contains(state, "name\tcasing", "the state file carries the name")
  contains(state, "state\tonline", "the state file carries the state")
end

do
  local publisher = newReport({ config = newConfig({ name = "casing" }) })
  publisher:start()
  check(publisher:draw(), "the page draws when a screen is attached")
end

do
  local publisher, _, component = newReport({
    config = newConfig({ name = "casing" }),
    componentOptions = { noScreen = true },
  })
  publisher:start()
  check(not publisher:draw(), "without a screen the page draws nothing")
  equal(#component.drawn, 0, "no GPU call is attempted without a screen")
end

--------------------------------------------------------------------------------
-- Configuration pushed by the master
--------------------------------------------------------------------------------

do
  local vfs = newVfs()
  local plant = newPlant({ { name = "casing/ingots", total = 744, state = "exact" } })
  local reloaded = 0
  plant.reload = function()
    reloaded = reloaded + 1
    return true
  end
  local publisher, _, component = newReport({
    config = newConfig({ name = "casing", master = "master-1" }),
    plant = plant,
    vfs = vfs,
  })
  publisher:start()

  local body = "casing/ingots\t800\t0\tflow\n"
  publisher:handle("CFG", { id = ADDRESS, file = "plant.tsv", body = body }, "master-1")
  equal(vfs.files["/etc/plant.tsv"], body, "the pushed configuration is written")
  equal(reloaded, 1, "the plant reloads after a push")
  local verb, fields = decodeSent(component.sent[#component.sent])
  equal(verb, "CFGACK", "the node acknowledges the push")
  equal(fields and fields.state, "applied", "the acknowledgement says applied")

  publisher:handle("CFG", { id = ADDRESS, file = "../../boot/kernel.lua", body = "x" }, "master-1")
  local _, rejected = decodeSent(component.sent[#component.sent])
  equal(rejected and rejected.state, "rejected", "a file outside the whitelist is rejected")

  publisher:handle("CFG", { id = ADDRESS, file = "plant.tsv", body = string.rep("y", 800) }, "master-1")
  local _, oversized = decodeSent(component.sent[#component.sent])
  equal(oversized and oversized.state, "rejected", "an oversized body is rejected")
end

if checked == 0 then
  failures[#failures + 1] = "no assertions ran"
end

return table.concat(failures, "\n")
