-- Local planner over the operated book.
--
-- `plan:run(target, qty)` walks backwards from the target, names the bottleneck
-- and the shortfall, and is a pure function over the book plus the cached stock
-- snapshot: no component call, no tick time. A suspect recipe still plans, uses
-- its measured ratio and carries a warning; a cycle is bounded and reported
-- instead of recursing forever.

local line = require("tc.line")
local bookModule = require("tc.book")

local plan = {}
plan.__index = plan

plan.MAX_DEPTH = 16

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function plan.parseTarget(value)
  if type(value) == "table" then
    local kind = value.kind
    if kind ~= "item" and kind ~= "fluid" then
      return nil
    end
    if type(value.key) ~= "string" or value.key == "" then
      return nil
    end
    return {
      kind = kind,
      key = value.key,
      damage = tonumber(value.damage) or 0,
    }
  end
  if type(value) ~= "string" then
    return nil
  end
  local text = trim(value)
  local kind, keyText = text:match("^(%a+)%s+(%S+)$")
  if kind ~= "item" and kind ~= "fluid" then
    return nil
  end
  local key, damage = line.parseKey(keyText, kind)
  if not key then
    return nil
  end
  return { kind = kind, key = key, damage = damage or 0 }
end

function plan.new(book)
  local self = setmetatable({}, plan)
  self.book = book
  self.runs = 0
  return self
end

local function stockIndex(stocks)
  local index = {}
  for _, stock in ipairs(stocks or {}) do
    for _, entry in ipairs(stock.entries or {}) do
      local key = bookModule.termKey({
        kind = entry.kind,
        key = entry.key,
        damage = entry.damage,
      })
      local count = tonumber(entry.count) or tonumber(entry.amount) or 0
      index[key] = (index[key] or 0) + count
    end
  end
  return index
end

function plan:run(target, qty, options)
  options = options or {}
  local goal = plan.parseTarget(target)
  if not goal then
    return nil, "invalid_target"
  end
  qty = tonumber(qty) or 1
  if qty < 1 or qty ~= math.floor(qty) then
    return nil, "invalid_qty"
  end
  if not self.book or #self.book.order == 0 then
    return nil, "empty_book"
  end

  local have = options.stockIndex or stockIndex(options.stocks)
  local steps = {}
  local stepOrder = {}
  local demands = {}
  local produced = {}
  local stockUsed = {}
  local warnings = {}
  local warned = {}
  local stack = {}

  local function addWarning(code, detail)
    local key = code .. ":" .. tostring(detail and (detail.recipe or detail.key) or "")
    if warned[key] then
      return
    end
    warned[key] = true
    local record = { code = code }
    if detail then
      for name, value in pairs(detail) do
        record[name] = value
      end
    end
    warnings[#warnings + 1] = record
  end

  local expand

  local function choose(term)
    local list = self.book.producers[bookModule.termKey(term)]
    if not list then
      return nil
    end
    return list[1]
  end

  expand = function(term, need, depth)
    local key = bookModule.termKey(term)
    local demand = demands[key]
    if not demand then
      demand = {
        kind = term.kind,
        key = term.key,
        damage = term.damage or 0,
        qty = 0,
      }
      demands[key] = demand
    end
    demand.qty = demand.qty + need

    -- The stock covers the demand before a recipe is asked to produce it, and
    -- a level is spent once across the whole plan rather than per branch.
    local available = math.max(0, (have[key] or 0) - (stockUsed[key] or 0))
    local covered = math.min(need, available)
    stockUsed[key] = (stockUsed[key] or 0) + covered
    local remaining = need - covered
    if remaining <= 0 then
      return
    end

    if depth > plan.MAX_DEPTH then
      addWarning("depth_limit", { key = key })
      return
    end

    local recipe = choose(term)
    if not recipe then
      return
    end
    if stack[recipe.id] then
      addWarning("cycle", { recipe = recipe.id, key = key })
      return
    end

    local outQty = 0
    for _, output in ipairs(recipe.outputs) do
      if bookModule.termKey(output) == key then
        outQty = outQty + output.qty * (output.chance or 1)
        if (output.chance or 1) < 1 then
          addWarning("rng_chain", { recipe = recipe.id, key = key })
        end
      end
    end
    if outQty <= 0 then
      return
    end

    produced[key] = true
    if recipe.status == "suspect" then
      addWarning("suspect_recipe", { recipe = recipe.id, ratio = recipe.ratio })
    end

    local crafts = math.ceil(remaining / outQty - 1e-9)
    local step = steps[recipe.id]
    if not step then
      step = {
        recipe = recipe.id,
        label = recipe.label,
        machine = recipe.machine,
        line = recipe.line,
        source = recipe.source,
        status = recipe.status,
        ratio = recipe.ratio,
        crafts = 0,
        seconds = 0,
        rate = recipe.machines / recipe.ticks,
      }
      steps[recipe.id] = step
      stepOrder[#stepOrder + 1] = step
    end
    step.crafts = step.crafts + crafts
    step.seconds = step.seconds + (crafts * recipe.ticks / recipe.machines)

    local ratio = recipe.ratio or 1
    stack[recipe.id] = true
    for _, input in ipairs(recipe.inputs) do
      expand(input, crafts * input.qty * ratio, depth + 1)
    end
    stack[recipe.id] = nil
  end

  expand(goal, qty, 0)

  local shortfall = {}
  for key, demand in pairs(demands) do
    if not produced[key] then
      local available = have[key]
      if available == nil then
        addWarning("unseen_key", { key = key })
        available = 0
      end
      -- A calibrated ratio can leave a fractional expected demand; a real
      -- order still needs whole items.
      local required = math.ceil(demand.qty - 1e-9)
      if available < required then
        shortfall[#shortfall + 1] = {
          kind = demand.kind,
          key = demand.key,
          damage = demand.damage,
          need = required,
          have = available,
          missing = required - available,
        }
      end
    end
  end
  table.sort(shortfall, function(a, b)
    if a.kind ~= b.kind then
      return a.kind < b.kind
    end
    if a.key ~= b.key then
      return a.key < b.key
    end
    return a.damage < b.damage
  end)

  local bottleneck = nil
  local seconds = 0
  for _, step in ipairs(stepOrder) do
    if step.seconds > seconds then
      seconds = step.seconds
    end
    -- Crafts per target unit differ between steps (8 ingots per plate, 1
    -- casing per batch), so the bottleneck compares target rates, not raw
    -- crafts per second.
    if step.crafts > 0 then
      step.targetRate = step.rate * qty / step.crafts
      if not bottleneck or step.targetRate < bottleneck.rate then
        bottleneck = {
          recipe = step.recipe,
          rate = step.targetRate,
          crafts = step.crafts,
          seconds = step.seconds,
        }
      end
    end
  end

  table.sort(warnings, function(a, b)
    if a.code ~= b.code then
      return a.code < b.code
    end
    return tostring(a.recipe or a.key) < tostring(b.recipe or b.key)
  end)

  self.runs = self.runs + 1
  return {
    target = goal,
    qty = qty,
    steps = stepOrder,
    bottleneck = bottleneck,
    seconds = seconds,
    rate = seconds > 0 and (qty / seconds) or 0,
    shortfall = shortfall,
    warnings = warnings,
    book = {
      recipes = #self.book.order,
      errors = #self.book.errors,
    },
  }
end

--- Calibration helper: one observed run, expressed as measured/declared input.
function plan:calibrate(id, measuredRatio, tolerance)
  return self.book:calibrate(id, measuredRatio, tolerance)
end

return plan
