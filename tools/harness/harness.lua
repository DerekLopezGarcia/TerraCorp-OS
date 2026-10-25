-- Run TerraCorp OS outside Minecraft using fake components, an in-memory disk,
-- a matrix-rasterizing GPU, and scripted events. Detect runtime errors.

local files = BUNDLE
local STRICT = STRICT == true
-- Fault injection: the real GPU may return nil, "not enough energy". Set
-- FAULT.set = N to reject the first N writes and verify that the OS retries.
local FAULT = rawget(_G, "FAULT") or {}
local faultsLeft = tonumber(FAULT.set) or 0
local faultsInjected = 0
local stats = { listCalls = 0, listReturned = 0, spaceCalls = 0 }
local written = {}
local deleted = {}
local directories = { ["/"] = true, ["/etc"] = true, ["/var"] = true, ["/var/log"] = true }
local handles = {}
local nextHandle = 0

local function readReal(path)
  if deleted[path] then
    return nil
  end
  if written[path] ~= nil then
    return written[path]
  end
  return files[path]
end

local function entriesUnder(path)
  local prefix = (path == "/") and "/" or (path .. "/")
  local seen, names = {}, {}

  local function consider(full)
    if full:sub(1, #prefix) ~= prefix then
      return
    end
    local rest = full:sub(#prefix + 1)
    local name = rest:match("^([^/]+)")
    if name and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end

  for full in pairs(files) do
    if not deleted[full] then
    consider(full)
    end
  end
  for full in pairs(written) do
    consider(full)
  end
  for full in pairs(directories) do
    consider(full)
  end

  table.sort(names)
  return names
end

local fsApi = {}

-- The real filesystem requires the parent directory before opening for write;
-- otherwise the harness could hide `ensureDir` failures.
local function isDirectoryPath(path)
  if path == "/" or directories[path] then
    return true
  end
  local prefix = path .. "/"
  for full in pairs(files) do
    if full:sub(1, #prefix) == prefix then return true end
  end
  for full in pairs(written) do
    if full:sub(1, #prefix) == prefix then return true end
  end
  for full in pairs(directories) do
    if full:sub(1, #prefix) == prefix then return true end
  end
  return false
end

local function parentOf(path)
  local parent = path:match("^(.*)/[^/]+$")
  if not parent or parent == "" then
    return "/"
  end
  return parent
end

function fsApi.open(path, mode)
  mode = mode or "r"
  nextHandle = nextHandle + 1

  local handle
  if mode == "r" or mode == "rb" then
    local content = readReal(path)
    if not content then
      return nil, "no such file: " .. tostring(path)
    end
    handle = { kind = "r", content = content, position = 1 }
  elseif mode == "w" or mode == "wb" then
    if not isDirectoryPath(parentOf(path)) then
      return nil, "no such file or directory: " .. tostring(path)
    end
    written[path] = ""
    deleted[path] = nil
    handle = { kind = "w", path = path }
  elseif mode == "a" or mode == "ab" then
    if not isDirectoryPath(parentOf(path)) then
      return nil, "no such file or directory: " .. tostring(path)
    end
    written[path] = readReal(path) or ""
    handle = { kind = "a", path = path }
  else
    return nil, "modo no soportado: " .. tostring(mode)
  end

  handles[nextHandle] = handle
  return nextHandle
end

function fsApi.read(id, count)
  local handle = handles[id]
  if not handle then
    return nil, "invalid handle"
  end
  if handle.kind ~= "r" then
    return nil
  end
  count = count or math.huge
  if handle.position > #handle.content then
    return nil
  end
  local chunk = handle.content:sub(handle.position, handle.position + count - 1)
  handle.position = handle.position + #chunk
  return chunk
end

function fsApi.write(id, data)
  local handle = handles[id]
  if not handle then
    return nil, "invalid handle"
  end
  if handle.kind == "r" then
    return nil, "read-only handle"
  end
  written[handle.path] = written[handle.path] .. data
  return true
end

function fsApi.close(id)
  handles[id] = nil
  return true
end

function fsApi.exists(path)
  return readReal(path) ~= nil or directories[path] == true
end

function fsApi.isDirectory(path)
  if path == "/" or directories[path] then
    return true
  end
  return #entriesUnder(path) > 0
end

-- The real `filesystem` component returns a 1..n table of names
-- (`list` es `String[]` en FileSystem.scala y se convierte a tabla Lua).
function fsApi.list(path)
  local names = entriesUnder(path)
  stats.listCalls = stats.listCalls + 1
  stats.listReturned = stats.listReturned + #names
  return names
end

function fsApi.size(path)
  local content = readReal(path)
  if not content then
    return 0
  end
  return #content
end

-- OpenComputers expone `spaceUsed`/`spaceTotal`, en bytes. `space()` no existe.
function fsApi.spaceUsed()
  stats.spaceCalls = stats.spaceCalls + 1
  return 131072
end

function fsApi.spaceTotal()
  return 4194304
end

function fsApi.makeDirectory(path)
  directories[path] = true
  return true
end

function fsApi.remove(path)
  written[path] = nil
  deleted[path] = true
  return true
end

local renameCalls = 0
function fsApi.rename(from, to)
  renameCalls = renameCalls + 1
  if rawget(_G, "SCENARIO") == "updater_rollback" and renameCalls == 4 then
    return nil, "injected rename failure"
  end
  local content = readReal(from)
  if content == nil then
    return nil, "source does not exist"
  end
  written[to] = content
  deleted[to] = nil
  written[from] = nil
  deleted[from] = true
  return true
end

-- ---------------------------------------------------------------------------
-- In-memory rasterizing GPU
-- ---------------------------------------------------------------------------

local width, height = 80, 25
-- Maximum simulated resolution; scenarios can test small and large screens.
local maxWidth = tonumber(rawget(_G, "MAX_WIDTH")) or 160
local maxHeight = tonumber(rawget(_G, "MAX_HEIGHT")) or 50
local cells = {}
local setCalls = 0
local clock = 0
local palette = {}
local paletteWrites = 0
local backgroundIsPalette = false
local foregroundIsPalette = false

local function resetScreen()
  cells = {}
  for y = 1, height do
    cells[y] = {}
    for x = 1, width do
      cells[y][x] = " "
    end
  end
end

local gpu = {}

function gpu.getResolution()
  return width, height
end

function gpu.maxResolution()
  return maxWidth, maxHeight
end

function gpu.setResolution(w, h)
  if w < 1 or h < 1 or w > maxWidth or h > maxHeight then
    return false
  end
  width, height = w, h
  resetScreen()
  return true
end

-- Match the component: return true on success and nil/reason when GPU power is
-- insufficient. The OS uses this to retry a span.
function gpu.setBackground(_, isPaletteIndex)
  backgroundIsPalette = isPaletteIndex == true
  return true
end

function gpu.setForeground(_, isPaletteIndex)
  foregroundIsPalette = isPaletteIndex == true
  return true
end

function gpu.setPaletteColor(index, color)
  local previous = palette[index]
  if previous == nil then
    paletteWrites = paletteWrites + 1
  end
  palette[index] = color
  return previous or 0
end

function gpu.getBackground()
  return 15
end

function gpu.getForeground()
  return 0
end

function gpu.set(x, y, value)
  setCalls = setCalls + 1
  if faultsLeft > 0 then
    faultsLeft = faultsLeft - 1
    faultsInjected = faultsInjected + 1
    return nil, "not enough energy"
  end
  if not cells[y] then
    return true
  end
  local column = x
  for _, code in utf8.codes(value) do
    if cells[y][column] then
      cells[y][column] = utf8.char(code)
    end
    column = column + 1
  end
  return true
end

function gpu.fill(x, y, w, h, character)
  for row = y, y + h - 1 do
    if cells[row] then
      for column = x, x + w - 1 do
        if cells[row][column] then
          cells[row][column] = character
        end
      end
    end
  end
  return true
end

resetScreen()

-- ---------------------------------------------------------------------------
-- Components and computer
-- ---------------------------------------------------------------------------

local fakeUpdates = rawget(_G, "SCENARIO") == "updater"
local fakeUpdateRollback = rawget(_G, "SCENARIO") == "updater_rollback"
local updateScenario = fakeUpdates or fakeUpdateRollback
local mockedReleaseVersion
if updateScenario then
  local currentVersion = files["/lib/tc/version.lua"]:match('version%s*=%s*"([^"]+)"')
  local major, minor, patch = currentVersion:match("^(%d+)%.(%d+)%.(%d+)$")
  mockedReleaseVersion = string.format("%s.%s.%d", major, minor, tonumber(patch) + 1)
end
local kinds = {
  ["gpu-1"] = "gpu",
  ["screen-1"] = "screen",
  ["fs-boot"] = "filesystem",
  ["eeprom-1"] = "eeprom",
}
if updateScenario then
  kinds["internet-1"] = "internet"
end

local kindOrder = { "eeprom-1", "fs-boot", "gpu-1", "screen-1" }
if updateScenario then
  kindOrder[#kindOrder + 1] = "internet-1"
end

component = {}

function component.list(kind)
  local result = {}
  for _, address in ipairs(kindOrder) do
    if not kind or kinds[address] == kind then
      result[#result + 1] = address
    end
  end
  local index = 0
  return function()
    index = index + 1
    local address = result[index]
    if address then
      return address, kinds[address]
    end
  end
end

function component.proxy(address)
  if address == "fs-boot" then
    return fsApi
  elseif address == "gpu-1" then
    return gpu
  end
  return nil
end

function component.invoke(address, method, ...)
  if address == "fs-boot" then
    local fn = fsApi[method]
    if not fn then
      return nil, "unknown method: " .. tostring(method)
    end
    return fn(...)
  elseif address == "gpu-1" and method == "bind" then
    return true
  elseif address == "internet-1" and method == "request" then
    local url = select(1, ...)
    local body
    if url:find("/releases/latest", 1, true) then
      body = '{"tag_name":"v' .. mockedReleaseVersion .. '"}'
    elseif url:find("/tools/manifest.txt", 1, true) then
      body = "src/init.lua\nsrc/boot/kernel.lua\nsrc/lib/tc/version.lua\n"
    elseif url:find("/src/lib/tc/version.lua", 1, true) then
      body = 'return { product = "TerraCorp OS", company = "TerraCorp", tagline = "Architects of Dawn", version = "'
        .. mockedReleaseVersion .. '", codename = "Foundry", api = 1, license = "MIT" }\n'
    elseif url:find("/src/init.lua", 1, true) then
      body = "return 1\n"
    elseif url:find("/src/boot/kernel.lua", 1, true) then
      body = "return 2\n"
    else
      return nil, "not found"
    end
    local sent = false
    local connectionChecks = 0
    local handle = {}
    handle.finishConnect = function(...)
        assert(select("#", ...) == 0, "finishConnect received unexpected arguments")
        connectionChecks = connectionChecks + 1
        return connectionChecks > 1
      end
    handle.response = function(...)
        assert(select("#", ...) == 0, "response received unexpected arguments")
        return 200, "OK", {}
      end
    handle.read = function(size)
        assert(size == 8192, "read did not receive the requested chunk size")
        if sent then
          return nil
        end
        sent = true
        return body
      end
    handle.close = function(...)
        assert(select("#", ...) == 0, "close received unexpected arguments")
        return true
      end
    return handle
  end
  return true
end

local shutdownFlag = false
local scripted = {}

local function ev(...)
  scripted[#scripted + 1] = table.pack(...)
end

computer = {}

function computer.uptime()
  return clock
end

function computer.pullSignal(timeout)
  stats.pullCalls = (stats.pullCalls or 0) + 1
  stats.lastPullTimeout = timeout
  clock = clock + (timeout or 0.25)
  if #scripted == 0 then
    return "shutdown"
  end
  local item = table.remove(scripted, 1)
  return table.unpack(item, 1, item.n)
end

function computer.address()
  return "abc12345-6789-4abc-8def-001122334455"
end

function computer.getBootAddress()
  return "fs-boot"
end

function computer.setBootAddress()
  return true
end

function computer.energy()
  return 8200, 10000
end

function computer.maxEnergy()
  return 10000
end

function computer.totalMemory()
  return 2097152
end

function computer.freeMemory()
  return 1600000
end

function computer.shutdown()
  shutdownFlag = true
  return true
end

-- ---------------------------------------------------------------------------
-- Interaction script anchored to simulated resolution, not fixed screen rows.
-- ---------------------------------------------------------------------------

local scenario = SCENARIO or "all"

local function idle(count)
  for _ = 1, count do
    ev("component_added", "x", "y")
  end
end

local function typeText(value)
  for character in value:gmatch(".") do
    ev("key_down", "screen-1", utf8.codepoint(character), nil, "tester")
  end
end

-- Scenarios use simulated resolution; the dock is on the penultimate row and
-- windows scale with the screen.
local dockY = maxHeight - 1

-- Match `ui:defaultGeometry` for the first window (offset 0). Pointer gestures
-- may miss if layout changes; this should not create false-positive coverage.
local function windowRect()
  local desktopTop = 3
  local desktopBottom = dockY - 1
  local usable = desktopBottom - desktopTop + 1
  local w = math.min(maxWidth - 4, math.max(34, math.floor(maxWidth * 0.74)))
  local h = math.min(usable - 1, math.max(10, math.floor(usable * 0.84)))
  local x = math.floor((maxWidth - w) / 2)
  local y = desktopTop + math.max(0, math.floor((usable - h) / 2))
  return x, y, w, h
end

if scenario == "dashboard_tick" then
  local source = files["/apps/dashboard.lua"]
  local chunk = assert(load(source, "=apps/dashboard.lua", "t", {
    setmetatable = setmetatable,
    tonumber = tonumber,
  }))
  local module = chunk("apps.dashboard")
  local now, expensiveReads = 0, 0
  local kernelMock = {
    memory = function()
      expensiveReads = expensiveReads + 1
      return 256, 1024
    end,
    energy = function()
      expensiveReads = expensiveReads + 1
      return 10, 10
    end,
    storage = function()
      expensiveReads = expensiveReads + 1
      return 1, 10
    end,
    components = function()
      expensiveReads = expensiveReads + 1
      return { total = 1, entries = {} }
    end,
    uptime = function()
      return now
    end,
  }
  local app = module.create({ kernel = kernelMock })
  local initialReads = expensiveReads
  now = 1
  assert(app:tick({ kernel = kernelMock }), "uptime tick did not request a redraw")
  assert(app.uptime == 1, "uptime did not advance after one second")
  assert(expensiveReads == initialReads, "expensive readings refreshed before two seconds")
  now = 2
  assert(app:tick({ kernel = kernelMock }), "two-second sample did not request a redraw")
  assert(app.uptime == 2 and app.samplesAt == 2, "two-second sample was not refreshed")
  assert(expensiveReads == initialReads + 4, "expected one full sensor refresh at two seconds")
  stats.dashboardTickChecked = true
elseif scenario == "refresh_rate" then
  idle(1)
elseif scenario == "dashboard" then
  ev("touch", "screen-1", 3, dockY, 0, "tester")
  idle(12)
elseif scenario == "console" then
  ev("key_down", "screen-1", nil, 0x3D, "tester")
  typeText("help")
  ev("key_down", "screen-1", nil, 0x1C, "tester")
  idle(2)
elseif scenario == "files" then
  -- Keyboard navigation should work at any screen size.
  ev("key_down", "screen-1", nil, 0x3C, "tester")   -- F2 opens Files
  idle(1)
  ev("key_down", "screen-1", nil, 0xD0, "tester")   -- abajo x3 hasta /lib
  ev("key_down", "screen-1", nil, 0xD0, "tester")
  ev("key_down", "screen-1", nil, 0xD0, "tester")
  ev("key_down", "screen-1", nil, 0x1C, "tester")   -- entra
  idle(1)
  ev("key_down", "screen-1", nil, 0xD0, "tester")   -- move down one level
  ev("key_down", "screen-1", nil, 0x1C, "tester")   -- open
  ev("key_down", "screen-1", nil, 0x0E, "tester")   -- go up
  idle(2)
elseif scenario == "settings" then
  ev("touch", "screen-1", 40, dockY, 0, "tester")
  idle(3)
elseif scenario == "updater" then
  local wx, wy, winWidth, winHeight = windowRect()
  ev("key_down", "screen-1", nil, 0x3F, "tester") -- F5 opens About
  idle(1)
  local contentHeight = winHeight - 3
  local buttonRow = math.max(4, contentHeight - 2)
  local buttonX = wx + 1 + math.floor((winWidth - 2) / 2)
  ev("touch", "screen-1", buttonX, wy + 1 + buttonRow, 0, "tester")
  idle(1)
  ev("touch", "screen-1", buttonX, wy + 1 + buttonRow, 0, "tester")
  idle(2)
elseif scenario == "updater_rollback" then
  local wx, wy, winWidth, winHeight = windowRect()
  ev("key_down", "screen-1", nil, 0x3F, "tester") -- F5 opens About
  idle(1)
  local contentHeight = winHeight - 3
  local buttonRow = math.max(4, contentHeight - 2)
  local buttonX = wx + 1 + math.floor((winWidth - 2) / 2)
  ev("touch", "screen-1", buttonX, wy + 1 + buttonRow, 0, "tester")
  idle(1)
  ev("touch", "screen-1", buttonX, wy + 1 + buttonRow, 0, "tester")
  idle(2)
else
  local wx, wy = windowRect()
  ev("touch", "screen-1", 3, dockY, 0, "tester")     -- abre Panel
  ev("touch", "screen-1", wx + 2, wy, 0, "tester")   -- grab the title bar
  ev("drop", "screen-1", wx + 3, wy + 1, 0, "tester")
  ev("scroll", "screen-1", wx + 2, wy + 1, 1, "tester")
  ev("key_down", "screen-1", "r", 0x13, "tester")
  ev("key_down", "screen-1", nil, 0x3D, "tester")
  typeText("help")
  ev("key_down", "screen-1", nil, 0x1C, "tester")
  ev("key_down", "screen-1", nil, 0x3F, "tester")
end

-- ---------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------

local chunk, loadError = load(files["/init.lua"], "=/init.lua")
if not chunk then
  print("COULD NOT COMPILE /init.lua: " .. tostring(loadError))
  TC_ERRORS = 1
  return
end

local ok, failure = pcall(chunk)

print("")
print("=== RUN ===")
print("result      : " .. (ok and "ok" or ("ERROR: " .. tostring(failure))))
print("powered off : " .. tostring(shutdownFlag))
print("gpu.set calls: " .. setCalls)
if faultsInjected > 0 then
  print("injected faults: " .. faultsInjected .. " (insufficient power)")
end
print("resolution  : " .. width .. "x" .. height)
print("scenario    : " .. tostring(scenario) .. (STRICT and " (strict)" or ""))

-- F0 measurements (see docs/tests.md). Harness startup is synchronous:
-- The first frame draws before any event is consumed, so real boot time and
-- memory must be measured in-game (uptime and computer.freeMemory in the log).
-- This harness measures rendering cost, which is comparable across versions.
local painted = 0
for y = 1, height do
  for x = 1, width do
    if cells[y][x] ~= " " then
      painted = painted + 1
    end
  end
end
local totalCells = width * height

print("")
print("=== METRICS ===")
print(string.format("painted   : %d of %d cells (%.1f %%) in %d gpu.set calls · %d signals",
  painted, totalCells, painted * 100 / totalCells, setCalls, stats.pullCalls or 0))

print("")
print("=== FINAL SCREEN ===")
for y = 1, height do
  print("|" .. table.concat(cells[y]) .. "|")
end

local journal = written["/var/log/tc.log"]
print("")
print("=== PERSISTED LOG ===")
print(journal or "(empty)")

local errors = 0
if not ok then
  errors = errors + 1
end
if journal and journal:find("ERR", 1, true) then
  errors = errors + 1
end
if setCalls == 0 then
  errors = errors + 1
end

local screenRows = {}
for y = 1, height do
  screenRows[#screenRows + 1] = table.concat(cells[y])
end
local finalScreen = table.concat(screenRows, "\n")

if scenario == "updater_rollback" then
  for _, path in ipairs({ "/init.lua", "/boot/kernel.lua", "/lib/tc/version.lua" }) do
    if readReal(path) ~= files[path] then
      errors = errors + 1
      print("FAIL: rollback did not restore " .. path)
    end
  end
  if not finalScreen:find("Could not install", 1, true) then
    errors = errors + 1
    print("FAIL: rollback scenario did not report the injected install failure")
  end
  if written["/etc/terracorp.cfg"] ~= nil then
    errors = errors + 1
    print("FAIL: updater changed persistent settings")
  end
end

-- Strict checks validate visible output as well as component calls.
if STRICT then
  local rows = {}
  for y = 1, height do
    rows[#rows + 1] = table.concat(cells[y])
  end
  local screen = table.concat(rows, "\n")

  if scenario == "refresh_rate" then
    local expected = 1 / 30
    if type(stats.lastPullTimeout) ~= "number"
      or stats.lastPullTimeout > expected + 0.000001
      or stats.lastPullTimeout <= 0 then
      errors = errors + 1
      print("FAIL: idle signal wait exceeds the 30 Hz target")
    end
  end

  if screen:find("could not list", 1, true) then
    errors = errors + 1
    print("FAIL: Files could not list entries (expected a table, not an iterator)")
  end
  if screen:find("Could not read boot disk", 1, true) then
    errors = errors + 1
    print("FAIL: Dashboard could not read storage (spaceUsed/spaceTotal)")
  end
  if scenario == "files" and stats.listReturned == 0 then
    errors = errors + 1
    print("FAIL: Files scenario did not list a directory")
  end
  if scenario == "dashboard" and stats.spaceCalls == 0 then
    errors = errors + 1
    print("FAIL: Dashboard did not query spaceUsed")
  end
  if scenario == "updater" and not screen:find("Installed 3 files", 1, true) then
      errors = errors + 1
      print("FAIL: the updater did not detect or install the mocked GitHub release")
  end
  if scenario == "dashboard_tick" and not stats.dashboardTickChecked then
    errors = errors + 1
    print("FAIL: dashboard one-second uptime tick was not verified")
  end
  if scenario == "updater" and screen:find("Could not install", 1, true) then
    errors = errors + 1
    print("FAIL: the updater could not commit the staged release")
  end

  if not backgroundIsPalette or not foregroundIsPalette then
    errors = errors + 1
    print("FAIL: GPU colors were sent as RGB instead of palette indexes")
  end
  if paletteWrites ~= 16 then
    errors = errors + 1
    print("FAIL: the 16 OpenComputers palette colors were not initialized")
  end

  -- After GPU faults, the display must be painted. If rejected writes are
  -- treated as successful, the differential renderer leaves permanent gaps.
  if faultsInjected > 0 then
    local visible = 0
    for y = 1, height do
      for x = 1, width do
        if cells[y][x] ~= " " then
          visible = visible + 1
        end
      end
    end
    if visible == 0 then
      errors = errors + 1
      print("FAIL: display is blank after rejected GPU writes")
    end
  end
end

print("")
print("=== SUMMARY ===")
print("list: " .. stats.listCalls .. " calls, " .. stats.listReturned .. " entries · spaceUsed: " .. stats.spaceCalls)
print(errors == 0 and "no errors" or (errors .. " problem(s)"))

TC_ERRORS = errors
