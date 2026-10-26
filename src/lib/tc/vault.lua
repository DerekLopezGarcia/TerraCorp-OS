-- Master side of the Vault pooled storage (no coordinator for placement —
-- the master is only the index keeper, disks stay on their nodes).
--
-- Every server's system disk stays local for the OS; all other disks on the
-- network join one shared namespace. Files are stored whole on the disk with
-- the most free space, tracked in /var/vault/index.tsv, and transferred in
-- ordered 512 B chunks so the desktop stays responsive.

local vault = {}
vault.__index = vault

vault.INDEX = "/var/vault/index.tsv"
vault.DISKS = "/var/vault/disks.tsv"
vault.BACKUP_PATH = "/.backup/index.tsv"
vault.MAX_FILE = 64 * 1024
vault.CHUNK = 512
vault.MAX_PATH = 96
vault.CACHE_LIMIT = 256 * 1024
vault.BACKUP_INTERVAL = 120
vault.RESTORE_INTERVAL = 60

local ESCAPES = { ["\\"] = "\\\\", ["\t"] = "\\t", ["\n"] = "\\n", ["\r"] = "\\r" }
local UNESCAPES = { ["\\"] = "\\", ["t"] = "\t", ["n"] = "\n", ["r"] = "\r" }

local function escapeField(value)
  return (tostring(value or ""):gsub("[\\\t\n\r]", ESCAPES))
end

local function unescapeField(value)
  return (value:gsub("\\(.)", UNESCAPES))
end

--- A virtual path is absolute, short, and cannot escape the namespace.
function vault.validPath(path)
  if type(path) ~= "string" or path:sub(1, 1) ~= "/" or #path > vault.MAX_PATH then
    return false
  end
  if path:find("..", 1, true) then
    return false
  end
  return path:match("^[%w/%.%-_ ]+$") ~= nil
end

--- Create the pool. `env` holds id, vfs, log, now, send(address, verb, fields).
function vault.new(env)
  local self = setmetatable({}, vault)
  self.id = tostring(env.id or "")
  self.vfs = env.vfs
  self.log = env.log
  self.now = env.now
  self.send = env.send
  self.disks = {}
  self.index = {}
  self.cache = {}
  self.cacheOrder = {}
  self.cacheBytes = 0
  self.tx = nil
  self.rx = nil
  self.pending = {}
  self.seq = 0
  self.indexDirty = false
  self.restored = false
  self.backupAt = nil
  self.restoreAt = nil
  return self
end

function vault:findDisk(nodeId, diskAddress)
  for _, disk in ipairs(self.disks) do
    if disk.node == nodeId and disk.disk == diskAddress then
      return disk
    end
  end
  return nil
end

function vault:findEntry(path)
  for _, entry in ipairs(self.index) do
    if entry.path == path then
      return entry
    end
  end
  return nil
end

function vault:usedOnDisk(nodeId, diskAddress)
  local used = 0
  for _, entry in ipairs(self.index) do
    if entry.node == nodeId and entry.disk == diskAddress then
      used = used + entry.size
    end
  end
  return used
end

--- Pick the disk with the most free space for a new file.
function vault:pickDisk(size)
  local best, bestFree = nil, -1
  for _, disk in ipairs(self.disks) do
    local free = disk.total - self:usedOnDisk(disk.node, disk.disk)
    if free >= size and free > bestFree then
      best, bestFree = disk, free
    end
  end
  return best
end

--------------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------------

function vault:save()
  local diskLines = {}
  for _, disk in ipairs(self.disks) do
    diskLines[#diskLines + 1] = table.concat({
      disk.node, disk.modem, disk.disk, tostring(disk.total),
    }, "\t")
  end
  local indexLines = {}
  for _, entry in ipairs(self.index) do
    indexLines[#indexLines + 1] = table.concat({
      escapeField(entry.path), entry.node, entry.disk, tostring(entry.size),
    }, "\t")
  end
  self.vfs.write(vault.DISKS, table.concat(diskLines, "\n")
    .. (#diskLines > 0 and "\n" or ""))
  self.vfs.write(vault.INDEX, table.concat(indexLines, "\n")
    .. (#indexLines > 0 and "\n" or ""))
  return true
end

function vault:load()
  local diskText = self.vfs.read(vault.DISKS)
  if type(diskText) == "string" then
    for line in diskText:gmatch("[^\r\n]+") do
      local node, modem, disk, total = line:match("^(.-)\t(.-)\t(.-)\t(%d+)$")
      if node then
        self.disks[#self.disks + 1] = {
          node = node, modem = modem, disk = disk, total = tonumber(total),
        }
      end
    end
  end
  local indexText = self.vfs.read(vault.INDEX)
  if type(indexText) == "string" then
    for line in indexText:gmatch("[^\r\n]+") do
      local path, node, disk, size = line:match("^(.-)\t(.-)\t(.-)\t(%d+)$")
      if path and self.validPath(unescapeField(path)) then
        self.index[#self.index + 1] = {
          path = unescapeField(path), node = node, disk = disk, size = tonumber(size),
        }
      end
    end
  end
  return #self.disks > 0 or #self.index > 0
end

function vault:start()
  local loaded = self:load()
  if loaded then
    self:save()
  end
  return loaded
end

--------------------------------------------------------------------------------
-- Frame handling
--------------------------------------------------------------------------------

--- A node reported its spare disks; that set replaces the previous one.
function vault:handleDisk(fields, remoteAddress)
  local nodeId = tostring(fields.id or "")
  local modem = tostring(remoteAddress or "")
  if nodeId == "" or modem == "" then
    return
  end

  local keep, reported = {}, {}
  for _, entry in ipairs(self.disks) do
    if entry.node ~= nodeId then
      keep[#keep + 1] = entry
    end
  end
  for item in tostring(fields.disks or ""):gmatch("[^,]+") do
    local address, total = item:match("^(.+):(%d+)$")
    if address and #address > 0 then
      keep[#keep + 1] = { node = nodeId, modem = modem, disk = address, total = tonumber(total) }
      reported[#reported + 1] = address:sub(1, 8)
    end
  end
  self.disks = keep
  self:save()

  -- Diagnostics: log the first report of a node and every change in its disk
  -- count. A node that reports zero spares while it has disks installed is
  -- the signature of an unseen component, not a transport problem.
  self.diskReports = self.diskReports or {}
  local previous = self.diskReports[nodeId]
  self.diskReports[nodeId] = #reported
  if self.log then
    if #reported > 0 then
      self.log.info("Vault pool: " .. #reported .. " disk(s) from " .. nodeId:sub(1, 8)
        .. " (" .. table.concat(reported, ",") .. ")")
    elseif previous == nil then
      self.log.warn("Vault pool: node " .. nodeId:sub(1, 8) .. " reports NO spare disk(s)")
    end
  end
end

function vault:finishWrite(ok, reason)
  local write = self.tx
  self.tx = nil
  if write.hidden then
    if ok then
      self.indexDirty = false
      if self.log then
        self.log.info("Vault index backed up to " .. write.node:sub(1, 8))
      end
    elseif self.log then
      self.log.info("Vault index backup failed: " .. tostring(reason))
    end
    return ok
  end
  if ok then
    local entry = self:findEntry(write.path)
    if entry then
      entry.node, entry.disk, entry.size = write.node, write.disk, write.size
    else
      self.index[#self.index + 1] = {
        path = write.path, node = write.node, disk = write.disk, size = write.size,
      }
    end
    self.indexDirty = true
    self:save()
    if self.log then
      self.log.info("Stored " .. write.path .. " (" .. write.size .. " B)")
    end
  elseif self.log then
    self.log.info("Vault write failed for " .. write.path .. ": " .. tostring(reason))
  end
  return ok
end

function vault:abortRead(reason)
  local read = self.rx
  self.rx = nil
  if self.log and read then
    self.log.info("Vault read failed for " .. read.path .. ": " .. tostring(reason))
  end
end

--- VDACK / VDONE / VERR from the nodes.
function vault:handleControl(verb, fields)
  local id = tostring(fields.id or "")
  if self.tx and self.tx.id == id then
    if verb == "VDACK" then
      self.tx.acked = tonumber(fields.off) or self.tx.acked
    elseif verb == "VDONE" then
      self:finishWrite(true)
    elseif verb == "VERR" then
      self:finishWrite(false, "the storage node refused the transfer")
    end
    return true
  end

  local pending = self.pending[id]
  if pending then
    self.pending[id] = nil
    if verb == "VDONE" then
      local entry = self:findEntry(pending.path)
      if entry then
        for index, item in ipairs(self.index) do
          if item == entry then
            table.remove(self.index, index)
            break
          end
        end
        self.cache[pending.path] = nil
        self.indexDirty = true
        self:save()
        if self.log then
          self.log.info("Deleted " .. pending.path)
        end
      end
    elseif self.log then
      self.log.info("Vault delete failed for " .. pending.path)
    end
    return true
  end

  if self.rx and self.rx.id == id and verb == "VERR" then
    self:abortRead("the storage node refused the transfer")
    return true
  end
  return false
end

--- VDATA slices for an in-flight read.
function vault:handleData(fields)
  local read = self.rx
  if not read or read.id ~= tostring(fields.id or "") then
    return false
  end
  read.awaiting = false
  if tonumber(fields.size) and read.size == nil then
    read.size = tonumber(fields.size)
  end
  local off = tonumber(fields.off) or 0
  if off ~= #read.body then
    self:abortRead("the transfer lost its order")
    return true
  end
  read.body = read.body .. tostring(fields.data or "")
  if read.size and #read.body >= read.size then
    self.rx = nil
    if read.hidden then
      self:restoreIndex(read.body)
    else
      self:cachePut(read.path, read.body)
      if self.log then
        self.log.info("Fetched " .. read.path .. " (" .. #read.body .. " B)")
      end
    end
  end
  return true
end

--- Parse a backup body into the index; used when a fresh master recovers it
-- from a pool disk.
function vault:restoreIndex(text)
  if self.restored or #self.index > 0 or type(text) ~= "string" or text == "" then
    return false
  end
  local count = 0
  for line in text:gmatch("[^\r\n]+") do
    local path, node, disk, size = line:match("^(.-)\t(.-)\t(.-)\t(%d+)$")
    if path and self.validPath(unescapeField(path)) then
      self.index[#self.index + 1] = {
        path = unescapeField(path), node = node, disk = disk, size = tonumber(size),
      }
      count = count + 1
    end
  end
  if count > 0 then
    self.restored = true
    self:save()
    if self.log then
      self.log.info("Vault index restored from the pool backup (" .. count .. " file(s))")
    end
  end
  return count > 0
end

--- Serialize the index for the pool backup.
function vault:indexText()
  local lines = {}
  for _, entry in ipairs(self.index) do
    lines[#lines + 1] = table.concat({
      escapeField(entry.path), entry.node, entry.disk, tostring(entry.size),
    }, "\t")
  end
  return table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
end

--------------------------------------------------------------------------------
-- Cache
--------------------------------------------------------------------------------

function vault:cachePut(path, body)
  if self.cache[path] == nil then
    self.cacheOrder[#self.cacheOrder + 1] = path
  end
  self.cache[path] = body
  self.cacheBytes = self.cacheBytes + #body
  while self.cacheBytes > vault.CACHE_LIMIT and #self.cacheOrder > 1 do
    local oldest = table.remove(self.cacheOrder, 1)
    if self.cache[oldest] then
      self.cacheBytes = self.cacheBytes - #self.cache[oldest]
      self.cache[oldest] = nil
    end
  end
end

function vault:body(path)
  return self.cache[path]
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

--- Start an async write; `tick` advances it one chunk per tick.
function vault:write(path, body)
  if self.tx or self.rx then
    return nil, "a transfer is already running"
  end
  if not self.validPath(path) then
    return nil, "the vault path is invalid"
  end
  body = tostring(body or "")
  if #body > vault.MAX_FILE then
    return nil, "files are limited to 64 KB in this build"
  end
  local disk = self:pickDisk(math.max(#body, 1))
  if not disk then
    return nil, "no pool disk has enough free space"
  end

  self.seq = self.seq + 1
  self.tx = {
    id = "w" .. self.seq,
    path = path,
    node = disk.node,
    modem = disk.modem,
    disk = disk.disk,
    size = #body,
    body = body,
    sent = 0,
    acked = 0,
  }
  self.send(disk.modem, "VOPEN", {
    id = self.tx.id, disk = disk.disk, path = path, size = #body,
  })
  if self.log then
    self.log.info("Storing " .. path .. " (" .. #body .. " B) on " .. disk.disk:sub(1, 8))
  end
  return true
end

--- Start an async read; the completed body lands in the cache.
function vault:read(path)
  if self.tx or self.rx then
    return nil, "a transfer is already running"
  end
  local entry = self:findEntry(path)
  if not entry then
    return nil, "the file is not in the vault"
  end

  self.seq = self.seq + 1
  self.rx = {
    id = "r" .. self.seq,
    path = path,
    node = entry.node,
    modem = nil,
    disk = entry.disk,
    size = entry.size,
    body = "",
    awaiting = false,
  }
  for _, disk in ipairs(self.disks) do
    if disk.node == entry.node and disk.disk == entry.disk then
      self.rx.modem = disk.modem
    end
  end
  if not self.rx.modem then
    self.rx = nil
    return nil, "the storage node has not reported that disk yet"
  end
  return true
end

--- Start an async delete; VDONE drops the index entry.
function vault:remove(path)
  local entry = self:findEntry(path)
  if not entry then
    return nil, "the file is not in the vault"
  end
  local modem = nil
  for _, disk in ipairs(self.disks) do
    if disk.node == entry.node and disk.disk == entry.disk then
      modem = disk.modem
    end
  end
  if not modem then
    return nil, "the storage node has not reported that disk yet"
  end

  self.seq = self.seq + 1
  local id = "d" .. self.seq
  self.pending[id] = { path = path, node = entry.node }
  self.send(modem, "VDEL", { id = id, disk = entry.disk, path = path })
  return true
end

--- The virtual namespace: directories are path prefixes of stored files.
-- Returns { files = {...}, dirs = {...} } for a directory path, or nil.
function vault:list(path)
  path = tostring(path or "/")
  if path ~= "" and path:sub(-1) ~= "/" then
    path = path .. "/"
  end
  local files, dirs = {}, {}
  local seen = {}
  for _, entry in ipairs(self.index) do
    if path == "/" or entry.path:sub(1, #path) == path then
      local rest = entry.path:sub(#path + 1)
      local slash = rest:find("/", 1, true)
      if slash then
        local name = rest:sub(1, slash - 1)
        if not seen["d" .. name] then
          seen["d" .. name] = true
          dirs[#dirs + 1] = name
        end
      else
        files[#files + 1] = rest
      end
    end
  end
  table.sort(files)
  table.sort(dirs)
  return { files = files, dirs = dirs }
end

--- The same namespace with per-file sizes for the UI.
function vault:detail(path)
  path = tostring(path or "/")
  if path ~= "" and path:sub(-1) ~= "/" then
    path = path .. "/"
  end
  local files, dirs, seen = {}, {}, {}
  for _, entry in ipairs(self.index) do
    if path == "/" or entry.path:sub(1, #path) == path then
      local rest = entry.path:sub(#path + 1)
      local slash = rest:find("/", 1, true)
      if slash then
        local name = rest:sub(1, slash - 1)
        if not seen[name] then
          seen[name] = true
          dirs[#dirs + 1] = name
        end
      else
        files[#files + 1] = { name = rest, size = entry.size }
      end
    end
  end
  table.sort(files, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  table.sort(dirs, function(a, b)
    return a:lower() < b:lower()
  end)
  return { files = files, dirs = dirs }
end

--- Per-disk and pool usage in KB.
function vault:usage()
  local disks, total, used = {}, 0, 0
  for _, disk in ipairs(self.disks) do
    local diskUsed = self:usedOnDisk(disk.node, disk.disk)
    disks[#disks + 1] = {
      node = disk.node,
      disk = disk.disk,
      total = math.floor(disk.total / 1024),
      used = math.floor(diskUsed / 1024),
    }
    total = total + disk.total
    used = used + diskUsed
  end
  table.sort(disks, function(a, b)
    if a.node == b.node then
      return a.disk < b.disk
    end
    return a.node < b.node
  end)
  return {
    disks = disks,
    total = math.floor(total / 1024),
    used = math.floor(used / 1024),
    files = #self.index,
  }
end

--- Advance the in-flight transfer by one step (one chunk per tick).
function vault:tick()
  if self.tx then
    local write = self.tx
    if write.acked >= write.sent and write.sent < write.size then
      local data = write.body:sub(write.sent + 1, write.sent + vault.CHUNK)
      self.send(write.modem, "VDATA", { id = write.id, off = write.sent, data = data })
      write.sent = write.sent + #data
    end
  elseif self.rx and not self.rx.awaiting then
    local read = self.rx
    local off = #read.body
    if read.size and off >= read.size then
      return false
    end
    self.send(read.modem, "VREAD", {
      id = read.id, disk = read.disk, path = read.path, off = off,
    })
    read.awaiting = true
  end

  -- Housekeeping runs only when no user transfer is in flight.
  if self.tx or self.rx or #self.disks == 0 then
    return self.tx ~= nil or self.rx ~= nil
  end
  local now = self:now()
  local disk = self.disks[1]

  if self.indexDirty and self.now() - (self.backupAt or -math.huge) >= vault.BACKUP_INTERVAL
    and #self.index > 0 then
    self.backupAt = now
    self.seq = self.seq + 1
    local body = self:indexText()
    self.tx = {
      id = "w" .. self.seq,
      hidden = true,
      path = vault.BACKUP_PATH,
      node = disk.node,
      modem = disk.modem,
      disk = disk.disk,
      size = #body,
      body = body,
      sent = 0,
      acked = 0,
    }
    self.send(disk.modem, "VOPEN", {
      id = self.tx.id, disk = disk.disk, path = vault.BACKUP_PATH, size = #body,
    })
  elseif not self.restored and #self.index == 0
    and self.now() - (self.restoreAt or -math.huge) >= vault.RESTORE_INTERVAL then
    self.restoreAt = now
    self.seq = self.seq + 1
    self.rx = {
      id = "r" .. self.seq,
      hidden = true,
      path = vault.BACKUP_PATH,
      node = disk.node,
      modem = disk.modem,
      disk = disk.disk,
      size = nil,
      body = "",
      awaiting = false,
    }
  end
  return self.tx ~= nil or self.rx ~= nil
end

--- Start the pool: load the persisted disks and index.
function vault:start()
  local loaded = self:load()
  if #self.index > 0 then
    self.restored = true
  end
  return loaded
end

return vault
