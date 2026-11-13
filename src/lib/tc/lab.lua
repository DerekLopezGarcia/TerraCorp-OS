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

-- The interpreter answers to a name that appears in its own error messages.
local REPL_PATH = "/var/lab/repl.lua"

-- The Terminal sets this to "repl" so `lua` opens the app on the interpreter.
-- The app clears it once it has switched tabs.
lab.openTab = nil

local MAX_LOG_BYTES = 65536
local MAX_RUN_LINES = 200
local MAX_RUN_BYTES = 24576
local MAX_LINE_CHARS = 400
local MAX_TAIL_BYTES = 16384
local MAX_TRANSCRIPT_LINES = 400
local MAX_HISTORY = 50

-- How much of a table a REPL result shows. OpenOS serializes the whole value;
-- the Lab bounds it so one result cannot fill the transcript or the log.
local MAX_SHOW_DEPTH = 2
local MAX_SHOW_ENTRIES = 10
local MAX_SHOW_SCAN = 64

-- REPL results are shown the way an operator inspects a component: strings
-- quoted, tables keyed and elided, everything else tostring. Keys are sorted
-- so the same value prints the same way twice. A table at the top level puts
-- one entry per line: a component listing is wider than any screen and must
-- stay readable in a transcript that only wraps, never scrolls sideways.
local function displayValue(value, depth)
  local kind = type(value)
  if kind == "string" then
    return string.format("%q", value)
  elseif kind ~= "table" then
    return tostring(value)
  end

  depth = depth or 0
  if depth >= MAX_SHOW_DEPTH then
    return "{...}"
  end

  local keys, count = {}, 0
  for key in pairs(value) do
    count = count + 1
    if count > MAX_SHOW_SCAN then
      break
    end
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)

  if #keys == 0 then
    return "{}"
  end

  local parts = {}
  local indent = depth == 0 and "  " or ""
  for index = 1, math.min(#keys, MAX_SHOW_ENTRIES) do
    local key = keys[index]
    parts[#parts + 1] = indent .. "[" .. displayValue(key, depth + 1) .. "]="
      .. displayValue(value[key], depth + 1)
  end
  if #keys > MAX_SHOW_ENTRIES then
    parts[#parts + 1] = indent .. "..."
  end

  if depth == 0 then
    return "{\n" .. table.concat(parts, "\n") .. "\n}"
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

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

-- A capture buffer is a plain line array that also carries `bytes` and
-- `truncated`, so one table is both the transcript and the budget.
local function clearBuffer(buffer)
  for index = #buffer, 1, -1 do
    buffer[index] = nil
  end
  buffer.bytes = 0
  buffer.truncated = false
end

local function pushLine(buffer, line)
  if #buffer >= MAX_RUN_LINES or (buffer.bytes or 0) >= MAX_RUN_BYTES then
    buffer.truncated = true
    return
  end
  buffer.bytes = (buffer.bytes or 0) + #line + 1
  buffer[#buffer + 1] = line
end

-- OpenOS hands programs `component.gpu` as a shortcut to the primary component
-- of that kind. TerraCorp does not load OpenOS, so the Lab builds that door on
-- top of the base API: a real method always wins, anything else is looked up
-- as a component kind and cached until the next run.
local function componentAccess()
  local cache = {}
  local access = {}

  for key, value in pairs(component) do
    access[key] = value
  end

  access.primary = function(kind)
    local cached = cache[kind]
    if cached ~= nil then
      return cached or nil
    end

    for address in component.list(kind) do
      local ok, proxy = pcall(component.proxy, address)
      if ok and proxy then
        cache[kind] = proxy
        return proxy
      end
    end

    cache[kind] = false
    return nil
  end

  access.refresh = function()
    for key in pairs(cache) do
      cache[key] = nil
    end
  end

  return setmetatable(access, {
    __index = function(self, key)
      return self.primary(key)
    end,
  })
end

-- Build a fresh environment per run so one script cannot leave globals behind
-- for the next one. `output` receives captured `print` lines.
function lab:environment(output)
  local kernel = self.kernel
  local env = baseLibrary()

  env._G = env
  env.kernel = kernel
  env.vfs = kernel.vfs
  env.component = componentAccess()
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
    pushLine(output, line)
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

--------------------------------------------------------------------------------
-- Interpreter
--
-- A script run gets a fresh environment every time; that is what makes one run
-- reproducible and what the scratchpad is for. The interpreter trades the other
-- way: one environment stays alive, so a name assigned on one line is still
-- there on the next.
--
-- Sessions are named environments, not saved files. Lua state is closures,
-- coroutines and userdata, so it cannot be written to disk and reloaded; the
-- registry lives in the module (which the kernel caches) and an empty
-- environment is one `:` command away. What does survive a reboot is the log:
-- every submission is recorded with the session name in its header.
--------------------------------------------------------------------------------

local repl = {}
repl.__index = repl

local SESSION_NAME = "^[%w_%-]+$"
local MAX_SESSION_NAME = 16

--- The registry of interpreter sessions for this boot.
function lab:sessions()
  if not lab.sessionRegistry then
    lab.sessionRegistry = { order = {}, map = {}, active = nil }
  end
  return lab.sessionRegistry
end

--- The active session, or the one named `name` when one is given.
-- With no argument it creates `main` on first use, so the app and the Terminal
-- can both ask for "the" session without coordinating.
function lab:repl(name)
  local registry = self:sessions()

  if name then
    local session = registry.map[name]
    if not session then
      return nil, "no session named " .. tostring(name)
    end
    registry.active = name
    return session
  end

  if not registry.active then
    self:newRepl("main")
  end
  return registry.map[registry.active]
end

--- Start a session with a clean environment and make it active.
function lab:newRepl(name)
  local registry = self:sessions()
  name = tostring(name or ""):match("^%s*(.-)%s*$")
  if name == "" then
    name = "s" .. tostring(#registry.order + 1)
  end
  if #name > MAX_SESSION_NAME or not name:match(SESSION_NAME) then
    return nil, "invalid session name: " .. name
  end
  if registry.map[name] then
    return nil, "session already exists: " .. name
  end

  local session = setmetatable({
    runner = self,
    name = name,
    buffer = {},
    pending = {},
    history = {},
    transcript = {},
    submissions = 0,
  }, repl)
  session:reset()

  registry.map[name] = session
  registry.order[#registry.order + 1] = name
  registry.active = name
  return session
end

--- Forget a session. The last one cannot go, and the log keeps its record.
function lab:dropRepl(name)
  local registry = self:sessions()
  if not registry.map[name] then
    return nil, "no session named " .. tostring(name)
  end
  if #registry.order <= 1 then
    return nil, "the last session cannot be dropped"
  end

  registry.map[name] = nil
  for index, value in ipairs(registry.order) do
    if value == name then
      table.remove(registry.order, index)
      break
    end
  end
  if registry.active == name then
    registry.active = registry.order[#registry.order]
  end
  return true
end

--- One line naming every session, the active one marked with `*`.
function lab:sessionList()
  local registry = self:sessions()
  local names = {}
  for _, name in ipairs(registry.order) do
    names[#names + 1] = name == registry.active and (name .. "*") or name
  end
  return "sessions: " .. table.concat(names, "  ")
end

-- One clipboard for the whole OS, held on the module so it survives closing a
-- window. OpenComputers has no clipboard API to write to: the mod only hands
-- text *to* the computer (`clipboard` signal), never reads it back out.
function lab:copy(text)
  lab.clipboard = text or ""
  return #lab.clipboard
end

function lab:clipped()
  return lab.clipboard or ""
end

--- Drop every pane transcript. The environments stay as they are.
function lab:clearSessionTranscripts()
  local registry = self:sessions()
  for _, name in ipairs(registry.order) do
    registry.map[name]:clearTranscript()
  end
end

--- Drop every name the session defined.
function repl:reset()
  self.buffer = {}
  self.env = self.runner:environment(self.buffer)
  self.pending = {}
  self.submissions = 0
  return self
end

--- Prompt for the next line; a `... ` prompt means a block is still open.
-- Both prompts are five cells so the input text starts at the same column on
-- the first line and on the continuation rows.
function repl:prompt()
  return #self.pending > 0 and "...  " or "lua> "
end

--- Split a cell into lines, for the continuation prompt and its status.
function repl:sourceLines(source)
  local lines = {}
  for line in (source .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

--- Drop the transcript of the pane. The environment is untouched.
function repl:clearTranscript()
  self.transcript = {}
  return self
end

--- Build the log and pane record for one submission.
function repl:record(source, ok, body, started)
  local result = {
    ok = ok,
    lines = {},
    duration = math.max(0, (uptime() - started) * 1000),
    path = "repl@" .. self.name,
  }

  result.lines[1] = string.format(
    "=== %s · %s · %s · %d ms",
    self.runner:stamp(),
    result.path,
    ok and "ok" or "error",
    math.floor(result.duration)
  )
  for line in (source .. "\n"):gmatch("(.-)\n") do
    result.lines[#result.lines + 1] = "> " .. line
  end
  for _, line in ipairs(body) do
    result.lines[#result.lines + 1] = line
  end
  return result
end

function repl:pushTranscript(lines)
  for _, line in ipairs(lines) do
    self.transcript[#self.transcript + 1] = line
  end
  while #self.transcript > MAX_TRANSCRIPT_LINES do
    table.remove(self.transcript, 1)
  end
  return self
end

--- `:` commands act on the session, never on the environment.
-- They are recorded in the pane and the log, so a session's story stays whole.
function repl:command(source)
  local started = uptime()
  local text = source:match("^%s*:(.*)$") or ""
  local name, rest = text:match("^(%S*)%s*(.*)$")
  name = (name or ""):lower()
  rest = (rest or ""):match("^%s*(.-)%s*$")

  local ok, output = true, {}

  if name == "" or name == "help" then
    output[1] = "sessions: :list  :new [name]  :use <name>  :reset  :clear  :drop <name>"
  elseif name == "list" then
    output[1] = self.runner:sessionList()
  elseif name == "new" then
    local session, reason = self.runner:newRepl(rest)
    if session then
      output[1] = "session " .. session.name .. " · clean environment"
    else
      ok, output[1] = false, "! " .. tostring(reason)
    end
  elseif name == "use" then
    if rest == "" then
      ok, output[1] = false, "! usage: :use <name>  (:list shows them)"
    else
      local session, reason = self.runner:repl(rest)
      if session then
        output[1] = "session " .. session.name
      else
        ok, output[1] = false, "! " .. tostring(reason)
      end
    end
  elseif name == "reset" then
    self:reset()
    output[1] = "session " .. self.name .. " · every name dropped"
  elseif name == "clear" then
    self:clearTranscript()
    output[1] = "session " .. self.name .. " · pane cleared"
  elseif name == "drop" then
    if rest == "" then
      ok, output[1] = false, "! usage: :drop <name>"
    else
      local dropped, reason = self.runner:dropRepl(rest)
      if dropped then
        output[1] = "session " .. rest .. " dropped"
      else
        ok, output[1] = false, "! " .. tostring(reason)
      end
    end
  else
    ok, output[1] = false, "! unknown command: :" .. name .. " (:help)"
  end

  -- `:new`, `:use` and `:drop` move the cursor, so the confirmation belongs to
  -- the session that is active now — the pane the operator is about to read.
  local target = self.runner:repl() or self
  local result = target:record(source, ok, output, started)
  target:pushTranscript(result.lines)
  self.runner:append(result)
  return result
end

--- Evaluate the input cell's whole source.
-- The app keeps the text on screen, so a block typed across several lines is
-- compiled as one chunk every time. Returns nil for an empty cell, `{ incomplete
-- = true }` while a block is still open, or a run record shaped like
-- `lab:execute`.
function repl:submit(input)
  input = input or ""
  if #self.pending == 0 and input:match("^%s*$") then
    return nil
  end

  if #self.pending == 0 and input:match("^%s*:") then
    return self:command(input)
  end

  local source = input
  local started = uptime()

  -- OpenOS's interpreter tries the line as an expression first and falls back
  -- to a statement, so a bare call prints its result there. Match it: `=expr`
  -- only skips the statement fallback. An open block shows up in the statement
  -- error, while `1 +` only reports `<eof>` as an expression, so both errors
  -- are consulted before waiting for another line.
  local chunk, expression, compileError
  local explicit = source:match("^%s*=") ~= nil

  if explicit then
    local body = source:gsub("^%s*=", "", 1)
    chunk, compileError = load("return " .. body, "=" .. REPL_PATH, "t", self.env)
    expression = chunk ~= nil
    if not chunk and tostring(compileError):find("<eof>", 1, true) then
      self.pending = self:sourceLines(source)
      return { incomplete = true }
    end
  else
    local asExpression, expressionError = load("return " .. source, "=" .. REPL_PATH, "t", self.env)
    if asExpression then
      chunk, expression = asExpression, true
    else
      local asStatement, statementError = load(source, "=" .. REPL_PATH, "t", self.env)
      chunk, compileError = asStatement, statementError
      if not asStatement
        and (tostring(statementError):find("<eof>", 1, true)
          or tostring(expressionError):find("<eof>", 1, true)) then
        self.pending = self:sourceLines(source)
        return { incomplete = true }
      end
    end
  end

  clearBuffer(self.buffer)
  if self.env.component and self.env.component.refresh then
    -- A component may have been placed or broken since the last cell.
    self.env.component.refresh()
  end
  local ok, failure = true, nil

  if chunk then
    local packed = table.pack(pcall(chunk))
    if not packed[1] then
      ok, failure = false, packed[2]
    elseif expression then
      for index = 2, packed.n do
        -- A table result is several lines; each one is a transcript row and
        -- keeps its own length cap.
        local text = displayValue(packed[index])
        for line in (text .. "\n"):gmatch("(.-)\n") do
          if #line > MAX_LINE_CHARS then
            line = line:sub(1, MAX_LINE_CHARS - 1) .. "…"
          end
          pushLine(self.buffer, line)
        end
      end
    end
  else
    ok, failure = false, compileError
  end

  if not ok then
    pushLine(self.buffer, "! " .. self:short(tostring(failure), REPL_PATH))
  end

  self.pending = {}
  self.submissions = self.submissions + 1

  if self.history[#self.history] ~= source then
    self.history[#self.history + 1] = source
    if #self.history > MAX_HISTORY then
      table.remove(self.history, 1)
    end
  end

  local body = {}
  for _, line in ipairs(self.buffer) do
    body[#body + 1] = line
  end
  if self.buffer.truncated then
    body[#body + 1] = string.format(
      "... output truncated (%d lines / %d KB)",
      MAX_RUN_LINES,
      math.floor(MAX_RUN_BYTES / 1024)
    )
  end

  local result = self:record(source, ok, body, started)
  result.error = failure
  result.session = self.name
  self:pushTranscript(result.lines)
  self.runner:append(result)
  return result
end

--- Short form of a compiler or runtime message, for the pane.
function repl:short(message, path)
  return self.runner:short(message, path)
end

--- Last `count` lines of the run log, newest last.
function lab:tail(count)
  count = math.max(1, math.floor(tonumber(count) or 80))
  local vfs = self.kernel.vfs
  local size = vfs.size(lab.LOG) or 0
  if size == 0 then
    return {}
  end

  local data = vfs.readTail(lab.LOG, MAX_TAIL_BYTES)
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
