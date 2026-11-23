-- Standalone test for src/lib/tc/link.lua.
--
-- The module only needs a fake component tree, a fake clock and reply text, so
-- this test does not load harness.lua. The JS runner injects NET_SOURCE,
-- LINK_SOURCE and SCENARIO, then reads LINK_ERRORS back.

local scenario = ...

local errors = 0
local function check(condition, message)
  if not condition then
    errors = errors + 1
    print("  FAIL " .. message)
  end
end

local net = assert(load(NET_SOURCE, "=net.lua"))()

-- The link asks tc.lab for an environment; the test only needs the print
-- capture, so this stands in for the module and keeps the check on the link.
local fakeLab = {
  new = function()
    return {
      environment = function(_, output)
        return {
          error = error,
          math = math,
          select = select,
          string = string,
          table = table,
          tostring = tostring,
          print = function(...)
            local pieces = {}
            for index = 1, select("#", ...) do
              pieces[index] = tostring((select(index, ...)))
            end
            output[#output + 1] = table.concat(pieces, "\t")
          end,
        }
      end,
    }
  end,
}

local BASE = {
  assert = assert,
  error = error,
  ipairs = ipairs,
  load = load,
  math = math,
  pairs = pairs,
  pcall = pcall,
  select = select,
  setmetatable = setmetatable,
  string = string,
  table = table,
  tonumber = tonumber,
  tostring = tostring,
  type = type,
}

local clock = 1000
local computer = {
  uptime = function()
    return clock
  end,
  address = function()
    return "aaaa-bbbb"
  end,
}

-- Each request hands out the next canned reply. Requests past the last reply
-- get an empty body, which is how the bridge says "nothing to do".
local function makeBridge(replies)
  local requests = {}
  local served = 0

  local function request(url, body, headers)
    requests[#requests + 1] = {
      url = url,
      body = body or "",
      headers = headers or {},
    }

    served = served + 1
    local reply = replies[served] or ""
    local position = 1
    local handle = {}
    handle.finishConnect = function()
      return true
    end
    handle.response = function()
      return 200
    end
    handle.read = function(count)
      if position > #reply then
        return nil
      end
      local chunk = reply:sub(position, position + count - 1)
      position = position + #chunk
      return chunk
    end
    handle.close = function()
      return true
    end
    return handle
  end

  return requests, request
end

local function makeComponent(request, hasCard)
  return {
    list = function(kind)
      local sent = false
      return function()
        if hasCard and not sent and (kind == nil or kind == "internet") then
          sent = true
          return "internet-1", "internet"
        end
        return nil
      end
    end,
    invoke = function(address, method, ...)
      if address == "internet-1" and method == "request" then
        return request(...)
      end
      return nil, "unknown method"
    end,
  }
end

local function build(settings, replies, files, listings, hasCard, plant, book, planner, gateService)
  clock = 1000
  local requests, request = makeBridge(replies)
  local opened = {}
  local warnings = {}

  local env = {}
  for key, value in pairs(BASE) do
    env[key] = value
  end
  env.require = function(id)
    if id == "tc.net" then
      return net
    end
    if id == "tc.lab" then
      return fakeLab
    end
    if id == "tc.path" then
      return assert(load(PATH_SOURCE, "=path.lua"))()
    end
    error("unexpected module: " .. tostring(id))
  end
  env.component = makeComponent(request, hasCard ~= false)
  env.computer = computer
  local live = {}
  for key, value in pairs(settings) do
    live[key] = value
  end
  env.config = {
    get = function(key) return live[key] end,
    set = function(key, value)
      -- Mirrors src/lib/tc/config.lua: linkInterval is a number of seconds and
      -- its accepted floor is 0.5, not 1. A fake that insisted on 1 would
      -- reject the sub-second cadence the OS deliberately allows.
      if key == "linkInterval" and type(value) == "number" and value >= 0.5 then
        live[key] = value
        return true
      end
      return false
    end,
  }
  local capture = { writes = {}, poweroff = 0 }

  env.vfs = {
    -- Dot-style like src/lib/tc/vfs.lua: `vfs.write(path, data)`. A fake that
    -- accepts an instance first would hide a caller passing self by mistake.
    read = function(path) return files[path] end,
    list = function(path) return listings[path] end,
    write = function(path, data)
      capture.writes[#capture.writes + 1] = "w " .. path .. " " .. data
      return true
    end,
    append = function(path, data)
      capture.writes[#capture.writes + 1] = "a " .. path .. " " .. data
      return true
    end,
    ensureDir = function(path)
      capture.writes[#capture.writes + 1] = "d " .. path
      return true
    end,
    remove = function(path)
      capture.writes[#capture.writes + 1] = "r " .. path
      return true
    end,
    rename = function(from, to)
      capture.writes[#capture.writes + 1] = "m " .. from .. " " .. to
      return true
    end,
  }
  env.log = {
    trace = function() end,
    info = function() end,
    warn = function(message) warnings[#warnings + 1] = message end,
    error = function(message) warnings[#warnings + 1] = message end,
  }
  env.version = { product = "TerraCorp OS", version = "0.3.19" }
  env.kernel = {
    hostname = "TC-TEST",
    plant = plant,
    book = book,
    plan = planner,
    gate = gateService,
    memory = function() return 256 * 1024, 1024 * 1024 end,
    components = function()
      return { total = 12, entries = { { kind = "card", count = 2 } } }
    end,
    poweroff = function()
      capture.poweroff = capture.poweroff + 1
      return true
    end,
    saveConfig = function()
      capture.saved = (capture.saved or 0) + 1
      return true
    end,
    ui = {
      open = function(_, id) opened[#opened + 1] = id end,
      findWindow = function(_, id)
        if id == "dashboard" then
          return { id = id }
        end
        return nil
      end,
      close = function(_, window) opened[#opened + 1] = "closed:" .. window.id end,
    },
  }

  local module = assert(load(LINK_SOURCE, "=link.lua", "t", env))("tc.link")
  local instance = module.new(env)
  return instance, requests, opened, warnings, capture
end

local function drive(instance, seconds)
  local steps = math.floor(seconds / 0.01)
  for _ = 1, steps do
    clock = clock + 0.01
    instance:tick()
  end
end

-- Decode the frames the OS posted back, as a bridge would.
local function posted(body)
  local result = {
    text = "",
    state = nil,
    reason = nil,
    ended = false,
    size = nil,
    endSize = nil,
    data = 0,
    offsets = {},
  }
  for line in body:gmatch("[^\n]+") do
    local verb, fields = net.decode(line)
    if verb == "LREP" then
      result.state = fields.state
      result.reason = fields.reason
      result.size = tonumber(fields.size)
    elseif verb == "LDATA" then
      result.text = result.text .. fields.data
      result.data = result.data + 1
      result.offsets[#result.offsets + 1] = tonumber(fields.off)
    elseif verb == "LEND" then
      result.ended = true
      result.endSize = tonumber(fields.size)
    end
  end
  return result
end

local function countOf(text, needle)
  local count = 0
  local start = 1
  while true do
    local index = text:find(needle, start, true)
    if not index then
      return count
    end
    count = count + 1
    start = index + #needle
  end
end

-- A fake plant service shaped like tc.plant: `status`, `snapshot`, `alarms`
-- and the stock revision the delta cursor uses.
local function makePlant(options)
  options = options or {}
  local stocks = options.stocks or {
    {
      name = "casing/ingots",
      kind = "item",
      path = "casing/ingots",
      cardinality = "single",
      state = "exact",
      total = 744,
      age = 1.25,
      updatedAt = 990,
      version = 4,
      members = 1,
      rate = -3.5,
      trend = -12.0,
      rateSpan = 120,
      entries = {
        {
          kind = "item",
          key = "gregtech:meta_ingot",
          damage = 113,
          label = "Titanium Ingot",
          count = 192,
        },
        {
          kind = "item",
          key = "gregtech:meta_ingot",
          damage = 20,
          label = "Steel Ingot",
          count = 552,
        },
      },
    },
    {
      name = "casing/casings",
      kind = "item",
      path = "casing/casings",
      cardinality = "single",
      state = "exact",
      total = 5,
      age = 1.25,
      updatedAt = 990,
      version = 4,
      members = 1,
      entries = {
        {
          kind = "item",
          key = "gregtech:machine_casing",
          damage = 4,
          label = "EV Machine Casing",
          count = 2,
        },
      },
    },
  }
  local alarms = options.alarms or {
    {
      code = "STARVED",
      source = "casing/ingots",
      severity = "warn",
      first = 900,
      last = 1000,
      message = "744 below minimum 800",
    },
  }
  local errors = options.errors or {
    { line = 4, message = "unknown stock: casing/nope" },
  }

  local plant = {
    stock = {
      generation = options.generation or 40,
      revision = options.revision or 7,
    },
  }

  function plant:status()
    return {
      version = "0.4.2",
      uptime = 1000,
      memory = { used = 1048576, total = 67108864 },
      energy = 87.5,
      stored = 123456,
      maximum = 654321,
      link = { enabled = true, state = "ready" },
      components = 15,
      stocks = #stocks,
      calls = 12,
      scanning = false,
      cacheAge = 1.25,
      historySamples = 720,
      historyPersisted = true,
      configured = true,
      errors = errors,
    }
  end

  function plant:snapshot()
    return {
      at = 990,
      generation = self.stock.generation,
      revision = self.stock.revision,
      scanning = false,
      calls = 12,
      stocks = stocks,
      alarms = alarms,
      errors = errors,
      configured = true,
    }
  end

  function plant:alarms()
    return alarms
  end

  function plant.stock:snapshot()
    return { stocks = stocks }
  end

  plant.stock.stocks = stocks
  plant.stock.paths = {
    paths = {
      ["casing/ingots"] = { cardinality = "single", members = { "node:comp:1" } },
      ["casing/casings"] = { cardinality = "single", members = { "node:comp:2" } },
      ["casing/unbound"] = { cardinality = "single", members = {} },
    },
  }

  plant.history = {
    samples = {
      ["casing/ingots"] = {
        { t = 900, total = 700, state = "exact" },
        { t = 1000, total = 744, state = "exact" },
      },
      ["casing/casings"] = {
        { t = 900, total = 5, state = "exact" },
        { t = 1000, total = 5, state = "exact" },
      },
    },
  }

  function plant.history:rate(name)
    return { rate = name == "casing/ingots" and 2.5 or 0, span = 100 }
  end

  function plant.history:trend(name)
    if name == "casing/ingots" then
      return { percent = -12 }
    end
    return nil
  end

  function plant:hallView()
    return {
      halls = {
        { name = "TC-TEST", state = "online", stocks = 2, age = 0 },
        { name = "hall2", state = "offline", stocks = 0 },
      },
      stocks = {
        {
          hall = "TC-TEST",
          name = "TC-TEST/casing/ingots",
          kind = "item",
          state = "exact",
          total = 744,
        },
      },
      online = 1,
      stale = 0,
      offline = 1,
    }
  end

  return plant, stocks, alarms, errors
end

-- A gate service shaped like tc.gate.
local function makeGate()
  local record = {
    line = "lv",
    component = "comp-gate",
    side = 1,
    input = "casing/ingots",
    output = "casing/casings",
    desired = nil,
  }
  return {
    line = function(_, name)
      if name == "lv" then
        return record
      end
      return nil
    end,
    set = function(_, name, state)
      if name ~= "lv" then
        return nil, "unknown_line"
      end
      local value = tonumber(state)
      if value ~= 0 and value ~= 1 then
        return nil, "bad_state"
      end
      record.desired = value
      return { line = name, desired = value }
    end,
    reconcile = function(_, name)
      if name ~= "lv" then
        return nil, "unknown_line"
      end
      return true, record.desired
    end,
  }
end

-- A book shaped like tc.book: `order`, `errors`, `configured` and `list()`.
local function makeBook()
  local recipe = {
    id = "casing_ev",
    label = "EV casing",
    machine = "assembler",
    ticks = 50,
    priority = 10,
    machines = 1,
    source = "book",
    status = "declared",
    ratio = 1,
    inputs = {
      { kind = "item", key = "gregtech:plate_titanium", damage = 0, qty = 8, chance = 1 },
    },
    outputs = {
      { kind = "item", key = "gregtech:machine_casing", damage = 4, qty = 1, chance = 1 },
    },
  }
  return {
    order = { recipe },
    errors = {},
    configured = true,
    list = function()
      return { recipe }
    end,
  }
end

-- A planner shaped like tc.plan: `run(target, qty, options)`.
local function makePlanner()
  return {
    run = function(_, target, qty)
      if target ~= "item gregtech:machine_casing@4" then
        return nil, "invalid_target"
      end
      return {
        target = { kind = "item", key = "gregtech:machine_casing", damage = 4 },
        qty = qty,
        steps = {
          {
            recipe = "casing_ev",
            label = "EV casing",
            machine = "assembler",
            source = "book",
            status = "suspect",
            ratio = 1.25,
            crafts = qty,
            seconds = qty * 50,
            rate = 0.02,
          },
        },
        bottleneck = { recipe = "casing_ev", rate = 0.02, crafts = qty, seconds = qty * 50 },
        seconds = qty * 50,
        rate = qty > 0 and (qty / (qty * 50)) or 0,
        shortfall = {
          {
            kind = "item",
            key = "gregtech:ore_titanium",
            damage = 0,
            need = qty * 16,
            have = 10,
            missing = math.max(0, qty * 16 - 10),
          },
        },
        warnings = {
          { code = "suspect_recipe", recipe = "casing_ev", ratio = 1.25 },
        },
        book = { recipes = 1, errors = 0 },
      }
    end,
  }
end

local settings = { linkSink = "http://bridge:8787", linkToken = "tok", linkInterval = 5, linkControl = "read" }
local files = { ["/var/log/tc.log"] = "alpha\nbeta\ngamma\n" }
local listings = { ["/etc"] = { "notes.cfg", "terracorp.cfg" } }

if scenario == "disabled" then
  local instance, requests = build({ linkSink = "", linkToken = "" }, {}, files, listings)
  drive(instance, 12)
  check(#requests == 0, "a disabled link must not issue a request")
  check(instance.enabled == false, "the link reports itself disabled")
elseif scenario == "no_card" then
  local instance, requests, _, warnings = build(settings, {}, files, listings, false)
  drive(instance, 12)
  check(#requests == 0, "no request without an Internet Card")
  local found = false
  for _, message in ipairs(warnings) do
    if message:find("no_card", 1, true) then
      found = true
    end
  end
  check(found, "the missing card is logged")
elseif scenario == "status" then
  local instance, requests = build(settings, { "TC1 LINK id=c1 token=tok cmd=status\n" }, files, listings)
  drive(instance, 12)
  check(#requests >= 2, "the reply is posted on the following exchange")
  check(requests[1].url:find("/link/next?node=aaaa-bbbb", 1, true) ~= nil, "the node address is in the URL")
  check(requests[1].headers["X-Link-Token"] == "tok", "the token header is set")
  check(requests[1].body == "", "the first exchange carries no results")
  local result = posted(requests[2].body)
  check(result.state == "ok", "status answers ok")
  check(result.ended, "the body is closed with LEND")
  check(result.text:find("version=0.3.19", 1, true) ~= nil, "status carries the version")
  check(result.text:find("product=TerraCorp OS", 1, true) ~= nil, "status carries the product name")
  check(result.text:find("memory=256KB/1024KB", 1, true) ~= nil, "status carries the memory split")
elseif scenario == "log" then
  local instance, requests = build(settings, { "TC1 LINK id=c1 token=tok cmd=log n=2\n" }, files, listings)
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.text == "beta\ngamma\n", "log returns the last two lines, got " .. string.format("%q", result.text))
elseif scenario == "app_open" then
  local writable = {
    linkSink = settings.linkSink,
    linkToken = settings.linkToken,
    linkInterval = 5,
    linkControl = "write",
  }
  local instance, requests, opened = build(
    writable,
    { "TC1 LINK id=c1 token=tok cmd=app.open arg=dashboard\n" },
    files,
    listings
  )
  drive(instance, 12)
  check(opened[1] == "dashboard", "app.open opens the named app")
  local result = posted(requests[2].body)
  check(result.state == "ok", "app.open reports ok")
  check(result.text:find("opened=dashboard", 1, true) ~= nil, "app.open reports what it opened")
elseif scenario == "bad_token" then
  local instance, requests = build(settings, { "TC1 LINK id=c1 token=wrong cmd=status\n" }, files, listings)
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "error", "a bad token is rejected")
  check(result.reason == "unauthorized", "the reason is unauthorized, got " .. tostring(result.reason))
elseif scenario == "unknown_cmd" then
  local instance, requests = build(settings, { "TC1 LINK id=c1 token=tok cmd=nuke\n" }, files, listings)
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "error", "an unknown command is rejected")
  check(result.reason == "unknown_cmd", "the reason is unknown_cmd, got " .. tostring(result.reason))
elseif scenario == "garbage" then
  local instance, requests = build(settings, { "this is not a frame\n" }, files, listings)
  drive(instance, 12)
  check(#requests >= 2, "the loop keeps going after a bad reply")
  check(requests[2].body == "", "a garbage reply produces no result frames")
elseif scenario == "fs_list" then
  local instance, requests = build(settings, { "TC1 LINK id=c1 token=tok cmd=fs.list path=%2Fetc\n" }, files, listings)
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.text == "notes.cfg\nterracorp.cfg\n", "fs.list lists the directory, got " .. string.format("%q", result.text))
elseif scenario == "check" then
  local instance, requests = build(settings, { "TC1 LINK id=c1 token=tok cmd=check\n" }, files, listings)
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.text:find("## devices", 1, true) ~= nil, "check lists devices")
  check(result.text:find("card x2", 1, true) ~= nil, "check counts component kinds")
  check(result.text:find("alpha", 1, true) ~= nil, "check includes the log tail")
elseif scenario == "write_refused" then
  local instance, requests, _, _, capture = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=fs.write path=%2Fvar%2Fx.txt data=hola\n" },
    files,
    listings
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "error", "a write with control off is rejected")
  check(result.reason == "needs_write_control", "reason is needs_write_control, got " .. tostring(result.reason))
  check(#capture.writes == 0, "a refused write touches nothing")
elseif scenario == "write_ok" then
  local writable = {
    linkSink = settings.linkSink,
    linkToken = settings.linkToken,
    linkInterval = 5,
    linkControl = "write",
  }
  local instance, requests, _, _, capture = build(
    writable,
    { "TC1 LINK id=c1 token=tok cmd=fs.write path=%2Fvar%2Fx.txt data=hola\n" },
    files,
    listings
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "ok", "a write at control=write succeeds")
  check(result.text:find("wrote=4", 1, true) ~= nil, "the write reports its size")
  check(capture.writes[1] == "w /var/x.txt hola", "the file was written, got " .. tostring(capture.writes[1]))
elseif scenario == "boot_guard" then
  local writable = {
    linkSink = settings.linkSink,
    linkToken = settings.linkToken,
    linkInterval = 5,
    linkControl = "write",
  }
  local instance, requests, _, _, capture = build(
    writable,
    { "TC1 LINK id=c1 token=tok cmd=fs.write path=%2Fboot%2Fkernel.lua data=x\n" },
    files,
    listings
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.reason == "needs_full_control", "the OS tree needs full control, got " .. tostring(result.reason))
  check(#capture.writes == 0, "a guarded write touches nothing")
elseif scenario == "boot_full" then
  local writable = {
    linkSink = settings.linkSink,
    linkToken = settings.linkToken,
    linkInterval = 5,
    linkControl = "full",
  }
  local instance, requests, _, _, capture = build(
    writable,
    { "TC1 LINK id=c1 token=tok cmd=fs.write path=%2Fboot%2Fkernel.lua data=x\n" },
    files,
    listings
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "ok", "full control may write the OS tree")
  check(capture.writes[1] == "w /boot/kernel.lua x", "the write reached the vfs")
elseif scenario == "app_close" then
  local writable = {
    linkSink = settings.linkSink,
    linkToken = settings.linkToken,
    linkInterval = 5,
    linkControl = "write",
  }
  local instance, requests, opened = build(
    writable,
    { "TC1 LINK id=c1 token=tok cmd=app.close arg=dashboard\n" },
    files,
    listings
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.text:find("closed=dashboard", 1, true) ~= nil, "app.close reports what it closed")
  check(opened[1] == "closed:dashboard", "the window was closed")
elseif scenario == "reboot" then
  local writable = {
    linkSink = settings.linkSink,
    linkToken = settings.linkToken,
    linkInterval = 5,
    linkControl = "write",
  }
  local instance, requests, _, _, capture = build(
    writable,
    { "TC1 LINK id=c1 token=tok cmd=reboot\n" },
    files,
    listings
  )
  drive(instance, 30)
  local result = posted(requests[2].body)
  check(result.text:find("reboot=scheduled", 1, true) ~= nil, "reboot acknowledges before restarting")
  check(capture.poweroff == 1, "poweroff was called once, got " .. tostring(capture.poweroff))
elseif scenario == "interval" then
  -- The interval is a link-level knob: available with linkControl off, because
  -- it changes only this client's cadence and touches no user data. It is the
  -- only command that reaches the OS at `off`.
  local offSettings = { linkSink = "http://bridge:8787", linkToken = "tok", linkInterval = 5 }
  local instance, requests, _, _, capture = build(
    offSettings,
    {
      "TC1 LINK id=c1 token=tok cmd=link.interval n=abc\n",
      "TC1 LINK id=c2 token=tok cmd=link.interval n=1\n",
    },
    files,
    listings
  )
  drive(instance, 12)
  local bad = posted(requests[2].body)
  check(bad.state == "error", "a non-numeric interval is rejected")
  check(bad.reason == "bad_interval", "reason is bad_interval, got " .. tostring(bad.reason))
  local applied = posted(requests[3].body)
  check(applied.state == "ok", "link.interval works with control off")
  check(
    applied.text:find("interval=1s", 1, true) ~= nil,
    "the reply names the new interval, got " .. string.format("%q", applied.text)
  )
  check(instance.interval == 1, "the client polls every second, got " .. tostring(instance.interval))
  check(capture.saved >= 1, "the new interval is persisted")
elseif scenario == "interval_max" then
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=link.interval n=900\n" },
    files,
    listings
  )
  drive(instance, 6)
  check(instance.interval == 60, "the interval is capped at 60 s, got " .. tostring(instance.interval))
elseif scenario == "interval_floor" then
  -- The floor is 0.5 s. A sub-second cadence must survive as a fraction, and a
  -- value below the floor must be clamped up to it rather than refused, because
  -- the whole point of the change is that the operator asked for "as fast as
  -- possible".
  local instance, requests = build(
    settings,
    {
      "TC1 LINK id=c1 token=tok cmd=link.interval n=0.5\n",
      "TC1 LINK id=c2 token=tok cmd=link.interval n=0.1\n",
    },
    files,
    listings
  )
  drive(instance, 12)
  local bodies = {}
  for index = 2, #requests do
    bodies[#bodies + 1] = posted(requests[index].body).text or ""
  end
  local joined = table.concat(bodies, "\n")
  check(
    joined:find("interval=0.5s", 1, true) ~= nil,
    "the reply keeps the fraction instead of rounding it, got " .. string.format("%q", joined)
  )
  check(instance.interval == 0.5, "the client polls every 0.5 s, got " .. tostring(instance.interval))
elseif scenario == "off_refuses_read" then
  -- `off` means off. Read access is its own tier, so a read command at `off`
  -- must be refused with the tier named. Before this, `off` and `read` shared a
  -- rank and every read verb answered at `off`.
  local offSettings = { linkSink = "http://bridge:8787", linkToken = "tok", linkInterval = 5 }
  local instance, requests = build(
    offSettings,
    { "TC1 LINK id=c1 token=tok cmd=status\n" },
    files,
    listings
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "error", "status is refused at off, got " .. tostring(result.state))
  check(
    result.reason == "needs_read_control",
    "the refusal names the read tier, got " .. tostring(result.reason)
  )
elseif scenario == "lua" then
  local full = {
    linkSink = settings.linkSink,
    linkToken = settings.linkToken,
    linkInterval = 5,
    linkControl = "full",
  }
  local instance, requests = build(
    full,
    { "TC1 LINK id=c1 token=tok cmd=lua data=print(6%2A7)\n" },
    files,
    listings
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "ok", "lua answers ok")
  check(result.text == "42\n", "the chunk output comes back, got " .. string.format("%q", result.text))
elseif scenario == "lua_error" then
  local full = {
    linkSink = settings.linkSink,
    linkToken = settings.linkToken,
    linkInterval = 5,
    linkControl = "full",
  }
  local instance, requests = build(
    full,
    { "TC1 LINK id=c1 token=tok cmd=lua data=error(%27boom%27)\n" },
    files,
    listings
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "ok", "a failing chunk still answers, with the text")
  check(result.text:find("error:", 1, true) ~= nil, "the failure is reported, got " .. string.format("%q", result.text))
  check(result.text:find("boom", 1, true) ~= nil, "the message is kept, got " .. string.format("%q", result.text))
elseif scenario == "lua_refused" then
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=lua data=print(1)\n" },
    files,
    listings
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "error", "lua needs full control")
  check(result.reason == "needs_full_control", "reason is needs_full_control, got " .. tostring(result.reason))
elseif scenario == "plant_status" then
  local plant = makePlant()
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.status\n" },
    files,
    listings,
    true,
    plant
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "ok", "plant.status answers ok")
  check(result.text:find("format=plant.status.v1", 1, true) ~= nil, "the status body names its format")
  check(result.text:find("version=0.4.2", 1, true) ~= nil, "plant.status carries the plant version")
  check(result.text:find("hall=TC-TEST", 1, true) ~= nil, "plant.status names the local hall")
  check(result.text:find("energy=87.5", 1, true) ~= nil, "plant.status carries energy")
  check(result.text:find("stocks=2", 1, true) ~= nil, "plant.status counts the stocks")
  check(result.text:find("revision=7", 1, true) ~= nil, "plant.status carries the revision")
  check(result.text:find("history_samples=720", 1, true) ~= nil, "plant.status carries the history size")
  check(result.text:find("alarms=1", 1, true) ~= nil, "plant.status counts the alarms")
  check(result.text:find("link_control=read", 1, true) ~= nil, "plant.status carries the link tier")
elseif scenario == "plant_snapshot" then
  local plant = makePlant()
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.snapshot\n" },
    files,
    listings,
    true,
    plant
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "ok", "plant.snapshot answers ok")
  check(result.ended, "plant.snapshot closes with LEND")
  check(result.size == #result.text, "the LREP size matches the body")
  check(result.text:find("format=plant.snapshot.v1", 1, true) ~= nil, "the snapshot body names its format")
  check(result.text:find("stock name=casing/ingots kind=item state=exact total=744", 1, true) ~= nil,
    "the snapshot carries the input stock")
  check(result.text:find("rate=-3.500", 1, true) ~= nil, "the snapshot carries the rate")
  check(result.text:find("trend=-12.0", 1, true) ~= nil, "the snapshot carries the trend")
  check(result.text:find("entry stock=casing/ingots", 1, true) ~= nil, "the snapshot carries entries")
  check(result.text:find("label=Titanium%20Ingot", 1, true) ~= nil, "a label with a space is escaped")
  check(result.text:find("alarm code=STARVED source=casing/ingots", 1, true) ~= nil,
    "the snapshot carries alarms")
  check(result.text:find("error line=4", 1, true) ~= nil, "the snapshot carries configuration errors")
elseif scenario == "plant_snapshot_hall" then
  local plant = makePlant()
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.snapshot hall=other\n" },
    files,
    listings,
    true,
    plant
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "error", "an unknown hall is rejected")
  check(result.reason == "unknown_hall", "reason is unknown_hall, got " .. tostring(result.reason))
elseif scenario == "plant_snapshot_filter" then
  local plant = makePlant()
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.snapshot stocks=casing/casings\n" },
    files,
    listings,
    true,
    plant
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "ok", "a filtered snapshot answers ok")
  check(countOf(result.text, "\nstock ") == 1, "the filter keeps one stock record")
  check(result.text:find("stock name=casing/casings", 1, true) ~= nil, "the filter keeps the named stock")
  check(result.text:find("stock name=casing/ingots", 1, true) == nil, "the filter drops the other stock")
elseif scenario == "plant_snapshot_paged" then
  local stocks = {}
  for index = 1, 40 do
    stocks[index] = {
      name = string.format("hall/stock-%02d", index),
      kind = "item",
      path = string.format("hall/stock-%02d", index),
      cardinality = "single",
      state = "exact",
      total = index,
      age = 1,
      updatedAt = 990,
      version = 1,
      members = 1,
      entries = {
        {
          kind = "item",
          key = "test:item",
          damage = index,
          label = "Test Item " .. tostring(index),
          count = index,
        },
      },
    }
  end
  local plant = makePlant({ stocks = stocks })
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.snapshot\n" },
    files,
    listings,
    true,
    plant
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "ok", "a large snapshot answers ok")
  check(#result.text > 1024, "the paged body is larger than one frame, got " .. tostring(#result.text))
  check(result.data > 1, "the body spans several LDATA frames, got " .. tostring(result.data))
  check(result.size == #result.text, "the size header matches the reassembled body")
  check(result.endSize == #result.text, "LEND matches the reassembled body")
  check(result.offsets[1] == 0, "the first slice starts at offset 0")
  check(result.offsets[#result.offsets] < #result.text, "the last slice starts inside the body")
  check(result.text:find("stock name=hall/stock-40", 1, true) ~= nil, "the last stock survives paging")
  check(result.text:find("label=Test%20Item%2040", 1, true) ~= nil, "the last label survives paging")
elseif scenario == "plant_delta_match" then
  local plant = makePlant()
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.delta cursor=7\n" },
    files,
    listings,
    true,
    plant
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "ok", "plant.delta answers ok")
  check(result.text:find("format=plant.delta.v1", 1, true) ~= nil, "the delta names its format")
  check(result.text:find("resync=0", 1, true) ~= nil, "a current cursor is not a resync")
  check(result.text:find("changes=0", 1, true) ~= nil, "a current cursor reports no changes")
  check(result.text:find("snapshot_begin", 1, true) == nil, "a matching cursor carries no snapshot")
elseif scenario == "plant_delta_resync" then
  local plant = makePlant()
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.delta cursor=3\n" },
    files,
    listings,
    true,
    plant
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "ok", "a stale delta answers ok")
  check(result.text:find("resync=1", 1, true) ~= nil, "a stale cursor asks for a resync")
  check(result.text:find("reason=stale_cursor", 1, true) ~= nil, "the resync names the reason")
  check(result.text:find("snapshot_begin", 1, true) ~= nil, "the resync carries a snapshot")
  check(result.text:find("stock name=casing/ingots", 1, true) ~= nil, "the resync snapshot is complete")
elseif scenario == "plant_delta_nocursor" then
  local plant = makePlant()
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.delta\n" },
    files,
    listings,
    true,
    plant
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.text:find("resync=1", 1, true) ~= nil, "a missing cursor starts with a resync")
  check(result.text:find("reason=no_cursor", 1, true) ~= nil, "the first sync names its reason")
elseif scenario == "plant_alarms" then
  local plant = makePlant()
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.alarms\n" },
    files,
    listings,
    true,
    plant
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "ok", "plant.alarms answers ok")
  check(result.text:find("format=plant.alarms.v1", 1, true) ~= nil, "the alarm body names its format")
  check(result.text:find("alarm code=STARVED source=casing/ingots", 1, true) ~= nil,
    "the alarm carries its source")
  check(result.text:find("message=744%20below%20minimum%20800", 1, true) ~= nil,
    "the alarm message is escaped, not split")
  check(result.text:find("count=1", 1, true) ~= nil, "the alarm count is one")
elseif scenario == "plant_alarms_since" then
  local plant = makePlant()
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.alarms since=1001\n" },
    files,
    listings,
    true,
    plant
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.text:find("count=0", 1, true) ~= nil, "an alarm older than `since` is filtered out")
  check(result.text:find("alarm code=", 1, true) == nil, "the filtered body carries no alarm record")
elseif scenario == "plant_unavailable" then
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.status\n" },
    files,
    listings
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "error", "a missing plant service is an error")
  check(result.reason == "plant_unavailable", "reason is plant_unavailable, got " .. tostring(result.reason))
elseif scenario == "plant_book" then
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.book\n" },
    files,
    listings,
    true,
    makePlant(),
    makeBook()
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "ok", "plant.book answers ok, got " .. tostring(result.state) .. " " .. tostring(result.reason))
  check(result.text:find("format=plant.book.v1", 1, true) ~= nil, "the book names its format")
  check(result.text:find("recipe id=casing_ev label=EV%20casing machine=assembler", 1, true) ~= nil,
    "the book carries the recipe")
  check(result.text:find("io recipe=casing_ev side=in kind=item key=gregtech:plate_titanium", 1, true) ~= nil,
    "the book carries its inputs")
  check(result.text:find("io recipe=casing_ev side=out kind=item key=gregtech:machine_casing damage=4", 1, true) ~= nil,
    "the book carries its outputs")
elseif scenario == "plant_book_one" then
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.book recipe=casing_ev\n" },
    files,
    listings,
    true,
    makePlant(),
    makeBook()
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(countOf(result.text, "\nrecipe ") == 1, "one recipe is returned")
  check(result.text:find("recipe id=casing_ev", 1, true) ~= nil, "the requested recipe is present")
elseif scenario == "plant_book_unknown" then
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.book recipe=nope\n" },
    files,
    listings,
    true,
    makePlant(),
    makeBook()
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "error", "an unknown recipe is rejected")
  check(result.reason == "unknown_recipe", "reason is unknown_recipe, got " .. tostring(result.reason))
elseif scenario == "plant_plan" then
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.plan target=item%20gregtech:machine_casing@4 qty=2\n" },
    files,
    listings,
    true,
    makePlant(),
    makeBook(),
    makePlanner()
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "ok", "plant.plan answers ok")
  check(result.text:find("format=plant.plan.v1", 1, true) ~= nil, "the plan names its format")
  check(result.text:find("qty=2", 1, true) ~= nil, "the plan carries the quantity")
  check(result.text:find("bottleneck=casing_ev", 1, true) ~= nil, "the plan names the bottleneck")
  check(result.text:find("step recipe=casing_ev", 1, true) ~= nil, "the plan carries its steps")
  check(result.text:find("shortfall kind=item key=gregtech:ore_titanium damage=0 need=32 have=10 missing=22",
    1, true) ~= nil, "the plan carries the shortfall")
  check(result.text:find("warning code=suspect_recipe recipe=casing_ev ratio=1.2500", 1, true) ~= nil,
    "the plan carries its warnings")
elseif scenario == "plant_plan_bad" then
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.plan target=item%20gregtech:machine_casing@4 qty=0\n" },
    files,
    listings,
    true,
    makePlant(),
    makeBook(),
    makePlanner()
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "error", "a zero quantity is rejected")
  check(result.reason == "invalid_qty", "reason is invalid_qty, got " .. tostring(result.reason))
elseif scenario == "plant_history" then
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.history stock=casing/ingots n=10\n" },
    files,
    listings,
    true,
    makePlant()
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "ok", "plant.history answers ok")
  check(result.text:find("format=plant.history.v1", 1, true) ~= nil, "the history names its format")
  check(result.text:find("stock name=casing/ingots samples=2 rate=2.500", 1, true) ~= nil,
    "the history stock carries its rate")
  check(result.text:find("trend=-12.0", 1, true) ~= nil, "the history stock carries its trend")
  check(countOf(result.text, "\nsample ") == 2, "both samples are returned")
  check(result.text:find("sample stock=casing/ingots t=1000.0 total=744 state=exact", 1, true) ~= nil,
    "the newest sample is present")
elseif scenario == "plant_history_unknown" then
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.history stock=nope\n" },
    files,
    listings,
    true,
    makePlant()
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "error", "an unknown stock is rejected")
  check(result.reason == "unknown_stock", "reason is unknown_stock, got " .. tostring(result.reason))
elseif scenario == "plant_paths" then
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.paths\n" },
    files,
    listings,
    true,
    makePlant()
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "ok", "plant.paths answers ok")
  check(result.text:find("format=plant.paths.v1", 1, true) ~= nil, "the paths body names its format")
  check(result.text:find("paths=3", 1, true) ~= nil, "three paths are listed")
  check(result.text:find("path name=casing/ingots cardinality=single members=1", 1, true) ~= nil,
    "a bound path carries its member count")
  check(result.text:find("path name=casing/unbound cardinality=single members=0 stocks=0 bound=0", 1, true) ~= nil,
    "an unbound path is reported as such")
elseif scenario == "plant_paths_one" then
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.paths path=casing/casings\n" },
    files,
    listings,
    true,
    makePlant()
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.text:find("paths=1", 1, true) ~= nil, "one path is returned")
  check(result.text:find("path name=casing/casings", 1, true) ~= nil, "the requested path is present")
  check(result.text:find("path name=casing/ingots", 1, true) == nil, "the other path is filtered out")
elseif scenario == "plant_paths_unknown" then
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.paths path=nope\n" },
    files,
    listings,
    true,
    makePlant()
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "error", "an unknown path is rejected")
  check(result.reason == "unknown_path", "reason is unknown_path, got " .. tostring(result.reason))
elseif scenario == "plant_halls" then
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=plant.halls\n" },
    files,
    listings,
    true,
    makePlant()
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "ok", "plant.halls answers ok")
  check(result.text:find("format=plant.halls.v1", 1, true) ~= nil, "the halls body names its format")
  check(result.text:find("halls=2", 1, true) ~= nil, "two halls are listed")
  check(result.text:find("hall name=TC-TEST state=online", 1, true) ~= nil, "the local hall is online")
  check(result.text:find("hall name=hall2 state=offline", 1, true) ~= nil, "the missing hall is offline")
  check(result.text:find("stock hall=TC-TEST name=TC-TEST/casing/ingots", 1, true) ~= nil,
    "the merged stock is prefixed with its hall")
elseif scenario == "gate_set" then
  local writable = {
    linkSink = settings.linkSink,
    linkToken = settings.linkToken,
    linkInterval = 5,
    linkControl = "write",
  }
  local instance, requests = build(
    writable,
    { "TC1 LINK id=c1 token=tok cmd=gate.set line=lv state=1\n" },
    files,
    listings,
    true,
    makePlant(),
    nil,
    nil,
    makeGate()
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.text:find("line=lv desired=1 actual=1", 1, true) ~= nil,
    "gate.set stores and reconciles the desired state")
elseif scenario == "gate_set_unknown" then
  local writable = {
    linkSink = settings.linkSink,
    linkToken = settings.linkToken,
    linkInterval = 5,
    linkControl = "write",
  }
  local instance, requests = build(
    writable,
    { "TC1 LINK id=c1 token=tok cmd=gate.set line=nope state=1\n" },
    files,
    listings,
    true,
    makePlant(),
    nil,
    nil,
    makeGate()
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "error", "an unknown gate line is rejected")
  check(result.reason == "unknown_line", "reason is unknown_line, got " .. tostring(result.reason))
elseif scenario == "gate_set_tier" then
  local instance, requests = build(
    settings,
    { "TC1 LINK id=c1 token=tok cmd=gate.set line=lv state=1\n" },
    files,
    listings,
    true,
    makePlant(),
    nil,
    nil,
    makeGate()
  )
  drive(instance, 12)
  local result = posted(requests[2].body)
  check(result.state == "error", "gate.set needs write control")
  check(result.reason == "needs_write_control", "reason is needs_write_control, got " .. tostring(result.reason))
else
  errors = errors + 1
  print("  FAIL unknown scenario: " .. tostring(scenario))
end

LINK_ERRORS = errors
