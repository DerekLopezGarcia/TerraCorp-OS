-- TerraCorp OS - punto de entrada del volumen de arranque.
--
-- Lo carga el BIOS de OpenComputers (o la EEPROM de tools/install.lua) y debe
-- funcionar con el entorno mínimo garantizado: `component` y `computer`.
-- No usa `require`, ni `fs`, ni `event`: OpenOS puede no estar instalado.

local component, computer = component, computer

local function invoke(address, method, ...)
  local result = table.pack(pcall(component.invoke, address, method, ...))
  if not result[1] then
    return nil, tostring(result[2])
  end
  return table.unpack(result, 2, result.n)
end

local function read(address, path)
  local handle, reason = invoke(address, "open", path, "r")
  if not handle then
    return nil, reason or ("no se pudo abrir " .. path)
  end

  local chunks = {}
  while true do
    local data, why = invoke(address, "read", handle, 4096)
    if not data then
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
  if not address then
    return false
  end

  local handle = invoke(address, "open", "/boot/kernel.lua", "r")
  if not handle then
    return false
  end

  invoke(address, "close", handle)
  return true
end

local function findVolume()
  local preferred = computer.getBootAddress()
  if isBootable(preferred) then
    return preferred
  end

  for address in component.list("filesystem") do
    if isBootable(address) then
      pcall(computer.setBootAddress, address)
      return address
    end
  end

  return nil
end

local function bindScreen()
  local gpu = component.list("gpu")()
  local screen = component.list("screen")()
  if not gpu or not screen then
    return false
  end

  local ok = pcall(component.invoke, gpu, "bind", screen)
  return ok
end

local address = findVolume()
if not address then
  error("TerraCorp OS: no hay volumen de arranque con /boot/kernel.lua", 0)
end

bindScreen()

local source, reason = read(address, "/boot/kernel.lua")
if not source then
  error("TerraCorp OS: " .. tostring(reason), 0)
end

local chunk, compileError = load(source, "=boot/kernel.lua")
if not chunk then
  error("TerraCorp OS: kernel inválido: " .. tostring(compileError), 0)
end

local kernel = chunk()
return kernel.start({
  address = address,
  invoke = invoke,
  read = function(path)
    return read(address, path)
  end,
})
