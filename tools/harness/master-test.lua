-- Tests for tc.master: the node registry as the plant's DNS.
--
-- Run through tools/harness/test-master.js. The modem records what the master
-- sends, the filesystem is in memory, and the clock is moved by hand.

local net = require("tc.net")
local master = require("tc.master")
local registry = require("tc.registry")

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

local MASTER_ADDRESS = "master-0001"

local function newComputer()
  local state = { clock = 5000 }
  state.computer = {
    address = function()
      return MASTER_ADDRESS
    end,
    uptime = function()
      return state.clock
    end,
  }
  function state.advance(seconds)
    state.clock = state.clock + seconds
  end
  return state
end

local function newComponent()
  local state = { sent = {}, broadcasts = {}, opened = false }
  state.component = {
    list = function(kind)
      local served = false
      return function()
        if served or kind ~= "modem" then
          return nil
        end
        served = true
        return "modem-1", "modem"
      end
    end,
    invoke = function(address, method, ...)
      local args = table.pack(...)
      if address ~= "modem-1" then
        return nil, "unknown component"
      end
      if method == "isWired" then
        return true
      elseif method == "open" then
        state.opened = true
        return true
      elseif method == "close" then
        state.opened = false
        return true
      elseif method == "send" then
        state.sent[#state.sent + 1] = { to = args[1], frame = args[3] }
        return true
      elseif method == "broadcast" then
        state.broadcasts[#state.broadcasts + 1] = { frame = args[2] }
        return true
      end
      return nil, "unknown method " .. tostring(method)
    end,
  }
  return state
end

local function newVfs(files)
  local vfs = { files = files or {}, dirs = {} }
  function vfs.exists(path)
    if vfs.files[path] ~= nil or vfs.dirs[path] == true then
      return true
    end
    local prefix = tostring(path):gsub("/*$", "") .. "/"
    for file in pairs(vfs.files) do
      if file:sub(1, #prefix) == prefix then
        return true
      end
    end
    return false
  end
  function vfs.read(path)
    return vfs.files[path]
  end
  function vfs.write(path, data)
    vfs.files[path] = data
    return true
  end
  function vfs.list(path)
    local prefix = tostring(path):gsub("/*$", "") .. "/"
    local names, seen = {}, {}
    for file in pairs(vfs.files) do
      if file:sub(1, #prefix) == prefix then
        local rest = file:sub(#prefix + 1)
        local name = rest:match("^([^/]+)")
        if name and not seen[name] then
          seen[name] = true
          names[#names + 1] = name
        end
      end
    end
    return names
  end
  function vfs.ensureDir(path)
    vfs.dirs[path] = true
    return true
  end
  return vfs
end

local function newMaster(opts)
  opts = opts or {}
  local computer = newComputer()
  local component = newComponent()
  return master.new({
    vfs = opts.vfs or newVfs(opts.files),
    log = { info = function() end, warn = function() end },
    version = { version = "0.4.9" },
    computer = computer.computer,
    component = component.component,
    staleAfter = opts.staleAfter,
  }), computer, component
end

local function frame(verb, fields)
  local encoded, reason = net.encode(verb, fields)
  assert(encoded, "could not encode " .. verb .. ": " .. tostring(reason))
  return encoded
end

local function lastSent(component)
  local entry = component.sent[#component.sent]
  if not entry then
    return nil
  end
  local verb, fields = net.decode(entry.frame)
  return verb, fields, entry
end

local function statusFields(id, name, extra)
  local fields = {
    id = id,
    name = name,
    state = "online",
    v = "0.4.9",
    mem = "900",
    disk = "120",
    uptime = "600",
    stocks = "2",
    s1 = "casing/ingots:744:exact:4.80",
    s2 = "casing/casings:5:exact:0.00",
  }
  for key, value in pairs(extra or {}) do
    fields[key] = value
  end
  return fields
end

--------------------------------------------------------------------------------
-- Registration and naming
--------------------------------------------------------------------------------

do
  local publisher, computer, component = newMaster()
  publisher:start()
  check(component.opened, "the master opens the modem port")

  publisher:handle("modem_message", "node-a", net.PORT, false, frame("HELLO", {
    id = "node-a", name = "casing", v = "0.4.9",
  }))
  local node = publisher:node("node-a")
  check(node ~= nil, "a HELLO registers the node")
  equal(node and node.name, "casing", "the registry keeps the proposed name")
  equal(node and node.state, "online", "the node starts online")

  local verb, fields = lastSent(component)
  equal(verb, "ASSIGN", "a new node is told its name")
  equal(fields and fields.name, "casing", "the assignment carries the accepted name")
  equal(fields and fields.master, MASTER_ADDRESS, "the assignment names the master")
  equal(fields and fields.role, "line", "the assignment carries the line role")
end

do
  local publisher, _, component = newMaster()
  publisher:start()
  publisher:handle("modem_message", "node-a", net.PORT, false, frame("HELLO", {
    id = "node-a", name = "casing",
  }))
  publisher:handle("modem_message", "node-b", net.PORT, false, frame("HELLO", {
    id = "node-b", name = "casing",
  }))

  equal(publisher:node("node-a").name, "casing", "the first node keeps the name")
  equal(publisher:node("node-b").name, "casing-2", "a duplicate name gets a suffix")
  local verb, fields = lastSent(component)
  equal(verb, "ASSIGN", "the second node is told the suffixed name")
  equal(fields and fields.name, "casing-2", "the suffix travels in the assignment")
end

do
  local publisher, computer, component = newMaster()
  publisher:start()
  publisher:handle("modem_message", "node-a", net.PORT, false, frame("STATUS", statusFields("node-a", "casing")))

  local sentBefore = #component.sent
  equal(sentBefore, 0, "a status for an unknown node does not reply to it")
  -- The node was registered by its status and then assigned.
  equal(publisher:node("node-a").name, "casing", "a STATUS alone registers the node")
end

--------------------------------------------------------------------------------
-- Status, names and the merged view
--------------------------------------------------------------------------------

do
  local publisher, computer, component = newMaster()
  publisher:start()
  publisher:handle("modem_message", "node-a", net.PORT, false, frame("HELLO", { id = "node-a", name = "casing" }))
  local assigned = #component.sent

  publisher:handle("modem_message", "node-a", net.PORT, false, frame("STATUS", statusFields("node-a", "casing")))
  equal(#component.sent, assigned, "a status that agrees on the name gets no reply")

  local node = publisher:node("node-a")
  equal(node.stocks, 2, "the registry keeps the stock count")
  equal(node.mem, 900, "the registry keeps the memory")
  equal(node.uptime, 600, "the registry keeps the node uptime")

  local view = publisher:snapshot()
  equal(#view.nodes, 1, "the merged view has one node")
  equal(#view.stocks, 2, "the merged view has both stocks")
  equal(view.stocks[1].name, "casing/casings", "the merged stocks are keyed by full path")
  equal(view.stocks[1].total, 5, "the merged stock keeps its total")
end

do
  local publisher, _, component = newMaster()
  publisher:start()
  publisher:handle("modem_message", "node-a", net.PORT, false, frame("HELLO", { id = "node-a", name = "casing" }))
  local before = #component.sent

  -- The operator renamed the node locally; the master wins.
  publisher:handle("modem_message", "node-a", net.PORT, false, frame("STATUS",
    statusFields("node-a", "otro-nombre")))
  equal(publisher:node("node-a").name, "casing", "the master keeps its own name")
  local verb, fields = lastSent(component)
  equal(#component.sent, before + 1, "the disagreement is answered")
  equal(verb, "ASSIGN", "the answer is an assignment")
  equal(fields and fields.name, "casing", "the assignment restores the master's name")
end

do
  local publisher, _, component = newMaster()
  publisher:start()
  publisher:handle("modem_message", "node-a", net.PORT, false, frame("STATUS", statusFields("node-a", "casing", {
    s2 = "otralinea/casings:5:exact:0.00",
  })))
  local view = publisher:snapshot()
  local foreign
  for _, stock in ipairs(view.stocks) do
    if stock.name:find("otralinea", 1, true) then
      foreign = stock
    end
  end
  check(foreign ~= nil, "a stock rooted elsewhere still appears")
  equal(foreign and foreign.state, "foreign", "and it is marked foreign")
end

--------------------------------------------------------------------------------
-- Silence, ping and forget
--------------------------------------------------------------------------------

do
  local publisher, computer, component = newMaster({ staleAfter = 30 })
  publisher:start()
  publisher:handle("modem_message", "node-a", net.PORT, false, frame("HELLO", { id = "node-a", name = "casing" }))
  publisher:handle("modem_message", "node-a", net.PORT, false, frame("STATUS", statusFields("node-a", "casing")))
  equal(publisher:node("node-a").state, "online", "the node is online after its status")

  computer.advance(10)
  publisher:tick()
  equal(publisher:node("node-a").state, "online", "a fresh node stays online")

  computer.advance(40)
  publisher:tick()
  equal(publisher:node("node-a").state, "offline", "a silent node goes offline")
  local view = publisher:snapshot()
  equal(view.stocks[1].state, "offline", "its stocks are marked offline, never dropped")
  equal(#view.stocks, 2, "the stocks stay in the view")
end

do
  local publisher, _, component = newMaster()
  publisher:start()
  publisher:handle("modem_message", "node-a", net.PORT, false, frame("HELLO", { id = "node-a", name = "casing" }))

  publisher:ping("node-a")
  local verb, fields = lastSent(component)
  equal(verb, "PING", "ping sends a PING")
  equal(fields and fields.id, "node-a", "the PING names the node")

  publisher:handle("modem_message", "node-a", net.PORT, false, frame("PING", { id = "node-a" }))
  local pongVerb = lastSent(component)
  equal(pongVerb, "PONG", "a PING from a node is answered with PONG")

  check(publisher:forget("node-a") ~= nil, "forget removes the node")
  equal(publisher:node("node-a"), nil, "the node is gone from the registry")
  check(publisher:forget("node-a") == nil, "forgetting twice is an error")
end

--------------------------------------------------------------------------------
-- Renaming from the app
--------------------------------------------------------------------------------

do
  local files = {
    ["/etc/plant.tsv"] = "casing/ingots 800\n",
    ["/etc/lines/casing.line"] = "stock in casing/ingots\n",
  }
  local publisher, _, component = newMaster({ files = files })
  publisher:start()
  publisher:handle("modem_message", "node-a", net.PORT, false, frame("HELLO", { id = "node-a", name = "casing" }))

  local result, reason = publisher:rename("node-a", "Casing Hall")
  check(result ~= nil, "the rename succeeds (" .. tostring(reason) .. ")")
  equal(result and result.name, "casing-hall", "the new name is normalised")
  equal(result and #result.references, 2, "the rename lists the files that mention the old prefix")
  contains(table.concat(result and result.references or {}, ","), "/etc/plant.tsv",
    "the thresholds file is listed")
  equal(publisher:node("node-a").name, "casing-hall", "the registry carries the new name")

  local verb, fields = lastSent(component)
  equal(verb, "ASSIGN", "the node is told about the rename")
  equal(fields and fields.name, "casing-hall", "the assignment carries the new name")

  local refused, why = publisher:rename("node-a", "!!")
  check(refused == nil, "an unusable name is refused")
  equal(why, "invalid_name", "the refusal names the reason")

  check(publisher:rename("unknown", "casing") == nil, "an unknown node cannot be renamed")
end

do
  local publisher = newMaster()
  publisher:start()
  publisher:handle("modem_message", "node-a", net.PORT, false, frame("HELLO", { id = "node-a", name = "casing" }))
  publisher:handle("modem_message", "node-b", net.PORT, false, frame("HELLO", { id = "node-b", name = "caster" }))
  local result, why = publisher:rename("node-b", "casing")
  check(result == nil, "a rename cannot steal another node's name")
  equal(why, "name_taken", "the refusal names the collision")
end

--------------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------------

do
  local vfs = newVfs()
  local first = newMaster({ vfs = vfs })
  first:start()
  first:handle("modem_message", "node-a", net.PORT, false, frame("STATUS", statusFields("node-a", "casing")))
  local stored = vfs.read("/var/nodes.tsv")
  check(stored ~= nil, "the registry is written to /var/nodes.tsv")
  contains(stored, "casing", "the file carries the name")

  local second = newMaster({ vfs = vfs })
  second:start()
  local node = second:node("node-a")
  check(node ~= nil, "a new master session loads the registry")
  equal(node and node.name, "casing", "the name survives a reboot")
  equal(node and node.state, "offline", "a loaded node starts offline")
end

--------------------------------------------------------------------------------
-- Configuration push
--------------------------------------------------------------------------------

do
  local publisher, _, component = newMaster()
  publisher:start()
  publisher:handle("modem_message", "node-a", net.PORT, false, frame("HELLO", { id = "node-a", name = "casing" }))

  local body = "casing/ingots\t800\t0\tflow\n"
  local ok, reason = publisher:sendConfig("node-a", "plant.tsv", body)
  check(ok, "a configuration file is pushed (" .. tostring(reason) .. ")")
  local verb, fields = lastSent(component)
  equal(verb, "CFG", "the push is a CFG frame")
  equal(fields and fields.file, "plant.tsv", "the frame names the file")
  equal(fields and fields.body, body, "the frame carries the body")

  local refused, why = publisher:sendConfig("node-a", "plant.tsv", string.rep("x", 800))
  check(refused == nil, "an oversized file is refused")
  equal(why, "config_too_large", "the refusal names the size")

  publisher:handle("modem_message", "node-a", net.PORT, false, frame("CFGACK", {
    id = "node-a", file = "plant.tsv", state = "applied",
  }))
  equal(publisher:node("node-a").configState, "applied", "the acknowledgement is recorded")
end

if checked == 0 then
  failures[#failures + 1] = "no assertions ran"
end

return table.concat(failures, "\n")
