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
link.MIN_INTERVAL = 0.5
link.MAX_INTERVAL = 60
link.MAX_LUA_OUTPUT = 16384
link.LOG_PATH = "/var/log/tc.log"

-- Closed command set with the tier each one needs. A frame names one of these;
-- nothing else runs, and `linkControl` decides how far a command can reach.
-- `link.interval` uses the "link" tier: it changes only this client's cadence,
-- touches no user data, and is allowed at every control level.
local COMMANDS = {
  status = "read",
  log = "read",
  check = "read",
  ["fs.list"] = "read",
  ["fs.read"] = "read",
  ["plant.status"] = "read",
  ["plant.snapshot"] = "read",
  ["plant.delta"] = "read",
  ["plant.alarms"] = "read",
  ["plant.book"] = "read",
  ["plant.plan"] = "read",
  ["plant.history"] = "read",
  ["plant.paths"] = "read",
  ["plant.halls"] = "read",
  ["gate.set"] = "write",
  ["link.interval"] = "link",
  ["fs.write"] = "write",
  ["fs.append"] = "write",
  ["fs.mkdir"] = "write",
  ["fs.remove"] = "write",
  ["fs.move"] = "write",
  ["app.open"] = "write",
  ["app.close"] = "write",
  reboot = "write",
  -- Remote Lua. `full` already allows rewriting /lib and rebooting, which is
  -- the same reach; this just makes diagnosis one exchange instead of a cycle.
  lua = "full",
}

-- How far the far side can reach. `off` and `link` share rank 0 on purpose:
-- `link.interval` changes only this client's cadence and touches no user data,
-- so it stays available at every level. Everything else needs a tier the
-- operator chose. `off` used to share rank 1 with `read`, which made it silently
-- mean "read-only"; it now means off.
local TIER_RANK = { link = 0, off = 0, read = 1, write = 2, full = 3 }

-- The accepted `linkControl` values, in the order GAIA offers them.
link.CONTROLS = { "off", "read", "write", "full" }

local CONTROL_SET = { off = true, read = true, write = true, full = true }

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

---------------------------------------------------------------- plant bodies

-- Plant replies are line-oriented: a `format=` line, then scalars as
-- `key=value`, then one record per line. A record is a name followed by
-- `key=value` tokens separated by one space. Every value goes through
-- net.escape, so a label with a space, a tab or a newline can never forge a
-- field or a record. This is the same escaping the wire format already uses.
local function plantScalar(key, value)
  return key .. "=" .. net.escape(tostring(value))
end

local function plantRecord(name, pairs)
  local parts = { name }
  for _, pair in ipairs(pairs) do
    if pair[2] ~= nil then
      parts[#parts + 1] = plantScalar(pair[1], pair[2])
    end
  end
  return table.concat(parts, " ")
end

local function plantNumber(value, digits, fallback)
  local number = tonumber(value)
  if not number then
    return fallback
  end
  if digits then
    return string.format("%." .. tostring(digits) .. "f", number)
  end
  return tostring(math.floor(number))
end

-- Seconds keep whole seconds whole and show a fraction as 0.5, so the reported
-- interval matches what the link actually does after link.interval.
local function plantSeconds(value)
  local number = tonumber(value)
  if not number then
    return "0"
  end
  if number == math.floor(number) then
    return tostring(math.floor(number))
  end
  return string.format("%.1f", number)
end

local function plantAlarmRecord(alarm)
  return plantRecord("alarm", {
    { "code", alarm.code },
    { "source", alarm.source },
    { "severity", alarm.severity },
    { "first", plantNumber(alarm.first, 3, "-1") },
    { "last", plantNumber(alarm.last, 3, "-1") },
    -- Acknowledgement is local to the app; a mirror only reports it.
    { "ack", alarm.ack and "1" or "0" },
    { "message", alarm.message },
  })
end

local function validStockPattern(pattern)
  if type(pattern) ~= "string" or pattern == "" then
    return false
  end
  for segment in pattern:gmatch("[^/]+") do
    if segment ~= "*" and segment ~= "**"
      and not segment:match("^[A-Za-z0-9_%-]+$") then
      return false
    end
  end
  return true
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
  if interval < link.MIN_INTERVAL then
    interval = link.MIN_INTERVAL
  end

  self.sink = sink:gsub("/+$", "")
  self.token = token
  self.interval = interval

  local control = tostring(self.config.get("linkControl") or "off")
  if not CONTROL_SET[control] then
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

  -- OpenComputers sends GET when the post argument is nil and POST when it is a
  -- string, even an empty one, so an empty outbox still passes "". The bridge
  -- serves /link/next as POST only; see docs/opencomputers.md.
  local requestOk, handle, reason = pcall(
    self.component.invoke,
    card,
    "request",
    url,
    body,
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
  elseif cmd == "link.interval" then
    return self:commandInterval(fields.n)
  elseif cmd == "fs.read" then
    return self:commandRead(fields.path)
  elseif cmd == "plant.status" then
    return self:commandPlantStatus()
  elseif cmd == "plant.snapshot" then
    return self:commandPlantSnapshot(fields)
  elseif cmd == "plant.delta" then
    return self:commandPlantDelta(fields)
  elseif cmd == "plant.alarms" then
    return self:commandPlantAlarms(fields)
  elseif cmd == "plant.book" then
    return self:commandPlantBook(fields)
  elseif cmd == "plant.plan" then
    return self:commandPlantPlan(fields)
  elseif cmd == "plant.history" then
    return self:commandPlantHistory(fields)
  elseif cmd == "plant.paths" then
    return self:commandPlantPaths(fields)
  elseif cmd == "plant.halls" then
    return self:commandPlantHalls()
  elseif cmd == "gate.set" then
    return self:commandGateSet(fields)
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
  elseif cmd == "lua" then
    return self:commandLua(fields.data)
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

----------------------------------------------------------------- plant mirror

-- The local plant service owns the readout. These commands only read its cache,
-- so a bridge operator sees exactly what the Plant app shows and never touches
-- a component from the link.

function link:plantService()
  local service = self.kernel and self.kernel.plant
  if type(service) ~= "table" then
    return nil, "plant_unavailable"
  end
  return service
end

function link:localHall()
  return tostring(self.kernel.hostname or "local")
end

-- A single local hall exists in 0.4.2. `local`, `self` and the node address are
-- accepted as aliases; anything else is a hall this node does not own.
function link:checkHall(hall)
  if hall == nil or hall == "" then
    return true
  end
  local wanted = tostring(hall)
  if wanted == "local" or wanted == "self"
    or wanted == self:localHall()
    or wanted == tostring(self.computer.address()) then
    return true
  end
  return nil, "unknown_hall"
end

function link:stockMatches(pattern, name)
  if pattern == nil or pattern == "" then
    return true
  end
  if pattern:find("*", 1, true) then
    local okPath, pathModule = pcall(require, "tc.path")
    if okPath and type(pathModule) == "table" and type(pathModule.matches) == "function" then
      return pathModule.matches(pattern, name)
    end
    return false
  end
  return pattern == name
end

function link:plantScalars(status)
  local memory = type(status.memory) == "table" and status.memory or {}
  local lines = {
    plantScalar("version", status.version or self.version.version or "?"),
    plantScalar("codename", self.version.codename or ""),
    plantScalar("address", self.computer.address()),
    plantScalar("hall", self:localHall()),
    plantScalar("uptime", plantNumber(status.uptime, 1, "0")),
    plantScalar("memory_used_kb", plantNumber((tonumber(memory.used) or 0) / 1024, nil, "0")),
    plantScalar("memory_total_kb", plantNumber((tonumber(memory.total) or 0) / 1024, nil, "0")),
    plantScalar("energy", plantNumber(status.energy, 1, "-1")),
    plantScalar("stored", plantNumber(status.stored, nil, "-1")),
    plantScalar("maximum", plantNumber(status.maximum, nil, "-1")),
    plantScalar("halls", "1"),
    plantScalar("stocks", plantNumber(status.stocks, nil, "0")),
    plantScalar("components", plantNumber(status.components, nil, "0")),
    plantScalar("calls", plantNumber(status.calls, nil, "0")),
    plantScalar("scanning", status.scanning and "1" or "0"),
    plantScalar("cache_age", plantNumber(status.cacheAge, 3, "-1")),
    plantScalar("history_samples", plantNumber(status.historySamples, nil, "0")),
    plantScalar("history_persisted", status.historyPersisted and "1" or "0"),
    plantScalar("configured", status.configured and "1" or "0"),
    plantScalar("errors", plantNumber(#(status.errors or {}), nil, "0")),
  }

  local linkReport = type(status.link) == "table" and status.link or nil
  if linkReport then
    lines[#lines + 1] = plantScalar("link_enabled", linkReport.enabled and "1" or "0")
    lines[#lines + 1] = plantScalar("link_state", linkReport.state or "?")
  end
  return lines
end

function link:commandPlantStatus()
  local service, reason = self:plantService()
  if not service then
    return nil, reason
  end
  local ok, status = pcall(service.status, service)
  if not ok or type(status) ~= "table" then
    return nil, "plant_status_failed"
  end

  local report = self:report()
  local lines = { "format=plant.status.v1" }
  for _, line in ipairs(self:plantScalars(status)) do
    lines[#lines + 1] = line
  end
  lines[#lines + 1] = plantScalar("generation",
    plantNumber(service.stock and service.stock.generation, nil, "0"))
  lines[#lines + 1] = plantScalar("revision",
    plantNumber(service.stock and service.stock.revision, nil, "0"))
  lines[#lines + 1] = plantScalar("alarms", plantNumber(#(service:alarms() or {}), nil, "0"))
  lines[#lines + 1] = plantScalar("link_control", report.control or "off")
  lines[#lines + 1] = plantScalar("link_interval", plantSeconds(report.interval))
  lines[#lines + 1] = plantScalar("link_failures", plantNumber(report.failures, nil, "0"))
  lines[#lines + 1] = plantScalar("link_commands", plantNumber(report.commands, nil, "0"))
  if report.problem then
    lines[#lines + 1] = plantScalar("link_problem", report.problem)
  end
  return table.concat(lines, "\n") .. "\n"
end

-- Shared by `plant.snapshot` and the resync branch of `plant.delta`, so the two
-- verbs can never disagree about what a stock looks like.
function link:plantSnapshotLines(snapshot, filter)
  local lines = {
    plantScalar("at", plantNumber(snapshot.at, 1, "-1")),
    plantScalar("generation", plantNumber(snapshot.generation, nil, "0")),
    plantScalar("revision", plantNumber(snapshot.revision, nil, "0")),
    plantScalar("scanning", snapshot.scanning and "1" or "0"),
    plantScalar("calls", plantNumber(snapshot.calls, nil, "0")),
    plantScalar("configured", snapshot.configured and "1" or "0"),
    plantScalar("halls", "1"),
    plantScalar("hall", self:localHall()),
    plantScalar("stocks", plantNumber(#(snapshot.stocks or {}), nil, "0")),
  }

  for _, stock in ipairs(snapshot.stocks or {}) do
    if self:stockMatches(filter, stock.name) then
      lines[#lines + 1] = plantRecord("stock", {
        { "name", stock.name },
        { "kind", stock.kind },
        { "state", stock.state },
        { "total", plantNumber(stock.total, nil, "0") },
        { "age", plantNumber(stock.age, 3, "-1") },
        { "version", plantNumber(stock.version, nil, "0") },
        { "members", plantNumber(stock.members, nil, "0") },
        { "cardinality", stock.cardinality },
        { "path", stock.path },
        { "rate", stock.rate and plantNumber(stock.rate, 3, nil) or nil },
        { "trend", stock.trend and plantNumber(stock.trend, 1, nil) or nil },
        { "rate_span", stock.rateSpan and plantNumber(stock.rateSpan, nil, nil) or nil },
        { "error", stock.error },
      })
      for _, entry in ipairs(stock.entries or {}) do
        lines[#lines + 1] = plantRecord("entry", {
          { "stock", stock.name },
          { "kind", entry.kind },
          { "key", entry.key },
          { "damage", entry.damage and plantNumber(entry.damage, nil, "0") or nil },
          { "label", entry.label },
          { "count", entry.count and plantNumber(entry.count, nil, "0") or nil },
          { "amount", entry.amount and plantNumber(entry.amount, nil, "0") or nil },
          { "capacity", entry.capacity and plantNumber(entry.capacity, nil, "0") or nil },
          { "hasTag", entry.hasTag and "1" or nil },
          { "tagged", entry.tagged and "1" or nil },
        })
      end
    end
  end

  for _, alarm in ipairs(snapshot.alarms or {}) do
    lines[#lines + 1] = plantAlarmRecord(alarm)
  end
  for _, item in ipairs(snapshot.errors or {}) do
    lines[#lines + 1] = plantRecord("error", {
      { "line", plantNumber(item.line, nil, "0") },
      { "message", item.message },
    })
  end
  return lines
end

function link:commandPlantSnapshot(fields)
  fields = fields or {}
  local okHall, hallReason = self:checkHall(fields.hall)
  if not okHall then
    return nil, hallReason
  end
  local filter = fields.stocks
  if filter ~= nil and filter ~= "" and not validStockPattern(filter) then
    return nil, "bad_stocks"
  end

  local service, reason = self:plantService()
  if not service then
    return nil, reason
  end
  local ok, snapshot = pcall(service.snapshot, service)
  if not ok or type(snapshot) ~= "table" then
    return nil, "plant_snapshot_failed"
  end

  local lines = { "format=plant.snapshot.v1" }
  if filter ~= nil and filter ~= "" then
    lines[#lines + 1] = plantScalar("filter", filter)
  end
  for _, line in ipairs(self:plantSnapshotLines(snapshot, filter)) do
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n") .. "\n"
end

-- A cursor that matches the current revision means nothing changed. Anything
-- else is answered with `resync=1` and a full snapshot in the same body, so a
-- mirror rebuilt after a lost cursor takes one exchange, not a guess.
function link:commandPlantDelta(fields)
  fields = fields or {}
  local cursor = nil
  if fields.cursor ~= nil and fields.cursor ~= "" then
    cursor = tonumber(fields.cursor)
    if not cursor then
      return nil, "bad_cursor"
    end
  end

  local service, reason = self:plantService()
  if not service then
    return nil, reason
  end
  local stock = service.stock
  if type(stock) ~= "table" then
    return nil, "plant_unavailable"
  end

  local revision = tonumber(stock.revision) or 0
  local lines = {
    "format=plant.delta.v1",
    plantScalar("cursor", plantNumber(cursor, nil, "-1")),
    plantScalar("revision", plantNumber(revision, nil, "0")),
    plantScalar("generation", plantNumber(stock.generation, nil, "0")),
  }

  if cursor == revision then
    lines[#lines + 1] = plantScalar("resync", "0")
    lines[#lines + 1] = plantScalar("changes", "0")
    return table.concat(lines, "\n") .. "\n"
  end

  local ok, snapshot = pcall(service.snapshot, service)
  if not ok or type(snapshot) ~= "table" then
    return nil, "plant_snapshot_failed"
  end
  lines[#lines + 1] = plantScalar("resync", "1")
  lines[#lines + 1] = plantScalar("reason", cursor == nil and "no_cursor" or "stale_cursor")
  lines[#lines + 1] = "snapshot_begin"
  for _, line in ipairs(self:plantSnapshotLines(snapshot)) do
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n") .. "\n"
end

function link:commandPlantAlarms(fields)
  fields = fields or {}
  local since = nil
  if fields.since ~= nil and fields.since ~= "" then
    since = tonumber(fields.since)
    if not since then
      return nil, "bad_since"
    end
  end

  local service, reason = self:plantService()
  if not service then
    return nil, reason
  end
  local ok, alarms = pcall(service.alarms, service)
  if not ok or type(alarms) ~= "table" then
    return nil, "plant_alarms_failed"
  end

  local lines = {
    "format=plant.alarms.v1",
    plantScalar("at", plantNumber(self.computer.uptime(), 1, "0")),
    plantScalar("since", plantNumber(since, nil, "-1")),
  }
  local count = 0
  for _, alarm in ipairs(alarms) do
    local last = tonumber(alarm.last) or 0
    if since == nil or last >= since then
      lines[#lines + 1] = plantAlarmRecord(alarm)
      count = count + 1
    end
  end
  lines[#lines + 1] = plantScalar("count", tostring(count))
  return table.concat(lines, "\n") .. "\n"
end

------------------------------------------------------------------- book/plan

function link:bookService()
  local service = self.kernel and self.kernel.book
  if type(service) ~= "table" then
    return nil, "book_unavailable"
  end
  return service
end

function link:commandPlantBook(fields)
  fields = fields or {}
  local service, reason = self:bookService()
  if not service then
    return nil, reason
  end

  local wanted = fields.recipe
  local recipes = service:list()
  if wanted ~= nil and wanted ~= "" then
    local found = nil
    for _, recipe in ipairs(recipes) do
      if recipe.id == wanted then
        found = recipe
        break
      end
    end
    if not found then
      return nil, "unknown_recipe"
    end
    recipes = { found }
  end

  local lines = {
    "format=plant.book.v1",
    plantScalar("recipes", plantNumber(#service.order, nil, "0")),
    plantScalar("errors", plantNumber(#service.errors, nil, "0")),
    plantScalar("configured", service.configured and "1" or "0"),
  }
  for _, recipe in ipairs(recipes) do
    lines[#lines + 1] = plantRecord("recipe", {
      { "id", recipe.id },
      { "label", recipe.label },
      { "machine", recipe.machine },
      { "ticks", plantNumber(recipe.ticks, nil, "0") },
      { "priority", plantNumber(recipe.priority, nil, "0") },
      { "machines", plantNumber(recipe.machines, nil, "1") },
      { "source", recipe.source },
      { "line", recipe.line },
      { "status", recipe.status },
      { "ratio", plantNumber(recipe.ratio, 4, "1.0000") },
    })
    for _, side in ipairs({ "inputs", "outputs" }) do
      local direction = side == "inputs" and "in" or "out"
      for _, term in ipairs(recipe[side] or {}) do
        lines[#lines + 1] = plantRecord("io", {
          { "recipe", recipe.id },
          { "side", direction },
          { "kind", term.kind },
          { "key", term.key },
          { "damage", plantNumber(term.damage, nil, "0") },
          { "qty", plantNumber(term.qty, nil, "0") },
          { "chance", plantNumber(term.chance, 4, "1.0000") },
        })
      end
    end
  end
  for index, item in ipairs(service.errors or {}) do
    lines[#lines + 1] = plantRecord("error", {
      { "index", tostring(index) },
      { "line", plantNumber(item.line, nil, "0") },
      { "message", item.message },
    })
  end
  return table.concat(lines, "\n") .. "\n"
end

function link:commandPlantPlan(fields)
  fields = fields or {}
  local planner = self.kernel and self.kernel.plan
  if type(planner) ~= "table" or type(planner.run) ~= "function" then
    return nil, "plan_unavailable"
  end
  local service, reason = self:plantService()
  if not service then
    return nil, reason
  end
  local qty = 1
  if fields.qty ~= nil and fields.qty ~= "" then
    qty = tonumber(fields.qty)
    if not qty or qty < 1 or qty ~= math.floor(qty) then
      return nil, "invalid_qty"
    end
  end
  if type(fields.target) ~= "string" or fields.target == "" then
    return nil, "invalid_target"
  end

  local okStock, snapshot = pcall(service.stock.snapshot, service.stock)
  if not okStock or type(snapshot) ~= "table" then
    return nil, "plant_snapshot_failed"
  end

  local ok, result, planReason = pcall(planner.run, planner, fields.target, qty, {
    stocks = snapshot.stocks,
  })
  if not ok then
    return nil, "plan_failed"
  end
  if type(result) ~= "table" then
    return nil, tostring(planReason or "plan_failed")
  end

  local lines = {
    "format=plant.plan.v1",
    plantScalar("target", fields.target),
    plantScalar("qty", plantNumber(result.qty, nil, "1")),
    plantScalar("steps", plantNumber(#(result.steps or {}), nil, "0")),
    plantScalar("seconds", plantNumber(result.seconds, 3, "0")),
    plantScalar("rate", plantNumber(result.rate, 6, "0")),
    plantScalar("bottleneck", result.bottleneck and result.bottleneck.recipe or ""),
    plantScalar("book_recipes", plantNumber(result.book and result.book.recipes, nil, "0")),
    plantScalar("book_errors", plantNumber(result.book and result.book.errors, nil, "0")),
  }
  for _, step in ipairs(result.steps or {}) do
    lines[#lines + 1] = plantRecord("step", {
      { "recipe", step.recipe },
      { "label", step.label },
      { "machine", step.machine },
      { "line", step.line },
      { "source", step.source },
      { "status", step.status },
      { "ratio", plantNumber(step.ratio, 4, "1.0000") },
      { "crafts", plantNumber(step.crafts, nil, "0") },
      { "seconds", plantNumber(step.seconds, 3, "0") },
      { "rate", plantNumber(step.rate, 6, "0") },
    })
  end
  for _, item in ipairs(result.shortfall or {}) do
    lines[#lines + 1] = plantRecord("shortfall", {
      { "kind", item.kind },
      { "key", item.key },
      { "damage", plantNumber(item.damage, nil, "0") },
      { "need", plantNumber(item.need, nil, "0") },
      { "have", plantNumber(item.have, nil, "0") },
      { "missing", plantNumber(item.missing, nil, "0") },
    })
  end
  for _, item in ipairs(result.warnings or {}) do
    lines[#lines + 1] = plantRecord("warning", {
      { "code", item.code },
      { "recipe", item.recipe },
      { "key", item.key },
      { "ratio", item.ratio and plantNumber(item.ratio, 4, nil) or nil },
    })
  end
  return table.concat(lines, "\n") .. "\n"
end

function link:commandPlantHistory(fields)
  fields = fields or {}
  local service, reason = self:plantService()
  if not service then
    return nil, reason
  end
  local store = service.history
  if type(store) ~= "table" or type(store.samples) ~= "table" then
    return nil, "history_unavailable"
  end

  local limit = math.floor(tonumber(fields.n) or 60)
  if limit < 1 then
    limit = 1
  elseif limit > 360 then
    limit = 360
  end
  local wanted = fields.stock

  local names = {}
  for name in pairs(store.samples) do
    if wanted == nil or wanted == "" or wanted == name then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  if wanted ~= nil and wanted ~= "" and #names == 0 then
    return nil, "unknown_stock"
  end

  local lines = {
    "format=plant.history.v1",
    plantScalar("at", plantNumber(self.computer.uptime(), 1, "0")),
    plantScalar("limit", tostring(limit)),
    plantScalar("stocks", tostring(#names)),
  }
  for _, name in ipairs(names) do
    local list = store.samples[name]
    local rate = store:rate(name)
    local trend = store:trend(name)
    lines[#lines + 1] = plantRecord("stock", {
      { "name", name },
      { "samples", plantNumber(#list, nil, "0") },
      { "rate", rate and plantNumber(rate.rate, 3, nil) or nil },
      { "rate_span", rate and plantNumber(rate.span, nil, nil) or nil },
      { "trend", trend and plantNumber(trend.percent, 1, nil) or nil },
      { "first", plantNumber(list[1] and list[1].t, 1, nil) },
      { "last", plantNumber(list[#list] and list[#list].t, 1, nil) },
    })
    local first = math.max(1, #list - limit + 1)
    for index = first, #list do
      local sample = list[index]
      lines[#lines + 1] = plantRecord("sample", {
        { "stock", name },
        { "t", plantNumber(sample.t, 1, "0") },
        { "total", plantNumber(sample.total, nil, "0") },
        { "state", sample.state },
      })
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

function link:commandPlantPaths(fields)
  fields = fields or {}
  local service, reason = self:plantService()
  if not service then
    return nil, reason
  end
  local registry = service.stock and service.stock.paths
  if type(registry) ~= "table" or type(registry.paths) ~= "table" then
    return nil, "paths_unavailable"
  end

  local pattern = fields.path
  if pattern ~= nil and pattern ~= "" and not validStockPattern(pattern) then
    return nil, "bad_path"
  end

  local names = {}
  for name in pairs(registry.paths) do
    if pattern == nil or pattern == "" or self:stockMatches(pattern, name) then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  if pattern ~= nil and pattern ~= "" and #names == 0 then
    return nil, "unknown_path"
  end

  local lines = {
    "format=plant.paths.v1",
    plantScalar("paths", tostring(#names)),
  }
  for _, name in ipairs(names) do
    local entry = registry.paths[name]
    local used = 0
    for _, item in ipairs(service.stock.stocks or {}) do
      if item.path == name then
        used = used + 1
      end
    end
    lines[#lines + 1] = plantRecord("path", {
      { "name", name },
      { "cardinality", entry.cardinality },
      { "members", plantNumber(#entry.members, nil, "0") },
      { "stocks", tostring(used) },
      { "bound", #entry.members > 0 and "1" or "0" },
    })
  end
  for _, item in ipairs(service.stock.errors or {}) do
    lines[#lines + 1] = plantRecord("error", {
      { "line", plantNumber(item.line, nil, "0") },
      { "message", item.message },
    })
  end
  return table.concat(lines, "\n") .. "\n"
end

function link:commandPlantHalls()
  local service, reason = self:plantService()
  if not service then
    return nil, reason
  end
  if type(service.hallView) ~= "function" then
    return nil, "halls_unavailable"
  end
  local ok, view = pcall(service.hallView, service)
  if not ok or type(view) ~= "table" then
    return nil, "halls_failed"
  end

  local lines = {
    "format=plant.halls.v1",
    plantScalar("halls", plantNumber(#(view.halls or {}), nil, "0")),
    plantScalar("online", plantNumber(view.online, nil, "0")),
    plantScalar("stale", plantNumber(view.stale, nil, "0")),
    plantScalar("offline", plantNumber(view.offline, nil, "0")),
  }
  for _, hall in ipairs(view.halls or {}) do
    lines[#lines + 1] = plantRecord("hall", {
      { "name", hall.name },
      { "state", hall.state },
      { "stocks", plantNumber(hall.stocks, nil, "0") },
      { "age", hall.age and plantNumber(hall.age, 1, nil) or nil },
    })
  end
  for _, stock in ipairs(view.stocks or {}) do
    lines[#lines + 1] = plantRecord("stock", {
      { "hall", stock.hall },
      { "name", stock.name },
      { "kind", stock.kind },
      { "state", stock.state },
      { "total", plantNumber(stock.total, nil, "0") },
      { "rate", stock.rate and plantNumber(stock.rate, 3, nil) or nil },
    })
  end
  return table.concat(lines, "\n") .. "\n"
end

function link:commandGateSet(fields)
  fields = fields or {}
  local gateService = self.kernel and self.kernel.gate
  if type(gateService) ~= "table" or type(gateService.reconcile) ~= "function" then
    return nil, "gate_unavailable"
  end
  local name = fields.line
  if type(name) ~= "string" or name == "" then
    return nil, "missing_line"
  end
  local record = gateService:line(name)
  if not record then
    return nil, "unknown_line"
  end

  local ok, reason = gateService:set(name, fields.state)
  if not ok then
    return nil, reason
  end

  local context = {}
  local plant = self.kernel.plant
  if plant and plant.stock then
    local thresholds = plant.thresholds or {}
    local function stock(name)
      for _, item in ipairs(plant.stock.stocks or {}) do
        if item.name == name then
          return item
        end
      end
      return nil
    end
    if record.input then
      local item = stock(record.input)
      if item then
        local threshold = thresholds[record.input] or {}
        context.input = { total = item.total, min = threshold.min }
      end
    end
    if record.output then
      local item = stock(record.output)
      if item then
        local threshold = thresholds[record.output] or {}
        context.output = { total = item.total, max = threshold.max }
      end
    end
  end

  local okProxy, proxy = pcall(component.proxy, record.component)
  local applied, actual = gateService:reconcile(name, okProxy and proxy or nil, context)
  if applied then
    return string.format("line=%s desired=%s actual=%s\n",
      name, tostring(record.desired), tostring(actual))
  end
  return string.format("line=%s desired=%s refused=%s\n",
    name, tostring(record.desired), tostring(actual))
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

-- Change this client's polling cadence from the bridge. Clamped to
-- MIN/MAX_INTERVAL, persisted in the preferences file and applied on the next
-- scheduling decision, so it survives a reboot.
function link:commandInterval(value)
  local seconds = tonumber(value) or 0
  if seconds < link.MIN_INTERVAL then
    return nil, "bad_interval"
  end
  if seconds > link.MAX_INTERVAL then
    seconds = link.MAX_INTERVAL
  end

  local previous = self.interval
  if not self.config.set("linkInterval", seconds) then
    return nil, "refused"
  end
  if type(self.kernel.saveConfig) == "function" then
    pcall(self.kernel.saveConfig, self.kernel)
  end
  self:refresh()
  self.log.info(string.format(
    "link: interval %ss -> %ss",
    tostring(previous),
    tostring(self.interval)
  ))
  return "interval=" .. tostring(self.interval) .. "s\n"
end

-- Run a Lua chunk in the same environment the Lab gives a script, so a probe
-- typed from the bridge behaves like one typed in-game. The transcript is the
-- reply body; a compile or runtime failure is reported as an `error:` line
-- because the protocol's LREP only carries a reason slug.
--
-- This is `full` control: the chunk runs on the desktop loop with the kernel in
-- reach, has no instruction budget, and a runaway loop freezes the node until
-- it reboots, exactly like the Lab.
function link:commandLua(source)
  if type(source) ~= "string" or source == "" then
    return nil, "missing_source"
  end

  local okLab, labModule = pcall(require, "tc.lab")
  if not okLab or type(labModule) ~= "table" then
    return nil, "lab_unavailable"
  end

  local output = {}
  local env = labModule.new(self.kernel):environment(output)
  local chunk, compileError = load(source, "=link", "t", env)
  if not chunk then
    return "error: " .. tostring(compileError) .. "\n"
  end

  local passed, failure = pcall(chunk)
  local body = table.concat(output, "\n")
  if not passed then
    body = body .. (body ~= "" and "\n" or "") .. "error: " .. tostring(failure)
  end

  if #body > link.MAX_LUA_OUTPUT then
    body = body:sub(1, link.MAX_LUA_OUTPUT) .. "\n... truncated\n"
  end
  if body == "" then
    return "ok\n"
  end
  return body .. "\n"
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
  -- The VFS methods are dot-style (`vfs.write(path, data)`), not methods that
  -- take the instance first. Passing self here made open() receive the table.
  local ok = writer(path, data)
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
