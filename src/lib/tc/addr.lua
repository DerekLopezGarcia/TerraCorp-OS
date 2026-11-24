-- Physical component addresses: node:component:face.
--
-- A component is only readable from the computer whose bus it hangs from, so
-- `node` is the owner and `face` is the numeric side the operation uses. The
-- semantic path (tc.path) is the human-facing name; this module never guesses
-- one from a block name.

local addr = {}
addr.__index = addr

local SEEN_PATH = "/var/plant/seen.tsv"

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Parse `node:component:face` or the short `component:face` form.
-- The short form fills the local node. Returns a record or nil, reason.
function addr.parse(value)
  if type(value) ~= "string" then
    return nil, "address must be a string"
  end
  local text = trim(value)
  local node, component, face = text:match("^([^:]+):([^:]+):(%d+)$")
  if not component then
    component, face = text:match("^([^:]+):(%d+)$")
    node = computer.address()
  end
  if not component or component == "" then
    return nil, "expected node:component:face"
  end
  if node == "" then
    return nil, "empty node address"
  end
  face = tonumber(face)
  if not face or face < 0 or face > 5 then
    return nil, "face must be 0-5"
  end
  if node == "local" or node == "self" then
    node = computer.address()
  end
  return { node = node, component = component, face = face }
end

function addr.format(record)
  if type(record) ~= "table" or not record.node or not record.component or not record.face then
    return nil, "invalid address record"
  end
  return record.node .. ":" .. record.component .. ":" .. tostring(record.face)
end

function addr.short(record)
  if type(record) ~= "table" or not record.component then
    return "?"
  end
  return tostring(record.component):sub(1, 8) .. ":" .. tostring(record.face)
end

--- The local computer address, or nil if the sandbox does not expose it.
function addr.localNode()
  local ok, value = pcall(computer.address)
  if ok and type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

function addr.new(options)
  local self = setmetatable({}, addr)
  options = options or {}
  self.vfs = options.vfs
  self.log = options.log
  self.seen = {}
  self.dirty = false
  self:load()
  return self
end

--- Load first-seen times from /var/plant/seen.tsv. A missing file is normal.
function addr:load()
  if not self.vfs then
    return true
  end
  local text = self.vfs.read(SEEN_PATH)
  if not text then
    return true
  end
  for line in text:gmatch("[^\r\n]+") do
    local value = line:gsub("#.*$", "")
    local component, first = value:match("^(%S+)%s+(%d+)$")
    if component then
      self.seen[component] = tonumber(first)
    end
  end
  return true
end

function addr:save()
  if not self.vfs then
    return true
  end
  self.vfs.ensureDir("/var/plant")
  local names = {}
  for component in pairs(self.seen) do
    names[#names + 1] = component
  end
  table.sort(names)
  local lines = { "# TerraCorp: component first-seen (uptime seconds)" }
  for _, component in ipairs(names) do
    lines[#lines + 1] = component .. "\t" .. tostring(self.seen[component])
  end
  local ok, reason = self.vfs.write(SEEN_PATH, table.concat(lines, "\n") .. "\n")
  if not ok then
    if self.log then
      self.log.warn("Could not save " .. SEEN_PATH .. ": " .. tostring(reason))
    end
    return false
  end
  self.dirty = false
  return true
end

--- Scan the local component tree. `kind` is optional. Returns sorted records:
-- { address, kind, first_seen, age }. This is a local component.list, not a
-- host component call.
function addr:scan(kind)
  local now = computer.uptime()
  local records = {}
  for address, componentKind in component.list(kind) do
    if self.seen[address] == nil then
      self.seen[address] = now
      self.dirty = true
    end
    records[#records + 1] = {
      address = address,
      kind = componentKind,
      first_seen = self.seen[address],
      age = math.max(0, now - self.seen[address]),
    }
  end
  table.sort(records, function(a, b)
    if a.kind == b.kind then
      return a.address < b.address
    end
    return a.kind < b.kind
  end)
  if self.dirty then
    self:save()
  end
  return records
end

--- Resolve a proxy only when the address belongs to this computer.
function addr.proxy(record)
  local parsed = record
  if type(record) == "string" then
    parsed = addr.parse(record)
    if not parsed then
      return nil, "invalid address"
    end
  elseif type(record) ~= "table" then
    return nil, "invalid address"
  end
  if parsed.node ~= addr.localNode() then
    return nil, "remote node"
  end
  local ok, proxy = pcall(component.proxy, parsed.component)
  if not ok or not proxy then
    return nil, "component unavailable"
  end
  return proxy, parsed
end

return addr
