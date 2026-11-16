-- Status publisher for a line node.
--
-- A line node reads its own line and tells the master what it sees: its name,
-- its worst alarm and its stocks (decision 26). The master owns the merged view
-- and the names, so this module proposes a name, adopts the one the master
-- assigns, and never stops reading when there is no master.
--
-- It also draws the node's own page with raw GPU calls: no framebuffer, no
-- desktop, no apps. That is the whole point of the floppy-sized build.

local net = require("tc.net")
local naming = require("tc.naming")

local report = {}
report.__index = report

report.HEARTBEAT = 30
report.RETRY_MIN = 5
report.RETRY_MAX = 60
report.MAX_STOCKS = 8
report.STATE_PATH = "/var/status/last.tsv"
report.CONFIG_BYTES = 700
-- The only files the master may write on a node. `/etc` is writable from the
-- wire, so the name is checked against this list instead of being joined into a
-- path, and nothing outside `/etc` is reachable.
report.CONFIG_FILES = {
  ["plant.tsv"] = true,
  ["stocks.tsv"] = true,
  ["paths.tsv"] = true,
}

function report.new(options)
  options = options or {}
  local self = setmetatable({}, report)
  self.kernel = options.kernel
  self.vfs = options.vfs
  self.log = options.log
  self.config = options.config
  self.version = options.version or {}
  self.plant = options.plant
  self.computer = options.computer or computer
  self.component = options.component or component
  self.modem = options.modem or net.newModem({
    component = self.component,
    computer = self.computer,
  })
  self.heartbeat = options.heartbeat or report.HEARTBEAT
  self.statePath = options.statePath or report.STATE_PATH

  self.name = nil
  self.provisional = false
  self.assigned = false
  self.master = nil
  self.opened = false
  self.nextSend = 0
  self.retry = 0
  self.sent = 0
  self.failed = 0
  self.lastSignature = ""
  self.lastReason = nil
  self.lastSentAt = nil
  return self
end

--------------------------------------------------------------------------------
-- Identity
--------------------------------------------------------------------------------

--- The stock a line names itself after: the last one configured, because a line
-- declares its input first and its output last, and a single-stock line is its
-- own output.
function report:outputStock(snapshot)
  local stocks = (snapshot and snapshot.stocks) or {}
  if #stocks == 0 then
    return nil
  end
  return stocks[#stocks]
end

--- Guess the name from what the line produces. Labels are display-only, so the
-- guess is persisted once by `persistName` and never recalculated.
function report:guessName(snapshot)
  local stock = self:outputStock(snapshot)
  if not stock then
    return nil
  end
  for _, entry in ipairs(stock.entries or {}) do
    local guess = naming.fromLabel(entry.label)
    if guess then
      return guess
    end
  end
  return nil
end

function report:persistName(name)
  if not self.config or not self.vfs then
    return false
  end
  if self.config.get("name") == name then
    return true
  end
  if not self.config.set("name", name) then
    return false
  end
  local ok, reason = self.config.save(self.vfs)
  if not ok and self.log and self.log.warn then
    self.log:warn("Report: could not save the name: " .. tostring(reason))
  end
  return ok
end

--- The configured name, else the guess from the output, else a provisional name
-- from the address. A provisional name is never persisted: it is a placeholder
-- until the line says what it makes.
function report:resolveName(snapshot)
  snapshot = snapshot or (self.plant and self.plant:snapshot() or nil)
  local configured = self.config and self.config.get("name") or ""
  local normalised = naming.normalise(configured)
  if normalised then
    self.name = normalised
    self.provisional = false
    return normalised
  end

  local guessed = self:guessName(snapshot)
  if guessed then
    self.name = guessed
    self.provisional = false
    self:persistName(guessed)
    return guessed
  end

  self.name = naming.provisional(self.computer.address())
  self.provisional = true
  return self.name
end

--------------------------------------------------------------------------------
-- What it publishes
--------------------------------------------------------------------------------

local function stockField(item, now)
  local rate = "-"
  if type(item.rate) == "number" then
    rate = string.format("%.2f", item.rate)
  end
  return string.format("%s:%s:%s:%s",
    tostring(item.name),
    tostring(item.total or 0),
    tostring(item.state or "?"),
    rate)
end

function report:statusFields()
  local now = self.computer.uptime()
  local snapshot = self.plant and self.plant:snapshot() or nil
  local alarms = (snapshot and snapshot.alarms) or {}
  local worst = alarms[1]

  local memoryUsed = 0
  if self.kernel and type(self.kernel.memory) == "function" then
    local used = self.kernel:memory()
    memoryUsed = tonumber(used) or 0
  end
  local diskUsed = 0
  if self.kernel and type(self.kernel.storage) == "function" then
    local used = self.kernel:storage()
    diskUsed = tonumber(used) or 0
  end

  local fields = {
    id = self.computer.address(),
    name = self.name or "",
    state = "online",
    v = tostring(self.version.version or ""),
    mem = tostring(math.floor(memoryUsed)),
    disk = tostring(math.floor(diskUsed)),
    uptime = tostring(math.floor(now)),
    stocks = tostring(#(snapshot and snapshot.stocks or {})),
  }
  if worst then
    fields.alarm = string.format("%s:%d", tostring(worst.code),
      math.max(0, math.floor(now - (worst.first or now))))
    fields.alarmPath = tostring(worst.source or "")
  end

  local stocks = (snapshot and snapshot.stocks) or {}
  for index = 1, math.min(#stocks, report.MAX_STOCKS) do
    fields["s" .. index] = stockField(stocks[index], now)
  end
  if #stocks > report.MAX_STOCKS then
    fields.more = tostring(#stocks - report.MAX_STOCKS)
  end
  return fields, #stocks
end

--- Encode a frame that fits the 1 KB limit, dropping stocks from the tail when
-- it does not. A line with more stocks than fit still reports its alarms.
local function fitFrame(verb, fields, stockCount)
  local total = fields.stocks
  local count = stockCount
  local frame, reason = net.encode(verb, fields)
  while not frame and count > 0 do
    fields["s" .. count] = nil
    count = count - 1
    fields.more = tostring((tonumber(total) or 0) - count)
    frame, reason = net.encode(verb, fields)
  end
  return frame, reason
end

function report:writeState(fields)
  if not self.vfs then
    return false
  end
  self.vfs.ensureDir("/var/status")
  local keys = {}
  for key in pairs(fields) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local lines = { "# TerraCorp: last published node status" }
  for _, key in ipairs(keys) do
    lines[#lines + 1] = key .. "\t" .. tostring(fields[key])
  end
  local ok, reason = self.vfs.write(self.statePath, table.concat(lines, "\n") .. "\n")
  if not ok and self.log and self.log.warn then
    self.log:warn("Report: could not write " .. self.statePath .. ": " .. tostring(reason))
  end
  return ok
end

--- Publish one frame. Returns true when it went out; a failure backs off.
function report:publish(reason)
  local fields, stockCount = self:statusFields()
  local verb = self.master and "STATUS" or "HELLO"
  local frame, encodeReason = fitFrame(verb, fields, math.min(stockCount, report.MAX_STOCKS))
  self.lastReason = reason

  local ok, sendReason
  if not self.opened then
    ok, sendReason = nil, "no network card"
  elseif not frame then
    ok, sendReason = nil, encodeReason or "could not encode the frame"
  elseif self.master then
    ok, sendReason = self.modem:sendFrame(self.master, frame)
  else
    ok, sendReason = self.modem:broadcast(verb, fields)
  end

  self:writeState(fields)

  local now = self.computer.uptime()
  if ok then
    self.sent = self.sent + 1
    self.retry = 0
    self.lastSentAt = now
    self.nextSend = now + self.heartbeat
  else
    self.failed = self.failed + 1
    self.retry = math.min(self.retry > 0 and self.retry * 2 or report.RETRY_MIN, report.RETRY_MAX)
    self.nextSend = now + self.retry
    if self.log and self.log.debug then
      self.log:debug("Report: " .. tostring(reason) .. " failed: " .. tostring(sendReason))
    end
  end
  return ok == true, sendReason
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function report:start()
  local opened, reason = self.modem:open()
  self.opened = opened == true
  if not self.opened and self.log and self.log.warn then
    self.log:warn("Report: no network card (" .. tostring(reason) .. ")")
  end

  local master = self.config and self.config.get("master") or ""
  self.master = (type(master) == "string" and master ~= "") and master or nil
  self:resolveName()
  self.nextSend = 0
  self:publish("hello")
  return self.opened
end

--- Called every loop: publishes the heartbeat, or immediately when the alarm set
-- changed. A local rename is retried while the name is still provisional.
function report:tick(now)
  now = now or self.computer.uptime()
  local snapshot = self.plant and self.plant:snapshot() or nil

  if not self.name then
    self:resolveName(snapshot)
  elseif self.provisional and not self.assigned then
    local guessed = self:guessName(snapshot)
    if guessed then
      self.name = guessed
      self.provisional = false
      self:persistName(guessed)
    end
  end

  local signature = {}
  for _, alarm in ipairs((snapshot and snapshot.alarms) or {}) do
    signature[#signature + 1] = alarm.key
  end
  local current = table.concat(signature, ",")
  local changed = current ~= self.lastSignature
  self.lastSignature = current

  if changed or now >= (self.nextSend or 0) then
    return self:publish(changed and "alarm" or "heartbeat")
  end
  return false
end

--- Handle one frame from the master. A rename is adopted and persisted; the
-- operator's local name loses, and the log says so.
function report:handle(verb, fields, remote)
  if type(fields) ~= "table" then
    return false
  end
  if verb == "ASSIGN" and fields.id == self.computer.address() then
    local assigned = naming.normalise(fields.name or "")
    if assigned and assigned ~= self.name then
      local previous = self.name
      self.name = assigned
      self.provisional = false
      self.assigned = true
      self:persistName(assigned)
      if self.log and self.log.info then
        self.log:info(string.format("Report: the master named this node %s (was %s)",
          assigned, tostring(previous)))
      end
      self.nextSend = 0
    end
    if type(fields.master) == "string" and fields.master ~= "" then
      self.master = fields.master
    elseif type(remote) == "string" and remote ~= "" then
      self.master = remote
    end
    return true
  end
  if verb == "PING" and fields.id == self.computer.address() then
    self:publish("ping")
    return true
  end
  if verb == "CFG" and fields.id == self.computer.address() then
    local state = self:applyConfig(fields)
    if type(remote) == "string" and remote ~= "" then
      self.modem:send(remote, "CFGACK", {
        id = self.computer.address(),
        file = fields.file or "",
        state = state,
      })
    end
    return true
  end
  return false
end

--- Write a configuration file pushed by the master and reload the plant.
-- Returns the state that goes back in the CFGACK frame.
function report:applyConfig(fields)
  local file = fields.file
  if type(file) ~= "string" or not report.CONFIG_FILES[file] then
    return "rejected"
  end
  local body = fields.body
  if type(body) ~= "string" or body == "" or #body > report.CONFIG_BYTES then
    return "rejected"
  end
  if not self.vfs then
    return "failed"
  end
  self.vfs.ensureDir("/etc")
  local ok, reason = self.vfs.write("/etc/" .. file, body)
  if not ok then
    if self.log and self.log.warn then
      self.log:warn("Report: could not apply /etc/" .. file .. ": " .. tostring(reason))
    end
    return "failed"
  end
  if self.plant and type(self.plant.reload) == "function" then
    pcall(self.plant.reload, self.plant)
  end
  if self.log and self.log.info then
    self.log:info("Report: applied /etc/" .. file .. " from the master")
  end
  return "applied"
end

--------------------------------------------------------------------------------
-- The node's own page, drawn with raw GPU calls
--------------------------------------------------------------------------------

local PAGE = { bg = 15, text = 0, dim = 8, accent = 9, warn = 4, danger = 14 }

function report:draw()
  local kind = "gpu"
  local gpu = self.component.list(kind)()
  local screen = self.component.list("screen")()
  if not gpu or not screen then
    return false
  end
  local ok, _, width, height = pcall(self.component.invoke, gpu, "getResolution")
  if not ok or type(width) ~= "number" or type(height) ~= "number" then
    return false
  end
  pcall(self.component.invoke, gpu, "bind", screen)

  local function put(row, text, color)
    if row > height then
      return
    end
    pcall(self.component.invoke, gpu, "setForeground", color or PAGE.text, true)
    pcall(self.component.invoke, gpu, "set", 1, row,
      tostring(text):sub(1, width))
  end

  pcall(self.component.invoke, gpu, "setBackground", PAGE.bg, true)
  pcall(self.component.invoke, gpu, "fill", 1, 1, width, height, " ")

  local label = self.name or "unnamed"
  put(1, "TerraCorp " .. tostring(self.version.version or "") .. " · " .. label, PAGE.accent)
  put(2, string.format("%s · sent %d · failed %d · %s",
    self.master and ("master " .. tostring(self.master):sub(1, 8)) or "no master",
    self.sent or 0, self.failed or 0,
    self.opened and "card open" or "no card"), PAGE.dim)

  local snapshot = self.plant and self.plant:snapshot() or nil
  local row = 4
  for _, item in ipairs((snapshot and snapshot.stocks) or {}) do
    if row > height - 3 then
      break
    end
    local rate = type(item.rate) == "number" and string.format("%.2f/min", item.rate) or "-"
    put(row, string.format("%-18s %8s %-7s %s",
      tostring(item.name), tostring(item.total or "-"), tostring(item.state), rate), PAGE.text)
    row = row + 1
  end

  local alarms = (snapshot and snapshot.alarms) or {}
  local alarmRow = math.max(row, height - 2)
  if alarms[1] then
    put(alarmRow, string.format("%s %s: %s", tostring(alarms[1].code),
      tostring(alarms[1].source), tostring(alarms[1].message)), PAGE.warn)
  else
    put(alarmRow, self.provisional and "no name yet: name the line in the app"
      or "no alarms", PAGE.dim)
  end
  return true
end

--------------------------------------------------------------------------------
-- The line role runtime
--------------------------------------------------------------------------------

--- Run a line node: read, alarm, publish, draw. Never returns.
function report.run(options)
  options = options or {}
  local self = report.new(options)
  self:start()

  local plant = self.plant
  local nextDraw = 0
  while true do
    local now = self.computer.uptime()
    if plant and type(plant.tick) == "function" then
      pcall(plant.tick, plant)
    end
    self:tick(now)

    local pack = table.pack(pcall(self.computer.pullSignal, 0.25))
    if pack[1] and pack[2] == "modem_message" then
      local _, remote, port, _, message = table.unpack(pack, 3, pack.n)
      if tonumber(port) == net.PORT then
        local verb, fields = net.decode(message)
        if verb then
          self:handle(verb, fields, remote)
        end
      end
    elseif pack[1] and (pack[2] == "shutdown" or pack[2] == "reboot") then
      if plant and type(plant.stop) == "function" then
        pcall(plant.stop, plant)
      end
      return false
    end

    now = self.computer.uptime()
    if now >= nextDraw then
      pcall(self.draw, self)
      nextDraw = now + 1
    end
  end
end

return report
