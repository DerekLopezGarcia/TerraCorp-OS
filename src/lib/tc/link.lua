-- External Link client.
--
-- Polls a bridge over outbound HTTP and runs a closed command set. OpenComputers
-- has no inbound ports, so this side is always the client: the bridge queues
-- work and this module collects it on its interval.
--
-- Wire format, command set and security model: docs/external-link.md.
-- Off unless `linkSink` and `linkToken` are both set in /etc/terracorp.cfg.
--
-- The exchange is a state machine that performs at most one HTTP operation per
-- desktop frame, so a slow bridge cannot hold the UI for a whole request.

local net = require("tc.net")

local link = {}
link.__index = link

link.MAX_RESPONSE = 64 * 1024
link.READ_CHUNK = 8192
link.SLICE = 180
link.MAX_COMMANDS = 8
link.LOG_LINES = 40
link.LOG_MAX_LINES = 200
link.TIMEOUT = 30
link.LOG_PATH = "/var/log/tc.log"

-- Closed command set with the tier each one needs. A frame names one of these;
-- nothing else runs, and `linkControl` decides how far a command can reach.
local COMMANDS = {
  status = "read",
  log = "read",
  check = "read",
  ["fs.list"] = "read",
  ["fs.read"] = "read",
  ["fs.write"] = "write",
  ["fs.append"] = "write",
  ["fs.mkdir"] = "write",
  ["fs.remove"] = "write",
  ["fs.move"] = "write",
  ["app.open"] = "write",
  ["app.close"] = "write",
  reboot = "write",
}

local TIER_RANK = { off = 1, read = 1, write = 2, full = 3 }

-- Files that belong to the running OS. Touching them needs `linkControl = full`
-- because a bad write there leaves a computer that cannot boot.
local PROTECTED = { "/init.lua", "/boot/", "/lib/", "/apps/" }

local function isProtected(path)
  for _, prefix in ipairs(PROTECTED) do
    if path:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

local function splitLines(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  return lines
end

function link.new(env)
  local self = setmetatable({}, link)
  self.kernel = env.kernel
  self.config = env.config
  self.vfs = env.vfs
  self.log = env.log
  self.version = env.version
  self.component = env.component or component
  self.computer = env.computer or computer

  self.outbox = {}
  self.buffer = {}
  self.received = 0
  self.failures = 0
  self.lastProblem = nil
  self.state = "idle"
  self.nextAt = 0
  self.handle = nil
  self.deadline = nil
  self.commands = 0
  self.lastCommand = nil
  self.lastAt = nil

  self:refresh()
  return self
end
-- Re-read the three keys that drive the link. Cheap enough to run per frame and
-- it makes a settings change take effect without a reboot.
function link:refresh()
  local sink = self.config.get("linkSink") or ""
  local token = self.config.get("linkToken") or ""
  local interval = tonumber(self.config.get("linkInterval")) or 5
  if interval < 1 then
    interval = 1
  end

  self.sink = sink:gsub("/+$", "")
  self.token = token
  self.interval = interval

  local control = tostring(self.config.get("linkControl") or "off")
  if control ~= "write" and control ~= "full" then
    control = "off"
  end
  self.control = control

  self.enabled = self.sink ~= "" and self.token ~= ""
  if not self.enabled then
    self:drop("disabled")
  end
  return self.enabled
end

-- Release an open handle without raising. Called from every exit path.
function link:drop(nextState)
  if self.handle then
    pcall(self.handle.close)
    self.handle = nil
  end
  self.buffer = {}
  self.received = 0
  self.deadline = nil
  self.state = nextState or "idle"
end

function link:close()
  self:drop("idle")
end

----------------------------------------------------------------- state machine

function link:tick()
  if not self:refresh() then
    return
  end

  local now = self.computer.uptime()

  -- A scheduled restart happens here so the acknowledgement is already posted.
  if self.rebootAt and now >= self.rebootAt then
    self.rebootAt = nil
    self:drop("idle")
    self.log.info("link: restarting")
    pcall(self.kernel.poweroff, self.kernel, true)
    return
  end

  if self.deadline and now > self.deadline then
    self:fail("timeout", now)
    return
  end

  if self.state == "idle" then
    if now >= self.nextAt then
      self:beginExchange(now)
    end
  elseif self.state == "connect" then
    self:stepConnect(now)
  elseif self.state == "response" then
    self:stepResponse(now)
  elseif self.state == "read" then
    self:stepRead(now)
  end
end

function link:beginExchange(now)
  local card = self.component.list("internet")()
  if not card then
    self:fail("no_card", now)
    return
  end

  local pending = self.outbox
  local body = ""
  if #pending > 0 then
    body = table.concat(pending, "\n") .. "\n"
  end

  local url = self.sink .. "/link/next?node=" .. tostring(self.computer.address())
  local headers = {
    ["X-Link-Token"] = self.token,
    ["Content-Type"] = "text/plain; charset=utf-8",
    ["Accept"] = "text/plain",
  }

  local requestOk, handle, reason = pcall(
    self.component.invoke,
    card,
    "request",
    url,
    body ~= "" and body or nil,
    headers
  )
  if not requestOk then
    self:fail("request_failed", now)
    return
  end
  if not handle then
    self:fail("request_failed", now)
    return
  end

  -- The results were accepted, so the outbox only clears on a successful start.
  self.outbox = {}
  self.handle = handle
  self.buffer = {}
  self.received = 0
  self.deadline = now + link.TIMEOUT
  self.state = type(handle.finishConnect) == "function" and "connect" or "response"
end

function link:stepConnect(now)
  local ok, connected = pcall(self.handle.finishConnect)
  if not ok then
    self:fail("connect_failed", now)
    return
  end
  if connected then
    self.state = "response"
  end
end

function link:stepResponse(now)
  local ok, status = pcall(self.handle.response)
  if not ok then
    self:fail("response_failed", now)
    return
  end
  if type(status) == "number" then
    if status ~= 200 then
      self:fail("http_" .. tostring(status), now)
      return
    end
    self.state = "read"
    return
  end
  if status ~= nil then
    self:fail("response_failed", now)
  end
end

function link:stepRead(now)
  local ok, chunk = pcall(self.handle.read, link.READ_CHUNK)
  if not ok then
    self:fail("read_failed", now)
    return
  end
  if chunk == nil then
    self:finishExchange(now)
    return
  end
  if type(chunk) == "string" and chunk ~= "" then
    self.received = self.received + #chunk
    if self.received > link.MAX_RESPONSE then
      self:fail("response_too_large", now)
      return
    end
    self.buffer[#self.buffer + 1] = chunk
  end
end

function link:finishExchange(now)
  local body = table.concat(self.buffer)
  self:drop("idle")

  local handled = 0
  for _, line in ipairs(splitLines(body)) do
    if handled >= link.MAX_COMMANDS then
      self.log.warn("link: reply had more than " .. link.MAX_COMMANDS .. " commands; the rest was dropped")
      break
    end
    if line ~= "" then
      handled = handled + 1
      self:handleFrame(line)
    end
  end

  self.failures = 0
  if self.lastProblem then
    self.log.info("link: recovered after " .. tostring(self.lastProblem))
    self.lastProblem = nil
  end
  self.nextAt = now + self.interval
end

function link:fail(reason, now)
  self:drop("idle")
  self.failures = self.failures + 1
  local backoff = self.interval * math.min(self.failures, 6)
  self.nextAt = now + backoff
  if reason ~= self.lastProblem then
    self.log.warn("link: " .. tostring(reason) .. " (retrying every " .. tostring(backoff) .. "s)")
    self.lastProblem = reason
  end
end

-------------------------------------------------------------------- dispatching

function link:handleFrame(frame)
  local verb, fields = net.decode(frame)
  if not verb then
    -- A bridge that answers with garbage must not advance any cursor.
    self.log.warn("link: rejected reply (" .. tostring(fields) .. ")")
    return false
  end
  if verb ~= "LINK" then
    self.log.warn("link: unexpected verb " .. tostring(verb))
    return false
  end

  if fields.token ~= self.token then
    self:queueError(fields.id, "unauthorized")
    self.log.warn("link: rejected a command with a bad token")
    return false
  end

  local needs = COMMANDS[fields.cmd]
  if not needs then
    self:queueError(fields.id, "unknown_cmd")
    return false
  end
  if TIER_RANK[needs] > TIER_RANK[self.control] then
    self:queueError(fields.id, "needs_" .. needs .. "_control")
    self.log.warn("link: " .. tostring(fields.cmd) .. " needs " .. needs .. " control")
    return false
  end

  -- A command returns its body, or nil plus a reason slug.
  local body, reason = self:run(fields.cmd, fields)
  if type(body) == "string" then
    self:queueBody(fields.id, body)
  else
    self:queueError(fields.id, reason or "failed")
  end
  self.commands = self.commands + 1
  self.lastCommand = tostring(fields.cmd)
  self.lastAt = self.computer.uptime()
  return true
end

function link:encode(verb, fields)
  local frame, reason = net.encode(verb, fields)
  if not frame then
    self.log.error("link: could not build " .. tostring(verb) .. ": " .. tostring(reason))
    return false
  end
  self.outbox[#self.outbox + 1] = frame
  return true
end

function link:queueError(id, reason)
  self:encode("LREP", {
    id = id,
    token = self.token,
    state = "error",
    reason = reason,
  })
end

-- LREP carries the size, LDATA carries the body in slices that always fit one
-- frame after escaping, and LEND closes it.
function link:queueBody(id, body)
  body = body or ""
  self:encode("LREP", {
    id = id,
    token = self.token,
    state = "ok",
    size = tostring(#body),
  })

  local offset = 0
  while offset < #body do
    self:encode("LDATA", {
      id = id,
      off = tostring(offset),
      data = body:sub(offset + 1, offset + link.SLICE),
    })
    offset = offset + link.SLICE
  end

  self:encode("LEND", {
    id = id,
    token = self.token,
    size = tostring(#body),
  })
end

--------------------------------------------------------------------- commands

function link:run(cmd, fields)
  if type(cmd) ~= "string" or not COMMANDS[cmd] then
    return nil, "unknown_cmd"
  end
  if cmd == "status" then
    return self:commandStatus()
  elseif cmd == "log" then
    return self:commandLog(fields.n)
  elseif cmd == "check" then
    return self:commandCheck()
  elseif cmd == "fs.list" then
    return self:commandList(fields.path)
  elseif cmd == "fs.read" then
    return self:commandRead(fields.path)
  elseif cmd == "fs.write" then
    return self:commandWrite(fields.path, fields.data, "w")
  elseif cmd == "fs.append" then
    return self:commandWrite(fields.path, fields.data, "a")
  elseif cmd == "fs.mkdir" then
    return self:commandMkdir(fields.path)
  elseif cmd == "fs.remove" then
    return self:commandRemove(fields.path)
  elseif cmd == "fs.move" then
    return self:commandMove(fields.path, fields.arg)
  elseif cmd == "app.open" then
    return self:commandOpen(fields.arg)
  elseif cmd == "app.close" then
    return self:commandClose(fields.arg)
  elseif cmd == "reboot" then
    return self:commandReboot()
  end
  return nil, "unknown_cmd"
end

function link:commandStatus()
  local lines = {
    "product=" .. tostring(self.version.product),
    "version=" .. tostring(self.version.version),
    "address=" .. tostring(self.computer.address()),
    string.format("uptime=%.1fs", tonumber(self.computer.uptime()) or 0),
  }

  local okMemory, used, total = pcall(self.kernel.memory, self.kernel)
  if okMemory and type(used) == "number" and type(total) == "number" then
    lines[#lines + 1] = string.format(
      "memory=%dKB/%dKB",
      math.floor(used / 1024),
      math.floor(total / 1024)
    )
  end

  local okComponents, components = pcall(self.kernel.components, self.kernel)
  if okComponents and type(components) == "table" and type(components.total) == "number" then
    lines[#lines + 1] = "components=" .. tostring(components.total)
  end

  return table.concat(lines, "\n") .. "\n"
end

function link:commandLog(count)
  local wanted = math.floor(tonumber(count) or link.LOG_LINES)
  if wanted < 1 then
    wanted = 1
  end
  if wanted > link.LOG_MAX_LINES then
    wanted = link.LOG_MAX_LINES
  end

  local text, reason = self.vfs.read(link.LOG_PATH)
  if not text then
    return nil, "no_log"
  end

  local lines = splitLines(text)
  local first = math.max(1, #lines - wanted + 1)
  local tail = {}
  for index = first, #lines do
    tail[#tail + 1] = lines[index]
  end
  if #tail == 0 then
    return ""
  end
  return table.concat(tail, "\n") .. "\n"
end

function link:commandCheck()
  local parts = { "## status", self:commandStatus() }

  local okComponents, components = pcall(self.kernel.components, self.kernel)
  if okComponents and type(components) == "table" and type(components.entries) == "table" then
    parts[#parts + 1] = "## devices"
    local listed = {}
    for _, entry in ipairs(components.entries) do
      listed[#listed + 1] = string.format("%s x%d", tostring(entry.kind), entry.count)
    end
    parts[#parts + 1] = table.concat(listed, "\n") .. "\n"
  end

  local tail = self:commandLog(20)
  if tail then
    parts[#parts + 1] = "## log"
    parts[#parts + 1] = tail
  end

  return table.concat(parts, "\n")
end

function link:commandList(path)
  if type(path) ~= "string" or path == "" then
    return nil, "missing_path"
  end
  local names = self.vfs.list(path)
  if type(names) ~= "table" then
    return nil, "list_failed"
  end
  if #names == 0 then
    return ""
  end
  return table.concat(names, "\n") .. "\n"
end

function link:commandRead(path)
  if type(path) ~= "string" or path == "" then
    return nil, "missing_path"
  end
  local body = self.vfs.read(path)
  if type(body) ~= "string" then
    return nil, "read_failed"
  end
  return body
end

-- The only command that changes what the operator sees. It opens an app that is
-- already installed; it cannot load one.
function link:commandOpen(id)
  if type(id) ~= "string" or id == "" then
    return nil, "missing_arg"
  end
  local ui = self.kernel.ui
  if type(ui) ~= "table" or type(ui.open) ~= "function" then
    return nil, "no_desktop"
  end
  local ok, reason = pcall(ui.open, ui, id)
  if not ok then
    self.log.error("link: app.open " .. tostring(id) .. " failed: " .. tostring(reason))
    return nil, "open_failed"
  end
  return "opened=" .. id .. "\n"
end

function link:commandClose(id)
  if type(id) ~= "string" or id == "" then
    return nil, "missing_arg"
  end
  local ui = self.kernel.ui
  if type(ui) ~= "table"
    or type(ui.findWindow) ~= "function"
    or type(ui.close) ~= "function" then
    return nil, "no_desktop"
  end
  local window = ui:findWindow(id)
  if not window then
    return nil, "not_open"
  end
  pcall(ui.close, ui, window)
  return "closed=" .. id .. "\n"
end

-- Guard shared by every write: the OS tree is only reachable at `full`.
function link:guardPath(path)
  if isProtected(path) and self.control ~= "full" then
    return "needs_full_control"
  end
  return nil
end

function link:commandWrite(path, data, mode)
  if type(path) ~= "string" or path == "" then
    return nil, "missing_path"
  end
  if type(data) ~= "string" then
    return nil, "missing_data"
  end
  local guard = self:guardPath(path)
  if guard then
    return nil, guard
  end

  local writer = mode == "a" and self.vfs.append or self.vfs.write
  if type(writer) ~= "function" then
    return nil, "unsupported"
  end
  local ok = writer(self.vfs, path, data)
  if not ok then
    return nil, "write_failed"
  end
  self.log.info("link: wrote " .. path .. " (" .. #data .. " B)")
  return "wrote=" .. tostring(#data) .. "\n"
end

function link:commandMkdir(path)
  if type(path) ~= "string" or path == "" then
    return nil, "missing_path"
  end
  local guard = self:guardPath(path)
  if guard then
    return nil, guard
  end
  if type(self.vfs.ensureDir) ~= "function" then
    return nil, "unsupported"
  end
  local ok = self.vfs.ensureDir(path)
  if not ok then
    return nil, "mkdir_failed"
  end
  return "mkdir=" .. path .. "\n"
end

function link:commandRemove(path)
  if type(path) ~= "string" or path == "" then
    return nil, "missing_path"
  end
  local guard = self:guardPath(path)
  if guard then
    return nil, guard
  end
  if type(self.vfs.remove) ~= "function" then
    return nil, "unsupported"
  end
  local ok = self.vfs.remove(path)
  if not ok then
    return nil, "remove_failed"
  end
  self.log.info("link: removed " .. path)
  return "removed=" .. path .. "\n"
end

function link:commandMove(from, to)
  if type(from) ~= "string" or from == "" then
    return nil, "missing_path"
  end
  if type(to) ~= "string" or to == "" then
    return nil, "missing_arg"
  end
  local guard = self:guardPath(from) or self:guardPath(to)
  if guard then
    return nil, guard
  end
  if type(self.vfs.rename) ~= "function" then
    return nil, "unsupported"
  end
  local ok = self.vfs.rename(from, to)
  if not ok then
    return nil, "move_failed"
  end
  self.log.info("link: moved " .. from .. " to " .. to)
  return "moved=" .. to .. "\n"
end

-- Restarting is deferred by two intervals so the acknowledgement reaches the
-- bridge before the computer goes down.
function link:commandReboot()
  local kernel = self.kernel
  if type(kernel.poweroff) ~= "function" then
    return nil, "unsupported"
  end
  self.rebootAt = self.computer.uptime() + (self.interval * 2)
  self.log.info("link: reboot scheduled")
  return "reboot=scheduled\n"
end

-- Snapshot for the GAIA app. Read-only: it must not disturb the state machine.
function link:report()
  return {
    enabled = self.enabled == true,
    sink = self.sink,
    control = self.control or "off",
    interval = self.interval,
    failures = self.failures,
    problem = self.lastProblem,
    queued = #self.outbox,
    state = self.state,
    commands = self.commands,
    lastCommand = self.lastCommand,
    lastAt = self.lastAt,
  }
end

return link
