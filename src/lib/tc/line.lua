-- Line program parser. A line is a black box: its program declares
-- `mat in = mat out` rules over the two boundary stocks. The file is data, never
-- code: /etc is writable through the external link, so an executable program
-- would be remote code execution (decision 22).

local line = {}

line.MAX_BYTES = 64 * 1024
line.MAX_LINES = 2000
line.MAX_RULES = 64
line.MAX_TERMS = 32
line.MAX_STOCKS = 16
line.MAX_NAME = 64
line.MAX_KEY = 128

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function addError(errors, number, message)
  errors[#errors + 1] = { line = number, message = message }
end

local function parseCount(text, allowZero)
  local value = tonumber(text)
  if not value or value ~= math.floor(value) then
    return nil
  end
  if allowZero then
    if value < 0 or value > 1000000000 then
      return nil
    end
  elseif value < 1 or value > 1000000000 then
    return nil
  end
  return value
end

local function parseKey(text, kind)
  if #text == 0 or #text > line.MAX_KEY then
    return nil
  end
  if text:find("%s") or text:find("%+") then
    return nil
  end
  if kind == "fluid" then
    if text:find("@", 1, true) then
      return nil
    end
    return text
  end
  local name, damage = text:match("^([^@]+)@(%d+)$")
  if name then
    local value = tonumber(damage)
    if not value or value > 65535 then
      return nil
    end
    return name, value
  end
  if text:find("@", 1, true) then
    return nil
  end
  return text, 0
end

local function parseTerms(text, number, errors)
  local terms = {}
  local rest = text
  while true do
    local plus = rest:find("+", 1, true)
    local piece = trim(plus and rest:sub(1, plus - 1) or rest)
    if #piece == 0 then
      addError(errors, number, "empty term")
      return nil
    end
    local qtyText, kind, key = piece:match("^(%S+)%s+(%S+)%s+(%S+)$")
    if not qtyText then
      addError(errors, number, "expected <qty> <item|fluid> <key>")
      return nil
    end
    local qty = parseCount(qtyText, false)
    if not qty then
      addError(errors, number, "quantity must be a positive integer: " .. qtyText)
      return nil
    end
    if kind ~= "item" and kind ~= "fluid" then
      addError(errors, number, "kind must be item or fluid: " .. kind)
      return nil
    end
    local keyName, damage = parseKey(key, kind)
    if not keyName then
      addError(errors, number, "invalid " .. kind .. " key: " .. key)
      return nil
    end
    if #terms >= line.MAX_TERMS then
      addError(errors, number, "too many terms (max " .. line.MAX_TERMS .. ")")
      return nil
    end
    terms[#terms + 1] = { kind = kind, key = keyName, damage = damage, qty = qty }
    if not plus then
      break
    end
    rest = rest:sub(plus + 1)
  end
  return terms
end

local function parseStocks(text, number, errors)
  local names = {}
  local seen = {}
  local start = 1
  while true do
    local comma = text:find(",", start, true)
    local name = trim(comma and text:sub(start, comma - 1) or text:sub(start))
    if #name == 0 or #name > line.MAX_KEY or not name:match("^[%w_%-%./:]+$") then
      addError(errors, number, "invalid stock name: " .. name)
      return nil
    end
    if not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
    if not comma then
      break
    end
    start = comma + 1
  end
  if #names == 0 then
    addError(errors, number, "stock list is empty")
    return nil
  end
  if #names > line.MAX_STOCKS then
    addError(errors, number, "too many stocks (max " .. line.MAX_STOCKS .. ")")
    return nil
  end
  return names
end

-- Parse a line program. Returns the program table, or nil plus a list of
-- { line = number, message = string } errors. It never executes the source.
function line.parse(text, name)
  if type(text) ~= "string" then
    return nil, { { line = 0, message = "source must be a string" } }
  end
  if text:sub(1, 3) == "\239\187\191" then
    text = text:sub(4)
  end
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")

  local errors = {}
  if #text > line.MAX_BYTES then
    return nil, { { line = 0, message = "file is larger than " .. line.MAX_BYTES .. " bytes" } }
  end

  local program = {
    name = name,
    stocks = { inputs = {}, outputs = {} },
    rules = {},
    limits = {},
    ticks = nil,
    bytes = #text,
    lines = 0,
  }
  local current
  local currentLine
  local seenRules = {}
  local seenStocks = { inputs = {}, outputs = {} }

  local function finishRule()
    if not current then
      return
    end
    if not current.sawIn then
      addError(errors, currentLine, "rule '" .. current.name .. "' has no in")
    end
    if not current.sawOut then
      addError(errors, currentLine, "rule '" .. current.name .. "' has no out")
    end
    current.sawIn, current.sawOut = nil, nil
    current = nil
  end

  local lineNumber = 0
  for raw in (text .. "\n"):gmatch("(.-)\n") do
    lineNumber = lineNumber + 1
    if lineNumber > line.MAX_LINES then
      addError(errors, lineNumber, "too many lines (max " .. line.MAX_LINES .. ")")
      break
    end
    local value = trim(raw:gsub("#.*$", ""))
    if value ~= "" then
      local stockSide, stockList = value:match("^stock%s+(in)%s+(.+)$")
      if not stockSide then
        stockSide, stockList = value:match("^stock%s+(out)%s+(.+)$")
      end
      local ruleName = value:match("^rule%s+(%S+)%s*$")
      local inputText = value:match("^in%s+(.+)$")
      local outputText = value:match("^out%s+(.+)$")
      local ticksText = value:match("^ticks%s+(%S+)%s*$")
      local limitText = value:match("^limit%s+(.+)$")

      if stockSide then
        finishRule()
        local stockKey = stockSide == "in" and "inputs" or "outputs"
        local names = parseStocks(stockList, lineNumber, errors)
        if names then
          for _, stockName in ipairs(names) do
            if not seenStocks[stockKey][stockName] then
              if #program.stocks[stockKey] >= line.MAX_STOCKS then
                addError(errors, lineNumber, "too many " .. stockSide .. " stocks (max " .. line.MAX_STOCKS .. ")")
              else
                seenStocks[stockKey][stockName] = true
                program.stocks[stockKey][#program.stocks[stockKey] + 1] = stockName
              end
            end
          end
        end
      elseif ruleName then
        finishRule()
        if #ruleName > line.MAX_NAME or not ruleName:match("^[%w_%-]+$") then
          addError(errors, lineNumber, "invalid rule name: " .. ruleName)
        elseif seenRules[ruleName] then
          addError(errors, lineNumber, "duplicate rule: " .. ruleName)
        elseif #program.rules >= line.MAX_RULES then
          addError(errors, lineNumber, "too many rules (max " .. line.MAX_RULES .. ")")
        else
          seenRules[ruleName] = true
          current = { name = ruleName, inputs = {}, outputs = {}, ticks = nil }
          currentLine = lineNumber
          program.rules[#program.rules + 1] = current
        end
      elseif inputText then
        if not current then
          addError(errors, lineNumber, "in outside a rule")
        elseif current.sawIn then
          addError(errors, lineNumber, "duplicate in in rule '" .. current.name .. "'")
        else
          current.inputs = parseTerms(inputText, lineNumber, errors) or {}
          current.sawIn = true
        end
      elseif outputText then
        if not current then
          addError(errors, lineNumber, "out outside a rule")
        elseif current.sawOut then
          addError(errors, lineNumber, "duplicate out in rule '" .. current.name .. "'")
        else
          current.outputs = parseTerms(outputText, lineNumber, errors) or {}
          current.sawOut = true
        end
      elseif ticksText then
        finishRule()
        local ticks = parseCount(ticksText, false)
        if not ticks then
          addError(errors, lineNumber, "ticks must be a positive integer")
        elseif program.ticks then
          addError(errors, lineNumber, "duplicate ticks")
        else
          program.ticks = ticks
        end
      elseif limitText then
        finishRule()
        local qtyText, kind, key = limitText:match("^(%S+)%s+(%S+)%s+(%S+)$")
        if not qtyText then
          addError(errors, lineNumber, "expected limit <qty> <item|fluid> <key>")
        else
          local qty = parseCount(qtyText, true)
          if not qty then
            addError(errors, lineNumber, "limit quantity must be a non-negative integer")
          elseif kind ~= "item" and kind ~= "fluid" then
            addError(errors, lineNumber, "limit kind must be item or fluid")
          else
            local keyName, damage = parseKey(key, kind)
            if not keyName then
              addError(errors, lineNumber, "invalid limit key: " .. key)
            else
              program.limits[#program.limits + 1] = {
                kind = kind,
                key = keyName,
                damage = damage,
                qty = qty,
              }
            end
          end
        end
      else
        addError(errors, lineNumber, "unknown directive: " .. value)
      end
    end
  end

  finishRule()
  program.lines = math.min(lineNumber, line.MAX_LINES)
  if #errors > 0 then
    return nil, errors
  end
  return program
end

-- Read and parse a line program through a VFS. IO failures are returned in the
-- same shape as parser errors, with line 0.
function line.load(vfs, path)
  if type(vfs) ~= "table" or type(vfs.read) ~= "function" then
    return nil, { { line = 0, message = "invalid vfs" } }
  end
  local text, reason = vfs.read(path)
  if not text then
    return nil, { { line = 0, message = "cannot read " .. tostring(path) .. ": " .. tostring(reason or "unknown") } }
  end
  return line.parse(text, path)
end

local function termText(term)
  local key = term.key
  if term.kind == "item" and term.damage and term.damage ~= 0 then
    key = key .. "@" .. tostring(term.damage)
  end
  return tostring(term.qty) .. " " .. term.kind .. " " .. key
end

function line.termText(term)
  return termText(term)
end

function line.ruleText(rule)
  local inputs, outputs = {}, {}
  for _, term in ipairs(rule.inputs or {}) do
    inputs[#inputs + 1] = termText(term)
  end
  for _, term in ipairs(rule.outputs or {}) do
    outputs[#outputs + 1] = termText(term)
  end
  return "in " .. table.concat(inputs, " + ") .. " = out " .. table.concat(outputs, " + ")
end

function line.findRule(program, name)
  for _, rule in ipairs((program and program.rules) or {}) do
    if rule.name == name then
      return rule
    end
  end
  return nil
end

function line.errorText(errors)
  local pieces = {}
  for _, item in ipairs(errors or {}) do
    pieces[#pieces + 1] = "line " .. tostring(item.line) .. ": " .. item.message
  end
  return table.concat(pieces, "; ")
end

-- Public key parser for the book and the planner: `name@damage` for items,
-- `name` for fluids. Returns name, damage or nil.
function line.parseKey(text, kind)
  return parseKey(text, kind)
end

return line
