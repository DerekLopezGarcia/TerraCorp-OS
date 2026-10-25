-- TerraCorp OS boot-volume entry point.
--
-- Loaded by the OpenComputers BIOS (or the optional EEPROM manager). It must
-- run in the minimal environment, which guarantees `component` and `computer`.
-- Do not use OpenOS `require`, `fs`, or `event` here.

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
    return nil, reason or ("could not open " .. path)
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

local function bootAddress()
  if type(computer.getBootAddress) ~= "function" then
    return nil
  end
  local ok, value = pcall(computer.getBootAddress)
  if not ok then
    return nil
  end
  return value
end

local function setBootAddress(address)
  if type(computer.setBootAddress) ~= "function" then
    return false
  end
  local ok, result = pcall(computer.setBootAddress, address)
  return ok and result ~= false
end

local function findVolume()
  local preferred = bootAddress()
  if isBootable(preferred) then
    return preferred
  end

  for address in component.list("filesystem") do
    if isBootable(address) then
      setBootAddress(address)
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
  error("TerraCorp OS: no boot volume contains /boot/kernel.lua", 0)
end

bindScreen()

local source, reason = read(address, "/boot/kernel.lua")
if not source then
  error("TerraCorp OS: " .. tostring(reason), 0)
end

local chunk, compileError = load(source, "=boot/kernel.lua")
if not chunk then
  error("TerraCorp OS: invalid kernel: " .. tostring(compileError), 0)
end

local kernel = chunk()
return kernel.start({
  address = address,
  invoke = invoke,
  read = function(path)
    return read(address, path)
  end,
})
