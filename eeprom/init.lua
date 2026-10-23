-- TerraCorp OS - gestor de arranque para la EEPROM del ordenador.
--
-- Se graba tal cual en la EEPROM (ver tools/install.lua). Su única tarea es
-- elegir un volumen con TerraCorp OS, fijarlo como volumen de arranque y ceder
-- el control a su /init.lua.
--
-- Entorno garantizado: `component` y `computer`.

local component, computer = component, computer

local function invoke(address, method, ...)
  local result = table.pack(pcall(component.invoke, address, method, ...))
  if not result[1] then
    return nil, tostring(result[2])
  end
  return table.unpack(result, 2, result.n)
end

-- En OpenComputers 1.7.x el entorno de la EEPROM NO trae
-- `computer.getBootAddress`/`setBootAddress`: las define el BIOS estándar al
-- arrancar (guardando el volumen en la propia EEPROM con getData/setData). Si
-- la EEPROM lleva este gestor, hay que crearlas aquí o el arranque revienta.
local eepromAddress = component.list("eeprom")()

if type(computer.getBootAddress) ~= "function" then
  computer.getBootAddress = function()
    if not eepromAddress then
      return nil
    end
    local data = invoke(eepromAddress, "getData")
    return data
  end
end

if type(computer.setBootAddress) ~= "function" then
  computer.setBootAddress = function(address)
    if not eepromAddress then
      return nil, "sin EEPROM"
    end
    local ok, reason = invoke(eepromAddress, "setData", address)
    if ok == nil then
      return nil, reason
    end
    return true
  end
end

local function read(address, path)
  local handle, reason = invoke(address, "open", path, "r")
  if not handle then
    return nil, reason or ("no se pudo abrir " .. path)
  end

  local chunks = {}
  while true do
    local data, why = invoke(address, "read", handle, 4096)
    if type(data) ~= "string" or data == "" then
      invoke(address, "close", handle)
      if why then
        return nil, why
      end
      break
    end
    chunks[#chunks + 1] = data
  end

  invoke(address, "close", handle)
  return table.concat(chunks)
end

local function isBootable(address)
  local handle = invoke(address, "open", "/boot/kernel.lua", "r")
  if not handle then
    return false
  end
  invoke(address, "close", handle)
  return true
end

local address = computer.getBootAddress()
if not isBootable(address) then
  address = nil
  for candidate in component.list("filesystem") do
    if isBootable(candidate) then
      address = candidate
      pcall(computer.setBootAddress, candidate)
      break
    end
  end
end

if not address then
  error("TerraCorp OS: la EEPROM no encuentra un volumen de arranque válido", 0)
end

local source, reason = read(address, "/init.lua")
if not source then
  error("TerraCorp OS: " .. tostring(reason), 0)
end

local chunk, compileError = load(source, "=init")
if not chunk then
  error("TerraCorp OS: /init.lua inválido: " .. tostring(compileError), 0)
end

return chunk()
