-- Hall registry and merged view.
--
-- A hall is one computer with its own stocks and paths. There is no table on
-- disk any more: decision 26 made the node's own name the root of its paths, so
-- the plant builds a one-row registry in memory and this module merges it. There
-- is no gateway and no DNS either: a hall that has not reported is `offline`,
-- and one whose last snapshot is old is `stale`, never silently dropped.

local halls = {}

halls.MAX_HALLS = 16
halls.STALE_AFTER = 30

function halls.new()
  return {
    list = {},
    byName = {},
    byAddress = {},
    errors = {},
    configured = false,
  }
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

--- Add a hall to an in-memory registry. The plant builds the local one; a second
-- computer would be added the same way once the master merges views.
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

return halls
