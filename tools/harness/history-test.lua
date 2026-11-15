-- Tests for tc.history: bounded ring, rates, trend and persistence.
-- Run through tools/harness/test-history.js.

local history = require("tc.history")

local failures = {}
local function fail(message)
  failures[#failures + 1] = message
end

local function check(condition, message)
  if not condition then
    fail(message)
  end
end

local function equal(actual, expected, message)
  if actual ~= expected then
    fail(message .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
  end
end

local function near(actual, expected, tolerance, message)
  if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
    fail(message .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
  end
end

local function newVfs()
  local files = {}
  return {
    files = files,
    read = function(path)
      return files[path]
    end,
    exists = function(path)
      return files[path] ~= nil
    end,
    write = function(path, data)
      files[path] = data
      return true
    end,
    append = function(path, data)
      files[path] = (files[path] or "") .. data
      return true
    end,
    ensureDir = function()
      return true
    end,
  }
end

local function stock(name, total, kind)
  return {
    name = name,
    kind = kind or "item",
    total = total,
    state = "exact",
    updatedAt = 1,
  }
end

local function lineCount(text)
  local count = 0
  for _ in text:gmatch("[^\r\n]+") do
    count = count + 1
  end
  return count
end

--------------------------------------------------------------------------------
-- Rate and ring bound
--------------------------------------------------------------------------------

local clock = 1700000000
local vfs = newVfs()
local store = history.new({ vfs = vfs, clock = function() return clock end })

for index = 1, 1000 do
  clock = clock + 10
  store:record({ stock("stock/a", index * 10) })
end

equal(#store.samples["stock/a"], history.MAX_SAMPLES, "the ring stops at MAX_SAMPLES")
equal(store:count(), history.MAX_SAMPLES, "count reports the bounded ring")
check(vfs.files[history.PATH] ~= nil, "samples are persisted")

local rate = store:rate("stock/a", 120)
check(rate ~= nil, "a rate is available")
if rate then
  near(rate.rate, 60, 0.01, "ten items every ten seconds is 60 items/min")
  near(rate.span, 120, 0.01, "the 120 s window is honored")
  equal(rate.delta, 120, "twelve samples of ten items make a delta of 120")
end

local summary = store:summary()
check(summary["stock/a"] ~= nil and summary["stock/a"].rate ~= nil, "the summary exposes the rate")
check(summary["stock/a"].samples == history.MAX_SAMPLES, "the summary counts the samples")

--------------------------------------------------------------------------------
-- Persistence across a reboot
--------------------------------------------------------------------------------

local reborn = history.new({ vfs = vfs, clock = function() return clock end })
equal(reborn:count(), history.MAX_SAMPLES, "the ring survives a new instance")
local rebornRate = reborn:rate("stock/a", 120)
check(rebornRate ~= nil, "the restored ring yields a rate")
if rebornRate then
  near(rebornRate.rate, 60, 0.01, "the restored rate matches")
end

--------------------------------------------------------------------------------
-- Monotonic clock across a reboot
--------------------------------------------------------------------------------

local bootClock = 0
computer = {
  uptime = function()
    return bootClock
  end,
}
local bootVfs = newVfs()
bootVfs.files[history.PATH] = "1000\tstock/c\titem\t10\texact\n"
local booted = history.new({ vfs = bootVfs })
equal(booted.base, 1000, "a new instance continues from the newest sample")
bootClock = 20
booted:record({ stock("stock/c", 20) }, booted:now())
local bootSamples = booted.samples["stock/c"]
equal(bootSamples[#bootSamples].t, 1020, "the new sample continues the monotonic clock")
check(booted:rate("stock/c", 10) ~= nil, "the continued clock yields a rate")

--------------------------------------------------------------------------------
-- File compaction
--------------------------------------------------------------------------------

local smallVfs = newVfs()
local smallClock = 1700000000
local small = history.new({
  vfs = smallVfs,
  clock = function() return smallClock end,
  maxSamples = 10,
  maxLines = 20,
})
for index = 1, 100 do
  smallClock = smallClock + 10
  small:record({ stock("stock/b", index) })
end
equal(#small.samples["stock/b"], 10, "the small ring keeps ten samples")
local fileLines = lineCount(smallVfs.files[history.PATH] or "")
check(fileLines <= 21, "compaction keeps the file bounded, got " .. tostring(fileLines))

--------------------------------------------------------------------------------
-- STALLED
--------------------------------------------------------------------------------

local stallVfs = newVfs()
local stallClock = 1700000000
local stalled = history.new({ vfs = stallVfs, clock = function() return stallClock end })
for _ = 1, 8 do
  stallClock = stallClock + 10
  stalled:record({ stock("line/out", 5) })
end

local conditions = stalled:conditions({ ["line/out"] = { flow = true } }, stallClock)
equal(#conditions, 1, "an unmoving flow stock raises one condition")
if conditions[1] then
  equal(conditions[1].code, "STALLED", "the condition is STALLED")
  equal(conditions[1].source, "line/out", "the source is the stock")
  check(conditions[1].message:find("no movement in", 1, true) ~= nil,
    "the message names the stall")
end

local quiet = stalled:conditions({ ["line/out"] = {} }, stallClock)
equal(#quiet, 0, "an idle stock without flow stays quiet")

--------------------------------------------------------------------------------
-- TREND
--------------------------------------------------------------------------------

local trendVfs = newVfs()
local trendClock = 1700000000
local trending = history.new({ vfs = trendVfs, clock = function() return trendClock end })
trending:record({ stock("line/out", 0) }, trendClock)
for step = 1, 6 do
  trendClock = trendClock + 10
  trending:record({ stock("line/out", step * 10) }, trendClock)
end
for step = 1, 6 do
  trendClock = trendClock + 10
  trending:record({ stock("line/out", 60 + step) }, trendClock)
end

local trend = trending:trend("line/out", 120)
check(trend ~= nil, "a trend is available")
if trend then
  near(trend.previous, 60, 0.01, "the previous window ran at 60/min")
  near(trend.recent, 6, 0.01, "the recent window runs at 6/min")
  near(trend.percent, -90, 0.01, "the trend is a 90 percent drop")
end

local trendConditions = trending:conditions({ ["line/out"] = { flow = true, trendPercent = 50 } }, trendClock)
local byCode = {}
for _, condition in ipairs(trendConditions) do
  byCode[condition.code] = condition
end
check(byCode.TREND ~= nil, "a rate drop raises TREND")
if byCode.TREND then
  check(byCode.TREND.message:find("-90%", 1, true) ~= nil,
    "the TREND message carries the percentage, got " .. tostring(byCode.TREND.message))
end

--------------------------------------------------------------------------------
-- Malformed and missing files
--------------------------------------------------------------------------------

local brokenVfs = newVfs()
brokenVfs.files[history.PATH] = "# header\nnot a sample\n123\tbad\n"
local broken = history.new({ vfs = brokenVfs, clock = function() return clock end })
equal(broken:count(), 0, "malformed history lines are skipped")

local empty = history.new({ vfs = newVfs(), clock = function() return clock end })
equal(empty:count(), 0, "a missing file is an empty ring")
check(empty:rate("stock/none", 60) == nil, "a stock without samples has no rate")

return table.concat(failures, "\n")
