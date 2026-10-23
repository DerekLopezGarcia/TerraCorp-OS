-- Instalador de TerraCorp OS. Se ejecuta bajo OpenOS, no bajo TerraCorp OS.
--
--   install <raizDelRepo> <direccionFilesystem> [--eeprom] [--yes]
--
-- Copia src/ a la raíz del filesystem indicado, prepara /etc y /var/log,
-- fija el volumen de arranque y, opcionalmente, graba eeprom/init.lua.

local component = require("component")
local computer = require("computer")
local filesystem = require("filesystem")
local shell = require("shell")
local term = require("term")

local args, options = shell.parse(...)

local repoRoot = args[1]
local address = args[2]

if not repoRoot or not address then
  print("Uso: install <raizDelRepo> <direccionFilesystem> [--eeprom] [--yes]")
  print("Ejemplo: install /home/TerraCorp-OS 1a2b3c4d-...")
  return
end

repoRoot = shell.resolve(repoRoot)
local sourceRoot = filesystem.concat(repoRoot, "src")
local eepromSource = filesystem.concat(repoRoot, "eeprom/init.lua")

if not filesystem.isDirectory(sourceRoot) then
  io.stderr:write("No existe el árbol de origen: " .. sourceRoot .. "\n")
  return
end

local proxy = component.proxy(address)
if not proxy or proxy.type ~= "filesystem" then
  io.stderr:write("La dirección no es un filesystem válido: " .. tostring(address) .. "\n")
  return
end

print(string.format("Origen : %s", sourceRoot))
print(string.format("Destino: %s (%s)", address, proxy.getLabel and (proxy.getLabel() or "sin etiqueta") or "sin etiqueta"))

local used = proxy.space()
local total = proxy.spaceTotal()
if used and total then
  print(string.format("Disco  : %.1f / %.1f MB usados", used / 1024, total / 1024))
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
        local data = input:read("*a")
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

local bootOk, bootReason = pcall(computer.setBootAddress, address)
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

  local code = input:read("*a")
  input:close()

  local flashed = pcall(component.invoke, eepromAddress, "set", code)
  if not flashed then
    local bytes = {}
    for index = 1, #code do
      bytes[index] = code:byte(index)
    end
    flashed = pcall(component.invoke, eepromAddress, "set", bytes)
  end

  if flashed then
    print("EEPROM grabada con el gestor de arranque de TerraCorp OS.")
  else
    io.stderr:write("No se pudo grabar la EEPROM. Copia eeprom/init.lua a mano.\n")
  end
end

print("")
print("Instalación completada. Reinicia el ordenador para arrancar TerraCorp OS.")
term.write("")
