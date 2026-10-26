-- Headless node runtime.
--
-- A node boots its own HDD, loads the kernel without a desktop, and talks to
-- the master over the wired network card. It reports STATUS, answers PING, and
-- accepts a runtime ASSIGN so the master can repair a node's identity without
-- reinstalling it. If no master is configured it announces itself as
-- unprovisioned and waits for the installer window on the master.

local net = require("tc.net")

local node = {}
node.__index = node

node.STATUS_INTERVAL = 10
node.HELLO_INTERVAL = 5
node.HELLO_WINDOW = 60
node.MODEM_RETRY = 10

-- The boot-time integrity check. A node stays silent until every path is
-- present, so the master only lists servers that boot a complete system.
node.CHECK_PATHS = {
  "/init.lua",
  "/boot/kernel.lua",
  "/lib/tc/vfs.lua",
  "/lib/tc/net.lua",
  "/lib/tc/node.lua",
  "/lib/tc/config.lua",
  "/etc/terracorp.cfg",
}

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

function node.new(env)
  local self = setmetatable({}, node)

  self.kernel = env.kernel
  self.config = env.config
  self.vfs = env.vfs or self.kernel.vfs
  self.log = env.log
  self.version = env.version
  self.theme = env.theme
  self.gfxModule = env.gfxModule
  self.component = env.component or component
  self.computer = env.computer or computer
  self.os = env.os or os

  self.id = self.computer.address()
  self.name = self.config.get("hostname")
  if self.name == "" then
    self.name = "TC-NODE"
  end
  self.role = self.config.get("nodeRole")
  self.master = self.config.get("master")
  self.masterId = self.config.get("masterId")

  self.modem = nil
  self.lastModemAttempt = -math.huge
  self.lastSendError = nil
  self.startedAt = self:now()
  self.lastStatus = -math.huge
  self.statusCount = 0
  self.gfx = nil
  self.screenAddress = nil
  self.screenErrors = 0

  return self
end

function node:now()
  return self.computer.uptime()
end

function node:memoryKB()
  local ok, total = pcall(self.computer.totalMemory)
  if not ok then
    return 0
  end
  return kilobytes((tonumber(total) or 0) / 1024)
end

function node:diskKB()
  local ok, used, total = pcall(self.kernel.storage, self.kernel)
  local _ = used
  if not ok then
    return 0
  end
  return kilobytes(total)
end

function node:hasMaster()
  return type(self.master) == "string" and self.master ~= ""
end

--- Verify the installed system before the node reports to the master.
-- The master only lists nodes that boot their own disk and pass this check,
-- so a half-written install never appears in Nodes. Returns true, or false
-- with the list of failed checks.
function node:verify()
  local failed = {}

  if type(self.computer.getBootAddress) == "function" then
    local ok, address = pcall(self.computer.getBootAddress)
    if not ok or address ~= self.kernel.volumeAddress then
      failed[#failed + 1] = "boot address"
    end
  end

  for _, path in ipairs(node.CHECK_PATHS) do
    local data = self.vfs.read(path)
    if type(data) ~= "string" or #data == 0 then
      failed[#failed + 1] = path
    end
  end

  if self.vfs.exists("/var/install-incomplete") then
    failed[#failed + 1] = "/var/install-incomplete"
  end

  if #failed > 0 then
    if self.log then
      self.log.error("node: system check failed: " .. table.concat(failed, ", "))
    end
    return false, failed
  end
  return true
end

function node:persist()
  if type(self.kernel.saveConfig) == "function" then
    return self.kernel:saveConfig()
  end
  return self.config.save(self.vfs)
end

function node:openModem()
  if self.modem then
    return true
  end
  if self:now() - self.lastModemAttempt < node.MODEM_RETRY then
    return nil, "waiting to retry the network card"
  end

  self.lastModemAttempt = self:now()
  local modem = net.newModem({
    component = self.component,
    computer = self.computer,
    port = net.PORT,
  })
  local ok, reason = modem:open()
  if not ok then
    if self.log then
      self.log.warn("node: " .. tostring(reason))
    end
    return nil, reason
  end

  self.modem = modem
  if self.log then
    self.log.info("node: network ready on " .. shortAddress(modem.address))
  end
  return true
end

function node:sendToMaster(verb, fields)
  local ok = self:openModem()
  if not ok then
    return nil, "network card is unavailable"
  end

  if self:hasMaster() then
    local sent, reason = self.modem:send(self.master, verb, fields)
    if sent then
      self.lastSendError = nil
      return true
    end
    if self.log and self.lastSendError ~= reason then
      self.lastSendError = reason
      self.log.warn("node: " .. tostring(reason))
    end
  end

  -- A replaced master card changes the modem address. A broadcast still reaches
  -- the master; its next PING teaches this node the new address.
  local sent, reason = self.modem:broadcast(verb, fields)
  if sent then
    self.lastSendError = nil
  elseif self.log and self.lastSendError ~= reason then
    self.lastSendError = reason
    self.log.warn("node: " .. tostring(reason))
  end
  return sent, reason
end

function node:helloFields()
  return {
    id = self.id,
    v = self.version and self.version.version or "",
    name = self.name,
    role = "unprovisioned",
    modem = self.modem and self.modem.address or "",
    mem = self:memoryKB(),
    disk = self:diskKB(),
  }
end

function node:statusFields()
  return {
    id = self.id,
    name = self.name,
    role = self.role,
    state = "online",
    mem = self:memoryKB(),
    disk = self:diskKB(),
    uptime = math.floor(self:now()),
    jobs = 0,
    v = self.version and self.version.version or "",
  }
end

function node:sendStatus()
  self.statusCount = self.statusCount + 1
  return self:sendToMaster("STATUS", self:statusFields())
end

function node:sendHello()
  self:openModem()
  if not self.modem then
    return nil, "network card is unavailable"
  end
  return self.modem:broadcast("HELLO", self:helloFields())
end

function node:sendPong(remoteAddress)
  if self.healthy == false then
    return nil, "the system check failed"
  end
  local fields = {
    id = self.id,
    state = "online",
    mem = self:memoryKB(),
    disk = self:diskKB(),
  }
  if remoteAddress and remoteAddress ~= "" then
    return self.modem and self.modem:send(remoteAddress, "PONG", fields)
  end
  return self:sendToMaster("PONG", fields)
end

function node:sendAck(token)
  local fields = {
    token = tostring(token or ""),
    id = self.id,
    v = self.version and self.version.version or "",
    boot = self.kernel.volumeAddress or "",
    mem = self:memoryKB(),
    disk = self:diskKB(),
  }
  return self:sendToMaster("ACK", fields)
end

function node:applyAssignment(fields, remoteAddress)
  if fields.id ~= self.id then
    return false
  end

  local name = tostring(fields.name or ""):match("^%s*(.-)%s*$")
  if name ~= "" and #name <= 24 then
    self.name = name
    self.config.set("hostname", name)
  end

  local role = fields.role
  if role == "worker" or role == "storage" or role == "node" then
    self.role = role
    self.config.set("nodeRole", role)
  end

  local master = fields.master
  if type(master) == "string" and master ~= "" then
    self.master = master
    self.config.set("master", master)
  elseif remoteAddress and remoteAddress ~= "" then
    self.master = remoteAddress
    self.config.set("master", remoteAddress)
  end

  local masterId = fields.masterId
  if type(masterId) == "string" and masterId ~= "" then
    self.masterId = masterId
    self.config.set("masterId", masterId)
  end

  self:persist()
  self:sendAck(fields.token)
  if self.log then
    self.log.info("node: assigned as " .. self.name .. " (" .. tostring(self.role) .. ")")
  end
  self:draw()
  return true
end

function node:adoptMaster(fields, remoteAddress)
  local changed = false

  if type(fields.master) == "string" and fields.master ~= ""
    and fields.master ~= self.master then
    self.master = fields.master
    self.config.set("master", fields.master)
    changed = true
  elseif not self:hasMaster() and remoteAddress and remoteAddress ~= "" then
    self.master = remoteAddress
    self.config.set("master", remoteAddress)
    changed = true
  end

  if type(fields.masterId) == "string" and fields.masterId ~= ""
    and fields.masterId ~= self.masterId then
    self.masterId = fields.masterId
    self.config.set("masterId", fields.masterId)
    changed = true
  end

  if changed then
    self:persist()
    if self.log then
      self.log.info("node: adopted master " .. shortAddress(self.master))
    end
  end
  return changed
end

function node:handleModem(localAddress, remoteAddress, port, distance, message)
  local _ = localAddress, distance
  if not self.modem or tonumber(port) ~= self.modem.port then
    return false
  end

  local verb, fields = net.decode(message)
  if not verb then
    if self.log then
      self.log.debug("node: rejected frame (" .. tostring(fields) .. ")")
    end
    return true
  end

  if verb == "ASSIGN" then
    self:applyAssignment(fields, remoteAddress)
  elseif verb == "PULL" and fields.id == self.id then
    self:startPull(fields, remoteAddress)
  elseif verb == "PING" and fields.id == self.id then
    self:adoptMaster(fields, remoteAddress)
    self:sendPong(remoteAddress)
  end
  return true
end

--- Stage a master-offered update and reboot into the boot-time applier.
-- The applier (src/boot/apply.lua, source=master) swaps the staged tree with
-- backup and rollback before the kernel starts; a failed swap boots the old
-- build and the node simply reports its old version again.
function node:startPull(fields, remoteAddress)
  if self.pulling or self.healthy == false then
    return
  end
  self:adoptMaster(fields, remoteAddress)

  local ok, staged = self:pullUpdate(fields, remoteAddress)
  if ok then
    if self.log then
      self.log.info("node: staged update to " .. tostring(fields.v)
        .. " (" .. tostring(staged) .. " files); rebooting")
    end
    self:draw()
    pcall(self.os.sleep, 1)
    pcall(self.computer.shutdown, true)
  else
    if self.log then
      self.log.error("node: update pull failed: " .. tostring(staged))
    end
    self:draw()
  end
end

function node:pullUpdate(fields, remoteAddress)
  local pull = require("tc.pull")
  local master = fields.master
  if type(master) ~= "string" or master == "" then
    master = remoteAddress
  end
  return pull.run({
    modem = self.modem,
    master = master,
    computer = self.computer,
    id = self.id,
    vfs = self.vfs,
    version = tostring(fields.v or ""),
  })
end

function node:resetScreen()
  self.gfx = nil
  self.screenAddress = nil
  self.screenErrors = 0
end

function node:componentChanged(address, kind)
  if kind == "modem" or (self.modem and address == self.modem.address) then
    if self.modem then
      self.modem:close()
    end
    self.modem = nil
    self.lastModemAttempt = -math.huge
  end
  if kind == "gpu" or kind == "screen" then
    self:resetScreen()
  end
end

function node:draw()
  if not self.gfxModule then
    return
  end

  local gpuAddress = self.component.list("gpu")()
  local screenAddress = self.component.list("screen")()
  if not gpuAddress or not screenAddress then
    return
  end

  if not self.gfx or self.gfx.address ~= gpuAddress then
    pcall(self.component.invoke, gpuAddress, "bind", screenAddress)
    local ok, gfx = pcall(self.gfxModule.new, gpuAddress)
    if not ok then
      self.screenErrors = self.screenErrors + 1
      if self.log and self.screenErrors == 1 then
        self.log.warn("node: display unavailable: " .. tostring(gfx))
      end
      return
    end
    self.gfx = gfx
    self.screenAddress = screenAddress
    self.screenErrors = 0
  elseif self.screenAddress ~= screenAddress then
    pcall(self.component.invoke, gpuAddress, "bind", screenAddress)
    self.screenAddress = screenAddress
    self.gfx:resize()
  end

  local c = self.theme.colors
  local gfx = self.gfx
  gfx:clear(c.bg)

  local function line(row, value, fg)
    if row <= gfx.h then
      gfx:put(2, row, value, fg or c.text, c.bg)
    end
  end

  line(1, "TERRACORP NODE", c.accent)
  line(2, self.name, c.text)
  line(4, "ROLE   " .. tostring(self.role), c.dim)
  line(5, "ADDRESS " .. self.id:sub(1, 8), c.dim)
  if self.healthy == false then
    line(8, "CHECK FAILED", c.warn)
    if self.check and self.check[1] then
      line(10, "missing " .. tostring(self.check[1]), c.warn)
    end
  elseif self:hasMaster() then
    line(6, "MASTER  " .. shortAddress(self.master), c.dim)
    line(8, "ONLINE  STATUS " .. tostring(self.statusCount), c.ok)
  else
    line(6, "MASTER  waiting for assignment", c.warn)
    line(8, "UNPROVISIONED", c.warn)
  end
  line(9, string.format("%d KB RAM  %d KB DISK", self:memoryKB(), self:diskKB()), c.dim)

  if gfx.h >= 12 and self.masterId and self.masterId ~= "" then
    line(11, "MASTER ID " .. shortAddress(self.masterId), c.dim)
  end
  if gfx.h >= 13 then
    line(gfx.h - 1, "Modem port " .. tostring(net.PORT), c.dim)
  end

  gfx:flush()
end

function node:tick()
  local now = self:now()
  if self.healthy == false then
    return
  end
  if not self.modem then
    self:openModem()
  end

  local age = now - self.startedAt
  local interval = node.STATUS_INTERVAL
  if not self:hasMaster() and age < node.HELLO_WINDOW then
    interval = node.HELLO_INTERVAL
  end

  if now - self.lastStatus >= interval then
    self.lastStatus = now
    if self:hasMaster() then
      self:sendStatus()
    else
      self:sendHello()
    end
    self:draw()
  end
end

function node:run()
  local ok, failures = self:verify()
  self.healthy = ok == true
  self.check = failures
  if not self.healthy and self.log then
    self.log.error("node: staying silent until the system check passes")
  end

  self:openModem()
  self:draw()
  self.lastStatus = self:now() - node.STATUS_INTERVAL

  while true do
    local pack = table.pack(pcall(self.computer.pullSignal, 0.5))
    if not pack[1] then
      if self.log then
        self.log.error("node: pullSignal: " .. tostring(pack[2]))
      end
      pcall(self.os.sleep, 0.5)
    else
      local name = pack[2]
      if name == "shutdown" or name == "reboot" then
        break
      elseif name == "modem_message" then
        self:handleModem(table.unpack(pack, 3, pack.n))
      elseif name == "screen_resized" then
        self:resetScreen()
      elseif name == "component_added" or name == "component_removed" then
        self:componentChanged(pack[3], pack[4])
      end
    end

    local ok, reason = pcall(self.tick, self)
    if not ok and self.log then
      self.log.error("node: tick: " .. tostring(reason))
      pcall(self.os.sleep, 1)
    end
  end

  self:shutdown()
end

function node:shutdown()
  if self.modem then
    self.modem:close()
    self.modem = nil
  end
end

return node
