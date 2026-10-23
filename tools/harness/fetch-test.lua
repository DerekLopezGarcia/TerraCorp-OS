-- Prueba tools/fetch.lua con OpenOS simulado (red, disco y shell falsos).
--
--   node tools/harness/test-fetch.js
--
-- Lo que se comprueba es lo que se ve en juego cuando algo va mal: que el
-- resultado se anuncie en una línea inequívoca ("RESULTADO: ..."), que un 404
-- se distinga de un fallo de red, y que un fichero corto se detecte mirando el
-- disco y no dando por buena la escritura.
--
-- Además se exige que TODA la salida sea ASCII y de 60 caracteres o menos: si
-- el terminal pinta mal, las líneas largas con acentos son ilegibles.

local scenario = ...

local out = {}
local disk = {}

local function emit(line)
  out[#out + 1] = line
end

local function say(...)
  local parts = {}
  for index = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(index, ...))
  end
  emit(table.concat(parts, " "))
end

component = {
  isAvailable = function(name)
    return scenario ~= "sin_tarjeta" and name == "internet"
  end,
}

filesystem = {
  concat = function(a, b)
    return (a:gsub("/+$", "")) .. "/" .. b
  end,
  makeDirectory = function()
    return true
  end,
  open = function(path, mode)
    if scenario == "lleno" then
      return nil, "sin espacio"
    end
    local buffer = {}
    return {
      write = function(_, content)
        buffer[#buffer + 1] = content
      end,
      close = function()
        local content = table.concat(buffer)
        if scenario == "corta" then
          content = content:sub(1, 2)
        end
        disk[path] = content
      end,
    }
  end,
  size = function(path)
    return disk[path] and #disk[path] or 0
  end,
}

local payloads = {
  ["http://prueba/tools/manifest.txt"] = "src/init.lua\nsrc/boot/kernel.lua\n",
  ["http://prueba/src/init.lua"] = "return 1\n",
  ["http://prueba/src/boot/kernel.lua"] = "return 2\n",
}

internet = {
  request = function(url)
    local status = 200
    local body = payloads[url]
    if scenario == "404" then
      status, body = 404, nil
    elseif scenario == "falta_uno" and url:find("kernel.lua", 1, true) then
      status, body = 404, nil
    end

    local chunks = body and { body:sub(1, 5), body:sub(6) } or { "" }
    local handle = { index = 0 }
    handle.response = function()
      return status, status == 200 and "OK" or "Not Found"
    end
    handle.close = function() end
    return setmetatable(handle, {
      __call = function(self)
        self.index = self.index + 1
        return chunks[self.index]
      end,
    })
  end,
}

shell = {
  parse = function()
    return { "/home/TerraCorp-OS", "http://prueba" }
  end,
  resolve = function(path)
    return path
  end,
}

local stubs = { component = component, filesystem = filesystem, internet = internet, shell = shell }
require = function(name)
  return stubs[name]
end

print = say
io = { stderr = { write = function(_, text) emit((text:gsub("\n$", ""))) end } }

local chunk, loadError = load(rawget(_G, "FETCH_SRC"), "=fetch.lua")
if not chunk then
  say("NO COMPILA: " .. tostring(loadError))
  FETCH_ERRORS = 1
  return
end

local ok, failure = pcall(chunk)
if not ok then
  say("ERROR DE EJECUCION: " .. tostring(failure))
  FETCH_ERRORS = 1
  return
end

local problems = 0
local function check(condition, message)
  if not condition then
    problems = problems + 1
    say("  FALLO en " .. scenario .. ": " .. message)
  end
end

local text = table.concat(out, "\n")
local function has(fragment)
  return text:find(fragment, 1, true) ~= nil
end

if scenario == "ok" then
  check(has("RESULTADO: OK"), "no anuncia el resultado correcto")
  check(disk["/home/TerraCorp-OS/src/init.lua"] == "return 1\n", "init.lua no se escribio entero")
  check(disk["/home/TerraCorp-OS/src/boot/kernel.lua"] == "return 2\n", "kernel.lua no se escribio entero")
elseif scenario == "404" then
  check(has("RESULTADO: ERROR"), "un 404 no se anuncia como error")
  check(has("HTTP 404"), "no distingue el 404 de un fallo de red")
  check(has("mayusculas"), "no sugiere revisar las mayusculas del propietario")
  check(next(disk) == nil, "escribio algo pese a no leer el manifiesto")
elseif scenario == "falta_uno" then
  check(has("RESULTADO: INCOMPLETO"), "un fichero que falta no marca incompleto")
  check(has("FALLO src/boot/kernel.lua"), "no identifica el fichero que falla")
  check(disk["/home/TerraCorp-OS/src/init.lua"] == "return 1\n", "no copio el fichero que si existia")
elseif scenario == "corta" then
  check(has("RESULTADO: INCOMPLETO"), "un fichero corto se da por bueno")
  check(has("quedaron"), "no dice cuantos bytes quedaron")
elseif scenario == "lleno" then
  check(has("RESULTADO: INCOMPLETO"), "un disco lleno se da por bueno")
  check(has("sin espacio"), "no propaga el motivo del sistema de ficheros")
elseif scenario == "sin_tarjeta" then
  check(has("RESULTADO: ERROR"), "sin tarjeta no se anuncia como error")
  check(has("tarjeta de red"), "no dice que falta la tarjeta de red")
end

-- La salida tiene que poder leerse aunque el terminal pinte mal.
for _, line in ipairs(out) do
  if #line > 60 then
    problems = problems + 1
    say("  FALLO en " .. scenario .. ": linea de " .. #line .. " caracteres")
  end
  for index = 1, #line do
    if line:byte(index) > 126 then
      problems = problems + 1
      say("  FALLO en " .. scenario .. ": caracter no ASCII en la salida")
      break
    end
  end
end

FETCH_ERRORS = problems
