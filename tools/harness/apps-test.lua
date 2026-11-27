-- Tests for the master-side apps (Nodes, Lines, DNS console) and the desktop
-- Settings DNS page.
--
-- Run through tools/harness/test-apps.js. The context is fake and records what
-- the apps draw and what they call; the master service is a stub with the same
-- contract as tc.master.

local keys = require("tc.keys")
local nodesApp = require("apps.nodes")
local linesApp = require("apps.lines")
local dnsApp = require("apps.dns")
local settingsApp = require("apps.settings")

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
-- Context
--------------------------------------------------------------------------------

local COLORS = {
  text = 1, dim = 2, accent = 3, warn = 4, danger = 5, ok = 6, panel = 7, deep = 8,
}

local function newContext(master, vfs)
  local view = { lines = {} }
  function view:clear() end
  function view:fill() end
  function view:hline() end
  function view:put(x, y, text)
    view.lines[y] = tostring(text)
    return true
  end
  function view:textRight(x, y, text)
    view.right = tostring(text)
    return true
  end

  local configData = {
    accent = "cyan",
    charset = "unicode",
    clock24 = true,
    splash = true,
    logLevel = "info",
    dnsMaster = "",
    dnsPort = 4201,
    dnsTransport = "auto",
  }
  local context
  local config = {
    path = "/etc/terracorp.cfg",
    accents = { "cyan", "orange" },
    charsets = { "unicode", "ascii" },
    logLevels = { "debug", "info", "warn", "error" },
    get = function(key)
      return configData[key]
    end,
    set = function(key, value)
      configData[key] = value
      return true
    end,
    cycle = function(key, values)
      for index, value in ipairs(values) do
        if value == configData[key] then
          configData[key] = values[(index % #values) + 1]
          return configData[key]
        end
      end
    end,
    reset = function()
      configData.dnsMaster = ""
      configData.dnsPort = 4201
      configData.dnsTransport = "auto"
    end,
    validate = function(key, value)
      if key == "dnsPort" then
        if type(value) ~= "number" or value % 1 ~= 0 or value < 1 or value > 65535 then
          return false, "Port must be a whole number from 1 to 65535."
        end
        return true
      end
      if key == "dnsTransport" then
        if value ~= "auto" and value ~= "wired" and value ~= "wireless" then
          return false, "Transport must be auto, wired or wireless."
        end
        return true
      end
      return true
    end,
  }

  context = {
    w = 70,
    h = 22,
    colors = COLORS,
    glyphs = { h = "─", v = "│", block = "█" },
    view = view,
    notifications = {},
    saved = 0,
    restarts = 0,
    text = {
      truncate = function(value, width)
        return tostring(value):sub(1, width)
      end,
      width = function(value)
        return #tostring(value)
      end,
    },
    util = {
      humanTime = function(value)
        return tostring(value) .. "s"
      end,
    },
    config = config,
    kernel = {
      master = master,
      address = "81dd02d0-91ef-4c9b-8b22-273979f1e637",
      vfs = vfs or { read = function() return nil end, write = function() return true end },
      saveConfig = function()
        context.saved = context.saved + 1
        return true
      end,
      applyTheme = function() end,
      restartDns = function()
        context.restarts = context.restarts + 1
        local master = configData.dnsMaster
        if master == "" then
          context.dnsStatusText = "Off"
        elseif master == "self" then
          context.dnsStatusText = "Master · port 4201 not open"
        else
          context.dnsStatusText = "Client · " .. master:sub(1, 8) .. "…"
        end
        return true
      end,
      dnsStatus = function()
        return context.dnsStatusText or "Off"
      end,
      poweroff = function() end,
    },
  }
  context.ui = {
    notify = function(_, kind, message)
      context.notifications[#context.notifications + 1] = kind .. ":" .. message
    end,
  }
  return context
end

local function newVfs(files)
  local vfs = { files = files or {} }
  function vfs.read(path)
    return vfs.files[path]
  end
  function vfs.write(path, data)
    vfs.files[path] = data
    return true
  end
  return vfs
end

local function newNode(id, name, state)
  return {
    id = id,
    name = name,
    state = state or "online",
    age = 2,
    v = "0.4.9",
    stocks = 2,
    alarm = "",
    alarmPath = "",
    uptime = 120,
  }
end

local function newMasterStub()
  local stub = {
    calls = {},
    nodes = { newNode("node-a", "casing"), newNode("node-b", "caster", "offline") },
    stocks = {
      { node = "casing", name = "casing/ingots", total = 744, state = "exact", rate = 4.8 },
      { node = "casing", name = "casing/casings", total = 5, state = "exact", rate = 0 },
    },
  }
  function stub:status()
    return { nodes = 2, online = 1, offline = 1, opened = true, received = 7, assigned = 2, staleAfter = 30 }
  end
  function stub:snapshot()
    return { nodes = self.nodes, stocks = self.stocks, online = 1, offline = 1 }
  end
  function stub:rename(id, name)
    stub.calls[#stub.calls + 1] = { "rename", id, name }
    if name == "taken" then
      return nil, "name_taken"
    end
    return { name = name, references = { "/etc/plant.tsv" } }
  end
  function stub:ping(id)
    stub.calls[#stub.calls + 1] = { "ping", id }
    return true
  end
  function stub:forget(id)
    stub.calls[#stub.calls + 1] = { "forget", id }
    return { id = id }
  end
  function stub:sendConfig(id, file, body)
    stub.calls[#stub.calls + 1] = { "sendConfig", id, file, body }
    return true
  end
  return stub
end

local function key(ctx, app, char, code)
  return app:handle(ctx, "key", char, code)
end

local function findHit(app, id)
  for _, hit in ipairs(app.hits) do
    if hit.id == id then
      return hit
    end
  end
end

--------------------------------------------------------------------------------
-- Nodes
--------------------------------------------------------------------------------

do
  local master = newMasterStub()
  local ctx = newContext(master)
  local app = nodesApp.create()

  app:draw(ctx)
  contains(ctx.view.lines[1], "Node registry", "the app draws its title")
  contains(ctx.view.right, "1 online", "the app counts the online nodes")
  contains(ctx.view.lines[4], "casing", "the first node is listed")
  contains(ctx.view.lines[5], "caster", "the second node is listed")

  key(ctx, app, nil, keys.down)
  equal(app.index, 2, "the selection moves down")

  key(ctx, app, "r", nil)
  equal(app.editing, "node-b", "R starts renaming the selected node")
  key(ctx, app, nil, keys.back)
  key(ctx, app, nil, keys.back)
  key(ctx, app, "L", nil)
  key(ctx, app, nil, keys.enter)
  equal(app.editing, nil, "Enter closes the editor")
  equal(master.calls[1][1], "rename", "the rename reaches the master")
  contains(ctx.notifications[#ctx.notifications], "still mention", "the app reports the references left behind")

  key(ctx, app, "p", nil)
  equal(master.calls[#master.calls][1], "ping", "P pings the selected node")

  key(ctx, app, "f", nil)
  equal(master.calls[#master.calls][1], "ping", "the first F only arms the forget")
  key(ctx, app, "f", nil)
  equal(master.calls[#master.calls][1], "forget", "the second F forgets the node")
end

do
  local ctx = newContext(nil)
  local app = nodesApp.create()
  app:draw(ctx)
  contains(ctx.view.lines[2], "unavailable", "without a master the app says so")
  check(key(ctx, app, "r", nil), "the keys still answer")
end

--------------------------------------------------------------------------------
-- Lines
--------------------------------------------------------------------------------

do
  local master = newMasterStub()
  local vfs = newVfs({})
  local ctx = newContext(master, vfs)
  local app = linesApp.create()

  app:draw(ctx)
  contains(ctx.view.lines[1], "Lines", "the app draws its title")
  contains(ctx.view.right, "2 stocks", "the app counts the stocks")
  contains(ctx.view.lines[4], "casing/ingots", "the first stock is listed")

  key(ctx, app, "m", nil)
  check(app.editing ~= nil, "M starts editing the minimum")
  key(ctx, app, nil, keys.back)
  key(ctx, app, nil, keys.back)
  key(ctx, app, nil, keys.back)
  key(ctx, app, "8", nil)
  key(ctx, app, "0", nil)
  key(ctx, app, "0", nil)
  key(ctx, app, nil, keys.enter)
  equal(app.thresholds["casing/ingots"].min, 800, "the minimum is committed")

  key(ctx, app, "t", nil)
  equal(app.thresholds["casing/ingots"].flow, false, "T toggles the flow flag")

  key(ctx, app, "s", nil)
  local saved = vfs.files["/etc/plant.tsv"]
  contains(saved, "casing/ingots", "S writes the thresholds file")
  contains(saved, "\t800", "the edited minimum is in the file")
  local pushed = master.calls[#master.calls]
  equal(pushed[1], "sendConfig", "S pushes the file to the node")
  equal(pushed[3], "plant.tsv", "the pushed file is the thresholds file")
  contains(pushed[4], "casing/casings", "the pushed body carries every threshold")
end

do
  local ctx = newContext(nil)
  local app = linesApp.create()
  app:draw(ctx)
  contains(ctx.view.lines[2], "unavailable", "without a master the app says so")
end

--------------------------------------------------------------------------------
-- DNS
--------------------------------------------------------------------------------

local function newDnsClient(paged)
  local client = { calls = {}, details = {
    ["node-a"] = { v = 7, node = { id = "node-a", name = "casing", ver = "0.4.9", boot = "boot-a",
      docs = "Main line" }, endpoints = { { name = "dns.status", rev = 2 }, { name = "plant", rev = 3 } } },
    ["node-b"] = { v = 4, node = { id = "node-b", name = "caster", ver = "0.4.9", boot = "boot-b",
      docs = "Caster line" }, endpoints = { { name = "dns.status", rev = 1 } } },
  } }
  function client:nodes(cursor, limit)
    local nodes = {
      { id = "node-a", name = "casing", state = "online", endpoints = 2 },
      { id = "node-b", name = "caster", state = "stale", endpoints = 1 },
    }
    if paged then
      if cursor == "node-a" then
        return { nodes[2] }, { total = 2, page = 2, count = 1, next = "-" }
      end
      return { nodes[1] }, { total = 2, page = 1, count = 1, next = "node-a" }
    end
    return nodes, { total = 2, page = 1, next = "-" }
  end
  function client:describe(id, target)
    local detail = client.details[id]
    if not detail then
      return nil, "timeout"
    end
    return detail
  end
  function client:edit(id, target, field, value, rev)
    client.calls[#client.calls + 1] = { "edit", id, target, field, value, rev }
    local detail = client.details[id]
    if rev ~= detail.v then
      return { ok = false, err = "conflict", rev = detail.v, body = detail }
    end
    detail.v = detail.v + 1
    detail.node.docs = value
    return { ok = true, rev = detail.v }
  end
  function client:exec(id, target, method, args)
    client.calls[#client.calls + 1] = { "exec", id, target, method }
    return { snapshot = 9, published = 8, calls = 3 }
  end
  return client
end

local function newDnsMasterStub()
  local stub = {}
  function stub:catalog(cursor, limit)
    return { nodes = { { id = "node-m", name = "master", state = "online", endpoints = 1 } }, total = 1 }
  end
  function stub:describe(id, target)
    return { v = 2, node = { id = "node-m", name = "master", ver = "0.4.9", boot = "boot-m",
      docs = "Master node" }, endpoints = { { name = "dns.status", rev = 1 } } }
  end
  return stub
end

do
  local client = newDnsClient()
  local ctx = newContext(nil)
  ctx.kernel.dnsclient = client
  local app = dnsApp.create()

  app:draw(ctx)
  contains(ctx.view.lines[3], "Loading registry", "before the first tick the app says it is loading")
  check(app:tick(ctx), "the first tick refreshes the registry")
  equal(#app.rows, 2, "the app keeps both catalog rows")
  equal(app.detail.id, "node-a", "the app loads the selected node")
  app:draw(ctx)
  contains(ctx.view.lines[1], "DNS registry", "the app draws its title")
  contains(ctx.view.lines[3], "casing", "the first node is listed")
  contains(ctx.view.lines[16], "casing", "the node identity is shown")
  contains(ctx.view.lines[17], "Main line", "the node document is shown")

  key(ctx, app, nil, keys.down)
  equal(app.detail.id, "node-b", "moving down loads the next node")

  key(ctx, app, "e", nil)
  equal(app.mode, "edit", "E starts editing the document")
  equal(app.buffer, "Caster line", "the editor starts with the current document")
  key(ctx, app, nil, keys.enter)
  equal(app.mode, "list", "Enter leaves the editor")
  local editCall = client.calls[#client.calls]
  equal(editCall[1], "edit", "the edit reaches the client")
  equal(editCall[2], "node-b", "the edit names the selected node")
  equal(editCall[3], "node", "the edit targets the node document")
  equal(editCall[6], 4, "the edit carries the revision the app displayed")
  contains(ctx.notifications[#ctx.notifications], "revision 5", "the app reports the new revision")

  client.details["node-b"].v = 8
  key(ctx, app, "e", nil)
  client.details["node-b"].v = 9
  key(ctx, app, nil, keys.enter)
  contains(ctx.notifications[#ctx.notifications], "revision 9", "a conflict names the winning revision")

  key(ctx, app, "p", nil)
  local execCall = client.calls[#client.calls]
  equal(execCall[1], "exec", "P reaches the client")
  equal(execCall[3], "endpoint:dns.status", "P runs the allowlisted status method")
  contains(ctx.notifications[#ctx.notifications], "snapshot 9", "the status reaches the app")
end

do
  local client = newDnsClient(true)
  local ctx = newContext(nil)
  ctx.kernel.dnsclient = client
  local app = dnsApp.create()
  app:tick(ctx)
  equal(#app.rows, 1, "the first page holds one row")
  equal(app.detail.id, "node-a", "the first page loads its node")
  equal(app.nextCursor, "node-a", "the page keeps the next cursor")
  key(ctx, app, nil, keys.right)
  equal(#app.rows, 1, "the second page holds one row")
  equal(app.detail.id, "node-b", "the second page loads the next node")
  equal(app.nextCursor, "-", "the last page has no cursor")
  key(ctx, app, nil, keys.left)
  equal(app.detail.id, "node-a", "the previous page returns to the first node")
  key(ctx, app, nil, keys.left)
  contains(ctx.notifications[#ctx.notifications], "first page", "the app reports the first page")
end

do
  local ctx = newContext(nil)
  ctx.kernel.dnsmaster = newDnsMasterStub()
  local app = dnsApp.create()
  app:tick(ctx)
  app:draw(ctx)
  contains(ctx.view.lines[3], "master", "the master cache is listed")
  contains(ctx.view.lines[16], "master", "the master identity is shown")
  contains(ctx.view.lines[17], "Master node", "the master describes its cache")
  key(ctx, app, "e", nil)
  contains(ctx.notifications[#ctx.notifications], "needs a DNS client", "the master desktop refuses edits")
end

do
  local ctx = newContext(nil)
  local app = dnsApp.create()
  app:tick(ctx)
  app:draw(ctx)
  contains(ctx.view.lines[3], "No DNS master", "without either service the app explains why")
end

--------------------------------------------------------------------------------
-- Settings / DNS
--------------------------------------------------------------------------------

do
  local ctx = newContext(nil)
  local app = settingsApp.create()

  app:draw(ctx)
  check(findHit(app, "tab:station") ~= nil, "the station tab is available")
  check(findHit(app, "tab:dns") ~= nil, "the DNS tab is available")

  key(ctx, app, nil, keys.tab)
  app:draw(ctx)
  contains(ctx.view.lines[2], "DNS for this desktop", "Tab opens the DNS page")
  equal(app.dns.mode, "off", "DNS starts in Off when dnsMaster is empty")

  findHit(app, "dns:mode").action(ctx)
  equal(app.dns.mode, "master", "the mode cycles to Master")
  app:draw(ctx)
  contains(ctx.view.lines[6], "81dd02d0", "Master mode shows this machine's address")
  findHit(app, "dns:Apply").action(ctx)
  equal(ctx.config.get("dnsMaster"), "self", "Master saves dnsMaster=self")
  equal(ctx.restarts, 1, "Apply restarts DNS once")
  findHit(app, "dns:Apply").action(ctx)
  equal(ctx.config.get("dnsMaster"), "self", "applying the same mode keeps one master setting")
  equal(ctx.restarts, 2, "applying the same mode replaces the listener instead of stacking it")

  app:draw(ctx)
  findHit(app, "dns:mode").action(ctx)
  equal(app.dns.mode, "client", "the mode cycles to Client")
  app:draw(ctx)
  findHit(app, "dns:transport").action(ctx)
  equal(app.dns.transport, "wired", "the transport cycles to wired")
  findHit(app, "dns:port").action(ctx)
  for _ = 1, 4 do
    key(ctx, app, nil, keys.back)
  end
  for _, digit in ipairs({ "4", "2", "0", "2" }) do
    key(ctx, app, digit, nil)
  end
  key(ctx, app, nil, keys.enter)
  equal(app.dns.port, 4202, "a valid port is accepted")
  equal(app.edit, nil, "Enter closes the port editor")

  app:draw(ctx)
  findHit(app, "dns:port").action(ctx)
  for _ = 1, 4 do
    key(ctx, app, nil, keys.back)
  end
  for _, digit in ipairs({ "7", "0", "0", "0", "0" }) do
    key(ctx, app, digit, nil)
  end
  key(ctx, app, nil, keys.enter)
  equal(app.dns.port, 4202, "an out-of-range port is refused")
  equal(app.edit, "port", "the editor stays open after a bad port")
  contains(app.message, "1 to 65535", "the port error is explained")

  key(ctx, app, nil, keys.tab)
  equal(app.edit, nil, "Tab cancels the field editor")
  app:draw(ctx)
  findHit(app, "dns:mode").action(ctx)
  equal(app.dns.mode, "off", "the mode cycles back to Off")
  findHit(app, "dns:Apply").action(ctx)
  contains(app.message, "Stopping Master", "leaving Master asks for confirmation")
  equal(ctx.config.get("dnsMaster"), "self", "the first Apply keeps Master running")
  findHit(app, "dns:Apply").action(ctx)
  equal(ctx.config.get("dnsPort"), 4202, "a valid port is saved")
  equal(ctx.config.get("dnsTransport"), "wired", "a valid transport is saved")

  ctx.w, ctx.h = 40, 8
  app:draw(ctx)
  check(findHit(app, "dns:mode") ~= nil, "the mode control fits a 40x16 screen")
  check(findHit(app, "dns:Apply") ~= nil, "Apply fits a 40x16 screen")
  check(findHit(app, "dns:Reset") ~= nil, "Reset fits a 40x16 screen")
  contains(ctx.view.lines[3], "Off", "the compact layout keeps the mode visible")
  contains(ctx.view.lines[4], "Port 4202", "the compact layout shows the effective port")
  contains(ctx.view.lines[5], "Off", "the status line fits a 40x16 screen")
end

do
  local ctx = newContext(nil)
  local app = settingsApp.create()
  local uuid = "01234567-89ab-cdef-0123-456789abcdef"

  key(ctx, app, nil, keys.tab)
  app:draw(ctx)
  findHit(app, "dns:mode").action(ctx)
  findHit(app, "dns:mode").action(ctx)
  equal(app.dns.mode, "client", "two mode clicks select Client")
  app:draw(ctx)
  findHit(app, "dns:master").action(ctx)
  equal(app.edit, "master", "the address row opens its editor")

  for index = 1, #uuid do
    key(ctx, app, uuid:sub(index, index), nil)
  end
  key(ctx, app, nil, keys.enter)
  equal(app.dns.master, uuid, "a full UUID is accepted")
  app:draw(ctx)
  findHit(app, "dns:Apply").action(ctx)
  equal(ctx.config.get("dnsMaster"), uuid, "Client saves the master UUID")
  equal(ctx.restarts, 1, "Client applies in place")

  app:draw(ctx)
  findHit(app, "dns:master").action(ctx)
  for _ = 1, #uuid do
    key(ctx, app, nil, keys.back)
  end
  key(ctx, app, "n", nil)
  key(ctx, app, nil, keys.enter)
  equal(app.edit, "master", "a short address is refused")
  contains(app.message, "36-character", "the address error names the expected shape")
end

do
  local ctx = newContext(nil)
  local app = settingsApp.create()
  local first = true
  ctx.kernel.restartDns = function()
    ctx.restarts = ctx.restarts + 1
    if first then
      first = false
      return nil, "no modem answered"
    end
    return true
  end

  key(ctx, app, nil, keys.tab)
  app:draw(ctx)
  findHit(app, "dns:mode").action(ctx)
  findHit(app, "dns:Apply").action(ctx)
  equal(ctx.config.get("dnsMaster"), "", "a failed apply restores the previous mode")
  equal(ctx.restarts, 2, "a failed apply also restarts the previous mode")
  contains(app.message, "previous mode restored", "the failure is reported")
end

if checked == 0 then
  failures[#failures + 1] = "no assertions ran"
end

return table.concat(failures, "\n")
