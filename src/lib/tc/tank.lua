-- Fluid entries for tank stocks. The Transposer returns an array of tank
-- descriptions; one entry has name, label, amount, capacity and hasTag. This
-- module normalizes and aggregates them without touching a component.

local tank = {}

function tank.entry(value)
  if type(value) ~= "table" then
    return nil
  end
  local key = value.name or value.key
  if type(key) ~= "string" or key == "" then
    return nil
  end
  return {
    kind = "fluid",
    key = key,
    label = value.label or key,
    amount = tonumber(value.amount) or tonumber(value.size) or 0,
    capacity = tonumber(value.capacity) or 0,
    hasTag = value.hasTag == true,
  }
end

function tank.merge(entries, value)
  local entry = tank.entry(value)
  if not entry then
    return nil
  end
  local current = entries[entry.key]
  if not current then
    entries[entry.key] = entry
    return entry
  end
  current.amount = current.amount + entry.amount
  if entry.capacity > current.capacity then
    current.capacity = entry.capacity
  end
  if entry.label and entry.label ~= "" then
    current.label = entry.label
  end
  current.hasTag = current.hasTag or entry.hasTag
  return current
end

function tank.total(entries)
  local total = 0
  for _, entry in pairs(entries or {}) do
    total = total + (tonumber(entry.amount) or 0)
  end
  return total
end

return tank
