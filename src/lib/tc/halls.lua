-- Hall registry and merged view.
--
-- A hall is one computer with its own stocks and paths. /etc/halls.tsv maps a
-- hall name to its address; the local computer resolves itself from that table
-- and the merged view prefixes each stock with its hall. There is no gateway
-- and no DNS: a hall that has not reported is `offline`, and one whose last
-- snapshot is old is `stale`, never silently dropped.

local halls = {}

halls.PATH = "/etc/halls.tsv"
halls.MAX_HALLS = 16
halls.STALE_AFTER = 30

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function splitTabs(value)
  local parts = {}
  for piece in (value .. "\t"):gmatch("([^\t]*)\t") do
    parts[#parts + 1] = piece
  end
  return parts
end

function halls.new()
  return {
    list = {},
    byName = {},
    byAddress = {},
    errors = {},
    configured = false,
  }
end

function halls.load(vfs, path)
  local registry = halls.new()
  if not vfs then
    return registry
  end
  local text = vfs.read(path or halls.PATH)
  if type(text) ~= "string" then
    return registry
  end

  local number = 0
  for raw in text:gmatch("[^\r\n]+") do
    number = number + 1
    local value = trim(raw:gsub("#.*$", ""))
    if value ~= "" then
      local fields = splitTabs(value)
      local name, address = fields[1], fields[2]
      if not name or not name:match("^[%w_%-%.]+$") then
        registry.errors[#registry.errors + 1] = {
          line = number,
          message = "invalid hall name: " .. tostring(name),
        }
      elseif not address or address == "" or address:find("%s") then
        registry.errors[#registry.errors + 1] = {
          line = number,
          message = "invalid hall address: " .. tostring(address),
        }
      elseif registry.byName[name] then
        registry.errors[#registry.errors + 1] = {
          line = number,
          message = "duplicate hall: " .. name,
        }
      elseif registry.byAddress[address] then
        registry.errors[#registry.errors + 1] = {
          line = number,
          message = "address already belongs to " .. registry.byAddress[address].name,
        }
      elseif #registry.list >= halls.MAX_HALLS then
        registry.errors[#registry.errors + 1] = {
          line = number,
          message = "too many halls (max " .. halls.MAX_HALLS .. ")",
        }
      else
        local record = { name = name, address = address }
        registry.list[#registry.list + 1] = record
        registry.byName[name] = record
        registry.byAddress[address] = record
      end
    end
  end
  registry.configured = #registry.list > 0
  return registry
end

--- Resolve the hall this computer belongs to. Without a row, the hostname (or
-- "local") names an implicit local hall so a single-machine plant still has a
-- stable name.
function halls.localHall(registry, address, hostname)
  local record = registry and registry.byAddress and registry.byAddress[address]
  if record then
    return { name = record.name, address = address, isLocal = true, implicit = false }
  end
  local name = tostring(hostname or "local")
  if not name:match("^[%w_%-%.]+$") then
    name = "local"
  end
  return { name = name, address = address, isLocal = true, implicit = true }
end

--- Merge one snapshot per hall. `snapshots[address]` is
-- `{ snapshot = <plant snapshot>, age = <seconds> }`. Missing snapshots are
-- offline; old ones are stale; both keep their name and address, and only a
-- fresh snapshot contributes stocks.
function halls.merge(registry, snapshots, options)
  options = options or {}
  snapshots = snapshots or {}
  local staleAfter = tonumber(options.staleAfter) or halls.STALE_AFTER

  local result = {
    halls = {},
    stocks = {},
    online = 0,
    stale = 0,
    offline = 0,
  }

  for _, hall in ipairs((registry and registry.list) or {}) do
    local entry = snapshots[hall.address]
    local record = {
      name = hall.name,
      address = hall.address,
      state = "offline",
      age = nil,
    }
    if entry and type(entry.snapshot) == "table" then
      local age = tonumber(entry.age)
      record.age = age
      if age and age > staleAfter then
        record.state = "stale"
        result.stale = result.stale + 1
      else
        record.state = "online"
        result.online = result.online + 1
      end
      for _, stock in ipairs(entry.snapshot.stocks or {}) do
        result.stocks[#result.stocks + 1] = {
          hall = hall.name,
          name = hall.name .. "/" .. tostring(stock.name),
          kind = stock.kind,
          state = stock.state,
          total = stock.total,
          rate = stock.rate,
          trend = stock.trend,
          entries = stock.entries,
          age = stock.age,
        }
      end
      record.stocks = #(entry.snapshot.stocks or {})
    else
      result.offline = result.offline + 1
      record.stocks = 0
    end
    result.halls[#result.halls + 1] = record
  end

  return result
end

--- Add a hall to /etc/halls.tsv. Used by the Nodes app or the link; the file
-- stays the source of truth.
function halls.assign(registry, name, address)
  if not registry or type(registry.list) ~= "table" then
    return nil, "invalid_registry"
  end
  if type(name) ~= "string" or not name:match("^[%w_%-%.]+$") then
    return nil, "invalid_hall"
  end
  if type(address) ~= "string" or address == "" or address:find("%s") then
    return nil, "invalid_address"
  end
  local existing = registry.byName[name]
  if existing then
    registry.byAddress[existing.address] = nil
    existing.address = address
    registry.byAddress[address] = existing
    return existing
  end
  if #registry.list >= halls.MAX_HALLS then
    return nil, "too_many_halls"
  end
  local record = { name = name, address = address }
  registry.list[#registry.list + 1] = record
  registry.byName[name] = record
  registry.byAddress[address] = record
  registry.configured = true
  return record
end

function halls.save(vfs, registry, path)
  if not vfs then
    return nil, "invalid_vfs"
  end
  vfs.ensureDir("/etc")
  local lines = { "# TerraCorp: halls (name, address)" }
  for _, hall in ipairs((registry and registry.list) or {}) do
    lines[#lines + 1] = hall.name .. "\t" .. hall.address
  end
  local ok, reason = vfs.write(path or halls.PATH, table.concat(lines, "\n") .. "\n")
  if not ok then
    return nil, reason
  end
  return true
end

return halls
