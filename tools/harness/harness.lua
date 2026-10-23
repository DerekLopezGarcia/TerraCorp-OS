-- Arnés de ejecución de TerraCorp OS fuera de Minecraft: componentes falsos,
-- disco en memoria (volcado desde el repo real por gen.js), GPU que rasteriza
-- en una matriz y señales guionizadas. Detecta errores de ejecución.

local files = BUNDLE
local STRICT = STRICT == true
-- Inyección de fallos: la GPU real devuelve nil, "not enough energy" cuando no
-- tiene energía. FAULT.set = N hace que las primeras N escrituras fallen, para
-- comprobar que el OS reintenta y acaba pintando la pantalla.
local FAULT = rawget(_G, "FAULT") or {}
local faultsLeft = tonumber(FAULT.set) or 0
local faultsInjected = 0
local stats = { listCalls = 0, listReturned = 0, spaceCalls = 0 }
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

-- El sistema de ficheros real exige que el directorio padre exista para
-- abrir en escritura; sin esto el arnés oculta fallos de `ensureDir`.
local function isDirectoryPath(path)
  if path == "/" or directories[path] then
    return true
  end
  local prefix = path .. "/"
  for full in pairs(files) do
    if full:sub(1, #prefix) == prefix then return true end
  end
  for full in pairs(written) do
    if full:sub(1, #prefix) == prefix then return true end
  end
  for full in pairs(directories) do
    if full:sub(1, #prefix) == prefix then return true end
  end
  return false
end

local function parentOf(path)
  local parent = path:match("^(.*)/[^/]+$")
  if not parent or parent == "" then
    return "/"
  end
  return parent
end

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
    if not isDirectoryPath(parentOf(path)) then
      return nil, "no such file or directory: " .. tostring(path)
    end
    written[path] = ""
    handle = { kind = "w", path = path }
  elseif mode == "a" or mode == "ab" then
    if not isDirectoryPath(parentOf(path)) then
      return nil, "no such file or directory: " .. tostring(path)
    end
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

-- El componente `filesystem` real devuelve una tabla 1..n con los nombres
-- (`list` es `String[]` en FileSystem.scala y se convierte a tabla Lua).
function fsApi.list(path)
  local names = entriesUnder(path)
  stats.listCalls = stats.listCalls + 1
  stats.listReturned = stats.listReturned + #names
  return names
end

function fsApi.size(path)
  local content = readReal(path)
  if not content then
    return 0
  end
  return #content
end

-- OpenComputers expone `spaceUsed`/`spaceTotal`, en bytes. `space()` no existe.
function fsApi.spaceUsed()
  stats.spaceCalls = stats.spaceCalls + 1
  return 131072
end

function fsApi.spaceTotal()
  return 4194304
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
-- Resolución máxima de la pantalla simulada; el guion puede cambiarla para
-- probar el mismo OS en monitores pequeños y grandes.
local maxWidth = tonumber(rawget(_G, "MAX_WIDTH")) or 160
local maxHeight = tonumber(rawget(_G, "MAX_HEIGHT")) or 50
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
  return maxWidth, maxHeight
end

function gpu.setResolution(w, h)
  if w < 1 or h < 1 or w > maxWidth or h > maxHeight then
    return false
  end
  width, height = w, h
  resetScreen()
  return true
end

-- Igual que el componente: devuelven true si escriben y nil, motivo si la GPU
-- no tiene energía. El OS usa ese valor para reintentar el tramo.
function gpu.setBackground()
  return true
end

function gpu.setForeground()
  return true
end

function gpu.getBackground()
  return 15
end

function gpu.getForeground()
  return 0
end

function gpu.set(x, y, value)
  setCalls = setCalls + 1
  if faultsLeft > 0 then
    faultsLeft = faultsLeft - 1
    faultsInjected = faultsInjected + 1
    return nil, "not enough energy"
  end
  if not cells[y] then
    return true
  end
  local column = x
  for _, code in utf8.codes(value) do
    if cells[y][column] then
      cells[y][column] = utf8.char(code)
    end
    column = column + 1
  end
  return true
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
  return true
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
-- Guion de interacción (anclado a la resolución simulada, no a filas fijas)
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

-- Los guiones se anclan a la resolución simulada, no a columnas fijas: el dock
-- está en la penúltima fila y las ventanas son proporcionales a la pantalla.
local dockY = maxHeight - 1

-- Misma geometría que `ui:defaultGeometry` para la primera ventana (offset 0).
-- Sólo sirve para apuntar los gestos del ratón; si el diseño cambia, el gesto
-- puede caer fuera y el escenario deja de cubrirlo, pero no falla en falso.
local function windowRect()
  local desktopTop = 3
  local desktopBottom = dockY - 1
  local usable = desktopBottom - desktopTop + 1
  local w = math.min(maxWidth - 4, math.max(34, math.floor(maxWidth * 0.74)))
  local h = math.min(usable - 1, math.max(10, math.floor(usable * 0.84)))
  local x = math.floor((maxWidth - w) / 2)
  local y = desktopTop + math.max(0, math.floor((usable - h) / 2))
  return x, y, w, h
end

if scenario == "dashboard" then
  ev("touch", "screen-1", 3, dockY, 0, "tester")
  idle(12)
elseif scenario == "console" then
  ev("key_down", "screen-1", nil, 0x3D, "tester")
  typeText("help")
  ev("key_down", "screen-1", nil, 0x1C, "tester")
  idle(2)
elseif scenario == "files" then
  -- Teclado: la lista se navega igual en cualquier tamaño de pantalla.
  ev("key_down", "screen-1", nil, 0x3C, "tester")   -- F2 abre Ficheros
  idle(1)
  ev("key_down", "screen-1", nil, 0xD0, "tester")   -- abajo x3 hasta /lib
  ev("key_down", "screen-1", nil, 0xD0, "tester")
  ev("key_down", "screen-1", nil, 0xD0, "tester")
  ev("key_down", "screen-1", nil, 0x1C, "tester")   -- entra
  idle(1)
  ev("key_down", "screen-1", nil, 0xD0, "tester")   -- baja un nivel más
  ev("key_down", "screen-1", nil, 0x1C, "tester")   -- entra
  ev("key_down", "screen-1", nil, 0x0E, "tester")   -- vuelve atrás
  idle(2)
elseif scenario == "settings" then
  ev("touch", "screen-1", 40, dockY, 0, "tester")
  idle(3)
else
  local wx, wy = windowRect()
  ev("touch", "screen-1", 3, dockY, 0, "tester")     -- abre Panel
  ev("touch", "screen-1", wx + 2, wy, 0, "tester")   -- agarra la barra de título
  ev("drop", "screen-1", wx + 3, wy + 1, 0, "tester")
  ev("scroll", "screen-1", wx + 2, wy + 1, 1, "tester")
  ev("key_down", "screen-1", "r", 0x13, "tester")
  ev("key_down", "screen-1", nil, 0x3D, "tester")
  typeText("help")
  ev("key_down", "screen-1", nil, 0x1C, "tester")
  ev("key_down", "screen-1", nil, 0x3F, "tester")
end

-- ---------------------------------------------------------------------------
-- Ejecución
-- ---------------------------------------------------------------------------

local chunk, loadError = load(files["/init.lua"], "=/init.lua")
if not chunk then
  print("NO SE PUDO COMPILAR /init.lua: " .. tostring(loadError))
  TC_ERRORS = 1
  return
end

local ok, failure = pcall(chunk)
print("")
print("=== EJECUCIÓN ===")
print("resultado : " .. (ok and "ok" or ("ERROR: " .. tostring(failure))))
print("apagado   : " .. tostring(shutdownFlag))
print("llamadas gpu.set: " .. setCalls)
if faultsInjected > 0 then
  print("fallos inyectados: " .. faultsInjected .. " (sin energía)")
end
print("resolución: " .. width .. "x" .. height)
print("escenario : " .. tostring(scenario) .. (STRICT and " (estricto)" or ""))

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

-- Comprobaciones estrictas: verifican el resultado visible, no solo que se
-- llamó al componente. Si el OS deja de hablar la API real, el error acaba
-- pintado en pantalla y esto lo detecta.
if STRICT then
  local rows = {}
  for y = 1, height do
    rows[#rows + 1] = table.concat(cells[y])
  end
  local screen = table.concat(rows, "\n")

  if screen:find("no se pudo listar", 1, true) then
    errors = errors + 1
    print("FALLO: la app Ficheros no pudo listar (¿se espera un iterador en vez de tabla?)")
  end
  if screen:find("No se pudo leer el disco", 1, true) then
    errors = errors + 1
    print("FALLO: el panel no pudo leer el volumen (spaceUsed/spaceTotal)")
  end
  if scenario == "files" and stats.listReturned == 0 then
    errors = errors + 1
    print("FALLO: el escenario de Ficheros no listó ningún directorio")
  end
  if scenario == "dashboard" and stats.spaceCalls == 0 then
    errors = errors + 1
    print("FALLO: el panel no consultó spaceUsed")
  end

  -- Tras inyectar fallos de GPU la pantalla debe acabar pintada: si el OS da
  -- por buenas las escrituras que la GPU rechazó, se queda en negro para
  -- siempre porque el volcado por diferencias nunca las reintenta.
  if faultsInjected > 0 then
    local visible = 0
    for y = 1, height do
      for x = 1, width do
        if cells[y][x] ~= " " then
          visible = visible + 1
        end
      end
    end
    if visible == 0 then
      errors = errors + 1
      print("FALLO: pantalla en negro después de que la GPU rechazara escrituras")
    end
  end
end

print("")
print("=== VEREDICTO ===")
print("list: " .. stats.listCalls .. " llamadas, " .. stats.listReturned .. " entradas · spaceUsed: " .. stats.spaceCalls)
print(errors == 0 and "sin errores" or (errors .. " problema(s)"))

TC_ERRORS = errors
