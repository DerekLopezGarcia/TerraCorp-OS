-- Line node installer entry.
--
-- init.lua runs this instead of the kernel when the boot volume carries
-- /installer.lua. It loads the filesystem and installer modules from the floppy
-- itself, picks the computer's first writable HDD, asks before it replaces an
-- existing node, copies the runtime, sets the boot address and reboots. The
-- floppy is only read, so the same floppy commissions every node.
--
-- It runs in the minimal BIOS environment: no OpenOS, no kernel, no `require`.

local install = {}

local COLORS = { bg = 15, text = 0, dim = 8, accent = 9, warn = 4, danger = 14 }
local MENU_SECONDS = 30

local function invoke(env, address, method, ...)
  local result = table.pack(pcall(env.component.invoke, address, method, ...))
  if not result[1] then
    return nil, tostring(result[2])
  end
  return table.unpack(result, 2, result.n)
end

--- The global environment a payload module may see. `tc.vfs` and `tc.installer`
-- are dependency-free: they use only these and never touch the world.
local function moduleEnv()
  return {
    assert = assert,
    error = error,
    ipairs = ipairs,
    pairs = pairs,
    next = next,
    pcall = pcall,
    select = select,
    tostring = tostring,
    tonumber = tonumber,
    type = type,
    setmetatable = setmetatable,
    getmetatable = getmetatable,
    rawget = rawget,
    rawset = rawset,
    rawequal = rawequal,
    load = load,
    table = table,
    string = string,
    math = math,
  }
end

--- Read a module from the floppy and compile it. Returns the module value.
local function loadModule(env, path)
  local source, reason = env.read(path)
  if type(source) ~= "string" or source == "" then
    return nil, "could not read " .. path .. ": " .. tostring(reason)
  end
  local chunk, compileError = load(source, "=" .. path, "t", moduleEnv())
  if not chunk then
    return nil, "invalid Lua in " .. path .. ": " .. tostring(compileError)
  end
  local ok, module = pcall(chunk)
  if not ok then
    return nil, path .. " failed to load: " .. tostring(module)
  end
  return module
end

local function screen(env)
  if env.noScreen then
    return nil
  end
  local gpu = env.component.list("gpu")()
  local localScreen = env.component.list("screen")()
  if not gpu or not localScreen then
    env.noScreen = true
    return nil
  end
  invoke(env, gpu, "bind", localScreen)
  local _, width, height = invoke(env, gpu, "getResolution")
  if type(width) ~= "number" or type(height) ~= "number" then
    env.noScreen = true
    return nil
  end
  return { gpu = gpu, width = width, height = math.min(height, 12) }
end

local function draw(env, heading, lines, color)
  local view = screen(env)
  if not view then
    return
  end
  local gpu, width = view.gpu, view.width
  pcall(invoke, env, gpu, "setBackground", COLORS.bg, true)
  pcall(invoke, env, gpu, "setForeground", COLORS.text, true)
  pcall(invoke, env, gpu, "fill", 1, 1, width, view.height, " ")

  local function textAt(row, value, fg)
    pcall(invoke, env, gpu, "setForeground", fg or COLORS.text, true)
    pcall(invoke, env, gpu, "set", 2, row, tostring(value):sub(1, math.max(1, width - 3)))
  end

  textAt(1, "TERRACORP LINE NODE INSTALLER", COLORS.accent)
  textAt(2, env.version and ("TerraCorp OS " .. tostring(env.version)) or "TerraCorp OS", COLORS.dim)
  textAt(4, heading or "", color or COLORS.text)
  local row = 6
  for _, line in ipairs(lines or {}) do
    if row > view.height then
      break
    end
    textAt(row, line, COLORS.dim)
    row = row + 1
  end
end

--- Wait for a key. Returns the lowercase character, or nil on timeout.
local function waitKey(env, seconds)
  if env.noScreen or type(env.computer.pullSignal) ~= "function" then
    return nil
  end
  local deadline = env.computer.uptime() + (seconds or MENU_SECONDS)
  while env.computer.uptime() < deadline do
    local pack = table.pack(pcall(env.computer.pullSignal, 0.5))
    if pack[1] and pack[2] == "key_down" then
      local char = tonumber(pack[3])
      if char and char > 0 then
        local text = string.char(char):lower()
        if text == "r" or text == "c" then
          return text
        end
      end
    end
  end
  return nil
end

--- The first filesystem that is not the installer medium and is writable.
local function findTarget(env, bootAddress)
  for address in env.component.list("filesystem") do
    if address ~= bootAddress then
      local readOnly = invoke(env, address, "isReadOnly")
      if readOnly ~= true then
        return address
      end
    end
  end
  return nil
end

function install.run(env)
  env = env or {}
  local component, computer = env.component, env.computer
  if not component or not computer or not env.address then
    return false
  end

  local bootAddress = env.address
  local versionModule = loadModule(env, "/lib/tc/version.lua")
  if type(versionModule) == "table" and versionModule.version then
    env.version = versionModule.version
  end

  local vfsModule, vfsReason = loadModule(env, "/lib/tc/vfs.lua")
  if type(vfsModule) ~= "table" then
    draw(env, "Broken installer", { tostring(vfsReason) }, COLORS.danger)
    return false
  end
  local installer, installerReason = loadModule(env, "/lib/tc/installer.lua")
  if type(installer) ~= "table" then
    draw(env, "Broken installer", { tostring(installerReason) }, COLORS.danger)
    return false
  end

  local volume = component.proxy(bootAddress)
  if not volume then
    draw(env, "No installer", { "The installer medium is not responding." }, COLORS.danger)
    return false
  end
  local floppy = vfsModule.new(volume)
  if not floppy then
    draw(env, "No installer", { "The installer medium is not readable." }, COLORS.danger)
    return false
  end

  local targetAddress = findTarget(env, bootAddress)
  if not targetAddress then
    draw(env, "No target disk", {
      "No writable hard disk was found.",
      "Add a hard disk and power the computer on again.",
    }, COLORS.danger)
    return false
  end
  local targetVolume = component.proxy(targetAddress)
  local target = targetVolume and vfsModule.new(targetVolume)
  if not target then
    draw(env, "No target disk", { "The hard disk is not readable." }, COLORS.danger)
    return false
  end

  local allowed, state = installer.checkTarget(target)
  local force = false
  if allowed then
    draw(env, "Installing", {
      "Disk " .. tostring(targetAddress):sub(1, 8) .. (state == "incomplete" and " (resuming)" or ""),
      "Copying the runtime. Do not power off.",
    }, COLORS.accent)
  elseif state == "installed" then
    draw(env, "This computer already has a node", {
      "Disk " .. tostring(targetAddress):sub(1, 8) .. " holds a TerraCorp runtime.",
      "R  reinstall the OS and keep /etc and /var",
      "C  cancel and leave it untouched",
      "Cancelling in " .. tostring(MENU_SECONDS) .. " s.",
    }, COLORS.warn)
    local key = waitKey(env, MENU_SECONDS)
    if key ~= "r" then
      draw(env, "Cancelled", {
        "Nothing was written. Remove the installer medium.",
      }, COLORS.text)
      return false
    end
    force = true
    draw(env, "Reinstalling", {
      "Disk " .. tostring(targetAddress):sub(1, 8),
      "Replacing the runtime, keeping /etc and /var.",
    }, COLORS.accent)
  else
    draw(env, "Cannot install", { tostring(state) }, COLORS.danger)
    return false
  end

  -- The image may already carry the node configuration prepared on the floppy.
  -- Without one, the installer writes a default and the node names itself from
  -- what its line produces.
  local configText = nil
  if not floppy.exists(installer.configPath) then
    configText = installer.configText({ name = "", master = "" })
  end

  local result, reason = installer.install(target, floppy, {
    version = env.version,
    force = force,
    configText = configText,
  })
  if not result then
    draw(env, "Install failed", {
      tostring(reason),
      "Nothing was booted; the medium can be retried.",
    }, COLORS.danger)
    return false
  end

  -- The boot address moves to the system disk only after a complete copy, so an
  -- interrupted install boots this medium again instead of a half-written disk.
  if type(computer.setBootAddress) ~= "function" then
    draw(env, "Set the boot address by hand", {
      string.format("%d files, %d KB copied to %s.", result.files, math.floor(result.bytes / 1024),
        tostring(targetAddress):sub(1, 8)),
      "This BIOS cannot set a boot address.",
      "Set it to that disk once, then remove the medium.",
    }, COLORS.warn)
    return false
  end

  local setOk, setReason = pcall(computer.setBootAddress, targetAddress)
  if not setOk then
    draw(env, "Boot address refused", {
      tostring(setReason),
      "The runtime is on disk but this computer will not boot it yet.",
    }, COLORS.danger)
    return false
  end

  draw(env, "Installed", {
    string.format("%d files, %d KB.", result.files, math.floor(result.bytes / 1024)),
    "Remove the installer medium, then boot.",
  }, COLORS.accent)
  if type(computer.shutdown) == "function" then
    pcall(computer.shutdown, true)
  end
  return true
end

return install
