-- Instalador de TerraCorp OS. Se ejecuta bajo OpenOS, no bajo TerraCorp OS.
--
--   install <raizDelRepo> [direccionFilesystem] [--eeprom] [--yes] [--list]
--
-- Copia src/ a la raíz del filesystem indicado, prepara /etc y /var/log,
-- fija el volumen de arranque y, opcionalmente, graba eeprom/init.lua.
-- Sin dirección, detecta el volumen: escribible, distinto del disco de OpenOS
-- y vacío o con una instalación previa de TerraCorp. Nunca elige un disco con
-- datos ajenos.

local component = require("component")
local computer = require("computer")
local filesystem = require("filesystem")
local shell = require("shell")
local term = require("term")

local args, options = shell.parse(...)

local repoRoot = args[1]
local address = args[2]

if not repoRoot then
  print("Uso: install <raizDelRepo> [direccionFilesystem] [--eeprom] [--yes] [--list]")
  print("Ejemplo: install /home/TerraCorp-OS")
  print("         install /home/TerraCorp-OS 1a2b3c4d-... --eeprom")
  return
end

repoRoot = shell.resolve(repoRoot)
local sourceRoot = filesystem.concat(repoRoot, "src")
local eepromSource = filesystem.concat(repoRoot, "eeprom/init.lua")

if not filesystem.isDirectory(sourceRoot) then
  io.stderr:write("No existe el árbol de origen: " .. sourceRoot .. "\n")
  return
end

--------------------------------------------------------------------------------
-- Detección del volumen de destino
--------------------------------------------------------------------------------

-- El OS necesita su hueco: por debajo de 1 MB no cabe. Esto descarta el tmpfs
-- de OpenOS (0.1 MB), que aparece como un filesystem vacío y escribible.
local MIN_BYTES = 1048576

-- Los handles de `filesystem` son los del componente: `read` espera un entero,
-- no acepta el formato "*a" de `io`.
local function readAll(handle)
  local chunks = {}
  while true do
    local chunk = handle:read(4096)
    if not chunk or chunk == "" then
      break
    end
    chunks[#chunks + 1] = chunk
  end
  return table.concat(chunks)
end

local function rootAddress()
  local ok, proxy = pcall(filesystem.get, "/")
  if ok and proxy and proxy.address then
    return proxy.address
  end
  return nil
end

local function countEntries(proxy)
  local ok, names = pcall(proxy.list, "")
  if not ok or type(names) ~= "table" then
    return 0
  end
  local total = 0
  for _ in pairs(names) do
    total = total + 1
  end
  return total
end

local function stateOf(proxy)
  local ok, exists = pcall(proxy.exists, "/boot/kernel.lua")
  if ok and exists then
    return "instalación existente"
  end
  if countEntries(proxy) == 0 then
    return "vacío"
  end
  return "con datos"
end

local function isWritable(proxy)
  local ok, readOnly = pcall(proxy.isReadOnly)
  return ok and readOnly == false
end

local function describe(item)
  local size = "sin límite"
  if item.size ~= math.huge then
    size = string.format("%.1f MB", item.size / 1048576)
  end
  return string.format("%s  %-20s %-16s %10s", item.address:sub(1, 8), item.state, item.label, size)
end

local function candidates()
  local root = rootAddress()
  local found = {}

  for candidate in component.list("filesystem") do
    if candidate ~= root then
      local proxy = component.proxy(candidate)
      if proxy and proxy.type == "filesystem" and isWritable(proxy) then
        local total = proxy.spaceTotal() or 0
        local state = stateOf(proxy)
        if state ~= "con datos" and total >= MIN_BYTES then
          found[#found + 1] = {
            address = candidate,
            proxy = proxy,
            state = state,
            label = (proxy.getLabel and proxy.getLabel()) or "sin etiqueta",
            size = total,
          }
        end
      end
    end
  end

  table.sort(found, function(a, b)
    return a.address < b.address
  end)

  return found
end

local function pick(found)
  if #found == 1 then
    print("Detectado: " .. describe(found[1]))
    return found[1]
  end

  print("Volúmenes donde puedo instalar:")
  for index, item in ipairs(found) do
    print(string.format("  %d) %s", index, describe(item)))
  end

  if options.yes then
    io.stderr:write("Hay varios candidatos: indica la dirección a mano.\n")
    return nil
  end

  io.write("¿En cuál instalo? [1] ")
  local answer = io.read("*l") or ""
  local index = tonumber(answer) or 1
  if not found[index] then
    io.stderr:write("Opción no válida.\n")
    return nil
  end

  return found[index]
end

local proxy

if options.list then
  local found = candidates()
  if #found == 0 then
    print("No hay volúmenes libres donde instalar.")
  end
  for _, item in ipairs(found) do
    print(describe(item))
  end
  return
end

if address then
  proxy = component.proxy(address)
  if not proxy or proxy.type ~= "filesystem" then
    io.stderr:write("La dirección no es un filesystem válido: " .. tostring(address) .. "\n")
    return
  end
else
  local found = candidates()
  if #found == 0 then
    io.stderr:write("No encuentro un volumen libre donde instalar.\n")
    io.stderr:write("Se ignoran los discos con datos y los de menos de 1 MB.\n")
    io.stderr:write("Conecta un disquete o un disco vacío, o pasa la dirección: install <raiz> <direccion>\n")
    return
  end

  local chosen = pick(found)
  if not chosen then
    return
  end

  proxy, address = chosen.proxy, chosen.address
end

print(string.format("Origen : %s", sourceRoot))
print(string.format("Destino: %s (%s)", address, proxy.getLabel and (proxy.getLabel() or "sin etiqueta") or "sin etiqueta"))

local used = proxy.spaceUsed()
local total = proxy.spaceTotal()
if used and total then
  print(string.format("Disco  : %.1f / %.1f MB usados · %s", used / 1048576, total / 1048576, stateOf(proxy)))
end

if not options.yes then
  io.write("Se sobrescribirán los ficheros con el mismo nombre. ¿Continuar? (s/N) ")
  local answer = io.read("*l") or ""
  if answer:lower() ~= "s" and answer:lower() ~= "si" and answer:lower() ~= "sí" then
    print("Cancelado.")
    return
  end
end

local mountPoint = "/mnt/terracorp-install"
if filesystem.exists(mountPoint) then
  pcall(filesystem.umount, mountPoint)
else
  filesystem.makeDirectory(mountPoint)
end

if not filesystem.mount(proxy, mountPoint) then
  io.stderr:write("No se pudo montar el destino en " .. mountPoint .. "\n")
  return
end

local copied, failed = 0, 0

local function copyTree(from, to)
  filesystem.makeDirectory(to)

  for name in filesystem.list(from) do
    local source = filesystem.concat(from, name)
    local target = filesystem.concat(to, name)

    if filesystem.isDirectory(source) then
      copyTree(source, target)
    else
      local input = filesystem.open(source, "rb")
      if not input then
        failed = failed + 1
        io.stderr:write("No se pudo leer " .. source .. "\n")
      else
        local data = readAll(input)
        input:close()

        local output = filesystem.open(target, "wb")
        if not output then
          failed = failed + 1
          io.stderr:write("No se pudo escribir " .. target .. "\n")
        else
          output:write(data)
          output:close()
          copied = copied + 1
        end
      end
    end
  end
end

local ok, reason = pcall(copyTree, sourceRoot, mountPoint)

filesystem.makeDirectory(filesystem.concat(mountPoint, "etc"))
filesystem.makeDirectory(filesystem.concat(mountPoint, "var/log"))

pcall(filesystem.umount, mountPoint)

if not ok then
  io.stderr:write("Instalación fallida: " .. tostring(reason) .. "\n")
  return
end

print(string.format("Copiados %d ficheros (%d errores).", copied, failed))

-- `pcall` solo detecta errores Lua: `component.invoke` devuelve `nil, motivo`
-- cuando el componente rechaza la llamada. Hay que mirar también el resultado.
local function succeeded(ok, value, reason)
  if not ok or value == false then
    return false, tostring(reason or value)
  end
  if value == nil and reason ~= nil then
    return false, tostring(reason)
  end
  return true
end

local bootOk, bootReason = succeeded(pcall(computer.setBootAddress, address))
if bootOk then
  print("Volumen de arranque fijado: " .. address)
else
  io.stderr:write("No se pudo fijar el volumen de arranque: " .. tostring(bootReason) .. "\n")
end

if options.eeprom then
  local eepromAddress = component.list("eeprom")()
  if not eepromAddress then
    io.stderr:write("No hay EEPROM en este ordenador.\n")
    return
  end

  local input = filesystem.open(eepromSource, "rb")
  if not input then
    io.stderr:write("No se encontró " .. eepromSource .. "\n")
    return
  end

  local code = readAll(input)
  input:close()

  local function flash(value)
    local ok, reason = succeeded(pcall(component.invoke, eepromAddress, "set", value))
    if ok then
      return true
    end
    return false, reason
  end

  local flashed, flashReason = flash(code)
  if not flashed then
    local bytes = {}
    for index = 1, #code do
      bytes[index] = code:byte(index)
    end
    local secondOk, secondReason = flash(bytes)
    if secondOk then
      flashed = true
    else
      flashReason = secondReason or flashReason
    end
  end

  if flashed then
    print("EEPROM grabada con el gestor de arranque de TerraCorp OS.")
  else
    io.stderr:write("No se pudo grabar la EEPROM (" .. tostring(flashReason) .. "). Copia eeprom/init.lua a mano.\n")
  end
end

print("")
print("Instalación completada. Reinicia el ordenador para arrancar TerraCorp OS.")
term.write("")
