-- Descargador de TerraCorp OS para OpenComputers (se ejecuta bajo OpenOS).
--
--   wget https://raw.githubusercontent.com/DerekLopezGarcia/TerraCorp-OS/main/tools/fetch.lua /tmp/fetch.lua
--   lua /tmp/fetch.lua [destino] [urlBase]
--
-- Copia el árbol del repo público al ordenador sin git ni copiar ficheros a
-- mano. Necesita una tarjeta de red y salida HTTP(S) permitida en el mod.

local component = require("component")
local filesystem = require("filesystem")
local internet = require("internet")
local shell = require("shell")

local args = shell.parse(...)
local target = shell.resolve(args[1] or "/home/TerraCorp-OS")
local base = (args[2] or "https://raw.githubusercontent.com/DerekLopezGarcia/TerraCorp-OS/main"):gsub("/+$", "")

if not component.isAvailable("internet") then
  io.stderr:write("Se necesita una tarjeta de red en el ordenador.\n")
  return
end

local function fetch(url)
  local ok, handle, reason = pcall(internet.request, url)
  if not ok then
    return nil, tostring(handle)
  end
  if not handle then
    return nil, reason or "sin respuesta"
  end

  local chunks = {}
  local readOk, readError = pcall(function()
    for chunk in handle do
      chunks[#chunks + 1] = chunk
    end
  end)
  if not readOk then
    return nil, tostring(readError)
  end

  return table.concat(chunks)
end

local function writeFile(path, content)
  local handle, reason = filesystem.open(path, "wb")
  if not handle then
    return nil, reason
  end
  handle:write(content)
  handle:close()
  return true
end

print("TerraCorp OS · " .. base)
print("Destino      · " .. target)

local manifest, reason = fetch(base .. "/tools/manifest.txt")
if not manifest then
  io.stderr:write("No se pudo leer el manifiesto: " .. tostring(reason) .. "\n")
  return
end

local paths = {}
for line in manifest:gmatch("[^\r\n]+") do
  line = line:gsub("^%s+", ""):gsub("%s+$", "")
  if line ~= "" and line:sub(1, 1) ~= "#" then
    paths[#paths + 1] = line
  end
end

if #paths == 0 then
  io.stderr:write("El manifiesto está vacío.\n")
  return
end

local copied, failed = 0, 0

for index, relative in ipairs(paths) do
  local destination = filesystem.concat(target, relative)
  local directory = destination:match("^(.*)/[^/]+$")
  if directory and directory ~= "" then
    pcall(filesystem.makeDirectory, directory)
  end

  local content, why = fetch(base .. "/" .. relative)
  if not content then
    failed = failed + 1
    io.stderr:write(string.format("  [%2d/%2d] FALLO %s (%s)\n", index, #paths, relative, tostring(why)))
  else
    local written, writeReason = writeFile(destination, content)
    if not written then
      failed = failed + 1
      io.stderr:write(string.format("  [%2d/%2d] FALLO %s (%s)\n", index, #paths, relative, tostring(writeReason)))
    else
      copied = copied + 1
      print(string.format("  [%2d/%2d] %s (%d B)", index, #paths, relative, #content))
    end
  end
end

print("")
print(string.format("Copiados %d/%d ficheros.", copied, #paths))

if failed > 0 then
  io.stderr:write("Faltan ficheros: revisa la red o la configuración de internet y repite el comando.\n")
  return
end

print("")
print("Siguiente paso:")
print("  cd " .. filesystem.concat(target, "tools"))
print("  ./install.lua " .. target .. " --eeprom")
