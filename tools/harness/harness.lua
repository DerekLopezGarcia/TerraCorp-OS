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
  -- OpenComputers declares the filesystem `close` callback as Unit, so real
  -- computers receive no value on success. Returning true here would hide
  -- updater bugs that reject a successful close.
end

-- Guard the fake itself: a callback that returns values cannot model OC.
assert(select("#", fsApi.close(0)) == 0, "filesystem close must return no values")

function fsApi.exists(path)
  return readReal(path) ~= nil or isDirectoryPath(path)
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
  directories[path] = nil
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
-- Independent in-memory filesystem (rack floppy)
-- ---------------------------------------------------------------------------
-- The Nodes scenario prepares a payload onto a floppy. That volume must not
-- share the boot volume's store, so it gets the same component contract with
-- its own files and capacity.

local function normalizePath(path)
  path = tostring(path or "/")
  path = "/" .. path:gsub("^/+", "")
  if #path > 1 then
    path = path:gsub("/+$", "")
  end
  return path
end

local function newVolume(capacity)
  local volume = {}
  local store = {}
  local dirs = { ["/"] = true }
  local openHandles = {}
  local nextId = 0

  local function newHandle(path, kind)
    nextId = nextId + 1
    openHandles[nextId] = { path = path, kind = kind, position = 1 }
    return nextId
  end

  function volume.open(path, mode)
    path = normalizePath(path)
    mode = mode or "r"
    if mode == "r" then
      if store[path] == nil then
        return nil, "no such file: " .. path
      end
    elseif mode == "w" then
      store[path] = ""
      dirs[path] = nil
    elseif mode == "a" then
      store[path] = store[path] or ""
    else
      return nil, "unsupported mode: " .. tostring(mode)
    end
    return newHandle(path, mode)
  end

  function volume.read(id, count)
    local handle = openHandles[id]
    if not handle or handle.kind ~= "r" then
      return nil, "invalid handle"
    end
    local content = store[handle.path] or ""
    if handle.position > #content then
      return nil
    end
    count = count or #content
    local chunk = content:sub(handle.position, handle.position + count - 1)
    handle.position = handle.position + #chunk
    return chunk
  end

  function volume.write(id, data)
    local handle = openHandles[id]
    if not handle or handle.kind == "r" then
      return nil, "invalid handle"
    end
    store[handle.path] = (store[handle.path] or "") .. data
    return true
  end

  function volume.close(id)
    openHandles[id] = nil
  end

  function volume.exists(path)
    path = normalizePath(path)
    return store[path] ~= nil or dirs[path] == true
  end

  function volume.isDirectory(path)
    path = normalizePath(path)
    if path == "/" or dirs[path] then
      return true
    end
    local prefix = path .. "/"
    for full in pairs(store) do
      if full:sub(1, #prefix) == prefix then
        return true
      end
    end
    return false
  end

  function volume.isReadOnly()
    return false
  end

  function volume.size(path)
    local content = store[normalizePath(path)]
    return content and #content or nil
  end

  function volume.list(path)
    path = normalizePath(path)
    local prefix = path == "/" and "/" or (path .. "/")
    local seen, names = {}, {}
    local function consider(full)
      if full:sub(1, #prefix) ~= prefix then
        return
      end
      local name = full:sub(#prefix + 1):match("^([^/]+)")
      if name and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
    for full in pairs(store) do
      consider(full)
    end
    for full in pairs(dirs) do
      if full ~= "/" then
        consider(full)
      end
    end
    table.sort(names)
    return names
  end

  function volume.makeDirectory(path)
    path = normalizePath(path)
    dirs[path] = true
    return true
  end

  function volume.remove(path)
    path = normalizePath(path)
    store[path] = nil
    dirs[path] = nil
    return true
  end

  function volume.rename(from, to)
    from = normalizePath(from)
    to = normalizePath(to)
    if store[from] == nil and dirs[from] == nil then
      return nil, "source does not exist"
    end
    store[to] = store[from]
    store[from] = nil
    dirs[to] = dirs[from]
    dirs[from] = nil
    return true
  end

  function volume.spaceUsed()
    local used = 0
    for _, data in pairs(store) do
      used = used + #data
    end
    return used
  end

  function volume.spaceTotal()
    return capacity
  end

  return volume
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
local fakeLegacyInternet = rawget(_G, "SCENARIO") == "updater_legacy"
local fakeUpdateRecover = rawget(_G, "SCENARIO") == "updater_recover"
local fakeBootUpdate = rawget(_G, "SCENARIO") == "boot_update"
local nodesScenario = rawget(_G, "SCENARIO") == "nodes"
local savedIconOrder = rawget(_G, "SCENARIO") == "icon_order_saved"
local savedIconSlot = rawget(_G, "SCENARIO") == "icon_slot_saved"
local savedUpdateIcon = rawget(_G, "SCENARIO") == "icon_update"
local updateScenario = fakeUpdates or fakeUpdateRollback or fakeLegacyInternet or fakeUpdateRecover or fakeBootUpdate
local mockedReleaseVersion
if updateScenario then
  local currentVersion = files["/lib/tc/version.lua"]:match('version%s*=%s*"([^"]+)"')
  local major, minor, patch = currentVersion:match("^(%d+)%.(%d+)%.(%d+)$")
  mockedReleaseVersion = string.format("%s.%s.%d", major, minor, tonumber(patch) + 1)
end
if fakeBootUpdate then
  directories["/var/update"] = true
  written["/var/update/pending"] = "version=" .. mockedReleaseVersion
    .. "\ntag=v" .. mockedReleaseVersion .. "\n"
  -- User data outside src/ must survive the update untouched.
  written["/var/notes.txt"] = "Reactor inspection due Friday\n"
  -- A reset during an earlier attempt left originals in the backup tree.
  local stale = "/var/update/backup/" .. mockedReleaseVersion
  directories[stale] = true
  directories[stale .. "/lib"] = true
  directories[stale .. "/lib/tc"] = true
  written[stale .. "/lib/tc/version.lua"] = 'return { version = "0.0.0" }\n'
end
if savedIconOrder then
  written["/etc/terracorp.cfg"] = 'return {\n'
    .. '  iconOrder = "files,dashboard,console,settings,notes,about",\n'
    .. '}\n'
end
if savedIconSlot then
  -- Slots 2 (Files) and 7.. are empty; Files sits on row 3, column 4. The
  -- 0.2.2 layout still says "about"; the UI must migrate it to "update".
  written["/etc/terracorp.cfg"] = 'return {\n'
    .. '  iconOrder = "dashboard,console,settings,notes,about,files",\n'
    .. '  iconLayout = "dashboard@1,console@3,settings@4,notes@5,about@6,files@32",\n'
    .. '}\n'
end
if savedUpdateIcon then
  -- A 0.2.2 desktop with Update (then About) in slot 6.
  written["/etc/terracorp.cfg"] = 'return {\n'
    .. '  iconLayout = "dashboard@1,console@2,settings@3,notes@4,files@5,about@6",\n'
    .. '}\n'
end
local nodesFloppy = nodesScenario and newVolume(512 * 1024) or nil
local modemPackets = 0

local kinds = {
  ["gpu-1"] = "gpu",
  ["screen-1"] = "screen",
  ["fs-boot"] = "filesystem",
  ["eeprom-1"] = "eeprom",
}
if updateScenario then
  kinds["internet-1"] = "internet"
end
if nodesScenario then
  kinds["floppy-1"] = "filesystem"
  kinds["drive-1"] = "disk_drive"
  kinds["modem-1"] = "modem"
end

local kindOrder = { "eeprom-1", "fs-boot", "gpu-1", "screen-1" }
if updateScenario then
  kindOrder[#kindOrder + 1] = "internet-1"
end
if nodesScenario then
  kindOrder[#kindOrder + 1] = "floppy-1"
  kindOrder[#kindOrder + 1] = "drive-1"
  kindOrder[#kindOrder + 1] = "modem-1"
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
  elseif address == "floppy-1" then
    return nodesFloppy
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
  elseif address == "floppy-1" then
    local fn = nodesFloppy and nodesFloppy[method]
    if not fn then
      return nil, "unknown method: " .. tostring(method)
    end
    return fn(...)
  elseif address == "drive-1" and method == "filesystem" then
    return "floppy-1"
  elseif address == "modem-1" then
    if method == "isWired" then
      return true
    elseif method == "send" or method == "broadcast" then
      modemPackets = modemPackets + 1
      return true
    elseif method == "open" or method == "close" then
      return true
    end
    return nil, "unknown method: " .. tostring(method)
  elseif address == "gpu-1" and method == "bind" then
    return true
  elseif address == "internet-1" and method == "request" then
    local url = select(1, ...)
    local body
    if url:find("/releases/latest", 1, true) then
      body = '{"tag_name":"v' .. mockedReleaseVersion .. '"}'
    elseif url:find("/tools/manifest.txt", 1, true) then
      body = "eeprom/init.lua\nsrc/init.lua\nsrc/boot/kernel.lua\nsrc/boot/apply.lua\nsrc/lib/tc/version.lua\ntools/fetch.lua\n"
    elseif url:find("/src/lib/tc/version.lua", 1, true) then
      body = 'return { product = "TerraCorp OS", company = "TerraCorp", tagline = "Architects of Dawn", version = "'
        .. mockedReleaseVersion .. '", codename = "Foundry", api = 1, license = "MIT" }\n'
    elseif url:find("/src/init.lua", 1, true) then
      body = files["/init.lua"]
    elseif url:find("/src/boot/kernel.lua", 1, true) then
      body = files["/boot/kernel.lua"]
    elseif url:find("/src/boot/apply.lua", 1, true) then
      body = files["/boot/apply.lua"]
    else
      return nil, "not found"
    end
    local sent = false
    local connectionChecks = 0
    local readChecks = 0
    local handle = {}
    if not fakeLegacyInternet then
      handle.finishConnect = function(...)
          assert(select("#", ...) == 0, "finishConnect received unexpected arguments")
          connectionChecks = connectionChecks + 1
          return connectionChecks > 1
        end
    end
    handle.response = function(...)
        assert(select("#", ...) == 0, "response received unexpected arguments")
        if fakeLegacyInternet and not sent then
          return nil
        end
        return 200, "OK", {}
      end
    handle.read = function(size)
        assert(size == 8192, "read did not receive the requested chunk size")
        readChecks = readChecks + 1
        if fakeLegacyInternet and readChecks == 1 then
          return ""
        end
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

-- Scenarios use simulated resolution; the taskbar is the last row and windows
-- scale with the screen. The icon grid covers the full screen width.
local taskbarY = maxHeight

local function iconColumns()
  local fit = math.floor((maxWidth - 3 + 2) / 11)
  return math.max(1, fit)
end

local ICON_APPS = 7

local function iconRowsFor(tile)
  local desktopTop = 3
  local available = (taskbarY - 1) - (desktopTop + 1) + 1
  local pitch = tile + 1
  return math.floor((available - (tile + 1)) / pitch) + 1
end

-- Match ui:resize: use the largest 5/3/2/1 tile that still fits every app.
local function iconTileHeight()
  local columns = iconColumns()
  local needed = math.ceil(ICON_APPS / columns)
  for _, candidate in ipairs({ 5, 3, 2, 1 }) do
    if iconRowsFor(candidate) >= needed then
      return candidate
    end
  end
  return 1
end

local function iconGridBottom()
  local desktopTop = 3
  local columns = iconColumns()
  local tile = iconTileHeight()
  local rows = math.ceil(ICON_APPS / columns)
  local lastY = desktopTop + 1 + (rows - 1) * (tile + 1)
  return lastY + tile
end

-- Match `ui:defaultGeometry` for the first window (offset 0). Pointer gestures
-- may miss if layout changes; this should not create false-positive coverage.
local function windowRect()
  local desktopTop = 3
  local desktopBottom = taskbarY - 1
  local usable = desktopBottom - desktopTop + 1
  local minWidth = math.min(34, maxWidth - 2)
  local w = math.min(maxWidth - 4, math.max(minWidth, math.floor(maxWidth * 0.74)))
  local x = math.floor((maxWidth - w) / 2)
  local h = math.min(usable - 1, math.max(10, math.floor(usable * 0.84)))
  local y = desktopTop + math.max(0, math.floor((usable - h) / 2))

  local below = iconGridBottom() + 1
  local maxBelow = desktopBottom - below + 1
  if maxBelow >= 10 then
    y = below
    h = math.min(h, maxBelow)
  end

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
elseif scenario == "drag_metric" then
  local wx, wy = windowRect()
  ev("key_down", "screen-1", nil, 0x3D, "tester") -- F3 opens Console
  idle(1)
  typeText("dragtest")
  ev("key_down", "screen-1", nil, 0x1C, "tester")
  idle(1)
  ev("touch", "screen-1", wx + 2, wy, 0, "tester")
  for index = 1, 6 do
    idle(8)
    ev("drag", "screen-1", wx + 2 + index * 3, wy + 1, 0, "tester")
  end
  ev("drop", "screen-1", wx + 20, wy + 1, 0, "tester")
  idle(1)
elseif scenario == "dashboard" then
  ev("touch", "screen-1", 6, 5, 0, "tester") -- first desktop icon: System
  ev("drop", "screen-1", 6, 5, 0, "tester")
  idle(12)
elseif scenario == "desktop" then
  -- Second icon (Files) is in the first row at any supported resolution.
  ev("touch", "screen-1", 17, 5, 0, "tester")
  ev("drop", "screen-1", 17, 5, 0, "tester")
  idle(2)
elseif scenario == "icon_order" then
  -- Drag the second icon (Files) across several cells to exercise the floating
  -- icon, then drop it on the first slot and open that slot.
  ev("touch", "screen-1", 17, 5, 0, "tester")
  idle(1)
  ev("drag", "screen-1", 16, 5, 0, "tester")
  idle(1)
  ev("drag", "screen-1", 14, 5, 0, "tester")
  idle(1)
  ev("drag", "screen-1", 11, 5, 0, "tester")
  idle(1)
  ev("drag", "screen-1", 8, 5, 0, "tester")
  idle(1)
  ev("drag", "screen-1", 6, 5, 0, "tester")
  idle(1)
  ev("drop", "screen-1", 6, 5, 0, "tester")
  idle(2)
  ev("touch", "screen-1", 6, 5, 0, "tester")
  ev("drop", "screen-1", 6, 5, 0, "tester")
  idle(2)
elseif scenario == "icon_order_saved" then
  -- The saved layout is loaded during boot; the first slot must be Files.
  ev("touch", "screen-1", 6, 5, 0, "tester")
  ev("drop", "screen-1", 6, 5, 0, "tester")
  idle(2)
elseif scenario == "icon_slot" then
  -- Drag Files from slot 2 to an empty cell on row 3 (column 4), then open it
  -- from its new position.
  ev("touch", "screen-1", 17, 5, 0, "tester")
  idle(1)
  ev("drag", "screen-1", 21, 6, 0, "tester")
  idle(1)
  ev("drag", "screen-1", 28, 10, 0, "tester")
  idle(1)
  ev("drag", "screen-1", 35, 16, 0, "tester")
  idle(1)
  ev("drag", "screen-1", 37, 18, 0, "tester")
  idle(1)
  ev("drop", "screen-1", 37, 18, 0, "tester")
  idle(2)
  ev("touch", "screen-1", 39, 19, 0, "tester")
  ev("drop", "screen-1", 39, 19, 0, "tester")
  idle(2)
elseif scenario == "icon_slot_saved" then
  -- The saved position puts Files at row 3, column 4.
  ev("touch", "screen-1", 39, 19, 0, "tester")
  ev("drop", "screen-1", 39, 19, 0, "tester")
  idle(2)
elseif scenario == "icon_update" then
  -- 0.2.2 saved "about@6"; clicking slot 6 must open Update.
  ev("touch", "screen-1", 60, 5, 0, "tester")
  ev("drop", "screen-1", 60, 5, 0, "tester")
  idle(2)
elseif scenario == "icon_drag" then
  -- Open Files, then drag System over the window and hold it there. The ghost
  -- must be drawn above the window content, like a dragged window.
  ev("key_down", "screen-1", nil, 0x3C, "tester") -- F2 opens Files
  idle(2)
  ev("touch", "screen-1", 6, 5, 0, "tester")
  idle(1)
  ev("drag", "screen-1", 20, 10, 0, "tester")
  idle(1)
  ev("drag", "screen-1", 40, 18, 0, "tester")
  idle(1)
  ev("drag", "screen-1", 60, 25, 0, "tester")
  idle(2)
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
  ev("key_down", "screen-1", nil, 0x3E, "tester") -- F4 opens Settings
  idle(3)
elseif scenario == "notes" then
  ev("key_down", "screen-1", nil, 0x3F, "tester") -- F5 opens Notes
  idle(1)
  typeText("Reactor inspection due Friday")
  ev("key_down", "screen-1", nil, 0x1C, "tester") -- new line, saving the note
  typeText("coolant loop check")
  ev("key_down", "screen-1", nil, 0x01, "tester") -- Esc minimizes and saves on blur
  idle(1)
  ev("key_down", "screen-1", nil, 0x3F, "tester") -- reopen the same note
  idle(2)
elseif scenario == "nodes" then
  -- F7 opens the seventh app. Preparing writes the runtime to the rack floppy
  -- and arms the ten-minute installer window.
  ev("key_down", "screen-1", nil, 0x41, "tester") -- F7 opens Nodes
  idle(1)
  typeText("p")
  idle(2)
elseif scenario == "boot_update" then
  idle(2)
elseif scenario == "updater" or scenario == "updater_legacy" or scenario == "updater_recover" then
  if scenario ~= "updater" and scenario ~= "updater_legacy" then
    deleted["/boot/apply.lua"] = true
  end
  if scenario == "updater_recover" then
    -- Simulate a reset mid-install: the originals of the target release were
    -- moved into its backup tree and never restored.
    local backup = "/var/update/backup/" .. mockedReleaseVersion
    directories[backup] = true
    directories[backup .. "/lib"] = true
    directories[backup .. "/lib/tc"] = true
    written[backup .. "/lib/tc/version.lua"] = 'return { version = "0.0.1" }\n'
  end
  local wx, wy, winWidth, winHeight = windowRect()
  ev("key_down", "screen-1", nil, 0x40, "tester") -- F6 opens Update
  idle(1)
  local contentHeight = winHeight - 3
  local buttonRow = math.max(4, contentHeight - 2)
  local buttonX = wx + 1 + math.floor((winWidth - 2) / 2)
  ev("touch", "screen-1", buttonX, wy + 1 + buttonRow, 0, "tester")
  idle(fakeLegacyInternet and 8 or 1)
  ev("touch", "screen-1", buttonX, wy + 1 + buttonRow, 0, "tester")
  idle(fakeLegacyInternet and 12 or 2)
elseif scenario == "updater_rollback" then
  -- Exercise the legacy in-process installer, which is still the fallback when
  -- /boot/apply.lua is unavailable.
  deleted["/boot/apply.lua"] = true
  local wx, wy, winWidth, winHeight = windowRect()
  ev("key_down", "screen-1", nil, 0x40, "tester") -- F6 opens Update
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
  ev("touch", "screen-1", 6, 5, 0, "tester")     -- opens System from the icon
  ev("drop", "screen-1", 6, 5, 0, "tester")
  ev("touch", "screen-1", wx + 2, wy, 0, "tester")   -- grab the title bar
  ev("drop", "screen-1", wx + 3, wy + 1, 0, "tester")
  ev("scroll", "screen-1", wx + 2, wy + 1, 1, "tester")
  ev("key_down", "screen-1", "r", 0x13, "tester")
  ev("key_down", "screen-1", nil, 0x3D, "tester")
  typeText("help")
  ev("key_down", "screen-1", nil, 0x1C, "tester")
  ev("key_down", "screen-1", nil, 0x40, "tester")
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
  if not finalScreen:find("injected rename failure", 1, true) then
    errors = errors + 1
    print("FAIL: rollback scenario did not report the injected install failure")
  end
  if written["/etc/terracorp.cfg"] ~= nil then
    errors = errors + 1
    print("FAIL: updater changed persistent settings")
  end
end

if scenario == "updater_recover" then
  if finalScreen:find("backup for this release already exists", 1, true) then
    errors = errors + 1
    print("FAIL: a leftover backup blocked the update")
  end
  if not finalScreen:find("Restart to apply", 1, true) then
    errors = errors + 1
    print("FAIL: the update did not complete after recovering the backup")
  end
  local version = readReal("/lib/tc/version.lua") or ""
  if not version:find(mockedReleaseVersion, 1, true) then
    errors = errors + 1
    print("FAIL: the installed version was not replaced after recovery")
  end
end

if scenario == "boot_update" then
  if readReal("/var/update/pending") ~= nil then
    errors = errors + 1
    print("FAIL: the pending update marker was not cleared")
  end
  local status = readReal("/var/update/status") or ""
  if not status:find("Update complete", 1, true) or not status:find(mockedReleaseVersion, 1, true) then
    errors = errors + 1
    print("FAIL: the boot-time updater did not report success")
  end
  if readReal("/var/notes.txt") ~= "Reactor inspection due Friday\n" then
    errors = errors + 1
    print("FAIL: the boot-time updater changed user data outside src/")
  end
  if not finalScreen:find("v" .. mockedReleaseVersion, 1, true) then
    errors = errors + 1
    print("FAIL: the boot-time updater did not install the new version")
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
  if scenario == "drag_metric" and not screen:find("Drag test:", 1, true) then
    errors = errors + 1
    print("FAIL: drag-event measurement was not displayed")
  end
  if scenario == "drag_metric" and not screen:find("interpolated frames", 1, true) then
    errors = errors + 1
    print("FAIL: drag interpolation did not report intermediate redraws")
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
  if scenario == "notes" then
    local content = readReal("/var/notes.txt")
    if not content then
      errors = errors + 1
      print("FAIL: Notes did not write /var/notes.txt")
    elseif not content:find("Reactor inspection due Friday", 1, true)
      or not content:find("coolant loop check", 1, true) then
      errors = errors + 1
      print("FAIL: Notes did not persist both lines")
    end
    if not screen:find("Station notes", 1, true) then
      errors = errors + 1
      print("FAIL: Notes did not redraw the saved note")
    end
  end
  if scenario == "dashboard" and stats.spaceCalls == 0 then
    errors = errors + 1
    print("FAIL: Dashboard did not query spaceUsed")
  end
  if scenario == "desktop" then
    if not screen:find("1 window", 1, true) then
      errors = errors + 1
      print("FAIL: clicking a desktop icon did not open exactly one window")
    end
    if not screen:find("Files", 1, true) then
      errors = errors + 1
      print("FAIL: the Files icon did not open the Files app")
    end
  end
  if scenario == "icon_order" then
    if not screen:find("1 window", 1, true) then
      errors = errors + 1
      print("FAIL: the reordered first icon did not open a window")
    end
    if not screen:find("Preview", 1, true) then
      errors = errors + 1
      print("FAIL: the reordered first icon did not open Files")
    end
    local preferences = written["/etc/terracorp.cfg"] or ""
    if not preferences:find(
      'iconOrder = "files,dashboard,console,settings,notes,update,nodes"',
      1,
      true
    ) then
      errors = errors + 1
      print("FAIL: the desktop icon order was not saved")
    end
    if not preferences:find(
      'iconLayout = "files@1,dashboard@2,console@3,settings@4,notes@5,update@6,nodes@7"',
      1,
      true
    ) then
      errors = errors + 1
      print("FAIL: the desktop icon layout was not saved")
    end
  end
  if scenario == "icon_order_saved" then
    if not screen:find("1 window", 1, true) then
      errors = errors + 1
      print("FAIL: the saved first icon did not open a window")
    end
    if not screen:find("Preview", 1, true) then
      errors = errors + 1
      print("FAIL: the saved layout did not put Files first")
    end
  end
  if scenario == "icon_slot" or scenario == "icon_slot_saved" then
    if not screen:find("1 window", 1, true) then
      errors = errors + 1
      print("FAIL: the icon in an empty slot did not open a window")
    end
    if not screen:find("Preview", 1, true) then
      errors = errors + 1
      print("FAIL: clicking the moved icon did not open Files")
    end
  end
  if scenario == "icon_slot" then
    -- Files must render on row 3 (label at row 21), not in its old cell.
    if not (rows[21] or ""):find("Files", 1, true) then
      errors = errors + 1
      print("FAIL: the dragged icon did not render in the empty full-screen slot")
    end
    local preferences = written["/etc/terracorp.cfg"] or ""
    if not preferences:find(
      'iconLayout = "dashboard@1,console@3,settings@4,notes@5,update@6,nodes@7,files@32"',
      1,
      true
    ) then
      errors = errors + 1
      print("FAIL: the empty-slot layout was not saved")
    end
  end
  if scenario == "icon_drag" then
    -- The ghost art starts at row 24 and its label at row 29, inside the Files
    -- window. The System icon is hidden while dragging, so this art can only
    -- come from the floating tile drawn above the window.
    if not (rows[24] or ""):find("┌───────┐", 1, true) then
      errors = errors + 1
      print("FAIL: the floating icon art was not drawn above the window")
    end
    if not (rows[29] or ""):find("System", 1, true) then
      errors = errors + 1
      print("FAIL: the floating icon label was not drawn above the window")
    end
  end
  if scenario == "icon_update" then
    if not screen:find("1 window", 1, true) then
      errors = errors + 1
      print("FAIL: clicking the migrated Update icon did not open a window")
    end
    if not screen:find("UPDATE", 1, true) or not screen:find("Check for updates", 1, true) then
      errors = errors + 1
      print("FAIL: the migrated Update icon did not open the Update app")
    end
  end
  if scenario == "nodes" then
    if not screen:find("Rack nodes", 1, true) then
      errors = errors + 1
      print("FAIL: F7 did not open the Nodes app")
    end
    if not screen:find("Installer armed", 1, true) then
      errors = errors + 1
      print("FAIL: the Nodes app did not arm the installer")
    end
    if not nodesFloppy.exists("/payload/.ready") then
      errors = errors + 1
      print("FAIL: the install payload was not written to the floppy")
    end
  end
  if (scenario == "updater" or scenario == "updater_legacy") then
    if not shutdownFlag then
      errors = errors + 1
      print("FAIL: the updater did not restart into the boot-time applier")
    end
    local marker = readReal("/var/update/pending") or ""
    if not marker:find("version=" .. mockedReleaseVersion, 1, true) then
      errors = errors + 1
      print("FAIL: the queued update marker does not name the mocked release")
    end
  end
  if scenario == "updater_recover" and not screen:find("Restart to apply", 1, true) then
    errors = errors + 1
    print("FAIL: the legacy installer did not recover the leftover backup")
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
