-- Tests for the two master-side apps: Nodes (the DNS) and Lines (the control).
--
-- Run through tools/harness/test-apps.js. The context is fake and records what
-- the apps draw and what they call; the master service is a stub with the same
-- contract as tc.master.

local keys = require("tc.keys")
local nodesApp = require("apps.nodes")
local linesApp = require("apps.lines")

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
  function view:put(x, y, text)
    view.lines[y] = tostring(text)
    return true
  end
  function view:textRight(x, y, text)
    view.right = tostring(text)
    return true
  end

  local context = {
    w = 70,
    h = 22,
    colors = COLORS,
    view = view,
    notifications = {},
    text = {
      truncate = function(value, width)
        return tostring(value):sub(1, width)
      end,
    },
    util = {
      humanTime = function(value)
        return tostring(value) .. "s"
      end,
    },
    kernel = {
      master = master,
      vfs = vfs or { read = function() return nil end, write = function() return true end },
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

if checked == 0 then
  failures[#failures + 1] = "no assertions ran"
end

return table.concat(failures, "\n")
