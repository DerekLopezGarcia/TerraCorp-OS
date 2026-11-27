-- Safe codec for DNS1 values.
--
-- The DNS1 envelope carries a serialized value in one scalar field. This codec
-- never calls `load` on remote data: it parses a deliberately small grammar
-- (nil, booleans, numbers, strings and tables) with hard limits. Encoding is
-- canonical: integer keys ascend, then string keys in byte order, so the same
-- table always produces the same bytes.

local value = {}

value.MAX_DEPTH = 24
value.MAX_KEYS = 256
value.MAX_STRING = 1024
value.MAX_TOTAL = 4096

local function fail(code)
  error({ code = code }, 0)
end

local function checkNumber(n)
  if n ~= n or n == math.huge or n == -math.huge then
    fail("bad_value")
  end
end

local function encodeString(text)
  if #text > value.MAX_STRING then
    fail("too_long")
  end
  local out = { '"' }
  for index = 1, #text do
    local byte = text:byte(index)
    local char = text:sub(index, index)
    if char == '"' then
      out[#out + 1] = '\\"'
    elseif char == "\\" then
      out[#out + 1] = "\\\\"
    elseif char == "\n" then
      out[#out + 1] = "\\n"
    elseif char == "\t" then
      out[#out + 1] = "\\t"
    elseif char == "\r" then
      out[#out + 1] = "\\r"
    elseif byte < 32 or byte == 127 then
      out[#out + 1] = string.format("\\%03d", byte)
    else
      out[#out + 1] = char
    end
  end
  out[#out + 1] = '"'
  return table.concat(out)
end

local function encodeNumber(n)
  checkNumber(n)
  if math.type(n) == "integer" then
    return string.format("%d", n)
  end
  return string.format("%.17g", n)
end

local function keyLess(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then
    return ta == "number"
  end
  if ta == "number" then
    return a < b
  end
  return a < b
end

local function encodeValue(item, depth, seen)
  local kind = type(item)
  if item == nil then
    return "nil"
  elseif kind == "boolean" then
    return item and "true" or "false"
  elseif kind == "number" then
    return encodeNumber(item)
  elseif kind == "string" then
    return encodeString(item)
  elseif kind ~= "table" then
    fail("unserializable")
  end

  if depth >= value.MAX_DEPTH then
    fail("too_deep")
  end
  if seen[item] then
    fail("bad_value")
  end

  local keys = {}
  for key in pairs(item) do
    local keyType = type(key)
    if keyType == "number" then
      if math.type(key) ~= "integer" or key < 0 then
        fail("bad_value")
      end
    elseif keyType ~= "string" then
      fail("unserializable")
    end
    keys[#keys + 1] = key
  end
  if #keys > value.MAX_KEYS then
    fail("too_many")
  end
  table.sort(keys, keyLess)

  seen[item] = true
  local out = { "{" }
  for index, key in ipairs(keys) do
    if index > 1 then
      out[#out + 1] = ","
    end
    if type(key) == "number" then
      out[#out + 1] = "[" .. string.format("%d", key) .. "]="
    else
      out[#out + 1] = "[" .. encodeString(key) .. "]="
    end
    out[#out + 1] = encodeValue(item[key], depth + 1, seen)
  end
  out[#out + 1] = "}"
  seen[item] = nil
  return table.concat(out)
end

--- Encode a value. Returns the canonical text, or nil and a code.
function value.encode(item)
  local ok, result = pcall(encodeValue, item, 0, {})
  if not ok then
    local code = type(result) == "table" and result.code or "bad_value"
    return nil, code
  end
  if #result > value.MAX_TOTAL then
    return nil, "too_long"
  end
  return result
end

local function decodeFailure(code)
  error({ code = code }, 0)
end

local function decodeString(text, position)
  position = position + 1 -- opening quote
  local out = {}
  while true do
    if position > #text then
      decodeFailure("bad_value")
    end
    local char = text:sub(position, position)
    if char == '"' then
      local result = table.concat(out)
      if #result > value.MAX_STRING then
        decodeFailure("too_long")
      end
      return result, position + 1
    elseif char == "\\" then
      local nextChar = text:sub(position + 1, position + 1)
      if nextChar == "n" then
        out[#out + 1] = "\n"
        position = position + 2
      elseif nextChar == "t" then
        out[#out + 1] = "\t"
        position = position + 2
      elseif nextChar == "r" then
        out[#out + 1] = "\r"
        position = position + 2
      elseif nextChar == '"' then
        out[#out + 1] = '"'
        position = position + 2
      elseif nextChar == "\\" then
        out[#out + 1] = "\\"
        position = position + 2
      elseif nextChar:match("%d") then
        local digits = text:sub(position + 1, position + 3)
        if #digits ~= 3 or not digits:match("^%d%d%d$") then
          decodeFailure("bad_value")
        end
        local byte = tonumber(digits, 10)
        if byte > 255 then
          decodeFailure("bad_value")
        end
        out[#out + 1] = string.char(byte)
        position = position + 4
      else
        decodeFailure("bad_value")
      end
    elseif char:byte() < 32 then
      decodeFailure("bad_value")
    else
      out[#out + 1] = char
      position = position + 1
    end
  end
end

local function decodeNumber(text, position)
  local rest = text:sub(position)
  local token = rest:match("^-?%d+%.%d+[eE][+-]?%d+")
    or rest:match("^-?%d+%.%d+")
    or rest:match("^-?%d+[eE][+-]?%d+")
    or rest:match("^-?%d+")
  if not token then
    decodeFailure("bad_value")
  end
  local number = tonumber(token)
  if not number then
    decodeFailure("bad_value")
  end
  checkNumber(number)
  return number, position + #token
end

local decodeValue

local function skipSpace(text, position)
  local _, last = text:find("^[ \t\r\n]*", position)
  return (last or position - 1) + 1
end

local function decodeTable(text, position, depth)
  if depth >= value.MAX_DEPTH then
    decodeFailure("too_deep")
  end
  position = position + 1 -- {
  local result, count = {}, 0
  local intKeys, stringKeys = {}, {}
  position = skipSpace(text, position)
  if text:sub(position, position) == "}" then
    return result, position + 1
  end

  while true do
    if text:sub(position, position) ~= "[" then
      decodeFailure("bad_value")
    end
    position = skipSpace(text, position + 1)

    local key
    if text:sub(position, position) == '"' then
      key, position = decodeString(text, position)
    else
      local number
      number, position = decodeNumber(text, position)
      if math.type(number) ~= "integer" or number < 0 then
        decodeFailure("bad_value")
      end
      key = number
    end

    position = skipSpace(text, position)
    if text:sub(position, position) ~= "]" then
      decodeFailure("bad_value")
    end
    position = skipSpace(text, position + 1)
    if text:sub(position, position) ~= "=" then
      decodeFailure("bad_value")
    end
    position = skipSpace(text, position + 1)

    if type(key) == "number" then
      if intKeys[key] then
        decodeFailure("bad_value")
      end
      intKeys[key] = true
    else
      if stringKeys[key] then
        decodeFailure("bad_value")
      end
      stringKeys[key] = true
    end

    count = count + 1
    if count > value.MAX_KEYS then
      decodeFailure("too_many")
    end

    local item
    item, position = decodeValue(text, position, depth + 1)
    result[key] = item

    position = skipSpace(text, position)
    local char = text:sub(position, position)
    if char == "," then
      position = skipSpace(text, position + 1)
      if text:sub(position, position) == "}" then
        decodeFailure("bad_value")
      end
    elseif char == "}" then
      return result, position + 1
    else
      decodeFailure("bad_value")
    end
  end
end

decodeValue = function(text, position, depth)
  position = skipSpace(text, position)
  local char = text:sub(position, position)
  if char == "" then
    decodeFailure("bad_value")
  elseif char == "{" then
    return decodeTable(text, position, depth)
  elseif char == '"' then
    return decodeString(text, position)
  elseif text:sub(position, position + 2) == "nil" then
    return nil, position + 3
  elseif text:sub(position, position + 3) == "true" then
    return true, position + 4
  elseif text:sub(position, position + 4) == "false" then
    return false, position + 5
  else
    return decodeNumber(text, position)
  end
end

--- Decode a value. Returns the value, or nil and a code.
function value.decode(text)
  if type(text) ~= "string" then
    return nil, "bad_value"
  end
  if #text > value.MAX_TOTAL then
    return nil, "too_long"
  end
  local ok, item, position = pcall(decodeValue, text, 1, 0)
  if not ok then
    local code = type(item) == "table" and item.code or "bad_value"
    return nil, code
  end
  position = skipSpace(text, position)
  if position <= #text then
    return nil, "bad_value"
  end
  return item
end

return value
