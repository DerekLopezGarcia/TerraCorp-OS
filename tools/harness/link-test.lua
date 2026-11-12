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

local BASE = {
  assert = assert,
  error = error,
  ipairs = ipairs,
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

local function build(settings, replies, files, listings, hasCard)
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
    error("unexpected module: " .. tostring(id))
  end
  env.component = makeComponent(request, hasCard ~= false)
  env.computer = computer
  env.config = { get = function(key) return settings[key] end }
  local capture = { writes = {}, poweroff = 0 }

  env.vfs = {
    read = function(path) return files[path] end,
    list = function(path) return listings[path] end,
    write = function(_, path, data)
      capture.writes[#capture.writes + 1] = "w " .. path .. " " .. data
      return true
    end,
    append = function(_, path, data)
      capture.writes[#capture.writes + 1] = "a " .. path .. " " .. data
      return true
    end,
    ensureDir = function(_, path)
      capture.writes[#capture.writes + 1] = "d " .. path
      return true
    end,
    remove = function(_, path)
      capture.writes[#capture.writes + 1] = "r " .. path
      return true
    end,
    rename = function(_, from, to)
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
    memory = function() return 256 * 1024, 1024 * 1024 end,
    components = function()
      return { total = 12, entries = { { kind = "card", count = 2 } } }
    end,
    poweroff = function()
      capture.poweroff = capture.poweroff + 1
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
  local result = { text = "", state = nil, reason = nil, ended = false }
  for line in body:gmatch("[^\n]+") do
    local verb, fields = net.decode(line)
    if verb == "LREP" then
      result.state = fields.state
      result.reason = fields.reason
    elseif verb == "LDATA" then
      result.text = result.text .. fields.data
    elseif verb == "LEND" then
      result.ended = true
    end
  end
  return result
end

local settings = { linkSink = "http://bridge:8787", linkToken = "tok", linkInterval = 5 }
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
else
  errors = errors + 1
  print("  FAIL unknown scenario: " .. tostring(scenario))
end

LINK_ERRORS = errors
