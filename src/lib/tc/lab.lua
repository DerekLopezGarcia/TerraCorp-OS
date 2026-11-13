-- Lua scratch runner for the Lab app and the Terminal `lua` command.
--
-- A script runs inside the live OS: the sandbox exposes the kernel, the VFS,
-- the component API and the standard libraries. `print` output is captured,
-- returned to the caller, and appended to /var/log/lab.log so a run survives
-- the window and can be read from Files or the Terminal.
--
-- A script runs in the desktop event loop: there is no preemption, so a
-- runaway loop blocks the node until it reboots.

local lab = {}
lab.__index = lab

lab.SCRIPT = "/var/lab/script.lua"
lab.LOG = "/var/log/lab.log"

local MAX_LOG_BYTES = 65536
local MAX_RUN_LINES = 200
local MAX_RUN_BYTES = 24576
local MAX_LINE_CHARS = 400
local TAIL_BYTES = 16384

-- Standard library surface. `io` is omitted: scripts write through `print` or
-- the VFS. `os` is copied without the entry points that would terminate the
-- machine process.
local function osLibrary()
  local copy = {}
  for key, value in pairs(os) do
    if key ~= "exit" and key ~= "execute" and key ~= "setlocale" then
      copy[key] = value
    end
  end
  return copy
end

local function baseLibrary()
  return {
    assert = assert,
    collectgarbage = collectgarbage,
    error = error,
    getmetatable = getmetatable,
    ipairs = ipairs,
    load = load,
    math = math,
    next = next,
    pairs = pairs,
    pcall = pcall,
    rawequal = rawequal,
    rawget = rawget,
    rawset = rawset,
    select = select,
    setmetatable = setmetatable,
    string = string,
    table = table,
    tonumber = tonumber,
    tostring = tostring,
    type = type,
    utf8 = utf8,
    xpcall = xpcall,
    coroutine = coroutine,
    os = osLibrary(),
  }
end

--- Create a runner bound to the running kernel.
function lab.new(kernel)
  return setmetatable({ kernel = kernel }, lab)
end

local function uptime()
  local ok, seconds = pcall(computer.uptime)
  if ok and type(seconds) == "number" then
    return seconds
  end
  return 0
end

function lab:stamp()
  local ok, value = pcall(os.date, "%H:%M:%S")
  return ok and value or "--:--:--"
end

-- Trim `/var/lab/script.lua:2: message` to `line 2: message`, which survives a
-- narrow Lab window. Other messages pass through untouched.
function lab:short(message, path)
  message = tostring(message or "unknown error")
  local prefix = path .. ":"
  if message:sub(1, #prefix) == prefix then
    local line, rest = message:sub(#prefix + 1):match("^(%d+):%s*(.*)$")
    if line then
      return string.format("line %s: %s", line, rest)
    end
  end
  return message
end

-- Build a fresh environment per run so one script cannot leave globals behind
-- for the next one. `output` receives captured `print` lines.
function lab:environment(output)
  local kernel = self.kernel
  local env = baseLibrary()

  env._G = env
  env.kernel = kernel
  env.vfs = kernel.vfs
  env.component = component
  env.computer = computer
  env.log = kernel.log
  env.config = kernel.config
  env.text = kernel.text
  env.util = kernel.util
  env.theme = kernel.theme
  env.version = kernel.version
  env.ui = kernel.ui
  env.require = kernel.require
  env.print = function(...)
    local pieces = {}
    for index = 1, select("#", ...) do
      pieces[index] = tostring((select(index, ...)))
    end
    local line = table.concat(pieces, "\t")
    if #line > MAX_LINE_CHARS then
      -- Bound the line: a captured string is copied into the log and the pane.
      line = line:sub(1, MAX_LINE_CHARS - 1) .. "…"
    end
    if #output >= MAX_RUN_LINES or (output.bytes or 0) >= MAX_RUN_BYTES then
      output.truncated = true
      return
    end
    output.bytes = (output.bytes or 0) + #line + 1
    output[#output + 1] = line
  end

  return env
end

-- Append a run to the log, rotating it first when it has grown too large.
function lab:append(result)
  local vfs = self.kernel.vfs
  local size = vfs.size(lab.LOG) or 0
  if size > MAX_LOG_BYTES then
    self:rotate()
  end

  local body = {}
  for _, line in ipairs(result.lines) do
    body[#body + 1] = line
  end
  body[#body + 1] = ""

  local ok, reason = vfs.append(lab.LOG, table.concat(body, "\n") .. "\n")
  if not ok then
    self.kernel.log.warn("lab: could not write " .. lab.LOG .. ": " .. tostring(reason))
  end
end

-- Keep the most recent half of the log. The first line may start mid-record,
-- so drop everything up to the first newline.
function lab:rotate()
  local vfs = self.kernel.vfs
  local tail = vfs.readTail(lab.LOG, math.floor(MAX_LOG_BYTES / 2))
  if not tail then
    return
  end
  local newline = tail:find("\n", 1, true)
  if newline and newline < #tail then
    tail = tail:sub(newline + 1)
  end
  vfs.write(lab.LOG, "... log rotated ...\n" .. tail)
end

--- Compile and run `source`, capture its output, and log the run.
-- Returns { ok, lines, error, truncated, duration, path }; `lines` starts with
-- a `===` header so the caller shows exactly what the log stores.
function lab:execute(source, path)
  path = path or lab.SCRIPT
  local started = uptime()
  local output = {}
  local chunkName = "=" .. path

  local chunk, compileError = load(source, chunkName, "t", self:environment(output))
  local ok, failure = true, nil

  if not chunk then
    ok = false
    failure = self:short(compileError, path)
  else
    local passed, reason = pcall(chunk)
    if not passed then
      ok = false
      failure = self:short(reason, path)
    end
  end

  if not ok then
    output[#output + 1] = "! " .. tostring(failure)
  end

  local result = {
    ok = ok,
    lines = {},
    error = failure,
    truncated = output.truncated == true,
    duration = math.max(0, (uptime() - started) * 1000),
    path = path,
  }

  result.lines[1] = string.format(
    "=== %s · %s · %s · %d ms",
    self:stamp(),
    path,
    ok and "ok" or "error",
    math.floor(result.duration)
  )
  for _, line in ipairs(output) do
    result.lines[#result.lines + 1] = line
  end
  if result.truncated then
    result.lines[#result.lines + 1] = string.format(
      "... output truncated (%d lines / %d KB)",
      MAX_RUN_LINES,
      math.floor(MAX_RUN_BYTES / 1024)
    )
  end

  self:append(result)
  return result
end

--- Last `count` lines of the run log, newest last.
function lab:tail(count)
  count = math.max(1, math.floor(tonumber(count) or 80))
  local vfs = self.kernel.vfs
  local size = vfs.size(lab.LOG) or 0
  if size == 0 then
    return {}
  end

  local data = vfs.readTail(lab.LOG, TAIL_BYTES)
  if not data or data == "" then
    return {}
  end

  local lines = self.kernel.util.split(data, "\n")
  if lines[#lines] == "" then
    table.remove(lines)
  end
  -- A short read starts mid-line; drop the partial record.
  if size > #data and #lines > 0 then
    table.remove(lines, 1)
  end

  local result = {}
  local from = math.max(1, #lines - count + 1)
  for index = from, #lines do
    result[#result + 1] = lines[index]
  end
  return result
end

--- Empty the run log.
function lab:clear()
  return self.kernel.vfs.write(lab.LOG, "")
end

return lab
