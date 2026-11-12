-- Standalone test for src/apps/gaia.lua.
--
-- The app is a window: draw, then touch or key. This drives it with a recording
-- view and a fake link so a nil field or a bad hit box fails the gate instead of
-- waiting for a player to click it in game.

local errors = 0
local function check(condition, message)
  if not condition then
    errors = errors + 1
    print("  FAIL " .. message)
  end
end

local keys = assert(load(KEYS_SOURCE, "=keys.lua"))()
local text = assert(load(TEXT_SOURCE, "=text.lua"))()

local function loadGaia()
  local env = {
    require = function(id)
      if id == "tc.keys" then
        return keys
      end
      return text
    end,
    ipairs = ipairs,
    math = math,
    pairs = pairs,
    pcall = pcall,
    setmetatable = setmetatable,
    string = string,
    table = table,
    tostring = tostring,
    type = type,
  }
  return assert(load(GAIA_SOURCE, "=gaia.lua", "t", env))("apps.gaia")
end

local function makeCtx(settings, link)
  local draws = 0
  local notices = {}

  local view = {
    clear = function() end,
    put = function()
      draws = draws + 1
    end,
    hline = function() end,
  }

  local config = {
    path = "/etc/terracorp.cfg",
    get = function(key) return settings[key] end,
    set = function(key, value)
      settings[key] = value
      return true
    end,
    cycle = function(key, options)
      for index, value in ipairs(options) do
        if value == settings[key] then
          settings[key] = options[(index % #options) + 1]
          return settings[key]
        end
      end
      settings[key] = options[1]
      return settings[key]
    end,
  }

  local kernel = {
    saveConfig = function() end,
    link = link,
  }

  local ctx = {
    view = view,
    config = config,
    kernel = kernel,
    ui = {
      notify = function(_, level, message)
        notices[#notices + 1] = level .. ":" .. message
      end,
    },
    colors = {
      text = "text",
      dim = "dim",
      deep = "deep",
      panel = "panel",
      accent = "accent",
      onAccent = "onAccent",
    },
    glyphs = { h = "-" },
    text = text,
    w = 60,
    h = 20,
  }

  return ctx, notices, function()
    return draws
  end
end

local function fakeLink()
  local link = { refreshed = 0 }
  link.refresh = function()
    link.refreshed = link.refreshed + 1
    return true
  end
  link.report = function()
    return {
      enabled = true,
      sink = "http://10.8.0.1:8787",
      control = "off",
      interval = 5,
      failures = 0,
      problem = nil,
      queued = 0,
      state = "idle",
      commands = 3,
      lastCommand = "status",
      lastAt = 12,
    }
  end
  return link
end

local gaia = loadGaia()

-- 1. Form fields and buttons render, and the icon is a 9x5 globe.
check(gaia.id == "gaia", "the app id is gaia")
check(gaia.iconArt ~= nil and #gaia.iconArt == 5, "iconArt has five rows")
for row = 1, 5 do
  check(text.width(gaia.iconArt[row]) == 9, "iconArt row " .. row .. " is nine cells")
end
check(text.width(gaia.icon) == 3, "the icon code is three cells")

do
  local settings = { linkSink = "", linkToken = "", linkControl = "off", linkInterval = 5 }
  local ctx, _, draws = makeCtx(settings, fakeLink())
  local instance = gaia.create()
  local ok, reason = pcall(instance.draw, instance, ctx)
  check(ok, "draw runs: " .. tostring(reason))
  check(draws() > 0, "draw writes something")
  check(#instance.hits > 2, "draw registers hit boxes for the fields and buttons")
end

-- 2. A missing link module must not crash the window.
do
  local settings = { linkSink = "", linkToken = "", linkControl = "off", linkInterval = 5 }
  local ctx = makeCtx(settings, nil)
  local instance = gaia.create()
  local ok, reason = pcall(instance.draw, instance, ctx)
  check(ok, "draw survives a missing link: " .. tostring(reason))
end

-- 3. The control tier cycles and is saved.
do
  local settings = { linkSink = "", linkToken = "", linkControl = "off", linkInterval = 5 }
  local link = fakeLink()
  local ctx = makeCtx(settings, link)
  local instance = gaia.create()
  instance:cycleTier(ctx)
  check(settings.linkControl == "write", "the tier advances to write, got " .. tostring(settings.linkControl))
  instance:cycleTier(ctx)
  check(settings.linkControl == "full", "the tier advances to full, got " .. tostring(settings.linkControl))
  instance:cycleTier(ctx)
  check(settings.linkControl == "off", "the tier wraps back to off, got " .. tostring(settings.linkControl))
  check(link.refreshed == 3, "the link is refreshed on every change")
end

-- 4. The interval cycles through the offered values.
do
  local settings = { linkSink = "", linkToken = "", linkControl = "off", linkInterval = 5 }
  local ctx = makeCtx(settings, fakeLink())
  local instance = gaia.create()
  instance:cycleInterval(ctx)
  check(settings.linkInterval == 10, "the interval advances to 10, got " .. tostring(settings.linkInterval))
end

-- 5. Editing the sink: type, then Enter commits it to the preferences.
do
  local settings = { linkSink = "", linkToken = "secret", linkControl = "off", linkInterval = 5 }
  local link = fakeLink()
  local ctx, notices = makeCtx(settings, link)
  local instance = gaia.create()

  instance:startEdit(ctx, "sink")
  check(instance.editing == "sink", "the sink field enters edit mode")
  instance.draft = "http://10.8.0.1:8787"
  local handled = instance:handle(ctx, "key", "", keys.enter)
  check(handled == true, "Enter is consumed while editing")
  check(settings.linkSink == "http://10.8.0.1:8787", "the sink was stored, got " .. tostring(settings.linkSink))
  check(instance.editing == nil, "editing ends after Enter")
  check(#notices > 0, "the operator is told the sink was saved")
end

-- 6. Esc abandons an edit without touching the preferences.
do
  local settings = { linkSink = "http://kept", linkToken = "", linkControl = "off", linkInterval = 5 }
  local ctx = makeCtx(settings, fakeLink())
  local instance = gaia.create()
  instance:startEdit(ctx, "sink")
  instance.draft = "http://discarded"
  instance:handle(ctx, "key", "", keys.esc)
  check(settings.linkSink == "http://kept", "Esc leaves the stored sink alone")
  check(instance.editing == nil, "Esc ends editing")
end

-- 7. Backspace removes one character.
do
  local settings = { linkSink = "http://abc", linkToken = "", linkControl = "off", linkInterval = 5 }
  local ctx = makeCtx(settings, fakeLink())
  local instance = gaia.create()
  instance:startEdit(ctx, "sink")
  instance:handle(ctx, "key", "", keys.back)
  check(instance.draft == "http://ab", "backspace trims the draft, got " .. tostring(instance.draft))
end

-- 8. Text typed while editing is appended.
do
  local settings = { linkSink = "", linkToken = "", linkControl = "off", linkInterval = 5 }
  local ctx = makeCtx(settings, fakeLink())
  local instance = gaia.create()
  instance:startEdit(ctx, "sink")
  instance:handle(ctx, "key", "h", 0)
  instance:handle(ctx, "key", "i", 0)
  check(instance.draft == "hi", "typed characters are appended, got " .. tostring(instance.draft))
end

GAIA_ERRORS = errors
