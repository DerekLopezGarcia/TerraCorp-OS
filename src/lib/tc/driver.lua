-- Declarative component drivers.
--
-- A driver says how to call a block, never what the plant should do. The first
-- version ships built-in descriptors for the blocks the probe verified; the
-- registry is data and is never executed from /etc. A new kind is a kernel
-- decision, not a config escape hatch (decision 22).

local driver = {}

local function inventory()
  return {
    name = { method = "getInventoryName", args = { "side" } },
    size = { method = "getInventorySize", args = { "side" } },
    all = { method = "getAllStacks", args = { "side" } },
    slot = { method = "getStackInSlot", args = { "side", "slot" } },
    key = { fields = { "name", "damage" } },
    count = { field = "size" },
  }
end

local function tank()
  return {
    count = { method = "getTankCount", args = { "side" } },
    fluid = { method = "getFluidInTank", args = { "side", "tank" } },
    level = { method = "getTankLevel", args = { "side", "tank" } },
    capacity = { method = "getTankCapacity", args = { "side", "tank" } },
    key = { fields = { "name" } },
  }
end

local BUILTINS = {
  transposer = {
    kind = "transposer",
    sides = true,
    capabilities = { inventory = inventory(), tank = tank() },
  },
  tank_controller = {
    kind = "tank_controller",
    sides = true,
    capabilities = { tank = tank() },
  },
  power_substation = {
    kind = "power_substation",
    sides = false,
    capabilities = {
      energy = {
        stored = { method = "getStored", number = "formatted" },
        capacity = { method = "getCapacity", number = "formatted" },
        input = { method = "getAverageInLastSec", number = "number" },
        output = { method = "getAverageOutLastSec", number = "number" },
        drain = { method = "getPassiveDrain", number = "number" },
      },
    },
  },
  redstone = {
    kind = "redstone",
    sides = true,
    capabilities = {
      redstone = {
        input = { method = "getInput", args = { "side" } },
        output = { method = "setOutput", args = { "side" } },
      },
    },
  },
}

function driver.new()
  local registry = { kinds = {}, faces = {} }
  driver.reload(registry)
  return registry
end

function driver.reload(registry)
  registry.kinds = {}
  registry.faces = {}
  local count = 0
  for kind, descriptor in pairs(BUILTINS) do
    registry.kinds[kind] = descriptor
    count = count + 1
  end
  -- Face kinds are what a Transposer reports via getInventoryName, not
  -- component kinds. A pipe has an inventory-shaped face but is transport.
  registry.faces["gregtech:machine"] = "inventory"
  registry.faces["minecraft:chest"] = "inventory"
  registry.faces["minecraft:hopper"] = "inventory"
  registry.faces["storagedrawers:basicdrawers"] = "inventory"
  return count
end

function driver.get(registry, kind)
  return registry and registry.kinds and registry.kinds[kind] or nil
end

function driver.list(registry)
  local names = {}
  for kind, descriptor in pairs((registry and registry.kinds) or {}) do
    names[#names + 1] = { kind = kind, capabilities = driver.capabilities(descriptor) }
  end
  table.sort(names, function(a, b)
    return a.kind < b.kind
  end)
  return names
end

function driver.capabilities(descriptor)
  local names = {}
  if descriptor and descriptor.capabilities then
    for name in pairs(descriptor.capabilities) do
      names[#names + 1] = name
    end
    table.sort(names)
  end
  return names
end

function driver.has(registry, kind, capability)
  local descriptor = driver.get(registry, kind)
  return descriptor ~= nil
    and descriptor.capabilities ~= nil
    and descriptor.capabilities[capability] ~= nil
end

--- Classify a Transposer face by the inventory name it reports.
function driver.faceKind(name)
  if type(name) ~= "string" then
    return "unknown"
  end
  if name:find("item_pipe", 1, true) or name:find("fluid_pipe", 1, true)
    or name:find("cable", 1, true) then
    return "transfer"
  end
  if name:find("drum", 1, true) or name:find("tank", 1, true) then
    return "tank"
  end
  if name == "gregtech:machine" or name:find("chest", 1, true)
    or name:find("drawers", 1, true) or name:find("barrel", 1, true)
    or name:find("crate", 1, true) or name:find("hopper", 1, true) then
    return "inventory"
  end
  return "unknown"
end

--- Invoke a descriptor operation with named values. Returns the packed
-- results, or nil and a reason. This is the only call path the stock reader
-- uses, so a missing method is a named failure, not a crash.
function driver.invoke(proxy, operation, values)
  if type(proxy) ~= "table" and type(proxy) ~= "userdata" then
    return nil, "invalid proxy"
  end
  if type(operation) ~= "table" or type(operation.method) ~= "string" then
    return nil, "invalid operation"
  end
  local method = proxy[operation.method]
  if method == nil then
    return nil, "missing method " .. operation.method
  end
  local args = {}
  for index, name in ipairs(operation.args or {}) do
    args[index] = values and values[name]
  end
  -- Component proxy methods are plain functions, not self methods: the
  -- Transposer is called as getInventoryName(side), never :getInventoryName.
  local result = table.pack(pcall(method, table.unpack(args, 1, #args)))
  if not result[1] then
    return nil, tostring(result[2])
  end
  return table.unpack(result, 2, result.n)
end

--- Normalize a numeric read. The Power Substation returns formatted strings
-- such as "261,015,954,464"; a plain number passes through.
function driver.number(value)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    local text = value:gsub(",", ""):gsub("%s+", "")
    local number = tonumber(text)
    if number then
      return number
    end
  end
  return nil
end

--- Dump a component's methods and their documentation. This is data, safe to
-- move around and paste into a ticket.
function driver.dump(address)
  local ok, methods = pcall(component.methods, address)
  if not ok or type(methods) ~= "table" then
    return nil, "could not read component methods"
  end
  local names = {}
  for name in pairs(methods) do
    names[#names + 1] = tostring(name)
  end
  table.sort(names)
  local result = { address = address, methods = {} }
  local okType, kind = pcall(component.type, address)
  result.kind = okType and kind or nil
  for _, name in ipairs(names) do
    local okDoc, doc = pcall(component.doc, address, name)
    result.methods[#result.methods + 1] = {
      name = name,
      doc = okDoc and doc or nil,
    }
  end
  return result
end

return driver
