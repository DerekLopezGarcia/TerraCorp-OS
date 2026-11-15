-- Bounded sample ring for the plant readout.
--
-- One sample is one finished scan: wall-clock time, stock total and state. The
-- ring keeps the last MAX_SAMPLES per stock and the file is append-only with a
-- compaction threshold, so history survives a reboot without growing without a
-- bound. Rates are items (or mB) per minute; a stock marked `flow` in
-- /etc/plant.tsv raises STALLED when it does not move and TREND when its rate
-- changes by more than the configured percentage.
--
-- The sandbox clock (`os.time`) can be frozen or reset by the host, so the ring
-- does not trust it. A sample is stamped with `base + computer.uptime()`, and
-- `base` continues from the newest persisted sample: timestamps are monotonic
-- across a reboot, and offline time is not counted as "no movement" in a rate.

local history = {}
history.__index = history

history.PATH = "/var/plant/history.tsv"
history.MAX_SAMPLES = 720
history.MAX_LINES = 4000
history.MIN_SPAN = 5
history.RATE_WINDOW = 120
history.STALL_WINDOW = 60
history.TREND_WINDOW = 120
history.TREND_PERCENT = 50
history.MIN_TREND_RATE = 1

local function uptimeClock()
  local ok, value = pcall(computer.uptime)
  if ok and type(value) == "number" then
    return value
  end
  return 0
end

function history.new(options)
  local self = setmetatable({}, history)
  options = options or {}
  self.vfs = options.vfs
  self.log = options.log
  self.path = options.path or history.PATH
  self.maxSamples = options.maxSamples or history.MAX_SAMPLES
  self.maxLines = options.maxLines or history.MAX_LINES
  self.base = tonumber(options.base) or 0
  if options.clock then
    self.clock = options.clock
  else
    self.clock = function()
      return self.base + uptimeClock()
    end
  end
  self.samples = {}
  self.lines = 0
  self.persist = self.vfs ~= nil
  self:load()
  -- Continue after the newest persisted sample. A hard reboot may lose the
  -- last few seconds of samples, but the next one can never go backwards.
  local newest = 0
  for _, list in pairs(self.samples) do
    local sample = list[#list]
    if sample and sample.t > newest then
      newest = sample.t
    end
  end
  if newest > self.base then
    self.base = newest
  end
  return self
end

function history:now()
  local ok, value = pcall(self.clock)
  if ok and type(value) == "number" then
    return value
  end
  return nil
end

local function countSamples(self)
  local total = 0
  for _, list in pairs(self.samples) do
    total = total + #list
  end
  return total
end

local function appendSample(self, name, stamp, total, kind, state)
  local list = self.samples[name]
  if not list then
    list = {}
    self.samples[name] = list
  end
  local last = list[#list]
  if last and last.t == stamp then
    last.total = total
    last.kind = kind
    last.state = state
    return
  end
  if last and stamp < last.t then
    return
  end
  list[#list + 1] = { t = stamp, total = total, kind = kind, state = state }
  while #list > self.maxSamples do
    table.remove(list, 1)
  end
end

--- Load the persisted ring. A missing file is a normal first boot; malformed
-- lines are skipped, never guessed.
function history:load()
  if not self.persist then
    return true
  end
  local text = self.vfs.read(self.path)
  if type(text) ~= "string" then
    return true
  end
  for line in text:gmatch("[^\r\n]+") do
    if line:sub(1, 1) ~= "#" then
      local stamp, name, kind, total, state =
        line:match("^(%d+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
      local number = tonumber(total)
      if stamp and name and number then
        self.lines = self.lines + 1
        appendSample(self, name, tonumber(stamp), number, kind, state)
      end
    end
  end
  if self.lines > countSamples(self) then
    self:compact()
  end
  return true
end

local function formatLine(stamp, name, kind, total, state)
  return string.format("%d\t%s\t%s\t%g\t%s\n", math.floor(stamp), name, kind, total, state or "?")
end

function history:compact()
  if not self.persist then
    return false
  end
  self.vfs.ensureDir("/var/plant")
  local lines = { "# TerraCorp: plant history (epoch, stock, kind, total, state)" }
  local names = {}
  for name in pairs(self.samples) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    for _, sample in ipairs(self.samples[name]) do
      lines[#lines + 1] = string.format(
        "%d\t%s\t%s\t%g\t%s",
        math.floor(sample.t), name, sample.kind, sample.total, sample.state or "?"
      )
    end
  end
  local ok = self.vfs.write(self.path, table.concat(lines, "\n") .. "\n")
  if ok then
    self.lines = #lines - 1
  end
  return ok
end

--- Record one finished scan. Every stock shares the same stamp; a repeated
-- stamp replaces the sample instead of duplicating it. Returns true when the
-- ring changed.
function history:record(stocks, now)
  if not self.persist then
    return false
  end
  local stamp = now or self:now()
  if not stamp then
    return false
  end

  local changed = false
  for _, item in ipairs(stocks or {}) do
    local total = tonumber(item.total)
    if item.updatedAt and total then
      local list = self.samples[item.name]
      local last = list and list[#list]
      if not last or last.t < stamp then
        appendSample(self, item.name, stamp, total, item.kind, item.state)
        self.lines = self.lines + 1
        changed = true
        if self.vfs and type(self.vfs.append) == "function" then
          self.vfs.append(self.path, formatLine(stamp, item.name, item.kind, total, item.state))
        end
      elseif last.t == stamp and last.total ~= total then
        last.total = total
        last.state = item.state
        changed = true
        self:compact()
      end
    end
  end

  if self.lines > self.maxLines then
    self:compact()
  end
  return changed
end

--- Rate over `window` seconds. The base is the newest sample at least `window`
-- old; with less history the oldest sample is used and the caller can inspect
-- `span`.
function history:rate(name, window)
  window = tonumber(window) or history.RATE_WINDOW
  local list = self.samples[name]
  if not list or #list < 2 then
    return nil
  end
  local newest = list[#list]
  local target = newest.t - window
  local base = list[1]
  for index = #list - 1, 1, -1 do
    if list[index].t <= target then
      base = list[index]
      break
    end
  end
  local span = newest.t - base.t
  if span < history.MIN_SPAN then
    return nil
  end
  local delta = newest.total - base.total
  return {
    rate = delta * 60 / span,
    delta = delta,
    span = span,
    from = base.total,
    to = newest.total,
  }
end

local function atOrBefore(list, target)
  local found = nil
  for _, sample in ipairs(list) do
    if sample.t <= target then
      found = sample
    else
      break
    end
  end
  return found
end

--- Compare the recent half-window with the previous half. Returns the two
-- rates and the signed percentage change when both halves have enough samples.
function history:trend(name, window)
  window = tonumber(window) or history.TREND_WINDOW
  local list = self.samples[name]
  if not list or #list < 3 then
    return nil
  end
  local newest = list[#list]
  local older = atOrBefore(list, newest.t - window)
  local middle = atOrBefore(list, newest.t - window / 2)
  if not older or not middle or older == middle then
    return nil
  end
  local previousSpan = middle.t - older.t
  local recentSpan = newest.t - middle.t
  if previousSpan < history.MIN_SPAN or recentSpan < history.MIN_SPAN then
    return nil
  end
  local previous = (middle.total - older.total) * 60 / previousSpan
  local recent = (newest.total - middle.total) * 60 / recentSpan
  if math.abs(previous) < history.MIN_TREND_RATE then
    return nil
  end
  return {
    previous = previous,
    recent = recent,
    percent = (recent - previous) / math.abs(previous) * 100,
  }
end

--- Current rate and trend per stock, for the snapshot and the app.
function history:summary(window)
  local result = {}
  for name, list in pairs(self.samples) do
    local rate = self:rate(name, window)
    if rate then
      local trend = self:trend(name)
      result[name] = {
        rate = rate.rate,
        span = rate.span,
        samples = #list,
        trend = trend and trend.percent or nil,
      }
    end
  end
  return result
end

--- Alarm conditions derived from the ring. Only a stock marked `flow` in
-- /etc/plant.tsv is expected to move; an idle hall must stay quiet.
function history:conditions(thresholds, now)
  local result = {}
  for name in pairs(self.samples) do
    local threshold = thresholds and thresholds[name]
    if threshold and threshold.flow then
      local rate = self:rate(name, history.STALL_WINDOW)
      if rate and rate.span >= history.STALL_WINDOW and math.abs(rate.delta) < 1 then
        result[#result + 1] = {
          code = "STALLED",
          source = name,
          severity = "warn",
          message = string.format("no movement in %ds", math.floor(rate.span)),
        }
      end
      local trend = self:trend(name, threshold.trendWindow or history.TREND_WINDOW)
      local percent = threshold.trendPercent or history.TREND_PERCENT
      if trend and math.abs(trend.percent) >= percent then
        result[#result + 1] = {
          code = "TREND",
          source = name,
          severity = trend.percent < 0 and "warn" or "info",
          message = string.format(
            "%+.0f%% rate (%.1f -> %.1f/min)",
            trend.percent, trend.previous, trend.recent
          ),
        }
      end
    end
  end
  table.sort(result, function(a, b)
    if a.code == b.code then
      return a.source < b.source
    end
    return a.code < b.code
  end)
  return result
end

function history:count()
  return countSamples(self)
end

function history:save()
  return self:compact()
end

return history
