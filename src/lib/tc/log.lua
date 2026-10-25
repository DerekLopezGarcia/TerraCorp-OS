-- In-memory severity logger with an optional disk sink.
-- The kernel connects `log.sink` to persist warnings and errors.

local log = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local TAGS = { [1] = "DBG", [2] = "INF", [3] = "WRN", [4] = "ERR" }
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

-- Computer uptime gives real elapsed time since node startup in-game, so the
-- boot trace can measure F0 without a stopwatch.
local function uptime()
  if type(computer) ~= "table" or type(computer.uptime) ~= "function" then
    return nil
  end
  local ok, seconds = pcall(computer.uptime)
  if ok and type(seconds) == "number" then
    return string.format("%.2fs", seconds)
  end
  return nil
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

-- Boot traces are always persisted, even at info level. They identify how far
-- a black-screen boot progressed; ordinary info messages stay in memory.
function log.trace(message)
  local entry = {
    level = LEVELS.info,
    tag = "TRZ",
    time = now(),
    message = tostring(message),
  }

  log.entries[#log.entries + 1] = entry
  if #log.entries > log.capacity then
    table.remove(log.entries, 1)
  end

  if log.sink then
    local up = uptime()
    local line = string.format("%s %s %s", entry.time, entry.tag, entry.message)
    if up then
      line = line .. " [" .. up .. "]"
    end
    pcall(log.sink, line)
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

return log
