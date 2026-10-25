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

local cluster = {}
cluster.__index = cluster

cluster.INSTALL_WINDOW = 600
cluster.OFFLINE_AFTER = 30
cluster.OFFLINE_GRACE = 5
cluster.PROVISION_TIMEOUT = 240
cluster.SAVE_INTERVAL = 10
cluster.LOG_LIMIT = 40

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
  for _, node in ipairs(self.nodes) do
    local name = tostring(node.name or "")
    used[name:lower()] = true
    local number = name:match("^TC%-N(%d+)$")
    if number then
      highest = math.max(highest, tonumber(number) or 0)
    end
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
    self.lastInstallLog = self.floppy.vfs.read(provision.logPath)
  end
  return self.lastInstallLog
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
  local lastReason
  for _, candidate in ipairs(candidates) do
    if candidate.safe then
      local result, why = provision.prepare(self.vfs, candidate.vfs, { version = version })
      if result then
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
        self:log(string.format(
          "Installer armed on %s: %d files, %d KB",
          shortAddress(candidate.address),
          result.files,
          math.floor(result.bytes / 1024 + 0.5)
        ))
        return true, "Installer armed. Power on each unprovisioned server."
      end
      lastReason = why
    else
      lastReason = candidate.reason or "the floppy contains other data"
    end
  end

  return nil, lastReason or "no usable floppy was found"
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

  registry.upsert(self.nodes, {
    id = id,
    name = pending.name,
    role = pending.role,
    modem = remoteAddress,
    state = "provisioning",
    mem = kilobytes(fields.mem),
    disk = kilobytes(fields.disk),
    lastSeen = now,
  })
  self:markDirty()

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
  local node = registry.upsert(self.nodes, {
    id = id,
    name = pending.name,
    role = pending.role,
    modem = remoteAddress,
    state = "provisioning",
    mem = fields.mem,
    disk = fields.disk,
    lastSeen = self:now(),
  })
  self:markDirty()
  self:save()
  if node then
    self:log(tostring(node.name) .. " acknowledged the install; waiting for STATUS")
  end
end

function cluster:handleStatus(fields, remoteAddress)
  local id = fields.id
  if type(id) ~= "string" or id == "" then
    return
  end

  local now = self:now()
  local node = self:findNode(id)
  local record = {
    id = id,
    modem = remoteAddress,
    state = fields.state == "offline" and "offline" or "online",
    mem = fields.mem,
    disk = fields.disk,
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
    elseif node.state == "provisioning" and idle > cluster.PROVISION_TIMEOUT then
      node.state = "offline"
      self:markDirty()
      self:log(tostring(node.name) .. " did not report after provisioning")
      changed = true
    end
  end

  if self.dirty and now - self.lastSave >= cluster.SAVE_INTERVAL then
    self:save()
  end
  return changed
end

function cluster:shutdown()
  self:save(true)
  if self.modem then
    self.modem:close()
    self.modem = nil
  end
end

return cluster
