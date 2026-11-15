-- Standalone test for src/lib/tc/line.lua.
--
-- The JS runner injects LINE_SOURCE and CASING_LINE, runs this file, then reads
-- LINE_ERRORS back.

local errors = 0
local function check(condition, message)
  if not condition then
    errors = errors + 1
    print("  FAIL " .. message)
  end
end

local line = assert(load(LINE_SOURCE, "=line.lua"))()

local function expectError(source, needle, label)
  local program, failures = line.parse(source, label)
  check(program == nil, label .. ": expected failure")
  local text = line.errorText(failures)
  check(text:find(needle, 1, true) ~= nil, label .. ": expected '" .. needle .. "' in " .. text)
end

local program, failures = line.parse(CASING_LINE, "casing")
check(program ~= nil, "casing parses: " .. line.errorText(failures))
if program then
  check(#program.stocks.inputs == 1 and program.stocks.inputs[1] == "casing/ingots", "stock in")
  check(#program.stocks.outputs == 1 and program.stocks.outputs[1] == "casing/casings", "stock out")
  check(#program.rules == 4, "four rules")
  local lv = line.findRule(program, "lv")
  check(lv ~= nil, "lv rule")
  if lv then
    check(#lv.inputs == 1, "lv one input")
    check(lv.inputs[1].kind == "item", "lv input kind")
    check(lv.inputs[1].key == "gregtech:meta_ingot", "lv input key")
    check(lv.inputs[1].damage == 324, "lv input damage")
    check(lv.inputs[1].qty == 8, "lv input qty")
    check(#lv.outputs == 1 and lv.outputs[1].damage == 1, "lv output")
    check(
      line.ruleText(lv) == "in 8 item gregtech:meta_ingot@324 = out 1 item gregtech:machine_casing@1",
      "lv text"
    )
  end
  check(program.ticks == 50, "ticks")
  check(#program.limits == 1, "one limit")
  if program.limits[1] then
    check(program.limits[1].kind == "item", "limit kind")
    check(program.limits[1].key == "gregtech:machine_casing", "limit key")
    check(program.limits[1].damage == 4, "limit damage")
    check(program.limits[1].qty == 64, "limit qty")
  end
end

local multi = [[
rule alloy
  in 4 item gregtech:meta_ingot@324 + 2 item gregtech:meta_ingot@2 + 1000 fluid water
  out 1 item gregtech:meta_ingot@113 + 500 fluid steam
]]
local multiProgram, multiFailures = line.parse(multi, "alloy")
check(multiProgram ~= nil, "multi parses: " .. line.errorText(multiFailures))
if multiProgram then
  local rule = multiProgram.rules[1]
  check(#rule.inputs == 3 and #rule.outputs == 2, "multi term counts")
  check(rule.inputs[3].kind == "fluid" and rule.inputs[3].key == "water", "fluid input")
  check(rule.inputs[3].damage == nil, "fluid has no damage")
  check(rule.outputs[2].kind == "fluid" and rule.outputs[2].qty == 500, "fluid output")
  check(line.ruleText(rule):find("1000 fluid water", 1, true) ~= nil, "fluid text")
end

local messy = "\239\187\191# comment\r\nrule a\r\n  in 1 item mod:thing\r\n  out 1 fluid water # trailing\r\n"
local messyProgram, messyFailures = line.parse(messy, "messy")
check(messyProgram ~= nil, "messy parses: " .. line.errorText(messyFailures))
if messyProgram then
  check(messyProgram.rules[1].inputs[1].damage == 0, "no @ means damage 0")
  check(messyProgram.rules[1].outputs[1].kind == "fluid", "fluid output")
end

local empty, emptyFailures = line.parse("# nothing\n", "empty")
check(empty ~= nil and #empty.rules == 0, "empty parses: " .. line.errorText(emptyFailures))

expectError("rule a\n in 1 item x\n", "has no out", "missing out")
expectError("rule a\n out 1 item x\n", "has no in", "missing in")
expectError(
  "rule a\n in 1 item x\n out 1 item y\nrule a\n in 1 item z\n out 1 item w\n",
  "duplicate rule",
  "duplicate rule"
)
expectError("rule a\n in 0 item x\n out 1 item y\n", "positive integer", "zero qty")
expectError("rule a\n in 1.5 item x\n out 1 item y\n", "positive integer", "fraction qty")
expectError("rule a\n in 1 stack x\n out 1 item y\n", "kind must be", "bad kind")
expectError("rule a\n in 1 item x\n out 1 item y\nbogus 1\n", "unknown directive", "unknown directive")
expectError("rule a\n in 1 item x\n out 1 item y\nlimit 1 item\n", "expected limit", "bad limit")
expectError("stock in a,,b\n", "invalid stock name", "bad stock")
expectError(string.rep("x", line.MAX_BYTES + 1), "larger than", "oversize")

local afterStock, afterFailures = line.parse("rule a\n in 1 item x\n out 1 item y\nstock in z\n", "after")
check(afterStock ~= nil and afterStock.stocks.inputs[1] == "z", "stock after rule: " .. line.errorText(afterFailures))

LINE_ERRORS = errors
