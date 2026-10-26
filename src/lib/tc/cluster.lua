-- Master side of the 0.3.0 node cluster.
--
-- The cluster owns the wired modem, the installer window, the node registry,
-- and the heartbeats. The kernel forwards `modem_message` signals here before
-- the desktop sees them; the Nodes app reads the public status methods.
--
-- Protocol and physical build notes: docs/cluster.md.

local net = require("tc.net")
local provision = require("tc.provision")
local registry = require("tc.registry")
local updater = require("tc.updater")
local jobsModule = require("tc.jobs")
local vaultModule = require("tc.vault")

local cluster = {}
cluster.__index = cluster

cluster.INSTALL_WINDOW = 600
cluster.OFFLINE_AFTER = 30
cluster.OFFLINE_GRACE = 5
cluster.UPDATE_WINDOW = 600
cluster.UPDATE_BATCH_FRACTION = 2
cluster.UPDATE_BATCH_WINDOW = 120
cluster.CHUNK = 512
cluster.SAVE_INTERVAL = 10
cluster.LOG_LIMIT = 40
cluster.NODEUPDATE_ROOT = "/var/nodeupdate"

-- Runtime paths the master may serve to a booting or updating node.
local SERVE_ROOTS = { "/init.lua", "/boot", "/lib", "/apps" }

local function shortAddress(address)
  return tostring(address or "?"):sub(1, 8)
end

local function kilobytes(value)
  local number = tonumber(value)
  if not number or number < 0 then
    return 0
  end
  return math.floor(number)
end

function cluster.new(env)
  local self = setmetatable({}, cluster)

  self.kernel = env.kernel
  self.vfs = env.vfs or self.kernel.vfs
  self.config = env.config
  self.logger = env.log
  self.version = env.version
  self.component = env.component or component
  self.computer = env.computer or computer

  self.nodes = {}
  self.pending = {}
  self.installer = nil
  self.floppy = nil
  self.modem = nil
  self.logs = {}
  self.dirty = false
  self.lastSave = 0
  self.lastModemAttempt = 0
  self.lastInstallLog = nil
  self.lastInstallLogAt = 0
  self.badFrames = 0

  self.jobs = jobsModule.newPublisher({
    id = self.kernel.address or self.computer.address(),
    vfs = self.vfs,
    log = self.logger,
    now = function()
      return self:now()
    end,
    send = function(address, verb, fields)
      return self:send(address, verb, fields)
    end,
    broadcast = function(verb, fields)
      return self:broadcast(verb, fields)
    end,
  })

  self.vault = vaultModule.new({
    id = self.kernel.address or self.computer.address(),
    vfs = self.vfs,
    log = self.logger,
    now = function()
      return self:now()
    end,
    send = function(address, verb, fields)
      return self:send(address, verb, fields)
    end,
  })

  return self
end

function cluster:now()
  return self.kernel:uptime()
end

function cluster:log(message)
  message = tostring(message)
  self.logs[#self.logs + 1] = { at = self:now(), message = message }
  while #self.logs > cluster.LOG_LIMIT do
    table.remove(self.logs, 1)
  end
  if self.logger then
    self.logger.info("cluster: " .. message)
  end
end

function cluster:recentLog(count)
  local lines = {}
  local first = math.max(1, #self.logs - (count or 6) + 1)
  for index = first, #self.logs do
    lines[#lines + 1] = self.logs[index]
  end
  return lines
end

function cluster:invokeValue(address, method)
  if not self.component or type(self.component.invoke) ~= "function" then
    return nil
  end
  local ok, value = pcall(self.component.invoke, address, method)
  if not ok then
    return nil
  end
  return value
end

function cluster:openModem()
  if self.modem then
    return true
  end

  self.lastModemAttempt = self:now()
  local modem = net.newModem({
    component = self.component,
    computer = self.computer,
    port = net.PORT,
  })
  local ok, reason = modem:open()
  if not ok then
    if self.logger then
      self.logger.warn("cluster: " .. tostring(reason))
    end
    return nil, reason
  end

  self.modem = modem
  self:log("Network ready on " .. shortAddress(modem.address))
  return true
end

function cluster:start()
  self.nodes = registry.load(self.vfs)
  self:log(string.format("Loaded %d registered node(s)", #self.nodes))

  local resumed = self.jobs:start()
  if resumed then
    local counts = self.jobs:summary()
    self:log(string.format(
      "Resumed the job queue (%d queued, %d granted)",
      counts.queued,
      counts.granted
    ))
  end

  if self.vault:start() then
    local usage = self.vault:usage()
    self:log(string.format(
      "Vault pool restored: %d file(s), %d disk(s)",
      usage.files,
      #usage.disks
    ))
  end

  local ok, reason = self:openModem()
  if not ok then
    self:log("No network card yet: " .. tostring(reason))
  end
  return ok, reason
end

function cluster:send(address, verb, fields)
  local ok = self:openModem()
  if not ok then
    return nil, "network card is unavailable"
  end
  return self.modem:send(address, verb, fields)
end

function cluster:broadcast(verb, fields)
  local ok = self:openModem()
  if not ok then
    return nil, "network card is unavailable"
  end
  return self.modem:broadcast(verb, fields)
end

function cluster:save(force)
  if not force and not self.dirty then
    return true
  end
  local ok, reason = registry.save(self.vfs, self.nodes)
  if ok then
    self.dirty = false
    self.lastSave = self:now()
  elseif self.logger then
    self.logger.warn("cluster: could not save the node registry: " .. tostring(reason))
  end
  return ok, reason
end

function cluster:markDirty()
  self.dirty = true
end

function cluster:findNode(id)
  return registry.find(self.nodes, id)
end

function cluster:nodesList()
  return self.nodes
end

function cluster:summary()
  return registry.aggregate(self.nodes)
end

function cluster:nextName()
  local used = {}
  local highest = 0

  local function reserve(name)
    name = tostring(name or "")
    used[name:lower()] = true
    local number = name:match("^TC%-N(%d+)$")
    if number then
      highest = math.max(highest, tonumber(number) or 0)
    end
  end

  for _, node in ipairs(self.nodes) do
    reserve(node.name)
  end
  -- Nodes that are still installing are not registered yet: reserve their
  -- assigned names too, or two servers provisioned together get the same one.
  for _, pending in pairs(self.pending) do
    reserve(pending and pending.name)
  end

  local number = highest
  repeat
    number = number + 1
  until not used[("tc-n" .. number)]
  return "TC-N" .. number
end

function cluster:newToken()
  local seed = tostring(self.kernel.address or self.computer.address())
  return string.format(
    "%s-%x-%x",
    seed:sub(1, 6),
    math.floor(self:now() * 1000) % 0x7fffffff,
    (#self.nodes + 1) * 7919
  )
end

function cluster:findCandidates()
  local candidates, seen = {}, {}
  local bootAddress = self.kernel.volumeAddress

  local function add(address, preferred)
    if type(address) ~= "string" or address == "" then
      return
    end
    if address == bootAddress or seen[address] then
      return
    end
    seen[address] = true

    local readOnly = self:invokeValue(address, "isReadOnly")
    if readOnly == true then
      return
    end

    local volume = self.kernel:mount(address)
    if not volume then
      return
    end
    local safe, reason = provision.checkTarget(volume)
    candidates[#candidates + 1] = {
      address = address,
      vfs = volume,
      total = kilobytes(self:invokeValue(address, "spaceTotal")),
      safe = safe == true,
      reason = reason,
      preferred = preferred == true,
    }
  end

  -- A rack-mounted drive exposes its inserted floppy through filesystem().
  for drive in self.component.list("disk_drive") do
    local ok, filesystem = pcall(self.component.invoke, drive, "filesystem")
    if ok and type(filesystem) == "string" then
      add(filesystem, true)
    end
  end

  for address in self.component.list("filesystem") do
    add(address, false)
  end

  table.sort(candidates, function(a, b)
    if a.preferred ~= b.preferred then
      return a.preferred
    end
    if a.total ~= b.total then
      return a.total < b.total
    end
    return a.address < b.address
  end)

  return candidates
end

function cluster:installerState()
  local now = self:now()
  if not self.installer then
    return { active = false, remaining = 0 }
  end

  local remaining = math.max(0, self.installer.expiresAt - now)
  return {
    active = self.installer.active and remaining > 0,
    remaining = remaining,
    preparedAt = self.installer.preparedAt,
    files = self.installer.files,
    bytes = self.installer.bytes,
    version = self.installer.version,
    floppy = self.installer.floppy,
    assigned = self.installer.assigned,
    lastName = self.installer.lastName,
    log = self:installLog(),
  }
end

function cluster:installLog()
  if not self.floppy or not self.floppy.vfs then
    return nil
  end
  local now = self:now()
  if not self.lastInstallLogAt or now - self.lastInstallLogAt >= 2 then
    self.lastInstallLogAt = now
    self.lastInstallLog = self:installLogTail(self.floppy.vfs)
  end
  return self.lastInstallLog
end

--- Read the last few kilobytes of the install log without holding the whole
-- file in memory: a long-waiting node grew it past what a 2 MB master can
-- buffer, which killed the read with an allocation error. Read in chunks and
-- keep only a sliding window of the tail.
function cluster:installLogTail(floppy)
  local handle, reason = floppy.volume and floppy.volume.open
    and floppy.volume.open(provision.logPath, "r")
  if not handle then
    return self.lastInstallLog
  end

  local window, newest = {}, 0
  local keep = 4 -- keep the last ~16 KB
  while true do
    local data = select(2, pcall(floppy.volume.read, handle, 4096))
    if type(data) ~= "string" or data == "" then
      break
    end
    if newest >= keep then
      table.remove(window, 1)
      newest = newest - 1
    end
    window[#window + 1] = data
    newest = newest + 1
  end
  pcall(floppy.volume.close, handle)

  local tail = {}
  for _, chunk in ipairs(window) do
    tail[#tail + 1] = chunk
  end
  return table.concat(tail)
end

function cluster:prepareInstaller()
  local ok, reason = self:openModem()
  if not ok then
    return nil, "the network card is unavailable: " .. tostring(reason)
  end

  local candidates = self:findCandidates()
  if #candidates == 0 then
    return nil, "No floppy found. Insert a floppy in the rack drive."
  end

  local version = self.version and self.version.version or "unknown"
  local wantPayload = self.config
    and type(self.config.get) == "function"
    and self.config.get("nodeFloppyPayload") == true
  local pinned = ""
  if self.config and type(self.config.get) == "function" then
    pinned = tostring(self.config.get("nodeFloppyAddress") or "")
  end
  local lastReason
  local armed, written = false, 0
  local result, why

  local function prepareOne(candidate)
    -- With nodeFloppyPayload the floppy also carries the full runtime so a
    -- server can install offline. If the payload does not fit, fall back to
    -- the pull-only bootstrap instead of failing the preparation.
    if wantPayload then
      result, why = provision.prepare(self.vfs, candidate.vfs, {
        version = version,
        reuse = true,
        payload = true,
      })
      if not result then
        self:log("Floppy " .. shortAddress(candidate.address)
          .. ": offline payload does not fit (" .. tostring(why)
          .. "); writing the pull bootstrap")
      end
    end
    if not result then
      result, why = provision.prepare(self.vfs, candidate.vfs, {
        version = version,
        reuse = true,
      })
    end
    return result
  end

  -- With nodeFloppyAddress set, write only that floppy: the operator carries
  -- it to the rack drive by hand and no other floppy on the bus is touched.
  if pinned ~= "" then
    local chosen = nil
    for _, candidate in ipairs(candidates) do
      if candidate.address == pinned then
        chosen = candidate
        break
      end
    end
    if not chosen then
      return nil, "No floppy matches nodeFloppyAddress ("
        .. shortAddress(pinned) .. "). Check the drive on the bus."
    end
    if not chosen.safe then
      return nil, chosen.reason or "the floppy contains other data"
    end
    result, why = nil, nil
    local prepared = prepareOne(chosen)
    if not prepared then
      return nil, why or "could not write the floppy"
    end
    self:log(string.format(
      "Floppy %s ready: %d files, %d KB (%s)",
      shortAddress(chosen.address),
      prepared.files,
      math.floor(prepared.bytes / 1024 + 0.5),
      prepared.reused and "reused" or "written"
    ))
    candidates = { chosen }
    lastResult, lastCandidate = prepared, chosen
    armed, written = true, 1
  else
    -- Prepare every writable floppy on the bus, not just one: a master cannot
    -- tell its own drive's floppy from a rack drive's, so writing them all
    -- guarantees the rack floppy is bootable and the log names each address.
    for _, candidate in ipairs(candidates) do
      local label = shortAddress(candidate.address)
      if not candidate.safe then
        self:log("Skipped floppy " .. label .. ": " .. tostring(candidate.reason or "other data"))
        lastReason = candidate.reason or "the floppy contains other data"
      else
        result, why = nil, nil
        local prepared = prepareOne(candidate)
        if prepared then
          armed = true
          written = written + 1
          self:log(string.format(
            "Floppy %s ready: %d files, %d KB (%s)",
            label,
            prepared.files,
            math.floor(prepared.bytes / 1024 + 0.5),
            prepared.reused and "reused" or "written"
          ))
          lastResult, lastCandidate = prepared, candidate
        else
          self:log("Floppy " .. label .. " failed: " .. tostring(why))
          lastReason = why
        end
      end
    end
    if not armed then
      return nil, lastReason or "no usable floppy was found"
    end
  end

  do
    local result, candidate = lastResult, lastCandidate
    local now = self:now()
    self.floppy = candidate
    self.installer = {
      active = true,
      preparedAt = now,
      expiresAt = now + cluster.INSTALL_WINDOW,
      files = result.files,
      bytes = result.bytes,
      version = result.version,
      floppy = candidate.address,
      assigned = 0,
      lastName = nil,
    }
    self.pending = {}
    self.lastInstallLog = nil
    self.lastInstallLogAt = 0
    if result.reused and written == 1 then
      return true, "Payload " .. result.version
        .. " is already on the floppy; installer armed."
    end
    return true, "Installer armed on " .. written .. " floppy(ies). Power on each unprovisioned server."
  end
end

function cluster:stopInstaller()
  if not self.installer then
    return true, "The installer is already idle."
  end
  self.installer.active = false
  self.installer = nil
  self.pending = {}
  self:log("Installer stopped")
  return true, "Installer stopped."
end

function cluster:ping(id)
  local node = self:findNode(id)
  if not node then
    return nil, "unknown node"
  end
  if not node.modem or node.modem == "" then
    return nil, "the node has no known network address"
  end

  local ok, reason = self:send(node.modem, "PING", {
    id = node.id,
    master = self.modem and self.modem.address or "",
    masterId = self.kernel.address or self.computer.address(),
  })
  if not ok then
    return nil, reason
  end
  self:log("Pinged " .. tostring(node.name))
  return true
end

--- Ping every node with a known modem address so the list reflects reality.
-- A node that answers comes back online through PONG; silent ones fall to the
-- regular offline tracking.
function cluster:refreshNodes()
  local known, sent = 0, 0
  for _, node in ipairs(self.nodes) do
    if node.modem and node.modem ~= "" then
      known = known + 1
      node.pinged = nil
      local ok = self:send(node.modem, "PING", {
        id = node.id,
        master = self.modem and self.modem.address or "",
        masterId = self.kernel.address or self.computer.address(),
      })
      if ok then
        sent = sent + 1
      end
    end
  end
  if known == 0 then
    return nil, "no node has a known network address yet"
  end
  self:log("Refreshed " .. sent .. " of " .. known .. " node(s)")
  return true, "Pinged " .. sent .. " of " .. known .. " node(s)."
end

--- Remove a node from the registry. Used to drop entries that never come back.
function cluster:forget(id)
  local node = registry.find(self.nodes, id)
  if not node then
    return nil, "unknown node"
  end

  registry.remove(self.nodes, id)
  self.pending[id] = nil
  self:save(true)
  self:log("Forgot " .. tostring(node.name))
  return true, "Forgot " .. tostring(node.name) .. "."
end

--- A path the master is allowed to serve, or nil. Blocks traversal outside
-- the runtime tree so /etc and /var never leave the master.
function cluster:serveAllowed(path)
  if type(path) ~= "string" or path == "" or #path > 96 then
    return nil
  end
  if path:find("%.%.") or path:find("//") then
    return nil
  end
  for _, root in ipairs(SERVE_ROOTS) do
    if path == root or path:sub(1, #root + 1) == root .. "/" then
      return path
    end
  end
  return nil
end

--- File serving is open while the installer window is armed, and restricted
-- to registered nodes while an update window is armed.
function cluster:mayServe(id)
  local now = self:now()
  if self.installer and self.installer.active and now < self.installer.expiresAt then
    return true
  end
  if self.update and self.update.active and now < self.update.expiresAt then
    if id and registry.find(self.nodes, id) then
      return true
    end
  end
  return false
end

function cluster:handleList(fields, remoteAddress)
  if not self:mayServe(fields.id) then
    return
  end

  local tree = self:serveTree()
  local path = self:serveAllowed(fields.path)
  local files, dirs = nil, nil
  if path and self.vfs.isDirectory((tree or "") .. path) then
    local entries, reason = self.vfs.list((tree or "") .. path)
    if entries then
      files, dirs = {}, {}
      for _, entry in ipairs(entries) do
        local name = tostring(entry):gsub("/+$", "")
        if name ~= "" then
          if self.vfs.isDirectory((tree or "") .. path .. "/" .. name) then
            dirs[#dirs + 1] = name
          else
            files[#files + 1] = name
          end
        end
      end
    end
  end

  if not files then
    self:send(remoteAddress, "MISS", { id = fields.id or "", path = tostring(fields.path or "") })
    return
  end
  self:send(remoteAddress, "DIRS", {
    id = fields.id or "",
    path = path,
    files = table.concat(files, ","),
    dirs = table.concat(dirs, ","),
  })
end

function cluster:handleFetch(fields, remoteAddress)
  if not self:mayServe(fields.id) then
    return
  end

  local tree = self:serveTree()
  local path = self:serveAllowed(fields.path)
  local body = path and self.vfs.read((tree or "") .. path) or nil
  if type(body) ~= "string" then
    self:send(remoteAddress, "MISS", { id = fields.id or "", path = tostring(fields.path or "") })
    return
  end

  local off = math.min(math.max(0, math.floor(tonumber(fields.off) or 0)), #body)
  local chunk = body:sub(off + 1, off + cluster.CHUNK)
  local frame, reason = net.encode("DATA", {
    id = fields.id or "",
    path = path,
    off = off,
    size = #body,
    data = chunk,
  })
  -- An escaping-heavy span can overflow the 1 KB frame; shrink and retry so
  -- any chunk still arrives.
  while not frame and #chunk > 32 do
    chunk = chunk:sub(1, math.floor(#chunk / 2))
    frame, reason = net.encode("DATA", {
      id = fields.id or "",
      path = path,
      off = off,
      size = #body,
      data = chunk,
    })
  end
  if not frame then
    self:send(remoteAddress, "MISS", { id = fields.id or "", path = path })
    return
  end
  if self.modem then
    self.modem:sendFrame(remoteAddress, frame)
  end
end

--- Offer the master's runtime version to every known node. The master first
-- checks GitHub for a newer stable release: if one exists it is downloaded to
-- /var/nodeupdate/<version> and served from there, so nodes receive the
-- latest even before the master itself is updated. Without a working check
-- the master serves its own runtime.
function cluster:armUpdate()
  local ok, reason = self:openModem()
  if not ok then
    return nil, "the network card is unavailable: " .. tostring(reason)
  end

  local own = self.version and self.version.version or "unknown"
  self.update = {
    active = true,
    phase = "checking",
    startedAt = self:now(),
    target = own,
    sent = 0,
  }
  self:log("Update requested; checking for the latest release")
  return true, "Checking for the latest release..."
end

--- The staged node-update tree, if one exists. Unlike serveTree, this never
-- falls back to the master's own runtime: it only reports a release that was
-- explicitly staged for the nodes (Update pressed at least once).
-- Returns the path prefix and the version, or nil and nil.
function cluster:stagedTree()
  local marker = self.vfs.read(cluster.NODEUPDATE_ROOT .. "/current.txt")
  local version = marker and marker:match("version=([%w%.%-]+)")
  if version and self.vfs.isDirectory(cluster.NODEUPDATE_ROOT .. "/" .. version) then
    return cluster.NODEUPDATE_ROOT .. "/" .. version, version
  end
  return nil, nil
end

--- Resolve the tree the master serves to nodes: an armed update's staged
-- tree first, then the last staged release, then the master's own runtime.
-- Returns the path prefix (nil for the live runtime) and the version served.
function cluster:serveTree()
  if self.update and self.update.tree then
    return self.update.tree, self.update.target
  end
  local prefix, version = self:stagedTree()
  if prefix then
    return prefix, version
  end
  return nil, self.version and self.version.version or nil
end

--- Send the PULL frames once the target tree is resolved. Nodes are updated
-- in waves: each wave is half of the remaining nodes, so part of the rack
-- always stays online while the rest reboots into the new version.
function cluster:finishUpdateArm()
  local update = self.update
  if not update then
    return
  end
  update.phase = "ready"
  update.expiresAt = self:now() + cluster.UPDATE_WINDOW
  update.queue = {}
  update.wave = {}
  update.waves = 0
  update.done = 0
  update.skipped = 0
  for _, node in ipairs(self.nodes) do
    if node.modem and node.modem ~= "" then
      update.queue[#update.queue + 1] = { id = node.id, modem = node.modem }
    else
      update.skipped = update.skipped + 1
    end
  end
  update.total = #update.queue
  if update.skipped > 0 then
    self:log(update.skipped .. " node(s) without a modem are skipped")
  end
  self:sendUpdateWave()
end

--- Offer PULL to the next wave of nodes.
function cluster:sendUpdateWave()
  local update = self.update
  if not update or #update.queue == 0 then
    return
  end
  local size = math.max(1, math.ceil(#update.queue / cluster.UPDATE_BATCH_FRACTION))
  local sent = 0
  for _ = 1, size do
    local entry = table.remove(update.queue, 1)
    if not entry then
      break
    end
    local pulled = self:send(entry.modem, "PULL", {
      id = entry.id,
      v = update.target,
      master = self.modem and self.modem.address or "",
      masterId = self.kernel.address or self.computer.address(),
    })
    if pulled then
      sent = sent + 1
    end
    update.wave[#update.wave + 1] = {
      id = entry.id,
      modem = entry.modem,
      deadline = self:now() + cluster.UPDATE_BATCH_WINDOW,
    }
  end
  update.waves = update.waves + 1
  update.sent = (update.sent or 0) + sent
  update.expiresAt = self:now() + cluster.UPDATE_WINDOW
  self:log("Update wave " .. update.waves .. ": " .. sent .. " node(s) offered "
    .. update.target .. " (" .. #update.queue .. " left)")
end

--- Advance the running update wave: nodes that report the target version or
-- fall offline leave the wave; when it empties, the next wave starts.
function cluster:sweepUpdate()
  local update = self.update
  if not update or update.phase ~= "ready" then
    return
  end
  local now = self:now()
  local remaining = {}
  for _, entry in ipairs(update.wave) do
    local node = registry.find(self.nodes, entry.id)
    if node and node.v == update.target then
      update.done = update.done + 1
    elseif node and node.state == "offline" then
      self:log(tostring(node.name) .. " went offline during the update wave")
    elseif now >= entry.deadline then
      self:log(shortAddress(entry.id) .. " did not report the new version in time")
    else
      remaining[#remaining + 1] = entry
    end
  end
  update.wave = remaining

  if #update.wave == 0 then
    if #update.queue > 0 then
      self:sendUpdateWave()
    elseif not update.complete then
      update.complete = true
      update.active = false
      self:log("Update finished: " .. update.done .. "/" .. update.total
        .. " node(s) at " .. update.target)
    end
  end
end

--- Advance the update state machine by one step. The GitHub check and the
-- per-file downloads run from tick so the desktop stays responsive.
function cluster:tickUpdate()
  local update = self.update
  if update.phase == "checking" then
    local okCheck, checkOrError = pcall(updater.check, update.target)
    local check, reason
    if okCheck then
      if type(checkOrError) == "table" then
        check = checkOrError
      else
        reason = checkOrError
      end
    else
      reason = checkOrError
    end

    if check and check.available and check.tag then
      local versionText = tostring(check.tag):sub(2)
      local okPaths, pathsOrError = pcall(updater.releasePaths, check.tag)
      local paths = okPaths and pathsOrError or nil
      if not paths then
        self:log("Could not list the release files (" ..
          tostring(okPaths and pathsOrError or pathsOrError) .. "); serving " .. update.target)
      else
        update.latest = versionText
        update.tag = check.tag
        update.paths = paths
        update.index = 1
        update.files = 0
        update.phase = "downloading"
        self:log("Downloading " .. versionText .. " for the nodes (" .. #paths .. " files)")
        return
      end
    elseif check and not check.available then
      self:log("The master already runs the latest release (" .. update.target .. ")")
    else
      self:log("No release check (" .. tostring(reason) .. "); serving " .. update.target)
    end
    self:finishUpdateArm()
  elseif update.phase == "downloading" then
    local repositoryPath = update.paths and update.paths[update.index]
    if not repositoryPath then
      self:finishUpdateArm()
      return
    end

    if not self.volume and self.component and self.kernel and self.kernel.volumeAddress
      and type(self.component.proxy) == "function" then
      self.volume = self.component.proxy(self.kernel.volumeAddress)
    end
    local okStage, bytesOrError, body = pcall(
      updater.stageFile, self.vfs, self.volume, update.tag, repositoryPath, update.stageRoot
    )
    if not okStage or not bytesOrError then
      self:log("Download failed for " .. repositoryPath ..
        " (" .. tostring(okStage and bytesOrError or bytesOrError) .. "); serving " .. update.target)
      update.phase = "ready"
      update.tree = nil
      self:finishUpdateArm()
      return
    end
    if repositoryPath == "src/lib/tc/version.lua" then
      update.stagedVersion = tostring(body or ""):match('version%s*=%s*"([^"]+)"')
    end
    update.index = update.index + 1
    update.files = (update.files or 0) + 1
    if update.index > #update.paths then
      if update.stagedVersion ~= update.latest then
        self:log("The staged version.lua does not match the release; serving " .. update.target)
        update.tree = nil
        self:finishUpdateArm()
        return
      end
      self.vfs.ensureDir(cluster.NODEUPDATE_ROOT)
      self.vfs.write(cluster.NODEUPDATE_ROOT .. "/current.txt", "version=" .. update.latest .. "\n")
      update.tree = update.stageRoot
      update.target = update.latest
      self:log("Staged " .. update.latest .. " for the nodes")
      self:finishUpdateArm()
    end
  end
end

function cluster:cancelUpdate()
  if not self.update then
    return true, "No update is armed."
  end
  self.update = nil
  self:log("Update window closed")
  return true, "Update window closed."
end

function cluster:updateState()
  local now = self:now()
  if not self.update then
    return { active = false, remaining = 0 }
  end
  local update = self.update
  local remaining = update.expiresAt and math.max(0, update.expiresAt - now) or 0
  return {
    active = update.active,
    phase = update.phase,
    remaining = remaining,
    target = update.target,
    latest = update.latest,
    files = update.files,
    total = update.paths and #update.paths or nil,
    sent = update.sent,
    waves = update.waves,
    waveSize = update.wave and #update.wave or 0,
    queued = update.queue and #update.queue or 0,
    updated = update.done or 0,
    waveTotal = update.total,
    complete = update.complete,
    skipped = update.skipped,
  }
end

function cluster:rename(id, name)
  local node, reason = registry.rename(self.nodes, id, name)
  if not node then
    return nil, reason
  end
  self:save(true)
  self:log("Renamed " .. shortAddress(id) .. " to " .. node.name)
  return true, "Renamed to " .. node.name
end

function cluster:setRole(id, role)
  local node, reason = registry.setRole(self.nodes, id, role)
  if not node then
    return nil, reason
  end
  self:save(true)
  self:log(tostring(node.name) .. " is now a " .. role .. " node")
  return true, "Role set to " .. role
end

function cluster:handleHello(fields, remoteAddress)
  local id = fields.id
  if type(id) ~= "string" or id == "" then
    return
  end
  local now = self:now()
  local node = self:findNode(id)

  -- Do not re-provision a node that is still reporting for duty. A node that
  -- was wiped and rebooted the floppy stops sending STATUS and is accepted once
  -- its heartbeat has gone stale.
  if node and node.state == "online" and now - (node.lastSeen or 0) < cluster.OFFLINE_AFTER then
    return
  end

  local installer = self.installer
  if not installer or not installer.active or now >= installer.expiresAt then
    self:log("Ignored HELLO from " .. shortAddress(id) .. " while the installer is idle")
    return
  end

  local pending = self.pending[id]
  if not pending or now - pending.at >= cluster.INSTALL_WINDOW then
    pending = {
      token = self:newToken(),
      name = node and node.name or self:nextName(),
      role = node and node.role or "worker",
      at = now,
      acked = false,
    }
    self.pending[id] = pending
  else
    pending.at = now
  end

  -- The node is not registered yet: it only joins the list once it boots its
  -- own disk, passes the integrity check, and reports STATUS.

  local sent, reason = self:send(remoteAddress, "ASSIGN", {
    id = id,
    name = pending.name,
    role = pending.role,
    master = self.modem and self.modem.address or "",
    masterId = self.kernel.address or self.computer.address(),
    token = pending.token,
  })
  if not sent then
    self:log("Could not answer " .. shortAddress(id) .. ": " .. tostring(reason))
    return
  end

  installer.assigned = (installer.assigned or 0) + (pending.sent and 0 or 1)
  pending.sent = true
  installer.lastName = pending.name
  self:log("Assigned " .. pending.name .. " to " .. shortAddress(id))
end

function cluster:handleAck(fields, remoteAddress)
  local id = fields.id
  local pending = id and self.pending[id] or nil

  -- ACK only requires the token, so accept a peer that omits its id and find
  -- the assignment by token instead.
  if not pending then
    for candidateId, candidate in pairs(self.pending) do
      if candidate.token == fields.token then
        id = candidateId
        pending = candidate
        break
      end
    end
  end

  if not pending or pending.token ~= fields.token then
    if self.logger then
      self.logger.debug("cluster: ignored ACK without a matching token")
    end
    return
  end

  pending.acked = true
  pending.at = self:now()
  pending.boot = fields.boot
  self:log(tostring(pending.name) .. " acknowledged the install; waiting for STATUS")
end

-- Compare dotted version strings: -1 when a < b, 0 when equal, 1 when a > b.
local function compareVersion(a, b)
  local at, bt = {}, {}
  for n in tostring(a):gmatch("%d+") do at[#at + 1] = tonumber(n) end
  for n in tostring(b):gmatch("%d+") do bt[#bt + 1] = tonumber(n) end
  for index = 1, math.max(#at, #bt) do
    local left, right = at[index] or 0, bt[index] or 0
    if left ~= right then
      return left < right and -1 or 1
    end
  end
  return 0
end

function cluster:handleStatus(fields, remoteAddress)
  local id = fields.id
  if type(id) ~= "string" or id == "" then
    return
  end

  local now = self:now()
  local node = self:findNode(id)
  local version = tostring(fields.v or "")
  if version:match("^v?%d+%.%d+%.%d+$") == nil then
    version = node and node.v or ""
  end
  local record = {
    id = id,
    modem = remoteAddress,
    state = fields.state == "offline" and "offline" or "online",
    mem = fields.mem,
    disk = fields.disk,
    v = version,
    jobs = fields.jobs,
    drain = fields.drain,
    lastSeen = now,
  }

  if not node then
    local name = fields.name
    if not registry.validName(name) then
      name = self:nextName()
    end
    local role = fields.role
    if not registry.roles[role] then
      role = "worker"
    end
    record.name = name
    record.role = role
    record.created = true
  end

  local stored = registry.upsert(self.nodes, record)
  if stored then
    stored.pinged = nil
    if record.created or stored.state ~= record.state then
      self:markDirty()
    end
  end
  self.pending[id] = nil
  self:markDirty()
  self:save()

  -- Node-driven update check: a node that just came online reports its
  -- version here; if a newer release is staged for the nodes, answer with
  -- PULL once per staged version. The node stages it and reboots into the
  -- boot-time applier. An operator-driven update session takes precedence.
  local auto = self.config
    and type(self.config.get) == "function"
    and self.config.get("nodeAutoUpdate")
  if auto and stored and not (self.update and self.update.active) then
    local _, stagedVersion = self:stagedTree()
    if stagedVersion
      and compareVersion(stagedVersion, version) > 0
      and stored.modem and stored.modem ~= ""
      and stored.autoPull ~= stagedVersion then
      stored.autoPull = stagedVersion
      local sent = self:send(stored.modem, "PULL", {
        id = id,
        v = stagedVersion,
        master = self.modem and self.modem.address or "",
        masterId = self.kernel.address or self.computer.address(),
      })
      if sent then
        self:log(tostring(stored.name or id) .. " reported " .. tostring(version or "unknown")
          .. "; offering staged " .. stagedVersion)
      end
    end
  end
end

function cluster:handlePong(fields)
  local id = fields.id
  local node = id and self:findNode(id) or nil
  if not node then
    return
  end

  local wasOffline = node.state ~= "online"
  node.state = fields.state == "offline" and "offline" or "online"
  node.lastSeen = self:now()
  node.pinged = nil
  if fields.mem then
    node.mem = kilobytes(fields.mem)
  end
  if fields.disk then
    node.disk = kilobytes(fields.disk)
  end
  if wasOffline then
    self:log(tostring(node.name) .. " answered a ping")
    self:markDirty()
  end
end

function cluster:handle(name, localAddress, remoteAddress, port, distance, message)
  local _ = localAddress, distance
  if name ~= "modem_message" then
    return false
  end
  if not self.modem or tonumber(port) ~= self.modem.port then
    return false
  end

  local verb, fields = net.decode(message)
  if not verb then
    self.badFrames = self.badFrames + 1
    if self.logger and self.badFrames % 10 == 1 then
      self.logger.debug("cluster: rejected frame (" .. tostring(fields) .. ")")
    end
    return true
  end

  if verb == "HELLO" then
    self:handleHello(fields, remoteAddress)
  elseif verb == "ACK" then
    self:handleAck(fields, remoteAddress)
  elseif verb == "STATUS" then
    self:handleStatus(fields, remoteAddress)
  elseif verb == "PONG" then
    self:handlePong(fields)
  elseif verb == "LIST" then
    self:handleList(fields, remoteAddress)
  elseif verb == "FETCH" then
    self:handleFetch(fields, remoteAddress)
  elseif verb == "CLAIM" then
    self.jobs:handleClaim(fields, remoteAddress)
  elseif verb == "RESULT" then
    self.jobs:handleResult(fields)
  elseif verb == "VDISK" then
    self.vault:handleDisk(fields, remoteAddress)
  elseif verb == "VDACK" or verb == "VDONE" or verb == "VERR" then
    self.vault:handleControl(verb, fields)
  elseif verb == "VDATA" then
    self.vault:handleData(fields)
  elseif verb == "JOB" or verb == "CANCEL" or verb == "DRAIN" then
    -- Relay verbs the master publishes but never consumes.
  elseif verb == "PING" then
    -- Masters do not answer PING; only nodes do.
  end

  return true
end

function cluster:tick()
  local now = self:now()
  local changed = false

  if not self.modem and now - self.lastModemAttempt >= 30 then
    self:openModem()
  end

  if self.installer and self.installer.active and now >= self.installer.expiresAt then
    self.installer.active = false
    self.pending = {}
    self:log("Installer window expired")
    changed = true
  end

  if self.update and self.update.phase == "ready" and self.update.expiresAt
    and now >= self.update.expiresAt then
    self.update.active = false
    self:log("Update window expired")
    changed = true
  end

  if self.update and (self.update.phase == "checking" or self.update.phase == "downloading") then
    local okTick, tickError = pcall(self.tickUpdate, self)
    if not okTick then
      self.update = nil
      self:log("Update aborted: " .. tostring(tickError))
      changed = true
    end
  end

  self:sweepUpdate()

  for _, node in ipairs(self.nodes) do
    local idle = now - (node.lastSeen or 0)
    if node.state == "online" then
      if idle >= cluster.OFFLINE_AFTER then
        if not node.pinged then
          node.pinged = now
          if node.modem and node.modem ~= "" then
            self:send(node.modem, "PING", {
              id = node.id,
              master = self.modem and self.modem.address or "",
              masterId = self.kernel.address or self.computer.address(),
            })
            self:log("No heartbeat from " .. tostring(node.name) .. "; pinging")
          end
        elseif now - node.pinged >= cluster.OFFLINE_GRACE then
          node.state = "offline"
          node.pinged = nil
          self:markDirty()
          self:log(tostring(node.name) .. " is offline")
          changed = true
        end
      end
    end
  end

  if self.dirty and now - self.lastSave >= cluster.SAVE_INTERVAL then
    self:save()
  end

  self.jobs:tick()
  self.vault:tick()
  return changed
end

--- Publish a job on the cluster queue. Returns the job, or nil and a reason.
function cluster:publishJob(task, args)
  local ok, reason = self:openModem()
  if not ok then
    return nil, "the network card is unavailable: " .. tostring(reason)
  end
  local job, publishReason = self.jobs:publish(task, args)
  if job then
    self:log(string.format("Published job %s (%s)", job.id, job.task))
  end
  return job, publishReason
end

function cluster:cancelJob(jobId)
  local job, reason = self.jobs:cancel(jobId)
  if job then
    self:log("Canceled job " .. tostring(job.id))
  end
  return job, reason
end

function cluster:jobsList()
  return self.jobs:list()
end

function cluster:jobsSummary()
  return self.jobs:summary()
end

--- Vault pool API. Transfers run one chunk per tick; results land in the
-- vault cache and the master log.
function cluster:vaultWrite(path, body)
  local ok, reason = self.vfs.ensureDir("/var/vault")
  if not ok and reason then
    return nil, tostring(reason)
  end
  return self.vault:write(path, body)
end

function cluster:vaultRead(path)
  return self.vault:read(path)
end

function cluster:vaultBody(path)
  return self.vault:body(path)
end

function cluster:vaultRemove(path)
  return self.vault:remove(path)
end

function cluster:vaultList(path)
  return self.vault:list(path)
end

function cluster:vaultDetail(path)
  return self.vault:detail(path)
end

function cluster:vaultUsage()
  return self.vault:usage()
end

--- Tell a node to stop claiming (drain) or to accept work again. The flag is
-- persisted on the node; the next STATUS echoes it back.
function cluster:drainNode(nodeId, flag)
  local node = self:findNode(nodeId)
  if not node then
    return nil, "the node is not registered"
  end
  if not node.modem or node.modem == "" then
    return nil, "the node has no known modem address"
  end

  local ok, reason = self:openModem()
  if not ok then
    return nil, "the network card is unavailable: " .. tostring(reason)
  end
  local sent = self:send(node.modem, "DRAIN", {
    id = node.id,
    drain = flag and "true" or "false",
  })
  if not sent then
    return nil, "could not reach " .. tostring(node.name)
  end
  self:log((flag and "Draining " or "Undraining ") .. tostring(node.name))
  return true
end

function cluster:shutdown()
  self:save(true)
  if self.modem then
    self.modem:close()
    self.modem = nil
  end
end

return cluster
