-- Banco de pruebas para el enlace Redstone Control -> OpenComputers.
--
--   spike-rc probe            enumera componentes y métodos (para descubrir la API)
--   spike-rc width            mide el ancho real de una señal (requiere bucle)
--   spike-rc bench [n]        latencia ida-vuelta palabra a palabra (requiere bucle)
--   spike-rc stream [n]       ráfaga y comprobación de pérdidas (requiere bucle)
--   spike-rc selftest         valida el propio banco con un adaptador en memoria
--
-- Antes de `width`, `bench` o `stream` hay que rellenar ADAPTER (abajo) con los
-- métodos que descubra `probe`. Sin eso, el enlace no existe: no se inventa.

local component = nil
do
  local ok, lib = pcall(require, "component")
  if ok then
    component = lib
  end
end

local computer = nil
do
  local ok, lib = pcall(require, "computer")
  if ok then
    computer = lib
  end
end

local function now()
  if computer and computer.uptime then
    return computer.uptime()
  end
  return os.clock()
end

local function sleep(seconds)
  if os.sleep then
    os.sleep(seconds)
  end
end

--------------------------------------------------------------------------------
-- ADAPTADOR
--
-- Sustituir por los métodos que exponga el Adapter de Redstone Control junto al
-- bloque de RC. Ejemplo de forma (los nombres son inventados):
--
--   local addr = "<direccion del adapter>"
--   ADAPTER = {
--     write = function(word)
--       return component.invoke(addr, "setSignal", "out", word)
--     end,
--     read = function()
--       return component.invoke(addr, "getSignal", "in")
--     end,
--   }
--------------------------------------------------------------------------------

local ADAPTER = nil

local function requireAdapter()
  if not ADAPTER then
    io.stderr:write("Falta configurar ADAPTER en tools/spike-rc.lua (ver cabecera).\n")
    io.stderr:write("Ejecuta `spike-rc probe` para descubrir los métodos disponibles.\n")
    return false
  end
  return true
end

-- Normaliza a 32 bits sin signo: RC puede devolver el mismo patrón como entero
-- con signo (-1); el banco compara patrones, no representaciones.
local function toWord(value)
  if type(value) ~= "number" then
    return nil
  end
  return math.floor(value) & 0xFFFFFFFF
end

-- Espera a leer `expected` con un límite de tiempo. Devuelve el valor y si coincidió.
local function waitFor(expected, timeout)
  local target = toWord(expected)
  local deadline = now() + (timeout or 2)
  local last
  repeat
    local value = ADAPTER.read()
    local normalized = toWord(value)
    if normalized ~= nil then
      last = value
      if normalized == target then
        return value, true
      end
    end
    sleep(0.05)
  until now() >= deadline

  return last, false
end

--------------------------------------------------------------------------------
-- Modos
--------------------------------------------------------------------------------

local function probe()
  if not component then
    print("`probe` necesita OpenOS (component).")
    return
  end

  local count = 0
  for address, kind in component.list() do
    count = count + 1
    print(string.format("%-20s %s", kind, address))

    local methods = component.methods and component.methods(address)
    if methods then
      local names = {}
      for name in pairs(methods) do
        names[#names + 1] = name
      end
      table.sort(names)

      local interesting = {}
      for _, name in ipairs(names) do
        if name:lower():match("signal") or name:lower():match("redstone")
          or name:lower():match("read") or name:lower():match("write")
          or name:lower():match("value") or name:lower():match("port") then
          interesting[#interesting + 1] = name
        end
      end

      print("  métodos: " .. table.concat(names, ", "))
      if #interesting > 0 then
        print("  candidatos: " .. table.concat(interesting, ", "))
        for _, name in ipairs(interesting) do
          local ok, doc = pcall(component.doc, address, name)
          if ok and doc and doc ~= "" then
            print("    " .. name .. ": " .. tostring(doc))
          end
        end
      end
    end
  end

  print("")
  print(string.format("%d componentes. Busca el que corresponda al Adapter de RC", count))
  print("y rellena ADAPTER con sus métodos de lectura y escritura.")
end

local function width()
  if not requireAdapter() then
    return
  end

  local patterns = {
    { "0x0", 0x0 },
    { "0x1", 0x1 },
    { "0xF", 0xF },
    { "0xFF", 0xFF },
    { "0xFFFF", 0xFFFF },
    { "0xFFFFFFFF", 0xFFFFFFFF },
  }

  print(string.format("%-12s %-12s %-14s %s", "escrito", "leído", "hex", "coincide"))
  for _, pattern in ipairs(patterns) do
    local label, value = pattern[1], pattern[2]
    ADAPTER.write(value)
    local readBack, matched = waitFor(value, 2)
    local hex = readBack and string.format("0x%X", toWord(readBack) or 0) or "-"
    local sign = (type(readBack) == "number" and readBack < 0) and (" (" .. readBack .. ")") or ""
    print(string.format("%-12s %-12s %-14s %s", label, tostring(readBack) .. sign, hex, matched and "sí" or "no"))
  end
end

local function bench(iterations)
  if not requireAdapter() then
    return
  end

  iterations = iterations or 200
  local worst, best, total, misses = 0, math.huge, 0, 0

  for index = 1, iterations do
    local word = index & 0xFFFFFFFF
    local start = now()
    ADAPTER.write(word)
    local _, matched = waitFor(word, 2)
    local elapsed = now() - start

    if matched then
      total = total + elapsed
      best = math.min(best, elapsed)
      worst = math.max(worst, elapsed)
    else
      misses = misses + 1
    end
  end

  local measured = iterations - misses
  local average = (measured > 0) and (total / measured) or 0

  print(string.format("palabras      : %d (%d sin respuesta)", iterations, misses))
  print(string.format("ida-vuelta    : media %.3f s · mín %.3f s · máx %.3f s", average, best, worst))
  if average > 0.001 then
    print(string.format("equivalente   : %.1f B/s por canal (4 B por palabra)", 4 / average))
  else
    print("equivalente   : por debajo de la resolución del reloj")
  end
  print("Nota: mide el bucle completo. El caudal real depende de los canales en paralelo.")
end

local function stream(iterations)
  if not requireAdapter() then
    return
  end

  iterations = iterations or 500
  local start = now()

  for index = 1, iterations do
    ADAPTER.write(index & 0xFFFFFFFF)
  end

  local sent = now() - start
  local received, mismatch = 0, 0

  for index = 1, iterations do
    local value = ADAPTER.read()
    if toWord(value) == (index & 0xFFFFFFFF) then
      received = received + 1
    else
      mismatch = mismatch + 1
    end
  end

  local elapsed = now() - start
  print(string.format("enviadas      : %d en %.3f s", iterations, sent))
  print(string.format("recibidas     : %d · desajustes %d", received, mismatch))
  print(string.format("caudal        : %.1f palabras/s · %.1f B/s", iterations / math.max(elapsed, 0.001),
    (iterations * 4) / math.max(elapsed, 0.001)))
end

-- Adaptador en memoria: valida la lógica del banco sin hardware.
local function selftest()
  local current = 0

  ADAPTER = {
    write = function(word)
      current = word & 0xFFFFFFFF
    end,
    read = function()
      return current
    end,
  }

  print("selftest: width")
  width()

  print("")
  print("selftest: bench")
  bench(50)

  print("")
  print("selftest: stream")
  local queue = {}
  ADAPTER = {
    write = function(word)
      queue[#queue + 1] = word & 0xFFFFFFFF
    end,
    read = function()
      return table.remove(queue, 1)
    end,
  }
  stream(100)

  ADAPTER = nil
  print("")
  print("selftest completado")
end

--------------------------------------------------------------------------------
-- Entrada
--------------------------------------------------------------------------------

local args = table.pack(...)
local mode = args[1] or (arg and arg[1]) or "help"
local argument = tonumber(args[2]) or (arg and tonumber(arg[2]))

if mode == "probe" then
  probe()
elseif mode == "width" then
  width()
elseif mode == "bench" then
  bench(argument)
elseif mode == "stream" then
  stream(argument)
elseif mode == "selftest" then
  selftest()
else
  print("uso: spike-rc probe|width|bench [n]|stream [n]|selftest")
end
