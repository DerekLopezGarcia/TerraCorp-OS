-- Registro en memoria con severidad y salida opcional a disco.
-- El kernel conecta `log.sink` para persistir avisos y errores.

local log = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local TAGS = { [1] = "DBG", [2] = "INF", [3] = "AVS", [4] = "ERR" }

log.levels = LEVELS
log.tags = TAGS
log.threshold = LEVELS.info
log.capacity = 200
log.entries = {}
log.sink = nil

local function now()
  local ok, stamp = pcall(os.date, "%H:%M:%S")
  return ok and stamp or "--:--:--"
end

function log.setLevel(name)
  log.threshold = LEVELS[name] or LEVELS.info
end

function log.setSink(sink)
  log.sink = sink
end

function log.write(level, message)
  local numeric = LEVELS[level] or LEVELS.info
  if numeric < log.threshold then
    return
  end

  local entry = {
    level = numeric,
    tag = TAGS[numeric],
    time = now(),
    message = tostring(message),
  }

  log.entries[#log.entries + 1] = entry
  if #log.entries > log.capacity then
    table.remove(log.entries, 1)
  end

  if log.sink and numeric >= LEVELS.warn then
    pcall(log.sink, string.format("%s %s %s", entry.time, entry.tag, entry.message))
  end
end

function log.debug(message)
  log.write("debug", message)
end

function log.info(message)
  log.write("info", message)
end

function log.warn(message)
  log.write("warn", message)
end

function log.error(message)
  log.write("error", message)
end

function log.tail(count)
  local result = {}
  local from = math.max(1, #log.entries - (count or 5) + 1)
  for index = from, #log.entries do
    result[#result + 1] = log.entries[index]
  end
  return result
end

function log.count(level)
  local numeric = LEVELS[level]
  if not numeric then
    return 0
  end

  local total = 0
  for _, entry in ipairs(log.entries) do
    if entry.level == numeric then
      total = total + 1
    end
  end
  return total
end

function log.clear()
  log.entries = {}
end

return log
