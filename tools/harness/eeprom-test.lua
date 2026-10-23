-- Prueba de eeprom/init.lua con el entorno de la EEPROM simulado.
-- El runner inyecta EEPROM_SOURCE (contenido de eeprom/init.lua).
-- uso: node test-boot.js <escenario 175|18>
local scenario = ...

local volumes = {}
local storedAddress = nil
local handles = {}
local nextHandle = 0
local booted = false
local patched = false

local function volume(address, files)
  volumes[address] = files
end

volume("floppy-01", { ["/init.lua"] = "return 'openos'" })
volume("hdd-02", {
  ["/boot/kernel.lua"] = "-- kernel",
  ["/init.lua"] = "BOOTED = (BOOTED or 0) + 1; return 'terracorp'",
})

local order = { "eeprom-0", "floppy-01", "hdd-02" }
local kinds = { ["eeprom-0"] = "eeprom", ["floppy-01"] = "filesystem", ["hdd-02"] = "filesystem" }

local component = {}

function component.list(kind)
  local index = 0
  return function()
    index = index + 1
    local address = order[index]
    while address and kind and kinds[address] ~= kind do
      index = index + 1
      address = order[index]
    end
    if address then
      return address, kinds[address]
    end
  end
end

function component.invoke(address, method, ...)
  if address == "eeprom-0" then
    if method == "getData" then
      return storedAddress
    elseif method == "setData" then
      storedAddress = (...)
      return true
    end
    return nil, "método desconocido: " .. tostring(method)
  end

  local files = volumes[address]
  if not files then
    return nil, "sin volumen"
  end

  if method == "open" then
    local path, mode = ...
    local content = files[path]
    if not content then
      return nil, "no such file"
    end
    nextHandle = nextHandle + 1
    handles[nextHandle] = { content = content, position = 1 }
    return nextHandle
  elseif method == "read" then
    local handle, count = ...
    local state = handles[handle]
    if not state then
      return nil, "handle inválido"
    end
    if state.position > #state.content then
      return nil
    end
    local chunk = state.content:sub(state.position, state.position + (count or 4096) - 1)
    state.position = state.position + #chunk
    return chunk
  elseif method == "close" then
    handles[(...)] = nil
    return true
  end

  return nil, "método desconocido: " .. tostring(method)
end

local computer = {}

if scenario == "18" then
  -- 1.8+: la API ya viene en el sandbox.
  computer.getBootAddress = function() return storedAddress end
  computer.setBootAddress = function(address) storedAddress = address; return true end
  patched = false
else
  -- 1.7.x: no existe; el script debe crearla.
  patched = true
end

local sandbox = {
  component = component,
  computer = computer,
  table = table,
  string = string,
  math = math,
  utf8 = utf8,
  tostring = tostring,
  tonumber = tonumber,
  type = type,
  pcall = pcall,
  error = error,
  print = print,
  next = next,
  ipairs = ipairs,
  pairs = pairs,
  select = select,
  setmetatable = setmetatable,
  getmetatable = getmetatable,
  rawget = rawget,
  rawset = rawset,
  assert = assert,
}
sandbox._G = sandbox
sandbox.load = function(source, name, mode, env)
  return load(source, name, mode or "t", env or sandbox)
end

local chunk = assert(load(EEPROM_SOURCE, "=bios", "t", sandbox))
chunk()

assert(type(computer.getBootAddress) == "function", "no creó getBootAddress")
assert(type(computer.setBootAddress) == "function", "no creó setBootAddress")
assert(storedAddress == "hdd-02", "boot address = " .. tostring(storedAddress))
assert(sandbox.BOOTED == 1, "/init.lua del volumen bueno no se ejecutó")
assert(computer.getBootAddress() == "hdd-02", "getBootAddress no lee la EEPROM")

if scenario == "18" then
  assert(not patched, "no debería parchear si la API existe")
else
  assert(patched, "escenario 1.7.x sin API")
end

print("OK arranque " .. scenario)
