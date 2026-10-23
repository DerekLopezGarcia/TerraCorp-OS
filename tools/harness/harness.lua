-- Arnés de ejecución de TerraCorp OS fuera de Minecraft: componentes falsos,
-- disco en memoria (volcado desde el repo real por gen.js), GPU que rasteriza
-- en una matriz y señales guionizadas. Detecta errores de ejecución.

local files = BUNDLE
local written = {}
local directories = { ["/"] = true, ["/etc"] = true, ["/var"] = true, ["/var/log"] = true }
local handles = {}
local nextHandle = 0

local function readReal(path)
  if written[path] ~= nil then
    return written[path]
  end
  return files[path]
end

local function entriesUnder(path)
  local prefix = (path == "/") and "/" or (path .. "/")
  local seen, names = {}, {}

  local function consider(full)
    if full:sub(1, #prefix) ~= prefix then
      return
    end
    local rest = full:sub(#prefix + 1)
    local name = rest:match("^([^/]+)")
    if name and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end

  for full in pairs(files) do
    consider(full)
  end
  for full in pairs(written) do
    consider(full)
  end
  for full in pairs(directories) do
    consider(full)
  end

  table.sort(names)
  return names
end

local fsApi = {}

function fsApi.open(path, mode)
  mode = mode or "r"
  nextHandle = nextHandle + 1

  local handle
  if mode == "r" or mode == "rb" then
    local content = readReal(path)
    if not content then
      return nil, "no such file: " .. tostring(path)
    end
    handle = { kind = "r", content = content, position = 1 }
  elseif mode == "w" or mode == "wb" then
    written[path] = ""
    handle = { kind = "w", path = path }
  elseif mode == "a" or mode == "ab" then
    written[path] = readReal(path) or ""
    handle = { kind = "a", path = path }
  else
    return nil, "modo no soportado: " .. tostring(mode)
  end

  handles[nextHandle] = handle
  return nextHandle
end

function fsApi.read(id, count)
  local handle = handles[id]
  if not handle then
    return nil, "handle inválido"
  end
  if handle.kind ~= "r" then
    return nil
  end
  count = count or math.huge
  if handle.position > #handle.content then
    return nil
  end
  local chunk = handle.content:sub(handle.position, handle.position + count - 1)
  handle.position = handle.position + #chunk
  return chunk
end

function fsApi.write(id, data)
  local handle = handles[id]
  if not handle then
    return nil, "handle inválido"
  end
  if handle.kind == "r" then
    return nil, "handle de lectura"
  end
  written[handle.path] = written[handle.path] .. data
  return true
end

function fsApi.close(id)
  handles[id] = nil
  return true
end

function fsApi.exists(path)
  return readReal(path) ~= nil or directories[path] == true
end

function fsApi.isDirectory(path)
  if path == "/" or directories[path] then
    return true
  end
  return #entriesUnder(path) > 0
end

function fsApi.list(path)
  local names = entriesUnder(path)
  local index = 0
  return function()
    index = index + 1
    return names[index]
  end
end

function fsApi.size(path)
  local content = readReal(path)
  if not content then
    return 0
  end
  return #content
end

function fsApi.space()
  return 128
end

function fsApi.spaceTotal()
  return 4096
end

function fsApi.makeDirectory(path)
  directories[path] = true
  return true
end

function fsApi.remove(path)
  written[path] = nil
  return true
end

function fsApi.rename(from, to)
  written[to] = readReal(from)
  written[from] = nil
  return true
end

-- ---------------------------------------------------------------------------
-- GPU que rasteriza en memoria
-- ---------------------------------------------------------------------------

local width, height = 80, 25
local cells = {}
local setCalls = 0

local function resetScreen()
  cells = {}
  for y = 1, height do
    cells[y] = {}
    for x = 1, width do
      cells[y][x] = " "
    end
  end
end

local gpu = {}

function gpu.getResolution()
  return width, height
end

function gpu.maxResolution()
  return 160, 50
end

function gpu.setResolution(w, h)
  if w < 1 or h < 1 or w > 160 or h > 50 then
    return false
  end
  width, height = w, h
  resetScreen()
  return true
end

function gpu.setBackground()
end

function gpu.setForeground()
end

function gpu.getBackground()
  return 15
end

function gpu.getForeground()
  return 0
end

function gpu.set(x, y, value)
  setCalls = setCalls + 1
  if not cells[y] then
    return
  end
  local column = x
  for _, code in utf8.codes(value) do
    if cells[y][column] then
      cells[y][column] = utf8.char(code)
    end
    column = column + 1
  end
end

function gpu.fill(x, y, w, h, character)
  for row = y, y + h - 1 do
    if cells[row] then
      for column = x, x + w - 1 do
        if cells[row][column] then
          cells[row][column] = character
        end
      end
    end
  end
end

resetScreen()

-- ---------------------------------------------------------------------------
-- Componentes y ordenador
-- ---------------------------------------------------------------------------

local kinds = {
  ["gpu-1"] = "gpu",
  ["screen-1"] = "screen",
  ["fs-boot"] = "filesystem",
  ["eeprom-1"] = "eeprom",
}

local kindOrder = { "eeprom-1", "fs-boot", "gpu-1", "screen-1" }

component = {}

function component.list(kind)
  local result = {}
  for _, address in ipairs(kindOrder) do
    if not kind or kinds[address] == kind then
      result[#result + 1] = address
    end
  end
  local index = 0
  return function()
    index = index + 1
    local address = result[index]
    if address then
      return address, kinds[address]
    end
  end
end

function component.proxy(address)
  if address == "fs-boot" then
    return fsApi
  elseif address == "gpu-1" then
    return gpu
  end
  return nil
end

function component.invoke(address, method, ...)
  if address == "fs-boot" then
    local fn = fsApi[method]
    if not fn then
      return nil, "método desconocido: " .. tostring(method)
    end
    return fn(...)
  elseif address == "gpu-1" and method == "bind" then
    return true
  end
  return true
end

local clock = 0
local shutdownFlag = false
local scripted = {}

local function ev(...)
  scripted[#scripted + 1] = table.pack(...)
end

computer = {}

function computer.uptime()
  return clock
end

function computer.pullSignal()
  clock = clock + 0.25
  if #scripted == 0 then
    return "shutdown"
  end
  local item = table.remove(scripted, 1)
  return table.unpack(item, 1, item.n)
end

function computer.address()
  return "abc12345-6789-4abc-8def-001122334455"
end

function computer.getBootAddress()
  return "fs-boot"
end

function computer.setBootAddress()
  return true
end

function computer.energy()
  return 8200, 10000
end

function computer.maxEnergy()
  return 10000
end

function computer.totalMemory()
  return 2097152
end

function computer.freeMemory()
  return 1600000
end

function computer.shutdown()
  shutdownFlag = true
  return true
end

-- ---------------------------------------------------------------------------
-- Guion de interacción (pantalla final 118x44, dock en la fila 43)
-- ---------------------------------------------------------------------------

local scenario = SCENARIO or "all"

local function idle(count)
  for _ = 1, count do
    ev("component_added", "x", "y")
  end
end

local function typeText(value)
  for character in value:gmatch(".") do
    ev("key_down", "screen-1", character, nil, "tester")
  end
end

if scenario == "dashboard" then
  ev("touch", "screen-1", 3, 43, 0, "tester")
  idle(12)
elseif scenario == "console" then
  ev("key_down", "screen-1", nil, 0x3D, "tester")
  typeText("help")
  ev("key_down", "screen-1", nil, 0x1C, "tester")
  idle(2)
elseif scenario == "files" then
  ev("touch", "screen-1", 14, 43, 0, "tester")   -- abre Ficheros
  ev("touch", "screen-1", 20, 13, 0, "tester")   -- selecciona /lib (4.º: las carpetas van primero)
  ev("touch", "screen-1", 20, 13, 0, "tester")   -- entra en /lib
  ev("touch", "screen-1", 20, 10, 0, "tester")   -- selecciona /lib/tc
  ev("touch", "screen-1", 20, 10, 0, "tester")   -- entra en /lib/tc
  ev("touch", "screen-1", 20, 12, 0, "tester")   -- selecciona un módulo
  idle(2)
elseif scenario == "settings" then
  ev("touch", "screen-1", 40, 43, 0, "tester")
  idle(3)
else
  ev("touch", "screen-1", 3, 43, 0, "tester")
  ev("key_down", "screen-1", "r", 0x13, "tester")
  ev("key_down", "screen-1", nil, 0x3D, "tester")
  typeText("help")
  ev("key_down", "screen-1", nil, 0x1C, "tester")
  ev("key_down", "screen-1", nil, 0x3F, "tester")
  ev("touch", "screen-1", 40, 8, 0, "tester")
  ev("drop", "screen-1", 41, 9, 0, "tester")
  ev("scroll", "screen-1", 40, 8, 1, "tester")
end

-- ---------------------------------------------------------------------------
-- Ejecución
-- ---------------------------------------------------------------------------

local chunk, loadError = load(files["/init.lua"], "=/init.lua")
if not chunk then
  print("NO SE PUDO COMPILAR /init.lua: " .. tostring(loadError))
  os.exit(1)
end

local ok, failure = pcall(chunk)
print("")
print("=== EJECUCIÓN ===")
print("resultado : " .. (ok and "ok" or ("ERROR: " .. tostring(failure))))
print("apagado   : " .. tostring(shutdownFlag))
print("llamadas gpu.set: " .. setCalls)
print("resolución: " .. width .. "x" .. height)

print("")
print("=== PANTALLA FINAL ===")
for y = 1, height do
  print("|" .. table.concat(cells[y]) .. "|")
end

local journal = written["/var/log/tc.log"]
print("")
print("=== REGISTRO PERSISTIDO ===")
print(journal or "(vacío)")

local errors = 0
if not ok then
  errors = errors + 1
end
if journal and journal:find("ERR", 1, true) then
  errors = errors + 1
end
if setCalls == 0 then
  errors = errors + 1
end

print("")
print("=== VEREDICTO ===")
print(errors == 0 and "sin errores" or (errors .. " problema(s)"))
