-- Descargador de TerraCorp OS para OpenComputers (se ejecuta bajo OpenOS).
--
--   wget https://raw.githubusercontent.com/DerekLopezGarcia/TerraCorp-OS/main/tools/fetch.lua /tmp/fetch.lua
--   lua /tmp/fetch.lua [destino] [urlBase]
--
-- Copia el arbol del repo publico al ordenador sin git ni copiar ficheros a
-- mano. Necesita una tarjeta de red y salida HTTP(S) permitida en el mod.
--
-- La salida es ASCII y en lineas cortas a proposito: si el terminal pinta mal
-- (columnas corridas, colores cruzados o glifos que no existen) un mensaje
-- largo con acentos es ilegible, y el resultado tiene que poder leerse igual.
-- La ultima linea, "RESULTADO:", es la que manda; los mensajes intermedios no.

local component = require("component")
local filesystem = require("filesystem")
local internet = require("internet")
local shell = require("shell")

local args = shell.parse(...)
local target = shell.resolve(args[1] or "/home/TerraCorp-OS")
local base = (args[2] or "https://raw.githubusercontent.com/DerekLopezGarcia/TerraCorp-OS/main"):gsub("/+$", "")

if not component.isAvailable("internet") then
  io.stderr:write("RESULTADO: ERROR - falta la tarjeta de red (internet)\n")
  return
end

-- Devuelve cuerpo, error y codigo HTTP. Separa el codigo del cuerpo porque un
-- 404 no es "no hay red": casi siempre es la ruta, y en raw.githubusercontent
-- el propietario distingue mayusculas (dereklopezagarcia != DerekLopezGarcia).
local function request(url)
  local ok, handle, reason = pcall(internet.request, url)
  if not ok then
    return nil, "excepcion: " .. tostring(handle)
  end
  if not handle then
    return nil, reason or "sin respuesta"
  end

  local status
  if type(handle.response) == "function" then
    local codeOk, code = pcall(handle.response, handle)
    if codeOk and type(code) == "number" then
      status = code
    end
  end

  local chunks = {}
  local readOk, readError = pcall(function()
    for chunk in handle do
      chunks[#chunks + 1] = chunk
    end
  end)
  pcall(handle.close, handle)

  if not readOk then
    return nil, "lectura: " .. tostring(readError), status
  end
  if status and status ~= 200 then
    return nil, "HTTP " .. status, status
  end

  local body = table.concat(chunks)
  if body == "" then
    return nil, "respuesta vacia", status
  end
  return body, nil, status
end

-- Un reintento: en OC el primer request tras arrancar a veces se cae solo.
local function fetch(url)
  local body, reason, status = request(url)
  if body then
    return body
  end
  body, reason, status = request(url)
  return body, reason, status
end

local copied, failed = 0, 0
local bytes = 0

print("TERRACORP OS - descarga")
print("destino: " .. target)
print("origen : " .. base)

local manifest, reason, status = fetch(base .. "/tools/manifest.txt")
if not manifest then
  io.stderr:write("RESULTADO: ERROR - no se pudo leer el manifiesto (" .. tostring(reason) .. ")\n")
  if status == 404 then
    io.stderr:write("ruta no encontrada. Comprueba que el repo es publico\n")
    io.stderr:write("y que el propietario lleva mayusculas: DerekLopezGarcia\n")
  else
    io.stderr:write("comprueba la red: component.isAvailable(\"internet\")\n")
  end
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
  io.stderr:write("RESULTADO: ERROR - el manifiesto esta vacio\n")
  return
end

print("ficheros: " .. #paths)

for index, relative in ipairs(paths) do
  local destination = filesystem.concat(target, relative)
  local directory = destination:match("^(.*)/[^/]+$")
  if directory and directory ~= "" then
    pcall(filesystem.makeDirectory, directory)
  end

  local content, why = fetch(base .. "/" .. relative)
  local writeReason

  if content then
    local handle, openError = filesystem.open(destination, "wb")
    if handle then
      local writeOk = pcall(function()
        handle:write(content)
        handle:close()
      end)
      if not writeOk then
        writeReason = "escritura interrumpida"
      else
        -- Verificar en disco, no en la pantalla: si el volumen esta lleno el
        -- fichero queda corto y el error no se ve hasta ejecutarlo.
        local okSize, size = pcall(filesystem.size, destination)
        if okSize and size ~= #content then
          writeReason = string.format("quedaron %s de %d B", tostring(size), #content)
        end
      end
    else
      writeReason = openError or "no se pudo abrir"
    end
  end

  if content and not writeReason then
    copied = copied + 1
    bytes = bytes + #content
    print(string.format("[%2d/%2d] %s", index, #paths, relative))
  else
    failed = failed + 1
    print(string.format("[%2d/%2d] FALLO %s (%s)", index, #paths, relative,
      tostring(writeReason or why)))
  end
end

if failed > 0 then
  print(string.format("RESULTADO: INCOMPLETO - %d/%d ficheros (%d fallos)",
    copied, #paths, failed))
  return
end

print(string.format("RESULTADO: OK - %d/%d ficheros, %d bytes", copied, #paths, bytes))
print("")
print("siguiente paso:")
print("  cd " .. filesystem.concat(target, "tools"))
print("  ./install.lua " .. target .. " --eeprom")
