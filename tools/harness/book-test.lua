-- Tests for tc.book and tc.plan: the operated book, the three-step chain,
-- bottleneck, shortfall, calibration and cycle handling.
-- Run through tools/harness/test-book.js.

local bookModule = require("tc.book")
local planModule = require("tc.plan")
local line = require("tc.line")

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

local function find(list, predicate)
  for _, item in ipairs(list or {}) do
    if predicate(item) then
      return item
    end
  end
  return nil
end

local function newVfs(files, listings)
  files = files or {}
  listings = listings or {}
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
    ensureDir = function()
      return true
    end,
    list = function(path)
      return listings[path]
    end,
  }
end

local recipes = table.concat({
  "# id\tdataset\tlabel\tmachine\tticks\tenergy\tpriority\tmachines",
  "casing_ev\tgregtech:machine_casing@4\tEV casing\tassembler\t50\t480\t10\t1",
  "plate_ti\tgregtech:plate_titanium\tTitanium plate\tbender\t20\t120\t5\t2",
  "ingot_ti\tgregtech:meta_ingot@113\tTitanium ingot\tfurnace\t10\t0\t1\t1",
}, "\n") .. "\n"

local io = table.concat({
  "# recipe\tside\tkind\tkey\tqty\tchance",
  "casing_ev\tin\titem\tgregtech:plate_titanium\t8\t",
  "casing_ev\tout\titem\tgregtech:machine_casing@4\t1\t",
  "plate_ti\tin\titem\tgregtech:meta_ingot@113\t1\t",
  "plate_ti\tout\titem\tgregtech:plate_titanium\t1\t",
  "ingot_ti\tin\titem\tgregtech:ore_titanium\t2\t",
  "ingot_ti\tout\titem\tgregtech:meta_ingot@113\t1\t",
}, "\n") .. "\n"

local lineProgram = table.concat({
  "stock in  casing/ingots",
  "stock out casing/casings",
  "",
  "rule lv",
  "  in  8 item gregtech:meta_ingot@324",
  "  out 1 item gregtech:machine_casing@1",
  "rule ev",
  "  in  8 item gregtech:meta_ingot@113",
  "  out 1 item gregtech:machine_casing@4",
  "",
  "ticks 50",
}, "\n") .. "\n"

local stocks = {
  {
    name = "casing/ingots",
    entries = {
      { kind = "item", key = "gregtech:meta_ingot", damage = 113, count = 0 },
    },
  },
  {
    name = "casing/ore",
    entries = {
      { kind = "item", key = "gregtech:ore_titanium", damage = 0, count = 10 },
    },
  },
}

--------------------------------------------------------------------------------
-- The book
--------------------------------------------------------------------------------

local vfs = newVfs({
  ["/etc/recipes.tsv"] = recipes,
  ["/etc/recipe-io.tsv"] = io,
  ["/etc/lines/casing.line"] = lineProgram,
}, {
  ["/etc/lines"] = { "casing.line" },
})

local book = bookModule.new({ vfs = vfs })
equal(#book.errors, 0, "the book loads without errors")
equal(#book.order, 5, "three recipes and two line rules")
check(book.configured == true, "the book reports itself configured")
check(book:recipe("casing_ev") ~= nil, "the casing recipe is present")
check(book:recipe("line/casing/ev") ~= nil, "the line rule is present")

local casingProducers = book.producers[bookModule.termKey({
  kind = "item", key = "gregtech:machine_casing", damage = 4,
})]
equal(#casingProducers, 2, "two producers for the EV casing")
equal(casingProducers[1].id, "casing_ev", "the higher-priority book recipe wins")

local rows = book:list()
equal(#rows, 5, "book:list returns every recipe")
local row = find(rows, function(item) return item.id == "casing_ev" end)
check(row ~= nil and row.machine == "assembler" and row.ticks == 50, "the row carries the machine and ticks")
equal(row and #row.inputs, 1, "the row carries its inputs")

--------------------------------------------------------------------------------
-- Three-step chain
--------------------------------------------------------------------------------

-- The planner under test uses the book alone, so a calibration cannot be
-- shadowed by the line rule with the same output.
local plainVfs = newVfs({
  ["/etc/recipes.tsv"] = recipes,
  ["/etc/recipe-io.tsv"] = io,
})
local plainBook = bookModule.new({ vfs = plainVfs })
local planner = planModule.new(plainBook)
local result, reason = planner:run("item gregtech:machine_casing@4", 1, { stocks = stocks })
check(result ~= nil, "the plan runs: " .. tostring(reason))
if result then
  equal(#result.steps, 3, "the chain has three steps")
  equal(result.steps[1].recipe, "casing_ev", "the target recipe runs first")
  equal(result.steps[2].recipe, "plate_ti", "the plate step follows")
  equal(result.steps[3].recipe, "ingot_ti", "the ingot step is the leaf")

  check(result.bottleneck ~= nil, "the plan names a bottleneck")
  equal(result.bottleneck and result.bottleneck.recipe, "plate_ti",
    "the two-machine plate step is the bottleneck per target")
  near(result.bottleneck and result.bottleneck.rate, 0.0125, 0.0001,
    "the bottleneck rate is 0.0125 targets/s")
  near(result.seconds, 80, 0.001, "one casing takes 80 s in the bottleneck")
  near(result.rate, 0.0125, 0.0001, "the chain rate matches the bottleneck")

  local shortfall = find(result.shortfall, function(item)
    return item.key == "gregtech:ore_titanium"
  end)
  check(shortfall ~= nil, "the missing ore is in the shortfall")
  if shortfall then
    equal(shortfall.need, 16, "one casing needs sixteen ore")
    equal(shortfall.have, 10, "the stock has ten ore")
    equal(shortfall.missing, 6, "six ore are missing")
  end
  equal(#result.shortfall, 1, "only the ore is short")
  equal(#result.warnings, 0, "a declared chain has no warnings")
end

local big = planner:run("item gregtech:machine_casing@4", 200, { stocks = stocks })
check(big ~= nil, "the 200-casing plan runs")
if big then
  equal(big.steps[1].crafts, 200, "200 casings need 200 crafts")
  equal(big.steps[2].crafts, 1600, "each casing needs eight plates")
  equal(big.steps[3].crafts, 1600, "each plate needs one ingot")
  near(big.seconds, 16000, 0.001, "1600 plates on two machines take 16000 s")
  local shortfall = find(big.shortfall, function(item)
    return item.key == "gregtech:ore_titanium"
  end)
  check(shortfall ~= nil and shortfall.need == 3200 and shortfall.missing == 3190,
    "the hand count matches: 3200 needed, 10 in stock, 3190 missing")
end

--------------------------------------------------------------------------------
-- Calibration
--------------------------------------------------------------------------------

local suspect = plainBook:calibrate("casing_ev", 10 / 8, 0.1)
check(suspect ~= nil, "the calibration is recorded")
equal(suspect and suspect.status, "suspect", "a 25 percent contradiction is suspect")
check(plainVfs.files["/var/plant/calibration.tsv"] ~= nil, "calibration is persisted")

local suspectPlan = planner:run("item gregtech:machine_casing@4", 1, { stocks = stocks })
check(suspectPlan ~= nil, "a suspect recipe still plans")
if suspectPlan then
  local warning = find(suspectPlan.warnings, function(item) return item.code == "suspect_recipe" end)
  check(warning ~= nil and warning.recipe == "casing_ev", "the plan warns about the suspect recipe")
  near(suspectPlan.steps[1].ratio, 1.25, 0.0001, "the plan uses the measured ratio")
  local shortfall = find(suspectPlan.shortfall, function(item)
    return item.key == "gregtech:ore_titanium"
  end)
  check(shortfall ~= nil and shortfall.need == 20,
    "the measured ratio turns eight plates into ten, so twenty ore")
end

local verified = plainBook:calibrate("casing_ev", 1.05, 0.1)
equal(verified and verified.status, "verified", "a five percent difference is verified")
local verifiedPlan = planner:run("item gregtech:machine_casing@4", 1, { stocks = stocks })
check(verifiedPlan ~= nil, "the verified recipe plans")
if verifiedPlan then
  equal(#verifiedPlan.warnings, 0, "a verified recipe has no suspect warning")
end

--------------------------------------------------------------------------------
-- Line rules as recipes
--------------------------------------------------------------------------------

local lineVfs = newVfs({}, { ["/etc/lines"] = { "casing.line" } })
lineVfs.files["/etc/lines/casing.line"] = lineProgram
local lineBook = bookModule.new({ vfs = lineVfs })
equal(#lineBook.errors, 0, "the line-only book loads")
equal(#lineBook.order, 2, "the line rules are recipes")
local linePlan = planModule.new(lineBook):run("item gregtech:machine_casing@4", 1, { stocks = stocks })
check(linePlan ~= nil, "the line rule plans")
if linePlan then
  equal(linePlan.steps[1].recipe, "line/casing/ev", "the EV rule is chosen")
  equal(linePlan.steps[1].line, "casing", "the step names its line")
  local shortfall = find(linePlan.shortfall, function(item)
    return item.key == "gregtech:meta_ingot" and item.damage == 113
  end)
  check(shortfall ~= nil and shortfall.missing == 8, "the line rule reads the same shortfall")
end

--------------------------------------------------------------------------------
-- Cycles, chance and empty books
--------------------------------------------------------------------------------

local cycleVfs = newVfs({
  ["/etc/recipes.tsv"] = table.concat({
    "recipe_a\t\tA\tmachine\t10\t0\t0\t1",
    "recipe_b\t\tB\tmachine\t10\t0\t0\t1",
  }, "\n") .. "\n",
  ["/etc/recipe-io.tsv"] = table.concat({
    "recipe_a\tin\titem\tb\t1\t",
    "recipe_a\tout\titem\ta\t1\t",
    "recipe_b\tin\titem\ta\t1\t",
    "recipe_b\tout\titem\tb\t1\t",
  }, "\n") .. "\n",
})
local cycleBook = bookModule.new({ vfs = cycleVfs })
local cyclePlan = planModule.new(cycleBook):run("item a", 1, { stocks = {} })
check(cyclePlan ~= nil, "a cycle still plans")
if cyclePlan then
  local warning = find(cyclePlan.warnings, function(item) return item.code == "cycle" end)
  check(warning ~= nil, "the cycle is reported, not followed forever")
  check(#cyclePlan.steps <= 2, "the cycle stops after the pair")
end

local chanceVfs = newVfs({
  ["/etc/recipes.tsv"] = "recipe_r\t\tR\tmachine\t10\t0\t0\t1\n",
  ["/etc/recipe-io.tsv"] = table.concat({
    "recipe_r\tin\titem\tore\t1\t",
    "recipe_r\tout\titem\tdust\t1\t0.5",
  }, "\n") .. "\n",
})
local chanceBook = bookModule.new({ vfs = chanceVfs })
local chancePlan = planModule.new(chanceBook):run("item dust", 1, { stocks = {} })
check(chancePlan ~= nil, "a chance recipe plans")
if chancePlan then
  local warning = find(chancePlan.warnings, function(item) return item.code == "rng_chain" end)
  check(warning ~= nil, "a chance output warns that the chain depends on luck")
  equal(chancePlan.steps[1].crafts, 2, "half a dust per craft needs two crafts")
end

local brokenVfs = newVfs({
  ["/etc/recipes.tsv"] = "recipe_r\t\tR\tmachine\t10\t0\t0\t1\n",
  ["/etc/recipe-io.tsv"] = "recipe_missing\tin\titem\tore\t1\t\n",
})
local broken = bookModule.new({ vfs = brokenVfs })
check(#broken.errors >= 1, "an unknown recipe in the IO file is an error")
local emptyPlan, emptyReason = planModule.new(bookModule.new({ vfs = newVfs() })):run("item x", 1)
check(emptyPlan == nil and emptyReason == "empty_book", "an empty book refuses to plan")

--------------------------------------------------------------------------------
-- Budget
--------------------------------------------------------------------------------

local started = os.clock()
for _ = 1, 200 do
  planner:run("item gregtech:machine_casing@4", 1, { stocks = stocks })
end
local elapsed = os.clock() - started
check(elapsed < 1, "200 three-step plans stay under one second, got " .. tostring(elapsed))

return table.concat(failures, "\n")
