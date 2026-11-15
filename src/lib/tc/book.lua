-- Operated recipe book.
--
-- The book is the small set of recipes this plant actually runs, not the pack
-- encyclopedia: two flat TSV files plus the line programs under /etc/lines.
-- Parsing is data-only and bounded; a malformed row is a named error, never a
-- half-loaded plan. Calibration lives in /var/plant/calibration.tsv: a run that
-- contradicts the declared quantity turns the recipe `suspect` and the planner
-- starts using the measured ratio.

local line = require("tc.line")

local book = {}
book.__index = book

book.RECIPES_PATH = "/etc/recipes.tsv"
book.IO_PATH = "/etc/recipe-io.tsv"
book.LINES_PATH = "/etc/lines"
book.CALIBRATION_PATH = "/var/plant/calibration.tsv"
book.MAX_RECIPES = 512
book.MAX_TERMS = 64

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Split a TSV row and keep empty trailing fields, so `chance` can be blank.
local function splitTabs(value)
  local parts = {}
  for piece in (value .. "\t"):gmatch("([^\t]*)\t") do
    parts[#parts + 1] = piece
  end
  return parts
end

local function termKey(term)
  return term.kind .. "|" .. term.key .. "@" .. tostring(term.damage or 0)
end

book.termKey = termKey

local function copyTerm(term)
  return {
    kind = term.kind,
    key = term.key,
    damage = term.damage or 0,
    qty = term.qty,
    chance = term.chance,
  }
end

local function addError(errors, number, message)
  errors[#errors + 1] = { line = number, message = message }
end

function book.new(options)
  local self = setmetatable({}, book)
  options = options or {}
  self.vfs = options.vfs
  self.log = options.log
  self.recipes = {}
  self.order = {}
  self.producers = {}
  self.errors = {}
  self.calibration = {}
  self.configured = false
  self:load()
  return self
end

function book:load()
  self.recipes = {}
  self.order = {}
  self.producers = {}
  self.errors = {}
  self.configured = false

  self:loadRecipes()
  self:loadIO()
  self:loadLines()
  self:loadCalibration()
  self:index()

  self.configured = #self.order > 0
  return true
end

function book:add(recipe, source, number)
  recipe.source = source
  recipe.inputs = recipe.inputs or {}
  recipe.outputs = recipe.outputs or {}
  recipe.status = "declared"
  recipe.ratio = 1
  if self.recipes[recipe.id] then
    addError(self.errors, number, "duplicate recipe: " .. recipe.id)
    return nil
  end
  if #self.order >= book.MAX_RECIPES then
    addError(self.errors, number, "too many recipes (max " .. book.MAX_RECIPES .. ")")
    return nil
  end
  self.recipes[recipe.id] = recipe
  self.order[#self.order + 1] = recipe
  return recipe
end

function book:loadRecipes()
  if not self.vfs then
    return
  end
  local text = self.vfs.read(book.RECIPES_PATH)
  if type(text) ~= "string" then
    return
  end

  local number = 0
  for raw in text:gmatch("[^\r\n]+") do
    number = number + 1
    local value = trim(raw:gsub("#.*$", ""))
    if value ~= "" then
      local fields = splitTabs(value)
      local id = fields[1]
      local ticks = tonumber(fields[5])
      local priority = fields[7] ~= "" and tonumber(fields[7]) or 0
      local machines = fields[8] ~= "" and tonumber(fields[8]) or 1
      if not id or not id:match("^[%w_%-%.]+$") then
        addError(self.errors, number, "invalid recipe id: " .. tostring(id))
      elseif not ticks or ticks < 1 or ticks ~= math.floor(ticks) then
        addError(self.errors, number, "ticks must be a positive integer: " .. tostring(fields[5]))
      elseif not priority or priority ~= math.floor(priority) then
        addError(self.errors, number, "priority must be an integer: " .. tostring(fields[7]))
      elseif not machines or machines < 1 or machines ~= math.floor(machines) then
        addError(self.errors, number, "machines must be a positive integer: " .. tostring(fields[8]))
      else
        self:add({
          id = id,
          dataset = fields[2] ~= "" and fields[2] or nil,
          label = fields[3] ~= "" and fields[3] or id,
          machine = fields[4] ~= "" and fields[4] or "?",
          ticks = ticks,
          energy = fields[6] ~= "" and tonumber(fields[6]) or nil,
          priority = priority,
          machines = machines,
          inputs = {},
          outputs = {},
        }, "book", number)
      end
    end
  end
end

function book:loadIO()
  if not self.vfs then
    return
  end
  local text = self.vfs.read(book.IO_PATH)
  if type(text) ~= "string" then
    return
  end

  local number = 0
  for raw in text:gmatch("[^\r\n]+") do
    number = number + 1
    local value = trim(raw:gsub("#.*$", ""))
    if value ~= "" then
      local fields = splitTabs(value)
      local id, side, kind = fields[1], fields[2], fields[3]
      local qty = tonumber(fields[5])
      local chance = fields[6] ~= "" and tonumber(fields[6]) or 1
      local recipe = self.recipes[id]
      local keyName, damage
      if not recipe then
        addError(self.errors, number, "unknown recipe: " .. tostring(id))
      elseif side ~= "in" and side ~= "out" then
        addError(self.errors, number, "side must be in or out: " .. tostring(side))
      elseif kind ~= "item" and kind ~= "fluid" then
        addError(self.errors, number, "kind must be item or fluid: " .. tostring(kind))
      elseif not qty or qty < 1 or qty ~= math.floor(qty) then
        addError(self.errors, number, "qty must be a positive integer: " .. tostring(fields[5]))
      elseif not chance or chance <= 0 or chance > 1 then
        addError(self.errors, number, "chance must be in (0, 1]: " .. tostring(fields[6]))
      else
        keyName, damage = line.parseKey(fields[4], kind)
        if not keyName then
          addError(self.errors, number, "invalid " .. kind .. " key: " .. tostring(fields[4]))
        else
          local term = {
            kind = kind,
            key = keyName,
            damage = damage or 0,
            qty = qty,
            chance = chance,
          }
          local target = side == "in" and recipe.inputs or recipe.outputs
          if #target >= book.MAX_TERMS then
            addError(self.errors, number, "too many terms (max " .. book.MAX_TERMS .. ")")
          else
            target[#target + 1] = term
          end
        end
      end
    end
  end
end

function book:loadLines()
  if not self.vfs or type(self.vfs.list) ~= "function" then
    return
  end
  local names = self.vfs.list(book.LINES_PATH)
  if type(names) ~= "table" then
    return
  end
  table.sort(names)
  for _, name in ipairs(names) do
    if name:match("%.line$") then
      local path = book.LINES_PATH .. "/" .. name
      local program, errors = line.load(self.vfs, path)
      if not program then
        for _, item in ipairs(errors or {}) do
          addError(self.errors, item.line, path .. ": " .. item.message)
        end
      else
        local lineName = name:gsub("%.line$", "")
        local ticks = program.ticks or 1
        for _, rule in ipairs(program.rules) do
          local inputs, outputs = {}, {}
          for _, term in ipairs(rule.inputs) do
            inputs[#inputs + 1] = copyTerm(term)
          end
          for _, term in ipairs(rule.outputs) do
            outputs[#outputs + 1] = copyTerm(term)
          end
          self:add({
            id = "line/" .. lineName .. "/" .. rule.name,
            label = rule.name .. " on " .. lineName,
            machine = "line",
            ticks = ticks,
            priority = 5,
            machines = 1,
            line = lineName,
            inputs = inputs,
            outputs = outputs,
          }, "line", 0)
        end
      end
    end
  end
end

function book:loadCalibration()
  if not self.vfs then
    return
  end
  local text = self.vfs.read(book.CALIBRATION_PATH)
  if type(text) ~= "string" then
    return
  end
  for raw in text:gmatch("[^\r\n]+") do
    local value = trim(raw:gsub("#.*$", ""))
    if value ~= "" then
      local fields = splitTabs(value)
      local id = fields[1]
      local status = fields[2]
      local ratio = tonumber(fields[3])
      local samples = tonumber(fields[4])
      if id and (status == "verified" or status == "suspect") and ratio and ratio > 0 then
        self.calibration[id] = {
          status = status,
          ratio = ratio,
          samples = samples or 1,
        }
        local recipe = self.recipes[id]
        if recipe then
          recipe.status = status
          recipe.ratio = ratio
        end
      end
    end
  end
end

function book:index()
  self.producers = {}
  for _, recipe in ipairs(self.order) do
    for _, term in ipairs(recipe.outputs) do
      local key = termKey(term)
      local list = self.producers[key]
      if not list then
        list = {}
        self.producers[key] = list
      end
      list[#list + 1] = recipe
    end
  end
  for _, list in pairs(self.producers) do
    table.sort(list, function(a, b)
      local left = a.status == "suspect" and 1 or 0
      local right = b.status == "suspect" and 1 or 0
      if left ~= right then
        return left < right
      end
      if a.priority ~= b.priority then
        return a.priority > b.priority
      end
      return a.id < b.id
    end)
  end
end

function book:recipe(id)
  return self.recipes[id]
end

--- Calibrate a recipe against one observed run. `measuredRatio` is the measured
-- input per declared input (1 = exact). Inside the tolerance the recipe is
-- `verified`; outside it becomes `suspect` and the planner uses the ratio.
function book:calibrate(id, measuredRatio, tolerance)
  local recipe = self.recipes[id]
  local ratio = tonumber(measuredRatio)
  if not recipe then
    return nil, "unknown_recipe"
  end
  if not ratio or ratio <= 0 then
    return nil, "invalid_ratio"
  end
  tolerance = tonumber(tolerance) or 0.1
  local status = math.abs(ratio - 1) <= tolerance and "verified" or "suspect"
  local record = self.calibration[id] or { samples = 0 }
  record.status = status
  record.ratio = ratio
  record.samples = (record.samples or 0) + 1
  self.calibration[id] = record
  recipe.status = status
  recipe.ratio = ratio
  self:index()
  self:saveCalibration()
  return record
end

function book:saveCalibration()
  if not self.vfs then
    return false
  end
  self.vfs.ensureDir("/var/plant")
  local ids = {}
  for id in pairs(self.calibration) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  local lines = { "# TerraCorp: recipe calibration (recipe, status, ratio, samples)" }
  for _, id in ipairs(ids) do
    local record = self.calibration[id]
    lines[#lines + 1] = string.format(
      "%s\t%s\t%.4f\t%d", id, record.status, record.ratio, record.samples or 1
    )
  end
  local ok = self.vfs.write(book.CALIBRATION_PATH, table.concat(lines, "\n") .. "\n")
  if not ok and self.log then
    self.log.warn("Could not save " .. book.CALIBRATION_PATH)
  end
  return ok
end

--- Recipes as plain rows, for the app, the link and the MCP surface.
function book:list()
  local result = {}
  for _, recipe in ipairs(self.order) do
    local inputs, outputs = {}, {}
    for _, term in ipairs(recipe.inputs) do
      inputs[#inputs + 1] = {
        kind = term.kind,
        key = term.key,
        damage = term.damage or 0,
        qty = term.qty,
        chance = term.chance,
      }
    end
    for _, term in ipairs(recipe.outputs) do
      outputs[#outputs + 1] = {
        kind = term.kind,
        key = term.key,
        damage = term.damage or 0,
        qty = term.qty,
        chance = term.chance,
      }
    end
    result[#result + 1] = {
      id = recipe.id,
      label = recipe.label,
      machine = recipe.machine,
      ticks = recipe.ticks,
      priority = recipe.priority,
      machines = recipe.machines,
      source = recipe.source,
      line = recipe.line,
      status = recipe.status,
      ratio = recipe.ratio,
      inputs = inputs,
      outputs = outputs,
    }
  end
  return result
end

return book
