-- Plant service: local readout, level alarms and node status.
--
-- The OS owns its hall. This module starts the boundary stock reader, evaluates
-- local level alarms against the cache, and reports the node status. It never
-- reads a machine buffer inside a line (decision 24) and never needs the
-- external service to show a number (decision 23).

local stock = require("tc.stock")
local addr = require("tc.addr")
local path = require("tc.path")
local driver = require("tc.driver")
local history = require("tc.history")
local halls = require("tc.halls")

local plant = {}
plant.__index = plant

plant.PLANTS_PATH = "/etc/plant.tsv"
plant.DEFAULT_POLL = 10
plant.STALE_AFTER = 30
plant.POWER_MIN = 15

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function loadThresholds(vfs)
  local thresholds = {}
  local errors = {}
  if not vfs then
    return thresholds, errors
  end
  local text, reason = vfs.read(plant.PLANTS_PATH)
  if not text then
    if vfs.exists(plant.PLANTS_PATH) then
      errors[#errors + 1] = { line = 0, message = "cannot read " .. plant.PLANTS_PATH .. ": " .. tostring(reason) }
    end
    return thresholds, errors
  end

  local number = 0
  for line in text:gmatch("[^\r\n]+") do
    number = number + 1
    local value = trim(line:gsub("#.*$", ""))
    if value ~= "" then
      local name, minText, maxText, expect, trendText =
        value:match("^(%S+)%s+(%S+)%s*(%S*)%s*(%S*)%s*(%S*)$")
      local minimum = tonumber(minText)
      local maximum = maxText ~= "" and tonumber(maxText) or 0
      local trend = trendText ~= "" and tonumber(trendText) or nil
      if not name then
        errors[#errors + 1] = { line = number, message = "expected <stock> <min> [max] [flow|idle] [trend%]" }
      elseif not minimum or minimum < 0 then
        errors[#errors + 1] = { line = number, message = "invalid minimum: " .. tostring(minText) }
      elseif maximum and maximum < 0 then
        errors[#errors + 1] = { line = number, message = "invalid maximum: " .. tostring(maxText) }
      elseif expect ~= "" and expect ~= "flow" and expect ~= "idle" then
        errors[#errors + 1] = { line = number, message = "expect must be flow or idle: " .. expect }
      elseif trendText ~= "" and (not trend or trend <= 0) then
        errors[#errors + 1] = { line = number, message = "invalid trend percentage: " .. trendText }
      else
        thresholds[name] = {
          min = minimum,
          max = maximum or 0,
          flow = expect == "flow",
          trendPercent = trend,
        }
      end
    end
  end
  return thresholds, errors
end

function plant.new(options)
  local self = setmetatable({}, plant)
  options = options or {}
  self.kernel = options.kernel
  self.vfs = options.vfs
  self.log = options.log
  self.version = options.version or {}
  self.pollInterval = options.pollInterval or plant.DEFAULT_POLL
  self.staleAfter = options.staleAfter or plant.STALE_AFTER
  self.powerMin = options.powerMin or plant.POWER_MIN
  self.addr = addr.new({ vfs = self.vfs, log = self.log })
  self.stock = stock.new({
    vfs = self.vfs,
    log = self.log,
    addr = self.addr,
    pollInterval = self.pollInterval,
  })
  self.history = history.new({ vfs = self.vfs, log = self.log })
  self.hallsRegistry = halls.load(self.vfs)
  self.hall = halls.localHall(self.hallsRegistry, computer.address(), self.kernel.hostname)
  self.thresholds = {}
  self.errors = {}
  self.alarmList = {}
  self.alarmState = {}
  self.alarmSignature = ""
  self.configured = false
  self.components = {}
  self.startedAt = computer.uptime()
  self:reload()
  return self
end

function plant:reload()
  local ok, reason = pcall(self.stock.reload, self.stock)
  if not ok and self.log then
    self.log.warn("Plant stock reload: " .. tostring(reason))
  end
  local thresholdErrors
  self.thresholds, thresholdErrors = loadThresholds(self.vfs)

  self.errors = {}
  for _, item in ipairs(self.stock.errors or {}) do
    self.errors[#self.errors + 1] = item
  end
  for _, item in ipairs(thresholdErrors or {}) do
    self.errors[#self.errors + 1] = item
  end

  self.configured = self.stock.configured
  self.alarmState = {}
  self.alarmList = {}
  self.alarmSignature = ""
  self.components = self.addr:scan()
  self.reloadedAt = computer.uptime()
  return true
end

local SEVERITY = { danger = 1, warn = 2, info = 3 }

local function addAlarm(state, order, code, source, severity, message, now)
  local key = code .. ":" .. tostring(source)
  if state[key] then
    return
  end
  state[key] = {
    key = key,
    code = code,
    source = tostring(source),
    severity = severity,
    message = tostring(message),
    first = now,
    last = now,
  }
  order[#order + 1] = state[key]
end

--- Evaluate local level alarms and node power. Returns true when the active
-- alarm set changed. This reads only the cache and the kernel's energy.
function plant:evaluate(now)
  now = now or computer.uptime()
  local nextState = {}
  local order = {}

  for _, item in ipairs(self.stock.stocks or {}) do
    local threshold = self.thresholds[item.name]
    if item.updatedAt then
      if threshold and threshold.min and item.total < threshold.min then
        addAlarm(nextState, order, "STARVED", item.name, "warn",
          string.format("%d below minimum %d", item.total, threshold.min), now)
      end
      if threshold and threshold.max and threshold.max > 0 and item.total > threshold.max then
        addAlarm(nextState, order, "FULL", item.name, "warn",
          string.format("%d above maximum %d", item.total, threshold.max), now)
      end
      if item.state == "unbound" then
        addAlarm(nextState, order, "UNBOUND", item.name, "danger",
          item.error or "no reachable member", now)
      elseif item.state == "coarse" then
        addAlarm(nextState, order, "COARSE", item.name, "warn",
          item.error or "part of the stock could not be read", now)
      end
      local age = now - item.updatedAt
      if age > self.staleAfter then
        addAlarm(nextState, order, "STALE", item.name, "warn",
          string.format("cache is %ds old", age), now)
      end
    end
  end

  local stored, maximum = self.kernel:energy()
  if stored and maximum and maximum > 0 then
    local percent = (stored / maximum) * 100
    if percent < self.powerMin then
      addAlarm(nextState, order, "NO POWER", "node", "danger",
        string.format("power at %.0f%%", percent), now)
    end
  end

  for _, condition in ipairs(self.history:conditions(self.thresholds, now)) do
    addAlarm(nextState, order, condition.code, condition.source,
      condition.severity, condition.message, now)
  end

  -- Preserve first-seen across ticks; last-seen always moves to now.
  for key, alarm in pairs(nextState) do
    local previous = self.alarmState[key]
    if previous then
      alarm.first = previous.first
    end
    alarm.last = now
  end

  table.sort(order, function(a, b)
    local left = SEVERITY[a.severity] or 99
    local right = SEVERITY[b.severity] or 99
    if left == right then
      return a.first < b.first
    end
    return left < right
  end)

  local parts = {}
  for _, alarm in ipairs(order) do
    parts[#parts + 1] = alarm.key
  end
  local signature = table.concat(parts, ",")
  local changed = signature ~= self.alarmSignature
  self.alarmState = nextState
  self.alarmList = order
  self.alarmSignature = signature
  return changed
end

function plant:tick()
  local now = computer.uptime()
  local changed = self.stock:tick(now)
  if changed then
    self.history:record(self.stock.stocks)
  end
  local alarmChanged = self:evaluate(now)
  return changed or alarmChanged
end

function plant:alarms()
  local list = {}
  for index, alarm in ipairs(self.alarmList or {}) do
    list[index] = alarm
  end
  return list
end

function plant:status()
  local used, total = self.kernel:memory()
  local stored, maximum = self.kernel:energy()
  local energy = nil
  if stored and maximum and maximum > 0 then
    energy = (stored / maximum) * 100
  end

  local link = nil
  if self.kernel.link then
    link = {
      enabled = self.kernel.link.enabled == true,
      state = self.kernel.link.state or "armed",
    }
  end

  local now = computer.uptime()
  return {
    version = self.version.version or "?",
    uptime = now,
    memory = { used = used, total = total },
    energy = energy,
    stored = stored,
    maximum = maximum,
    link = link,
    components = #(self.components or {}),
    hall = self.hall and self.hall.name or nil,
    halls = math.max(1, #(self.hallsRegistry and self.hallsRegistry.list or {})),
    stocks = #(self.stock.stocks or {}),
    calls = self.stock.calls,
    scanning = self.stock.scanning,
    cacheAge = self.stock.updatedAt and math.max(0, now - self.stock.updatedAt) or nil,
    historySamples = self.history:count(),
    historyPersisted = self.history.persist,
    configured = self.configured,
    errors = self.errors,
  }
end

function plant:snapshot()
  local snapshot = self.stock:snapshot()
  local rates = self.history:summary()
  for _, item in ipairs(snapshot.stocks or {}) do
    local value = rates[item.name]
    if value then
      item.rate = value.rate
      item.trend = value.trend
      item.rateSpan = value.span
    end
  end
  snapshot.status = self:status()
  snapshot.alarms = self:alarms()
  snapshot.configured = self.configured
  snapshot.errors = self.errors
  return snapshot
end

--- The local hall plus every configured hall that has no snapshot yet. With
-- one machine this is a one-row view; a second hall shows `offline` until it
-- reports through the aggregator.
function plant:hallView()
  local registry = self.hallsRegistry
  if #(registry.list or {}) == 0 then
    registry = halls.new()
    halls.assign(registry, self.hall.name, self.hall.address)
  end
  local snapshots = {
    [self.hall.address] = { snapshot = self:snapshot(), age = 0 },
  }
  return halls.merge(registry, snapshots, { staleAfter = self.staleAfter })
end

function plant:stop()
  if self.addr and self.addr.save then
    self.addr:save()
  end
  if self.history and self.history.save then
    self.history:save()
  end
end

return plant
