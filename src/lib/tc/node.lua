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

-- Relay worker limits. One concurrent slot on a Tier 2 CPU; a claim that is
-- never granted expires and the worker forgets it.
node.JOB_SLOTS = 1
node.CLAIM_TTL = 30

-- Vault disk gateway. Spare disks (everything except the boot volume and
-- read-only media) join the cluster pool; transfers are 512 B chunks.
node.VDISK_INTERVAL = 60
node.VAULT_MAX = 64 * 1024

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

  self.claims = {}
  self.runningJob = nil
  self.drain = self.config.get("drain") == "true"

  self.vaultWrite = nil
  self.lastVdisk = -math.huge

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
  local jobs = self.runningJob and 1 or 0
  return {
    id = self.id,
    name = self.name,
    role = self.role,
    state = "online",
    mem = self:memoryKB(),
    disk = self:diskKB(),
    uptime = math.floor(self:now()),
    jobs = jobs,
    drain = self:isDraining() and "true" or "false",
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

--------------------------------------------------------------------------------
-- Relay worker: claim, run, and answer named tasks
--------------------------------------------------------------------------------

--- Built-in task registry. A job runs a named task with contract-bound
-- arguments; remote code is never accepted. Each entry is
-- `run(self, args) -> ok, out`.
node.TASKS = {}

node.TASKS["fs.check"] = function(self, args)
  local _ = args
  local ok, failed = self:verify()
  if ok then
    return true, "ok"
  end
  return false, "failed: " .. table.concat(failed, ", ")
end

node.TASKS["disk.report"] = function(self, args)
  local _ = args
  local ok, used, total = pcall(self.kernel.storage, self.kernel)
  if not ok then
    return false, "storage is unavailable"
  end
  -- kernel:storage() already reports KB; dividing again shrank 4 MB to 4 KB.
  return true, string.format(
    "used=%dKB total=%dKB",
    kilobytes(tonumber(used) or 0),
    kilobytes(tonumber(total) or 0)
  )
end

node.TASKS["log.tail"] = function(self, args)
  local count = tonumber(args) or 10
  if count < 1 then
    count = 1
  elseif count > 30 then
    count = 30
  end
  local text = self.vfs.read("/var/log/tc.log")
  if type(text) ~= "string" or text == "" then
    return true, "empty"
  end
  local lines = {}
  for line in text:gmatch("[^\r\n]+") do
    lines[#lines + 1] = line
  end
  local first = math.max(1, #lines - count + 1)
  local out = {}
  for index = first, #lines do
    out[#out + 1] = lines[index]
  end
  return true, table.concat(out, " | ")
end

node.TASKS["comp.count"] = function(self, args)
  local _ = args
  if not self.component or type(self.component.list) ~= "function" then
    return false, "component API unavailable"
  end

  -- Count with a kind filter AND without it: they are different code paths in
  -- the component API, and a node whose no-filter listing comes back empty
  -- while filtered listings work pinpoints a visibility/hot-plug issue.
  local function count(kind)
    local ok, iterator = pcall(self.component.list, kind)
    if not ok or type(iterator) ~= "function" then
      return "ERR(" .. tostring(iterator) .. ")"
    end
    local total = 0
    while true do
      local address = iterator()
      if not address then
        break
      end
      total = total + 1
    end
    return total
  end

  return true, string.format(
    "all=%s filesystem=%s modem=%s eeprom=%s gpu=%s internet=%s redstone=%s",
    count(nil), count("filesystem"), count("modem"), count("eeprom"),
    count("gpu"), count("internet"), count("redstone")
  )
end

function node:isDraining()
  return self.drain == true or self.drain == "true"
end

--- Offer to run an offered job: claim only when the task is known, a slot is
-- free, and the node is not draining.
function node:offerJob(fields)
  if self:isDraining() then
    return
  end
  local jobId = tostring(fields.id or "")
  if jobId == "" or not node.TASKS[tostring(fields.task or "")] then
    return
  end
  if self.runningJob or self.claims[jobId] then
    return
  end
  local claims = 0
  for _ in pairs(self.claims) do
    claims = claims + 1
  end
  if claims >= node.JOB_SLOTS then
    return
  end

  self.claims[jobId] = {
    task = tostring(fields.task),
    args = tostring(fields.args or ""),
    expires = self:now() + node.CLAIM_TTL,
  }
  self:sendToMaster("CLAIM", { id = jobId, worker = self.id, jobs = claims })
  if self.log then
    self.log.debug("node: claimed job " .. jobId .. " (" .. tostring(fields.task) .. ")")
  end
end

--- A granted claim runs immediately with pcall and answers the granting
-- address (falling back to the master route).
function node:startGranted(fields, remoteAddress)
  local jobId = tostring(fields.id or "")
  local claim = self.claims[jobId]
  if not claim or self.runningJob then
    return
  end
  self.claims[jobId] = nil
  self.runningJob = jobId

  local task = node.TASKS[claim.task]
  -- Tasks return (ok, out); pcall adds its own success flag in front.
  local callOk, taskOk, out = pcall(task, self, claim.args)
  local state, result
  if not callOk then
    state = "failed"
    result = tostring(taskOk or "the task crashed")
    if self.log then
      self.log.error("node: task " .. claim.task .. " crashed: " .. result)
    end
  else
    state = taskOk and "done" or "failed"
    result = tostring(out or "")
    if not taskOk and self.log then
      self.log.error("node: task " .. claim.task .. " failed: " .. result)
    end
  end

  local fields_out = {
    id = jobId,
    token = tostring(fields.token or ""),
    state = state,
    out = result:sub(1, 700),
  }
  if remoteAddress and remoteAddress ~= "" then
    self:openModem()
    if self.modem then
      self.modem:send(remoteAddress, "RESULT", fields_out)
    end
  else
    self:sendToMaster("RESULT", fields_out)
  end
  self.runningJob = nil
  if self.log then
    self.log.info("node: job " .. jobId .. " (" .. claim.task .. ") " .. state)
  end
  self:draw()
end

function node:dropJob(jobId)
  self.claims[jobId] = nil
end

--- Persist the drain flag; a draining node stops claiming new work.
function node:setDrain(fields)
  local value = fields.drain == true or fields.drain == "true"
  self.drain = value
  self.config.set("drain", value and "true" or "false")
  self:persist()
  if self.log then
    self.log.info(value and "node: draining" or "node: accepting work again")
  end
  self:sendStatus()
  self:draw()
end

--------------------------------------------------------------------------------
-- Vault disk gateway: the node reads and writes its own spare disks
--------------------------------------------------------------------------------

--- Enumerate the spare disks: local filesystem components that are not the
-- boot volume and not read-only media.
function node:vaultDisks()
  local disks = {}
  if not self.component or type(self.component.list) ~= "function" then
    return disks
  end
  local ok, iterator = pcall(self.component.list, "filesystem")
  if not ok or type(iterator) ~= "function" then
    return disks
  end
  while true do
    local address = iterator()
    if not address then
      break
    end
    if address ~= self.kernel.volumeAddress then
      local readonly, roValue = pcall(self.component.invoke, address, "isReadOnly")
      local total, totalValue = pcall(self.component.invoke, address, "spaceTotal")
      if not (readonly and roValue) and total and type(totalValue) == "number" then
        disks[#disks + 1] = {
          address = address,
          total = math.floor(totalValue / 1024),
        }
      end
    end
  end
  return disks
end

function node:vdiskFields()
  local items = {}
  for _, disk in ipairs(self:vaultDisks()) do
    items[#items + 1] = disk.address .. ":" .. disk.total
  end
  return table.concat(items, ",")
end

function node:sendVdisk()
  self.lastVdisk = self:now()
  return self:sendToMaster("VDISK", { id = self.id, disks = self:vdiskFields() })
end

--- Invoke a method on one of the node's own disk components.
function node:invokeDisk(disk, method, ...)
  if not self.component or type(self.component.invoke) ~= "function" then
    return nil
  end
  local ok, value = pcall(self.component.invoke, disk, method, ...)
  if not ok then
    return nil
  end
  return value
end

function node:vaultFail(fields, reason)
  if self.log then
    self.log.warn("node: vault transfer failed: " .. tostring(reason))
  end
  self:sendToMaster("VERR", { id = tostring(fields.id or "") })
end

--- VOPEN: start one file write into vault/<path>.part on the target disk.
function node:vaultOpen(fields)
  if self.vaultWrite then
    return self:vaultFail(fields, "another write is running")
  end
  local size = tonumber(fields.size) or -1
  if size < 0 or size > node.VAULT_MAX then
    return self:vaultFail(fields, "the file size is out of range")
  end
  local path = tostring(fields.path or "")
  if path:find("..", 1, true) or path:find("\t", 1, true) or path:sub(1, 1) ~= "/" then
    return self:vaultFail(fields, "the path is invalid")
  end
  local disk = tostring(fields.disk or "")

  -- Make sure the parent directories exist on that disk.
  local parts = {}
  for part in path:gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  local prefix = "vault"
  self:invokeDisk(disk, "makeDirectory", prefix)
  for index = 1, #parts - 1 do
    prefix = prefix .. "/" .. parts[index]
    if not self:invokeDisk(disk, "exists", prefix) then
      self:invokeDisk(disk, "makeDirectory", prefix)
    end
  end

  local target = "vault/" .. table.concat(parts, "/")
  local handle = self:invokeDisk(disk, "open", target .. ".part", "wb")
  if handle == nil then
    return self:vaultFail(fields, "could not open the part file")
  end
  self.vaultWrite = {
    id = tostring(fields.id or ""),
    disk = disk,
    target = target,
    size = size,
    handle = handle,
    received = 0,
  }
end

function node:vaultClose(ok, reason)
  local write = self.vaultWrite
  if not write then
    return
  end
  self.vaultWrite = nil
  pcall(self.component.invoke, write.disk, "close", write.handle)
  if ok then
    self:sendToMaster("VDONE", { id = write.id, size = write.size })
    if self.log then
      self.log.info("node: stored " .. write.target .. " (" .. write.size .. " B)")
    end
  else
    self:invokeDisk(write.disk, "remove", write.target .. ".part")
    self:sendToMaster("VERR", { id = write.id })
    if self.log then
      self.log.warn("node: vault write failed: " .. tostring(reason))
    end
  end
end

--- VDATA: append an in-order chunk to the running write.
function node:vaultData(fields)
  local write = self.vaultWrite
  if not write or write.id ~= tostring(fields.id or "") then
    return
  end
  local off = tonumber(fields.off) or -1
  local data = tostring(fields.data or "")
  if off ~= write.received or write.received + #data > write.size then
    return self:vaultClose(false, "the chunks arrived out of order")
  end
  local done, reason = pcall(self.component.invoke, write.disk, "write", write.handle, data)
  if not done or reason == false then
    return self:vaultClose(false, tostring(reason or "the disk refused the write"))
  end
  write.received = write.received + #data
  self:sendToMaster("VDACK", { id = write.id, off = write.received })
  if write.received >= write.size then
    pcall(self.component.invoke, write.disk, "close", write.handle)
    local stored = self:invokeDisk(write.disk, "size", write.target .. ".part")
    if stored ~= write.size then
      return self:vaultClose(false, "the stored size does not match")
    end
    local moved = self:invokeDisk(write.disk, "rename", write.target .. ".part", write.target)
    self.vaultWrite = nil
    if not moved then
      self:sendToMaster("VERR", { id = write.id })
      if self.log then
        self.log.warn("node: vault rename failed for " .. write.target)
      end
      return
    end
    self:sendToMaster("VDONE", { id = write.id, size = write.size })
    if self.log then
      self.log.info("node: stored " .. write.target .. " (" .. write.size .. " B)")
    end
  end
end

--- VREAD: one 512 B slice of a stored file.
function node:vaultRead(fields)
  local id = tostring(fields.id or "")
  local disk = tostring(fields.disk or "")
  local path = tostring(fields.path or "")
  local off = tonumber(fields.off) or 0
  local target = "vault" .. path
  local total = self:invokeDisk(disk, "size", target)
  if total == nil then
    return self:vaultFail(fields, "the file is missing")
  end
  local handle = self:invokeDisk(disk, "open", target, "rb")
  if handle == nil then
    return self:vaultFail(fields, "could not open the file")
  end
  local seeked = self:invokeDisk(disk, "seek", handle, "set", off)
  if seeked == nil and off > 0 then
    self:invokeDisk(disk, "read", handle, off)
  end
  local data = self:invokeDisk(disk, "read", handle, 512) or ""
  pcall(self.component.invoke, disk, "close", handle)
  self:sendToMaster("VDATA", { id = id, off = off, size = total, data = data })
end

--- VLST: a directory listing of one pool disk (0.3.4b uses it for repair UI).
function node:vaultList(fields)
  local id = tostring(fields.id or "")
  local disk = tostring(fields.disk or "")
  local path = "vault" .. tostring(fields.path or "/")
  local entries = self:invokeDisk(disk, "list", path)
  if entries == nil then
    return self:vaultFail(fields, "the directory is missing")
  end
  local files, dirs = {}, {}
  for _, name in ipairs(entries) do
    if tostring(name):sub(-1) == "/" then
      dirs[#dirs + 1] = tostring(name):sub(1, -2)
    else
      files[#files + 1] = tostring(name)
    end
  end
  self:sendToMaster("VDIRS", {
    id = id,
    path = tostring(fields.path or "/"),
    files = table.concat(files, ","),
    dirs = table.concat(dirs, ","),
  })
end

--- VDEL: remove a stored file from the pool disk.
function node:vaultDelete(fields)
  local id = tostring(fields.id or "")
  local target = "vault" .. tostring(fields.path or "")
  local removed = self:invokeDisk(tostring(fields.disk or ""), "remove", target)
  if removed then
    self:sendToMaster("VDONE", { id = id })
  else
    self:vaultFail(fields, "the file is missing")
  end
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
  elseif verb == "JOB" then
    self:offerJob(fields)
  elseif verb == "GRANT" then
    self:startGranted(fields, remoteAddress)
  elseif verb == "CANCEL" then
    self:dropJob(tostring(fields.id or ""))
  elseif verb == "DRAIN" and fields.id == self.id then
    self:setDrain(fields)
  elseif verb == "VOPEN" then
    self:vaultOpen(fields)
  elseif verb == "VDATA" then
    self:vaultData(fields)
  elseif verb == "VREAD" then
    self:vaultRead(fields)
  elseif verb == "VLST" then
    self:vaultList(fields)
  elseif verb == "VDEL" then
    self:vaultDelete(fields)
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

  for jobId, claim in pairs(self.claims) do
    if now >= claim.expires then
      self.claims[jobId] = nil
    end
  end

  if now - self.lastVdisk >= node.VDISK_INTERVAL then
    self:sendVdisk()
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
