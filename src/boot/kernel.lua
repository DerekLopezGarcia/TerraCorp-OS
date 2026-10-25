-- TerraCorp OS kernel.
--
-- Responsibilities: mount the boot volume, load OS modules without OpenOS
-- `require`, start services, and run the desktop event loop.

local kernel = {}
local SIGNAL_POLL_INTERVAL = 1 / 30

local MODULE_ROOTS = {
  tc = "/lib/tc/",
  apps = "/apps/",
}

local APP_IDS = { "dashboard", "files", "console", "settings", "notes", "update" }

local function packCall(fn, ...)
  local result = table.pack(pcall(fn, ...))
  if not result[1] then
    return nil, tostring(result[2])
  end
  return table.unpack(result, 2, result.n)
end

local function splitPath(path)
  local parts = {}
  for part in tostring(path):gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  return parts
end

-- Minimal filesystem layer over the boot-volume component.
local function makeVfs(volume)
  local vfs = {}

  function vfs.read(path)
    local handle, reason = packCall(volume.open, path, "r")
    if not handle then
      return nil, reason
    end

    local chunks = {}
    while true do
      local data, why = packCall(volume.read, handle, 4096)
      -- Stop on an empty string as well as nil to avoid a driver-induced loop.
      if type(data) ~= "string" or data == "" then
        packCall(volume.close, handle)
        if why then
          return nil, why
        end
        break
      end
      chunks[#chunks + 1] = data
    end

    packCall(volume.close, handle)
    return table.concat(chunks)
  end

  local function writeMode(path, data, mode)
    local handle, reason = packCall(volume.open, path, mode)
    if not handle then
      return nil, reason
    end
    local ok, why = packCall(volume.write, handle, data)
    packCall(volume.close, handle)
    if not ok then
      return nil, why
    end
    return true
  end

  function vfs.write(path, data)
    return writeMode(path, data, "w")
  end

  function vfs.append(path, data)
    return writeMode(path, data, "a")
  end

  function vfs.exists(path)
    local ok, value = pcall(volume.exists, path)
    return ok and value == true
  end

  function vfs.isDirectory(path)
    local ok, value = pcall(volume.isDirectory, path)
    return ok and value == true
  end

  function vfs.size(path)
    local value = packCall(volume.size, path)
    return tonumber(value)
  end

  -- The component returns a 1..n table of names (see docs/opencomputers.md).
  -- Accept iterators as well for compatibility with older drivers.
  function vfs.list(path)
    local result, reason = packCall(volume.list, path)

    if type(result) == "function" then
      local names = {}
      local ok = pcall(function()
        for name in result do
          names[#names + 1] = tostring(name)
        end
      end)
      if not ok then
        return nil, "could not list " .. tostring(path)
      end
      table.sort(names)
      return names
    end

    if type(result) ~= "table" then
      return nil, reason or ("could not list " .. tostring(path))
    end

    local names = {}
    for _, name in ipairs(result) do
      names[#names + 1] = tostring(name)
    end

    -- Also support a table whose keys are not sequential.
    if #names == 0 and next(result) ~= nil then
      for _, name in pairs(result) do
        names[#names + 1] = tostring(name)
      end
    end

    table.sort(names)
    return names
  end

  function vfs.ensureDir(path)
    local current = ""
    for _, part in ipairs(splitPath(path)) do
      current = current .. "/" .. part
      if not vfs.exists(current) then
        local ok, reason = packCall(volume.makeDirectory, current)
        if not ok and not vfs.exists(current) then
          return nil, reason
        end
      end
    end
    return true
  end

  function vfs.remove(path)
    return packCall(volume.remove, path)
  end

  function vfs.rename(from, to)
    return packCall(volume.rename, from, to)
  end

  -- OpenComputers reports spaceUsed/spaceTotal in bytes; the OS uses KB.
  function vfs.space()
    local used = packCall(volume.spaceUsed)
    local total = packCall(volume.spaceTotal)
    if type(used) ~= "number" or type(total) ~= "number" then
      return nil
    end
    return used / 1024, total / 1024
  end

  return vfs
end

--------------------------------------------------------------------------------
-- Kernel services
--------------------------------------------------------------------------------

function kernel:uptime()
  return computer.uptime()
end

function kernel:energy()
  local ok, stored, maximum = pcall(computer.energy)
  if not ok or type(stored) ~= "number" then
    return nil
  end
  -- If the node reports no maximum, treat energy as unavailable rather than
  -- attempting to divide by nil.
  if type(maximum) ~= "number" or maximum <= 0 then
    return nil
  end
  return stored, maximum
end

function kernel:energyPercent()
  local stored, maximum = self:energy()
  if not stored or not maximum or maximum <= 0 then
    return 100
  end
  return (stored / maximum) * 100
end

function kernel:memory()
  local total = computer.totalMemory()
  local free = computer.freeMemory()
  return total - free, total
end

function kernel:components()
  local now = computer.uptime()
  local cached = self._components
  if cached and now - cached.at < 3 then
    return cached
  end

  local counts, total = {}, 0
  for _, kind in component.list() do
    counts[kind] = (counts[kind] or 0) + 1
    total = total + 1
  end

  -- The Devices card shows peripherals, not internal components.
  local internal = {
    computer = true,
    eeprom = true,
    filesystem = true,
    gpu = true,
    keyboard = true,
    screen = true,
  }

  local entries = {}
  for kind, count in pairs(counts) do
    if not internal[kind] then
      entries[#entries + 1] = { kind = kind, count = count }
    end
  end
  table.sort(entries, function(a, b)
    if a.count == b.count then
      return a.kind < b.kind
    end
    return a.count > b.count
  end)

  self._components = { at = now, total = total, entries = entries }
  return self._components
end

function kernel:storage()
  return self.vfs.space()
end

function kernel:applyTheme()
  self.theme = self.themeModule.build(self.config)
  self.ui.theme = self.theme
  self.ui.colors = self.theme.colors
  self.ui.glyphs = self.theme.glyphs
  self.log.setLevel(self.config.get("logLevel"))
  self.ui:markDirty()
end

function kernel:saveConfig()
  local ok, reason = self.config.save(self.vfs)
  if not ok then
    self.log.warn("Could not save settings: " .. tostring(reason))
  end
  return ok
end

function kernel:rebindScreen()
  local gpuAddress = component.list("gpu")()
  local screenAddress = component.list("screen")()

  if gpuAddress and screenAddress then
    pcall(component.invoke, gpuAddress, "bind", screenAddress)
  end

  if gpuAddress and gpuAddress ~= self.gfx.address then
    local ok, replacement = pcall(self.gfxModule.new, gpuAddress)
    if ok then
      self.gfx = replacement
      self.ui.gfx = replacement
    end
  end

  if self.gfx:resize() then
    self.ui:resize()
  end
  self.ui:markDirty()
end

function kernel:poweroff(reboot)
  local colors = self.theme.colors
  self.gfx:clear(colors.bg)
  self.gfx:put(2, 1, reboot and "Restarting TerraCorp OS..." or "Shutting down TerraCorp OS...", colors.dim, colors.bg)
  self.gfx:flush()
  pcall(os.sleep, 0.3)
  computer.shutdown(reboot == true)
end

  -- Last resort: draw an error directly through the GPU if desktop rendering
  -- fails, so a black screen is not the only diagnostic.
function kernel:emergency(reason)
  local gpu = self.gfx and self.gfx.gpu
  if not gpu then
    return
  end

  local ok, width, height = pcall(gpu.getResolution)
  if not ok or not width or not height then
    width, height = 80, 25
  end

  local message = tostring(reason or "no details")
  pcall(gpu.setBackground, 15, true)
  pcall(gpu.setForeground, 14, true)
  pcall(gpu.fill, 1, 1, width, math.min(7, height), " ")
  pcall(gpu.set, 2, 2, "TerraCorp OS: could not draw the desktop")
  pcall(gpu.set, 2, 4, string.sub(message, 1, math.max(1, width - 4)))
  pcall(gpu.set, 2, 5, "Full details: /var/log/tc.log")
end

function kernel:loop()
  local lastTick = computer.uptime()
  local renderErrors = 0
  local gpuFailures = 0

  while true do
    -- Cap idle wait to one 30 Hz interval. Signals still wake the loop
    -- immediately, so input-driven updates are not throttled to this rate.
    local pack = table.pack(pcall(computer.pullSignal, SIGNAL_POLL_INTERVAL))

    if not pack[1] then
      self.log.error("pullSignal: " .. tostring(pack[2]))
      pcall(os.sleep, 0.25)
    elseif pack[2] then
      local name = pack[2]
      if name == "shutdown" or name == "reboot" then
        return
      end
      if name ~= "interrupted" then
        local ok, reason = pcall(self.ui.dispatch, self.ui, table.unpack(pack, 2, pack.n))
        if not ok then
          self.log.error("Event " .. tostring(name) .. ": " .. tostring(reason))
        end
      end
    end

    local now = computer.uptime()
    if now - lastTick >= 1 then
      lastTick = now
      pcall(self.ui.tick, self.ui)
    end

    local okRender, reason, failed = pcall(self.ui.render, self.ui, false)

      -- The GPU may reject spans when power is low. Keep those cells pending
      -- and retry them on a later frame.
    if okRender and type(failed) == "number" and failed > 0 then
      gpuFailures = gpuFailures + 1
      if gpuFailures == 1 or gpuFailures % 20 == 0 then
        self.log.warn("gpu: " .. failed .. " spans rejected (power?) in " .. gpuFailures .. " frames")
      end
    elseif okRender and gpuFailures > 0 then
      self.log.info("gpu recovered after " .. gpuFailures .. " frames")
      gpuFailures = 0
    end

    if not okRender then
      renderErrors = renderErrors + 1
      -- Rendering clears `dirty` before drawing. Mark it again after a partial
      -- failure or the display may freeze.
      self.ui:markDirty()
      if renderErrors == 1 then
        -- Show an on-screen warning; a blank screen alone is not diagnostic.
        self:emergency(reason)
      end
      -- Rate-limit disk logging if a removed screen causes repeated failures.
      if renderErrors == 1 or renderErrors % 30 == 0 then
        self.log.error("render (" .. renderErrors .. " failures): " .. tostring(reason))
      end
      pcall(os.sleep, math.min(1, 0.05 * renderErrors))
    elseif renderErrors > 0 then
      self.log.info("render recovered after " .. renderErrors .. " failures")
      renderErrors = 0
    end
  end
end

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

function kernel.start(boot)
  local volume = component.proxy(boot.address)
  if not volume then
    error("TerraCorp OS: boot volume " .. tostring(boot.address) .. " is not responding", 0)
  end

  local vfs = makeVfs(volume)
  local cache = {}

  local BASE = {
    assert = assert,
    error = error,
    ipairs = ipairs,
    pairs = pairs,
    next = next,
    pcall = pcall,
    xpcall = xpcall,
    select = select,
    print = print,
    tonumber = tonumber,
    tostring = tostring,
    type = type,
    setmetatable = setmetatable,
    getmetatable = getmetatable,
    rawget = rawget,
    rawset = rawset,
    rawequal = rawequal,
    unpack = table.unpack,
    load = load,
    math = math,
    string = string,
    table = table,
    os = os,
    io = io,
    coroutine = coroutine,
    utf8 = utf8,
  }

  local requireModule

  local function resolve(id)
    local root, name = id:match("^(%a[%w_]*)%.([%w_]+)$")
    local base = root and MODULE_ROOTS[root]
    if not base then
      return nil
    end
    return base .. name .. ".lua"
  end

  local function newEnv()
    local env = {}
    for key, value in pairs(BASE) do
      env[key] = value
    end
    env.require = requireModule
    env.component = component
    env.computer = computer
    env._G = env
    return env
  end

  requireModule = function(id)
    local cached = cache[id]
    if cached ~= nil then
      return cached
    end

    local path = resolve(id)
    if not path then
      error("Unknown module: " .. tostring(id), 0)
    end

    local source, reason = vfs.read(path)
    if not source then
      error("Could not read " .. path .. ": " .. tostring(reason), 0)
    end

    local chunk, compileError = load(source, "=" .. path, "t", newEnv())
    if not chunk then
      error("Syntax error in " .. path .. ": " .. tostring(compileError), 0)
    end

    local result = chunk(id)
    cache[id] = result
    return result
  end

  local version = requireModule("tc.version")
  local util = requireModule("tc.util")
  local text = requireModule("tc.text")
  local log = requireModule("tc.log")
  local config = requireModule("tc.config")
  local themeModule = requireModule("tc.theme")
  local gfxModule = requireModule("tc.gfx")
  local uiModule = requireModule("tc.ui")

  -- Create /etc and /var/log before loading preferences or opening the log;
  -- manual copies of src/ do not create them.
  vfs.ensureDir("/etc")
  vfs.ensureDir("/var/log")

  config.load(vfs)
  log.setLevel(config.get("logLevel"))

  -- Open the log before initializing video. If boot hangs in GPU setup or the
  -- splash, the first trace proves the boot volume was readable.
  log.setSink(function(line)
    local size = vfs.size("/var/log/tc.log") or 0
    if size > 131072 then
      vfs.write("/var/log/tc.log", "")
    end
    vfs.append("/var/log/tc.log", line .. "\n")
  end)

  local address = computer.address()
  local configured = config.get("hostname")
  local hostname = configured
  if hostname == "" then
    hostname = "TC-" .. tostring(address):sub(1, 4):upper()
  end

  log.trace("Booting " .. version.product .. " " .. version.version .. " on " .. hostname)

  local gpuAddress = component.list("gpu")()
  if not gpuAddress then
    error("TerraCorp OS: a GPU is required to boot", 0)
  end

  local screenAddress = component.list("screen")()
  if screenAddress then
    pcall(component.invoke, gpuAddress, "bind", screenAddress)
  end

  local theme = themeModule.build(config)
  local gfx = gfxModule.new(gpuAddress)

  -- Use the screen's current resolution. Window geometry is proportional and
  -- clamped to fit, so both small and large screens are supported.
  local okLimits, maxWidth, maxHeight = pcall(gfx.gpu.maxResolution)
  if okLimits and maxWidth and maxHeight then
    if maxWidth ~= gfx.w or maxHeight ~= gfx.h then
      if pcall(gfx.gpu.setResolution, maxWidth, maxHeight) then
        gfx:resize()
      end
    end
  end

  local function drawSplash(ratio, message)
    local colors = theme.colors
    gfx:clear(colors.bg)

    local function center(textValue, row, fg)
      local column = math.max(1, math.floor((gfx.w - text.width(textValue)) / 2) + 1)
      gfx:put(column, row, textValue, fg, colors.bg)
    end

    local middle = math.floor(gfx.h / 2)
    center("TERRACORP", middle - 4, colors.accent)
    center("O S", middle - 3, colors.accent)
    center(version.tagline:upper(), middle - 1, colors.dim)
    center("v" .. version.version .. "  " .. version.codename, middle, colors.dim)

    local width = math.min(40, gfx.w - 8)
    local column = math.floor((gfx.w - width) / 2) + 1
    gfx:bar(column, middle + 2, width, ratio, colors.accent, colors.bg, theme.glyphs.block)
    center(message, middle + 4, colors.dim)
    gfx:flush()
  end

  local splash = config.get("splash") == true
  if splash then
    log.trace("splash")
    drawSplash(0.25, "Loading core services")
  end

  local instance = setmetatable({
    version = version,
    util = util,
    text = text,
    log = log,
    config = config,
    theme = theme,
    themeModule = themeModule,
    gfxModule = gfxModule,
    gfx = gfx,
    vfs = vfs,
    volume = volume,
    volumeAddress = boot.address,
    address = address,
    hostname = hostname,
  }, { __index = kernel })

  -- Record the GPU, screen, and resolution for black-screen diagnostics.
  log.trace(string.format(
    "gpu %s · screen %s · %dx%d · %d KB free",
    tostring(gpuAddress):sub(1, 4),
    tostring(screenAddress or "-"):sub(1, 4),
    gfx.w,
    gfx.h,
    math.floor(computer.freeMemory() / 1024)
  ))

  local apps = {}
  for _, id in ipairs(APP_IDS) do
    local ok, module = pcall(requireModule, "apps." .. id)
    if ok and type(module) == "table" then
      apps[#apps + 1] = module
    else
      log.error("App unavailable: " .. id .. " (" .. tostring(module) .. ")")
    end
  end

  instance.ui = uiModule.new({
    kernel = instance,
    gfx = gfx,
    theme = theme,
    log = log,
    config = config,
    version = version,
    apps = apps,
    util = util,
  })

  if splash then
    drawSplash(0.75, "Starting desktop")
    pcall(os.sleep, 0.4)
    drawSplash(1, "Session ready")
    pcall(os.sleep, 0.35)
  end

  -- First controlled composition: show a diagnostic if drawing the desktop
  -- fails instead of silently leaving a blank framebuffer.
  log.trace("First render")
  local okPaint, paintReason = pcall(instance.ui.render, instance.ui, true)
  if not okPaint then
    instance:emergency(paintReason)
    log.error("First render: " .. tostring(paintReason))
  elseif instance.ui.failures then
    log.error("First render warnings: " .. table.concat(instance.ui.failures, " | "))
  else
    log.trace("First render OK")
  end

  instance:loop()
end

return kernel
