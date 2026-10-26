-- TerraCorp rack pull installer.
--
-- The master copies this script to a floppy as /init.lua together with tc.net
-- as /net.lua. An unprovisioned server has no boot address, so the stock Lua
-- BIOS boots this floppy. The script announces the server, waits for an
-- ASSIGN, pulls the runtime tree from the master over the wired network,
-- writes it to the first HDD, sets the boot address, and reboots.
--
-- It runs in the minimal BIOS environment: only the floppy's /net.lua is
-- local; everything else arrives over the wire. Nothing is written to the
-- EEPROM except the boot address, and an existing install is never
-- overwritten unless it carries /var/install-incomplete.

local netfetch = {}

-- Seconds to wait for a master ASSIGN before falling back to the offline
-- payload on the floppy (when it carries one).
netfetch.WAIT = 60

local COLORS = {
  bg = 15,
  text = 0,
  dim = 8,
  accent = 9,
  warn = 4,
  danger = 14,
}

local function invoke(env, address, method, ...)
  local result = table.pack(pcall(env.component.invoke, address, method, ...))
  if not result[1] then
    return nil, tostring(result[2])
  end
  return table.unpack(result, 2, result.n)
end

local function readComponent(env, address, path)
  local handle, reason = invoke(env, address, "open", path, "r")
  if not handle then
    return nil, reason or ("could not open " .. path)
  end

  local chunks = {}
  while true do
    local data, why = invoke(env, address, "read", handle, 4096)
    if type(data) ~= "string" or data == "" then
      invoke(env, address, "close", handle)
      if why then
        return nil, why
      end
      break
    end
    chunks[#chunks + 1] = data
  end
  invoke(env, address, "close", handle)
  return table.concat(chunks)
end

local function writeComponent(env, address, path, data, mode)
  local handle, reason = invoke(env, address, "open", path, mode or "w")
  if not handle then
    return nil, reason
  end
  local ok, why = invoke(env, address, "write", handle, data)
  invoke(env, address, "close", handle)
  if not ok then
    return nil, why
  end
  return true
end

local function appendLog(env, line)
  if not env.floppyAddress then
    return false
  end
  local ok = writeComponent(env, env.floppyAddress, "/install.log", tostring(line) .. "\n", "a")
  return ok, nil
end

netfetch.appendLog = appendLog

local function draw(env, heading, lines, color)
  if env.noScreen then
    return
  end

  local gpu = env.component.list("gpu")()
  local screen = env.component.list("screen")()
  if not gpu or not screen then
    return
  end

  local _, width, height = pcall(invoke, env, gpu, "getResolution")
  if type(width) ~= "number" or type(height) ~= "number" then
    env.noScreen = true
    return
  end

  invoke(env, gpu, "bind", screen)
  pcall(invoke, env, gpu, "setBackground", COLORS.bg, true)
  pcall(invoke, env, gpu, "setForeground", COLORS.text, true)
  pcall(invoke, env, gpu, "fill", 1, 1, width, height, " ")

  local function textAt(row, value, fg)
    if row < 1 or row > height then
      return
    end
    pcall(invoke, env, gpu, "setForeground", fg or COLORS.text, true)
    pcall(invoke, env, gpu, "set", 2, row, tostring(value):sub(1, math.max(1, width - 3)))
  end

  textAt(1, "TERRACORP NETWORK INSTALLER", COLORS.accent)
  textAt(2, env.version and ("TerraCorp OS " .. env.version) or "TerraCorp OS", COLORS.dim)

  local row = 4
  textAt(row, heading or "Preparing", color or COLORS.text)
  row = row + 2
  for _, line in ipairs(lines or {}) do
    if row > height then
      break
    end
    textAt(row, line, COLORS.dim)
    row = row + 1
  end
  pcall(invoke, env, gpu, "setForeground", COLORS.text, true)
end

netfetch.draw = draw

local function sandbox(env, modules)
  local space = {
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
    os = env.os or os,
    io = io,
    coroutine = coroutine,
    utf8 = utf8,
    component = env.component,
    computer = env.computer,
    require = function(name)
      return modules[name]
    end,
  }
  space._G = space
  return space
end

local function loadModule(env, source, path, modules)
  local chunk, compileError = load(source, "=" .. path, "t", sandbox(env, modules or {}))
  if not chunk then
    return nil, tostring(compileError)
  end

  local ok, module = pcall(chunk)
  if not ok then
    return nil, tostring(module)
  end
  return module
end

local function findBootVolume(env)
  local ok, address = pcall(env.computer.getBootAddress)
  if ok and type(address) == "string" and address ~= "" then
    return address
  end

  for candidate in env.component.list("filesystem") do
    if readComponent(env, candidate, "/ready.txt") then
      return candidate
    end
  end
  return nil
end

local function fail(env, heading, message)
  appendLog(env, "FAILED " .. heading .. ": " .. tostring(message))
  draw(env, heading, {
    tostring(message),
    "",
    "The server stays on. Power it off, fix the cause,",
    "then power it on again with the floppy inserted.",
  }, COLORS.danger)

  while true do
    local pack = table.pack(pcall(env.computer.pullSignal, 5))
    if not pack[1] or pack[2] == "shutdown" or pack[2] == "reboot" then
      return false
    end
  end
end

local function nodeMemoryKB(env)
  local ok, total = pcall(env.computer.totalMemory)
  if not ok then
    return 0
  end
  return math.floor((tonumber(total) or 0) / 1024)
end

local function diskKB(env, address)
  local total = invoke(env, address, "spaceTotal")
  return math.floor((tonumber(total) or 0) / 1024)
end

local function firstDiskKB(env, bootAddress)
  for address in env.component.list("filesystem") do
    if address ~= bootAddress and invoke(env, address, "isReadOnly") ~= true then
      return diskKB(env, address)
    end
  end
  return 0
end

--- Fetch one whole file from the master with the minimal inline loop. This is
-- only used to load tc.pull itself; pull.walk fetches the rest of the tree.
local function fetchWhole(env, modem, master, id, path)
  local size = nil
  local chunks = {}
  local off = 0
  while true do
    local sent = modem:send(master, "FETCH", { id = id, path = path, off = off })
    if not sent then
      return nil, "could not send FETCH for " .. path
    end

    local reply = nil
    local deadline = env.computer.uptime() + 5
    while env.computer.uptime() < deadline do
      local pack = table.pack(pcall(env.computer.pullSignal, 0.5))
      if pack[1] and pack[2] == "modem_message" then
        local port, message = pack[5], pack[7]
        if tonumber(port) == modem.port then
          local verb, fields = netfetch.decode(message)
          if verb == "DATA" and fields.id == id and fields.path == path then
            reply = fields
            break
          elseif verb == "MISS" and fields.id == id then
            return nil, "the master refused " .. path
          end
        end
      end
    end
    if not reply then
      return nil, "no DATA for " .. path
    end

    size = tonumber(reply.size) or size
    local data = tostring(reply.data or "")
    if data == "" then
      break
    end
    chunks[#chunks + 1] = data
    off = off + #data
    if size and off >= size then
      break
    end
  end

  local body = table.concat(chunks)
  if size and #body ~= size then
    return nil, "incomplete transfer of " .. path
  end
  return body
end

netfetch.fetchWhole = fetchWhole

--- Find the first writable non-boot filesystem and verify it is safe to use.
-- Mirrors the classic installer: an empty disk is safe, a disk carrying the
-- install marker can be retried, anything else is refused.
function netfetch.findTarget(env, bootAddress, vfsModule, provisionModule)
  for address in env.component.list("filesystem") do
    if address ~= bootAddress then
      local readOnly = invoke(env, address, "isReadOnly")
      if readOnly ~= true then
        local volume = env.component.proxy(address)
        if volume then
          local disk = vfsModule.new(volume)
          if not disk then
            return nil, "the target disk is not readable"
          end
          local safe, reason = provisionModule.checkInstallTarget(disk)
          if not safe then
            return nil, reason
          end
          return address, disk
        end
      end
    end
  end
  return nil, "no writable hard disk was found"
end

--- Offline install from the floppy's own /payload (no master answered).
-- Same check chain as the pull path: safe target, install marker, verified
-- per-file copy (done by provision.install), completeness check, node config,
-- and the boot address only after everything is on disk.
function netfetch.installOffline(env, bootAddress, id, net)
  local component, computer = env.component, env.computer

  appendLog(env, "OFFLINE no master answered; installing from the payload")
  draw(env, "Offline install", {
    "No master answered within " .. tostring(netfetch.WAIT) .. " s.",
    "Installing the runtime carried on this floppy...",
  }, COLORS.warn)

  local vfsSource, vfsReason = readComponent(env, bootAddress, "/payload/lib/tc/vfs.lua")
  if not vfsSource then
    return fail(env, "Broken payload", "could not read vfs.lua: " .. tostring(vfsReason))
  end
  local provisionSource, provisionReason = readComponent(env, bootAddress, "/payload/lib/tc/provision.lua")
  if not provisionSource then
    return fail(env, "Broken payload", "could not read provision.lua: " .. tostring(provisionReason))
  end

  local modules = { ["tc.net"] = net }
  local vfsModule, vfsError = loadModule(env, vfsSource, "/payload/lib/tc/vfs.lua", modules)
  if not vfsModule then
    return fail(env, "Broken payload", "could not load tc.vfs: " .. tostring(vfsError))
  end
  local provisionModule, provisionLoadError = loadModule(
    env, provisionSource, "/payload/lib/tc/provision.lua", modules)
  if not provisionModule then
    return fail(env, "Broken payload", "could not load tc.provision: " .. tostring(provisionLoadError))
  end

  local volume = component.proxy(bootAddress)
  local floppy = volume and vfsModule.new(volume)
  if not floppy then
    return fail(env, "Broken payload", "the boot floppy is not readable")
  end

  local targetAddress, target, targetReason = netfetch.findTarget(
    env, bootAddress, vfsModule, provisionModule)
  if not targetAddress then
    return fail(env, "No target disk", tostring(targetReason))
  end

  -- No master named this node; it adopts a master from a later PING or PULL.
  local name = "TC-" .. tostring(id):sub(1, 4)
  appendLog(env, "INSTALL target=" .. tostring(targetAddress) .. " (offline)")

  local result, installReason = provisionModule.install(target, floppy, {
    version = tostring(env.version),
    configText = provisionModule.configText({
      name = name,
      role = "worker",
      master = "",
      masterId = "",
    }),
  })
  if not result then
    return fail(env, "Install failed", tostring(installReason))
  end

  appendLog(env, string.format(
    "OK %d files, disk=%s (offline)",
    result.files or 0,
    tostring(targetAddress)
  ))

  local setOk, setReason = pcall(computer.setBootAddress, targetAddress)
  if not setOk then
    return fail(env, "Boot address", "Could not set the boot address: " .. tostring(setReason))
  end
  if type(computer.getBootAddress) == "function" then
    local checkOk, current = pcall(computer.getBootAddress)
    if checkOk and type(current) == "string" and current ~= "" and current ~= targetAddress then
      return fail(env, "Boot address", "The EEPROM did not keep the new boot address.")
    end
  end

  draw(env, "Install complete", {
    name .. " is ready.",
    string.format("%d files copied from the payload.", result.files or 0),
    "It will find the master on the next boot.",
  }, COLORS.accent)

  pcall(env.os.sleep, 2)
  pcall(computer.shutdown, true)
  return true
end

function netfetch.run(env)
  env = env or {}
  env.os = env.os or os
  env.version = env.version or "0.3.0"

  local component, computer = env.component, env.computer
  if not component or not computer then
    return false
  end

  local bootAddress = findBootVolume(env)
  if not bootAddress then
    return fail(env, "No installer", "No TerraCorp installer was found on this computer.")
  end
  env.floppyAddress = bootAddress

  local netSource, netReason = readComponent(env, bootAddress, "/net.lua")
  if not netSource then
    return fail(env, "Broken installer", "Could not read /net.lua: " .. tostring(netReason))
  end
  local modules = {}
  local net, loadError = loadModule(env, netSource, "/net.lua", modules)
  if not net then
    return fail(env, "Broken installer", "Could not load tc.net: " .. tostring(loadError))
  end
  modules["tc.net"] = net
  netfetch.decode = net.decode

  local ready = readComponent(env, bootAddress, "/ready.txt")
  if ready then
    local marker = ready:match("version=([^\r\n]+)")
    if marker and marker ~= "" then
      env.version = marker
    end
  end

  -- An offline payload lets this floppy install without a master. The payload
  -- version is authoritative for the install itself.
  local payloadReady = readComponent(env, bootAddress, "/payload/.ready")
  local payloadVersion = payloadReady and payloadReady:match("version=([^\r\n]+)")
  local hasPayload = payloadReady ~= nil
    and readComponent(env, bootAddress, "/payload/lib/tc/provision.lua") ~= nil
    and readComponent(env, bootAddress, "/payload/lib/tc/vfs.lua") ~= nil
  if payloadVersion and payloadVersion ~= "" then
    env.version = payloadVersion
  end

  local modem = net.newModem({ component = component, computer = computer, port = net.PORT })
  local opened, openReason = modem:open()
  if not opened then
    return fail(env, "No network", "No wired network card is available: " .. tostring(openReason))
  end

  local id = computer.address()
  local hello = {
    id = id,
    v = env.version,
    role = "unprovisioned",
    modem = modem.address or "",
    mem = nodeMemoryKB(env),
    disk = firstDiskKB(env, bootAddress),
  }

  local assignment = nil
  local lastHello = -math.huge
  local offline = false
  local waitDeadline = hasPayload and (computer.uptime() + netfetch.WAIT) or nil
  draw(env, "Waiting for the master", {
    "Server " .. tostring(id):sub(1, 8),
    "Broadcasting HELLO on port " .. tostring(net.PORT) .. ".",
    "Arm the installer in Nodes, then leave this server on.",
  }, COLORS.warn)

  while not assignment do
    local now = computer.uptime()
    if waitDeadline and now >= waitDeadline then
      offline = true
      break
    end
    if now - lastHello >= 5 then
      lastHello = now
      modem:broadcast("HELLO", hello)
      appendLog(env, "HELLO " .. tostring(id):sub(1, 8))
    end

    local pack = table.pack(pcall(computer.pullSignal, 1))
    if not pack[1] then
      appendLog(env, "pullSignal: " .. tostring(pack[2]))
    elseif pack[2] == "shutdown" or pack[2] == "reboot" then
      return false
    elseif pack[2] == "modem_message" then
      local _, remoteAddress, messagePort, _, message = table.unpack(pack, 3, pack.n)
      if tonumber(messagePort) == modem.port then
        local verb, fields = net.decode(message)
        if verb == "ASSIGN" and fields.id == id then
          assignment = fields
          assignment.remoteAddress = remoteAddress
        end
      end
    end
  end

  if offline then
    return netfetch.installOffline(env, bootAddress, id, net)
  end

  local master = assignment.master
  if type(master) ~= "string" or master == "" then
    master = assignment.remoteAddress
  end
  if type(master) ~= "string" or master == "" then
    return fail(env, "No route", "The master did not provide a return address.")
  end

  local role = assignment.role
  if role ~= "worker" and role ~= "storage" and role ~= "node" then
    role = "worker"
  end
  local name = tostring(assignment.name or ("TC-" .. id:sub(1, 4)))

  appendLog(env, "ASSIGN " .. name .. " role=" .. role .. " master=" .. tostring(master))
  draw(env, "Assigned as " .. name, {
    "Server " .. tostring(id):sub(1, 8),
    "Role " .. role,
    "Pulling the runtime from the master...",
  }, COLORS.accent)

  -- Load the pull client and its helpers from the master before walking the
  -- whole tree.
  local pullSource, pullReason = fetchWhole(env, modem, master, id, "/lib/tc/pull.lua")
  if not pullSource then
    return fail(env, "Pull failed", tostring(pullReason))
  end
  local vfsSource, vfsReason = fetchWhole(env, modem, master, id, "/lib/tc/vfs.lua")
  if not vfsSource then
    return fail(env, "Pull failed", tostring(vfsReason))
  end
  local provisionSource, provisionReason = fetchWhole(env, modem, master, id, "/lib/tc/provision.lua")
  if not provisionSource then
    return fail(env, "Pull failed", tostring(provisionReason))
  end

  local provisionModule, provisionError = loadModule(env, provisionSource, "/lib/tc/provision.lua", modules)
  if not provisionModule then
    return fail(env, "Broken pull", "Could not load tc.provision: " .. tostring(provisionError))
  end
  modules["tc.provision"] = provisionModule
  local vfsModule, vfsError = loadModule(env, vfsSource, "/lib/tc/vfs.lua", modules)
  if not vfsModule then
    return fail(env, "Broken pull", "Could not load tc.vfs: " .. tostring(vfsError))
  end
  local pull, pullError = loadModule(env, pullSource, "/lib/tc/pull.lua", modules)
  if not pull then
    return fail(env, "Broken pull", "Could not load tc.pull: " .. tostring(pullError))
  end
  modules["tc.pull"] = pull

  local targetAddress, target, targetReason = netfetch.findTarget(
    env,
    bootAddress,
    vfsModule,
    provisionModule
  )
  if not targetAddress then
    return fail(env, "No target disk", tostring(targetReason))
  end

  draw(env, "Installing " .. name, {
    "Target disk " .. tostring(targetAddress):sub(1, 8),
    "Pulling the runtime over the network...",
    "Do not power off the server.",
  }, COLORS.accent)
  appendLog(env, "INSTALL target=" .. tostring(targetAddress))

  -- Mark the install as in progress so an interrupted copy can be retried,
  -- then pull the whole runtime tree onto the disk.
  local dirOk = target.ensureDir("/var")
  if not dirOk then
    return fail(env, "Install failed", "could not create /var")
  end
  local marked = target.write(provisionModule.markerPath, "version=" .. tostring(env.version) .. "\n")
  if not marked then
    return fail(env, "Install failed", "could not write the install marker")
  end

  local pulled = 0
  local writer = function(path, body)
    if path:sub(-4) == ".lua" then
      local chunk = load(body, "@" .. path, "t", {})
      if not chunk then
        return nil, "invalid Lua in " .. path
      end
    end
    local parent = path:match("^(.*)/[^/]+$")
    if parent then
      local ok, reason = target.ensureDir(parent)
      if not ok then
        return nil, reason
      end
    end
    local written, writeReason = target.write(path, body)
    if not written then
      return nil, writeReason
    end
    pulled = pulled + 1
    return true
  end

  local request = pull.requestLoop({
    modem = modem,
    master = master,
    computer = computer,
    id = id,
  })
  local walked, walkError = pull.walk(request, writer, {
    files = { "/init.lua" },
    dirs = { "/boot", "/lib", "/apps" },
  })
  if not walked then
    return fail(env, "Install failed", tostring(walkError))
  end
  if not target.exists("/init.lua") or not target.exists("/boot/kernel.lua") then
    return fail(env, "Install failed", "the pulled runtime is incomplete")
  end

  local config = provisionModule.configText({
    name = name,
    role = role,
    master = master,
    masterId = assignment.masterId or "",
  })
  local etcOk, etcReason = target.ensureDir("/etc")
  if not etcOk then
    return fail(env, "Install failed", tostring(etcReason))
  end
  local configOk, configReason = target.write("/etc/terracorp.cfg", config)
  if not configOk then
    return fail(env, "Install failed", tostring(configReason or "could not write the node configuration"))
  end

  local cleared = target.remove(provisionModule.markerPath)
  if not cleared then
    return fail(env, "Install failed", "could not clear the install marker")
  end

  appendLog(env, string.format(
    "OK %d files, disk=%s",
    pulled,
    tostring(targetAddress)
  ))

  -- The boot address moves to the system disk only after a complete copy. An
  -- interrupted install leaves the EEPROM alone, so the next boot runs this
  -- floppy again instead of a half-written disk.
  local setOk, setReason = pcall(computer.setBootAddress, targetAddress)
  if not setOk then
    return fail(env, "Boot address", "Could not set the boot address: " .. tostring(setReason))
  end
  if type(computer.getBootAddress) == "function" then
    local checkOk, current = pcall(computer.getBootAddress)
    if checkOk and type(current) == "string" and current ~= "" and current ~= targetAddress then
      return fail(env, "Boot address", "The EEPROM did not keep the new boot address.")
    end
  end

  draw(env, "Install complete", {
    name .. " is ready.",
    string.format("%d files pulled over the network.", pulled),
    "Sending ACK and rebooting into the node.",
  }, COLORS.accent)

  modem:send(master, "ACK", {
    token = assignment.token,
    id = id,
    v = env.version,
    boot = targetAddress,
    mem = nodeMemoryKB(env),
    disk = diskKB(env, targetAddress),
  })

  pcall(env.os.sleep, 2)
  pcall(computer.shutdown, true)
  return true
end

-- Loaded by the BIOS with no arguments. Tests may pass `{ module = true }` to
-- inspect helpers without starting an install. `require` passes the module
-- name string, which also returns the helpers for unit tests.
local env = ...
if type(env) == "table" and env.module then
  return netfetch
end
if type(env) == "string" then
  return netfetch
end

return netfetch.run({ component = component, computer = computer })
