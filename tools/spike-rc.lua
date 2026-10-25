-- Test bench for the Redstone Control -> OpenComputers link.
--
--   spike-rc probe            list components and methods to discover the API
--   spike-rc width            measure signal width (requires an event loop)
--   spike-rc bench [n]        measure word-by-word round-trip latency
--   spike-rc stream [n]       send a burst and check loss (requires an event loop)
--   spike-rc selftest         validate the bench with an in-memory adapter
--
-- Before `width`, `bench`, or `stream`, fill in ADAPTER below with the methods
-- discovered by `probe`. Do not invent an API that is not present.

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
-- Replace with methods exposed by the Redstone Control Adapter next to the
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
    io.stderr:write("Configure ADAPTER in tools/spike-rc.lua (see the header).\n")
    io.stderr:write("Run `spike-rc probe` to discover available methods.\n")
    return false
  end
  return true
end

-- Normalize to unsigned 32-bit values: RC may return a bit pattern as a signed
-- integer (-1). Compare bit patterns, not their representations.
local function toWord(value)
  if type(value) ~= "number" then
    return nil
  end
  return math.floor(value) & 0xFFFFFFFF
end

-- Wait for `expected` with a timeout. Return the observed value and match state.
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
    print("`probe` requires OpenOS (component).")
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

      print("  methods: " .. table.concat(names, ", "))
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
  print(string.format("%d components. Find the Redstone Control Adapter", count))
  print("and fill in ADAPTER with its read/write methods.")
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

  print(string.format("%-12s %-12s %-14s %s", "written", "read", "hex", "match"))
  for _, pattern in ipairs(patterns) do
    local label, value = pattern[1], pattern[2]
    ADAPTER.write(value)
    local readBack, matched = waitFor(value, 2)
    local hex = readBack and string.format("0x%X", toWord(readBack) or 0) or "-"
    local sign = (type(readBack) == "number" and readBack < 0) and (" (" .. readBack .. ")") or ""
    print(string.format("%-12s %-12s %-14s %s", label, tostring(readBack) .. sign, hex, matched and "yes" or "no"))
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

  print(string.format("words         : %d (%d timeouts)", iterations, misses))
  print(string.format("round trip    : avg %.3f s · min %.3f s · max %.3f s", average, best, worst))
  if average > 0.001 then
    print(string.format("equivalent    : %.1f B/s per channel (4 B per word)", 4 / average))
  else
    print("equivalent    : below clock resolution")
  end
  print("Note: this measures the full loop. Throughput depends on parallel channels.")
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
  print(string.format("sent          : %d in %.3f s", iterations, sent))
  print(string.format("received      : %d · mismatches %d", received, mismatch))
  print(string.format("throughput    : %.1f words/s · %.1f B/s", iterations / math.max(elapsed, 0.001),
    (iterations * 4) / math.max(elapsed, 0.001)))
end

-- In-memory adapter for validating the bench logic without hardware.
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
