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

local APP_IDS = { "dashboard", "files", "console", "settings", "notes", "update", "nodes", "gaia", "lab", "plant", "lines", "dns" }

local function packCall(fn, ...)
  local result = table.pack(pcall(fn, ...))
  if not result[1] then
    return nil, tostring(result[2])
  end
  return table.unpack(result, 2, result.n)
end

-- Bootstrap reader used to load tc.vfs from the boot volume. Everything after
-- that uses the shared filesystem module, including mounted node disks.
local function bootRead(volume, path)
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

--------------------------------------------------------------------------------
-- Kernel services
--------------------------------------------------------------------------------

function kernel:uptime()
  return computer.uptime()
end

-- Wall clock. Not present in every sandbox; callers must tolerate nil.
function kernel:realTime()
  local ok, value = pcall(computer.realTime)
  if not ok or type(value) ~= "number" then
    return nil
  end
  return value
end

-- The emulated uptime advances with server ticks while the wall clock does
-- not, so their ratio estimates the server tick rate: TPS = 20 * dUptime /
-- dRealTime. Pending in-game verification of computer.realTime resolution.
local TPS_WINDOW = 10

function kernel:tickClock()
  local real = self:realTime()
  if not real then
    self.tpsClock = nil
    self.tpsValue = nil
    return
  end
  local clock = self.tpsClock
  if not clock then
    self.tpsClock = { real = real, up = self:uptime() }
    return
  end
  local realDelta = real - clock.real
  if realDelta >= TPS_WINDOW then
    local upDelta = self:uptime() - clock.up
    if upDelta >= 0 then
      self.tpsValue = 20 * upDelta / realDelta
    end
    self.tpsClock = { real = real, up = self:uptime() }
  end
end

--- The last server tick rate estimate, or nil until a window completes.
function kernel:tps()
  return self.tpsValue
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

--- Mount another filesystem component through the shared VFS.
-- The cluster uses this to inspect a floppy and to pass a prepared payload to
-- the netboot installer. Mounts are cached until the component disappears.
function kernel:mount(address)
  if type(address) ~= "string" or address == "" then
    return nil, "missing filesystem address"
  end
  local cached = self.mounts and self.mounts[address]
  if cached then
    return cached
  end

  local volume = component.proxy(address)
  if not volume then
    return nil, "the filesystem is not responding"
  end

  local ok, mounted = pcall(self.vfsModule.new, volume)
  if not ok or not mounted then
    return nil, ok and "could not wrap the filesystem" or tostring(mounted)
  end

  self.mounts[address] = mounted
  return mounted
end

function kernel:unmount(address)
  if self.mounts then
    self.mounts[address] = nil
  end
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
  if self.dnsmaster and type(self.dnsmaster.close) == "function" then
    pcall(self.dnsmaster.close, self.dnsmaster)
  end
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
  self:tickClock()

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
        if self.master then
          self.master:close()
        end
        if self.dnsnet then
          pcall(self.dnsnet.close, self.dnsnet)
        end
        if self.link then
          self.link:close()
        end
        if self.plant then
          pcall(self.plant.stop, self.plant)
        end
        return
      end

      if name == "component_removed" and pack[3] then
        self:unmount(pack[3])
      end

      if name ~= "interrupted" then
        local handled = false
        if name == "modem_message" and self.dnsnet then
          local ok, routed = pcall(self.dnsnet.handle, self.dnsnet, pack)
          if not ok then
            self.log.error("DNS1 event: " .. tostring(routed))
          else
            handled = routed == true
          end
        end

        if not handled and name == "modem_message" and self.master then
          local ok, routed = pcall(
            self.master.handle,
            self.master,
            table.unpack(pack, 2, pack.n)
          )
          if not ok then
            self.log.error("master event: " .. tostring(routed))
          else
            handled = routed == true
          end
        end

        if not handled then
          local ok, reason = pcall(self.ui.dispatch, self.ui, table.unpack(pack, 2, pack.n))
          if not ok then
            self.log.error("Event " .. tostring(name) .. ": " .. tostring(reason))
          end
        end
      end
    end

    local now = computer.uptime()
    pcall(self.tickClock, self)
    if now - lastTick >= 1 then
      lastTick = now
      if self.master then
        local ok, reason = pcall(self.master.tick, self.master)
        if not ok then
          self.log.error("master tick: " .. tostring(reason))
        end
      end
      if self.dnsmaster then
        local ok, reason = pcall(self.dnsmaster.tick, self.dnsmaster)
        if not ok then
          self.log.error("DNS1 master tick: " .. tostring(reason))
        end
      end
      if self.plant then
        local ok, reason = pcall(self.plant.tick, self.plant)
        if not ok then
          self.log.error("plant tick: " .. tostring(reason))
        end
      end
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

    -- One HTTP step per frame at most; see lib/tc/link.lua.
    if self.link then
      pcall(self.link.tick, self.link)
    end
  end
end

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

local function parseVersion(value)
  local major, minor, patch = tostring(value or ""):match("^(%d+)%.(%d+)%.(%d+)$")
  if not major then
    return nil
  end
  return { tonumber(major), tonumber(minor), tonumber(patch) }
end

local function versionLess(left, right)
  for index = 1, 3 do
    if left[index] ~= right[index] then
      return left[index] < right[index]
    end
  end
  return false
end

-- Write the notes of every version between the one the node was running and
-- this one. `/var/version` records the last booted version and survives
-- updates, so a node that skipped releases gets all of them, not just the last.
local function writeReleaseNotes(instance, requireModule)
  local vfs, version, log = instance.vfs, instance.version, instance.log
  local current = version.version

  vfs.ensureDir("/var")
  local previous = vfs.read("/var/version")
  previous = previous and previous:match("([%d]+%.[%d]+%.[%d]+)")
  vfs.write("/var/version", current .. "\n")

  if not previous or previous == current then
    return nil
  end

  local from, to = parseVersion(previous), parseVersion(current)
  if not from or not to or not versionLess(from, to) then
    return nil
  end

  local ok, changelog = pcall(requireModule, "tc.changelog")
  if not ok or type(changelog) ~= "table" or type(changelog.notes) ~= "table" then
    log.warn("Release notes unavailable: " .. tostring(changelog))
    return nil
  end

  local lines = {
    "# What's new",
    "",
    "Updated from " .. previous .. " to " .. current .. ".",
    "",
  }
  local included = 0
  for _, candidate in ipairs(changelog.order or {}) do
    local candidateVersion = parseVersion(candidate)
    local notes = changelog.notes[candidate]
    if candidateVersion and notes
      and versionLess(from, candidateVersion)
      and not versionLess(to, candidateVersion) then
      included = included + 1
      lines[#lines + 1] = "## " .. candidate
      for _, note in ipairs(notes) do
        lines[#lines + 1] = "- " .. note
      end
      lines[#lines + 1] = ""
    end
  end

  if included == 0 then
    return nil
  end

  local written = vfs.write("/var/whatsnew.md", table.concat(lines, "\n"))
  if not written then
    log.warn("Could not write /var/whatsnew.md")
    return nil
  end
  log.info(string.format("Release notes: %d version(s), %s -> %s", included, previous, current))
  return "/var/whatsnew.md"
end

local function dnsBootId()
  local ok, wall = pcall(os.time)
  if ok and type(wall) == "number" then
    return tostring(wall)
  end
  return tostring(computer.uptime())
end

local function registerDnsInventory(node, log)
  local okList, list = pcall(component.list, "inventory_controller")
  if not okList or not list then
    log.info("DNS1: no inventory_controller found")
    return 0, {}
  end
  local count = 0
  local addresses = {}
  local names = {}
  if type(list) == "function" then
    for address in list do
      addresses[#addresses + 1] = address
    end
  else
    for _, address in ipairs(list) do
      addresses[#addresses + 1] = address
    end
  end
  table.sort(addresses)
  for _, address in ipairs(addresses) do
    count = count + 1
    local name = count == 1 and "inventory_controller" or ("inventory_controller_" .. count)
    names[#names + 1] = name
    node:registerComponent({
      name = name,
      componentType = "inventory_controller",
      address = address,
      tags = { "inventory" },
      docs = "Read-only inventory of this node's chests and stacks.",
      allow = { "getAllStacks" },
      methods = {
        getAllStacks = {
          mode = "read",
          description = "Returns every slot: slot, name, size, maxSize, stackSize and hasTag.",
          args = {},
          returns = "table",
          examples = { "exec endpoint:inventory_controller getAllStacks" },
        },
        getStackInSlot = {
          mode = "read",
          description = "Returns one slot by index; announced but not allowed.",
          args = { "slot:number" },
          returns = "table",
          examples = { "exec endpoint:inventory_controller getStackInSlot 1" },
        },
      },
    })
  end
  return count, names
end

-- Line role: open DNS1, publish this node's snapshot. The node falls back to
-- the TC1 master when dnsMaster is empty, and serves without publishing when
-- neither address is configured.
local function startDnsNode(instance, requireModule, config, version, log, vfs)
  local okNet, dnsnetModule = pcall(requireModule, "tc.dnsnet")
  if not okNet or type(dnsnetModule) ~= "table" then
    log.error("DNS1 transport unavailable: " .. tostring(dnsnetModule))
    return nil, nil
  end
  local port = tonumber(config.get("dnsPort")) or 4201
  local transport = dnsnetModule.new({
    computer = computer,
    component = component,
    port = port,
    nodeId = instance.address,
    transport = config.get("dnsTransport") or "auto",
    log = log,
  })
  local opened, reason = transport:open()
  if not opened then
    log.warn("DNS1: not listening on port " .. tostring(port) .. ": " .. tostring(reason))
  end
  instance.dnsnet = transport

  local okNode, nodeModule = pcall(requireModule, "tc.dnsnode")
  if not okNode or type(nodeModule) ~= "table" then
    log.error("DNS1 node unavailable: " .. tostring(nodeModule))
    return transport, nil
  end

  local master = config.get("dnsMaster") or ""
  if master == "self" then
    master = ""
  end
  if master == "" then
    master = config.get("master") or ""
  end
  if master == "" then
    log.warn("DNS1: no master configured; the node serves but does not publish")
  end

  local node = nodeModule.new({
    id = instance.address,
    name = instance.hostname,
    ver = version.version,
    boot = dnsBootId(),
    tags = { "line", "dns" },
    docs = "TerraCorp line node. DNS1 registry, plant readout, state and inbox.",
    transport = opened and transport or nil,
    master = master ~= "" and master or nil,
    computer = computer,
    component = component,
    dnsPort = port,
    log = log,
    vfs = vfs,
  })
  node:registerStatus()
  node:registerState()
  node:registerInbox()
  if instance.plant then
    node:registerPlant(instance.plant)
  end
  local _, inventoryNames = registerDnsInventory(node, log)

  node:addPath({
    name = "status",
    members = { "dns.status" },
    tags = { "dns", "status" },
    docs = "DNS1 status endpoint.",
  })
  if #inventoryNames > 0 then
    node:addPath({
      name = "inventory",
      members = inventoryNames,
      tags = { "inventory" },
      docs = "Every inventory controller on this node.",
    })
  end
  node:addPath({
    name = "spike",
    members = { "dns.status", "inventory_controller" },
    tags = { "dns", "m0" },
    docs = "M0 read-only spike path; kept for older clients.",
  })
  instance.dnsnode = node
  node:tick(computer.uptime())
  return transport, node
end

-- Desktop role: `self` runs the DNS1 master; any other non-empty address runs
-- the client. Empty means DNS1 is off on this desktop.
local function startDnsDesktop(instance, requireModule, config, version, log, vfs)
  local setting = config.get("dnsMaster") or ""
  if setting == "" then
    return nil
  end

  local okNet, dnsnetModule = pcall(requireModule, "tc.dnsnet")
  if not okNet or type(dnsnetModule) ~= "table" then
    log.error("DNS1 transport unavailable: " .. tostring(dnsnetModule))
    return nil
  end
  local port = tonumber(config.get("dnsPort")) or 4201
  local transport = dnsnetModule.new({
    computer = computer,
    component = component,
    port = port,
    nodeId = instance.address,
    transport = config.get("dnsTransport") or "auto",
    log = log,
  })
  local opened, reason = transport:open()
  if not opened then
    log.warn("DNS1: not listening on port " .. tostring(port) .. ": " .. tostring(reason))
  end
  instance.dnsnet = transport

  if setting == "self" then
    local okMaster, dnsmasterModule = pcall(requireModule, "tc.dnsmaster")
    if not okMaster or type(dnsmasterModule) ~= "table" then
      log.error("DNS1 master unavailable: " .. tostring(dnsmasterModule))
      return transport
    end
    local master = dnsmasterModule.new({
      id = instance.address,
      ver = version.version,
      boot = dnsBootId(),
      computer = computer,
      transport = transport,
      vfs = vfs,
      log = log,
    })
    transport.onFrame = function(side, from, verb, fields)
      return master:onFrame(side, from, verb, fields)
    end
    instance.dnsmaster = master
    log.trace("DNS1 master listening on port " .. tostring(port))
  else
    local okClient, dnsclientModule = pcall(requireModule, "tc.dnsclient")
    if not okClient or type(dnsclientModule) ~= "table" then
      log.error("DNS1 client unavailable: " .. tostring(dnsclientModule))
      return transport
    end
    instance.dnsclient = dnsclientModule.new({
      computer = computer,
      net = transport,
      master = setting,
      log = log,
    })
    log.trace("DNS1 client targeting " .. tostring(setting))
  end
  return transport
end

function kernel.start(boot)
  local volume = component.proxy(boot.address)
  if not volume then
    error("TerraCorp OS: boot volume " .. tostring(boot.address) .. " is not responding", 0)
  end

  -- Only `read` is needed to load the shared filesystem module itself.
  local vfs = {
    read = function(path)
      return bootRead(volume, path)
    end,
  }
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

  local vfsModule = requireModule("tc.vfs")
  vfs = vfsModule.new(volume)
  if not vfs then
    error("TerraCorp OS: boot volume is not readable", 0)
  end

  local version = requireModule("tc.version")
  local util = requireModule("tc.util")
  local text = requireModule("tc.text")
  local log = requireModule("tc.log")
  local config = requireModule("tc.config")

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

  local instance = setmetatable({
    version = version,
    util = util,
    text = text,
    log = log,
    config = config,
    vfs = vfs,
    vfsModule = vfsModule,
    -- Apps and Lab scripts load core modules through the kernel's loader, so
    -- they share the cached instances instead of re-reading the boot volume.
    require = requireModule,
    mounts = {},
    volume = volume,
    volumeAddress = boot.address,
    address = address,
    hostname = hostname,
    tpsClock = nil,
    tpsValue = nil,
  }, { __index = kernel })

  -- Notes for every release this node skipped, written before either role
  -- starts so a headless server gets the file too.
  instance.notesPath = writeReleaseNotes(instance, requireModule)

  -- A line node has no desktop and reads its own line: the plant service, its
  -- own level alarms and the status publisher. It never needs a GPU.
  if config.get("role") == "line" then
    log.trace("Line role: starting the line node runtime")
    local linePlant = nil
    local okPlant, plantModule = pcall(requireModule, "tc.plant")
    if okPlant and type(plantModule) == "table" then
      local okNew, service = pcall(plantModule.new, {
        kernel = instance,
        vfs = vfs,
        log = log,
        version = version,
      })
      if okNew then
        linePlant = service
        instance.plant = service
        log.trace("Plant readout started")
      else
        log.error("Plant service failed: " .. tostring(service))
      end
    else
      log.error("Plant service unavailable: " .. tostring(plantModule))
    end

    local okReport, reportModule = pcall(requireModule, "tc.report")
    if okReport and type(reportModule) == "table" then
      local dns, dnsnode = startDnsNode(instance, requireModule, config, version, log, vfs)
      return reportModule.run({
        kernel = instance,
        vfs = vfs,
        log = log,
        config = config,
        version = version,
        plant = linePlant,
        dns = dns,
        dnsnode = dnsnode,
      })
    end
    log.error("Report module unavailable: " .. tostring(reportModule))
    return
  end

  -- The desktop UI is loaded here rather than before the role split: a line node
  -- has no screen, and theme+gfx+ui are about 51 KB it would never call.
  local themeModule = requireModule("tc.theme")
  local gfxModule = requireModule("tc.gfx")
  local uiModule = requireModule("tc.ui")
  instance.themeModule = themeModule
  instance.gfxModule = gfxModule
  instance.theme = themeModule.build(config)
  -- Kept as a local too: the splash and the UI below capture it.
  local theme = instance.theme

  -- The local plant readout starts before the desktop: the app only reads its
  -- cache, and the first scan is one component call per second.
  local okPlant, plantModule = pcall(requireModule, "tc.plant")
  if okPlant and type(plantModule) == "table" then
    local okNew, service = pcall(plantModule.new, {
      kernel = instance,
      vfs = vfs,
      log = log,
      version = version,
    })
    if okNew then
      instance.plant = service
      log.trace("Plant readout started")
    else
      log.error("Plant service failed: " .. tostring(service))
    end
  else
    log.error("Plant service unavailable: " .. tostring(plantModule))
  end

  -- The operated book and the planner are pure data: the book is parsed once at
  -- boot and the planner reads the cached stock snapshot. A broken book is
  -- reported, never fatal, so the desktop still starts.
  local okBook, bookModule = pcall(requireModule, "tc.book")
  if okBook and type(bookModule) == "table" then
    local okNew, service = pcall(bookModule.new, { vfs = vfs, log = log })
    if okNew then
      instance.book = service
      log.trace(string.format("Recipe book: %d recipes, %d errors", #service.order, #service.errors))
      local okPlan, planModule = pcall(requireModule, "tc.plan")
      if okPlan and type(planModule) == "table" then
        instance.plan = planModule.new(service)
      else
        log.error("Planner unavailable: " .. tostring(planModule))
      end
    else
      log.error("Recipe book failed: " .. tostring(service))
    end
  else
    log.error("Recipe book unavailable: " .. tostring(bookModule))
  end

  if instance.plant then
    instance.hall = instance.plant.hall
  end

  -- Setpoints and movement are harness-tested until a gate and a transport
  -- exist; loading them now means the first gate is config, not a code change.
  local okGate, gateModule = pcall(requireModule, "tc.gate")
  if okGate and type(gateModule) == "table" then
    local okNew, gateService = pcall(gateModule.new, { vfs = vfs, log = log })
    if okNew then
      instance.gate = gateService
      log.trace(string.format("Gates: %d lines, %d errors", #gateService.order, #gateService.errors))
    else
      log.error("Gate service failed: " .. tostring(gateService))
    end
  else
    log.error("Gate service unavailable: " .. tostring(gateModule))
  end

  local okMove, moveModule = pcall(requireModule, "tc.move")
  if okMove and type(moveModule) == "table" then
    instance.move = moveModule
  else
    log.error("Move module unavailable: " .. tostring(moveModule))
  end

  local gpuAddress = component.list("gpu")()
  if not gpuAddress then
    error("TerraCorp OS: a GPU is required to boot the desktop", 0)
  end

  local screenAddress = component.list("screen")()
  if screenAddress then
    pcall(component.invoke, gpuAddress, "bind", screenAddress)
  end

  local gfx = gfxModule.new(gpuAddress)
  instance.gfx = gfx

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

  if instance.notesPath then
    instance.ui:notify("info", "What's new: " .. instance.notesPath)
  end

  -- The master owns the node registry, which is the plant's DNS: it receives the
  -- line nodes' status, keeps their names and merges their stocks by path.
  local okMaster, masterModule = pcall(requireModule, "tc.master")
  if okMaster and type(masterModule) == "table" then
    instance.master = masterModule.new({
      kernel = instance,
      vfs = vfs,
      config = config,
      log = log,
      version = version,
      component = component,
      computer = computer,
    })
    instance.master:start()
  else
    log.error("Master service unavailable: " .. tostring(masterModule))
  end

  -- DNS1 is independent of TC1: the master answers on 4201 and the catalog is
  -- filled by line nodes publishing their snapshots.
  startDnsDesktop(instance, requireModule, config, version, log, vfs)

  -- The flasher writes a node installer medium from this runtime: the tree, the
  -- marker that makes /init.lua run the installer, and a configuration that
  -- already names this master. Nothing happens until the operator asks for it.
  local okFlash, flashModule = pcall(requireModule, "tc.flash")
  if okFlash and type(flashModule) == "table" then
    instance.flash = flashModule.new({
      kernel = instance,
      vfs = vfs,
      log = log,
      config = config,
      version = version,
      component = component,
      computer = computer,
    })
  else
    log.error("Flasher unavailable: " .. tostring(flashModule))
  end

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

  -- The external link starts after the first render: boot never depends on it.
  local okLink, linkModule = pcall(requireModule, "tc.link")
  if okLink and type(linkModule) == "table" then
    instance.link = linkModule.new({
      kernel = instance,
      config = config,
      vfs = vfs,
      log = log,
      version = version,
    })
    if instance.link.enabled then
      log.trace("external link armed")
    end
  else
    log.error("External link unavailable: " .. tostring(linkModule))
  end

  instance:loop()
end

return kernel
