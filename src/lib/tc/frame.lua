-- Generic single-line frame parser shared by TC1 (port 4200) and DNS1 (4201).
--
-- A frame is `PROTOCOL VERB key=value key=value ...` on one line. Values
-- percent-escape %, space, tab, CR, LF and =. The parser rejects unknown
-- verbs, duplicate or malformed keys, missing required fields and oversized
-- frames. The wire format is deliberately verbatim with the old TC1 parser:
-- extracting it here must not change a single TC1 byte.

local frame = {}

frame.MAX_FRAME = 8 * 1024

local ESCAPES = {
  ["%"] = "%25",
  [" "] = "%20",
  ["\t"] = "%09",
  ["\r"] = "%0D",
  ["\n"] = "%0A",
  ["="] = "%3D",
}

local UNESCAPES = {
  ["25"] = "%",
  ["20"] = " ",
  ["09"] = "\t",
  ["0D"] = "\r",
  ["0A"] = "\n",
  ["3D"] = "=",
}

function frame.escape(value)
  return (tostring(value):gsub("[%% \t\r\n=]", ESCAPES))
end

function frame.unescape(value)
  return (value:gsub("%%(%x%x)", function(code)
    return UNESCAPES[code:upper()] or string.char(tonumber(code, 16))
  end))
end

local function scalar(value)
  local kind = type(value)
  if kind == "string" or kind == "number" then
    return tostring(value)
  end
  if kind == "boolean" then
    return value and "true" or "false"
  end
  return nil
end

local function maxOf(opts)
  return (opts and opts.max) or frame.MAX_FRAME
end

--- Encode one frame. Fields must be a flat table of scalar values.
-- Returns the frame, or nil and a reason.
function frame.encode(protocol, verbs, verb, fields, opts)
  if type(verb) ~= "string" or not verb:match("^[A-Z][A-Z0-9_]*$") then
    return nil, "invalid verb"
  end
  if not verbs[verb] then
    return nil, "unknown verb: " .. tostring(verb)
  end

  fields = fields or {}
  local keys = {}
  for key in pairs(fields) do
    if type(key) ~= "string" or not key:match("^[a-z][a-zA-Z0-9_]*$") then
      return nil, "invalid field name: " .. tostring(key)
    end
    keys[#keys + 1] = key
  end
  table.sort(keys)

  local parts = { protocol, verb }
  local present = {}
  for _, key in ipairs(keys) do
    local value = scalar(fields[key])
    if value == nil then
      return nil, "invalid value for " .. key
    end
    present[key] = value
    parts[#parts + 1] = key .. "=" .. frame.escape(value)
  end

  for _, key in ipairs(verbs[verb]) do
    if present[key] == nil or present[key] == "" then
      return nil, "missing field: " .. key
    end
  end

  local text = table.concat(parts, " ")
  if #text > maxOf(opts) then
    return nil, "frame too large"
  end
  return text
end

--- Decode one frame. Returns verb, fields, or nil and a reason.
-- `opts.allowUnknown` keeps an unknown verb readable (used to answer ERR).
function frame.decode(protocol, verbs, text, opts)
  opts = opts or {}
  if type(text) ~= "string" then
    return nil, "frame is not a string"
  end
  if #text == 0 or #text > maxOf(opts) then
    return nil, "invalid frame length"
  end
  if text:find("[\r\n%z]") then
    return nil, "frame must be one line"
  end

  local got, verb, rest = text:match("^(%S+)%s+(%S+)%s*(.*)$")
  if got ~= protocol then
    return nil, "unsupported protocol: " .. tostring(got)
  end
  if not verbs[verb] and not opts.allowUnknown then
    return nil, "unknown verb: " .. tostring(verb)
  end

  local fields = {}
  for token in rest:gmatch("%S+") do
    local key, value = token:match("^([^=]+)=(.*)$")
    if not key then
      return nil, "malformed field: " .. token
    end
    if not key:match("^[a-z][a-zA-Z0-9_]*$") then
      return nil, "invalid field name: " .. key
    end
    if fields[key] ~= nil then
      return nil, "duplicate field: " .. key
    end
    fields[key] = frame.unescape(value)
  end

  if verbs[verb] then
    for _, key in ipairs(verbs[verb]) do
      if fields[key] == nil or fields[key] == "" then
        return nil, "missing field: " .. key
      end
    end
  end

  return verb, fields
end

return frame
