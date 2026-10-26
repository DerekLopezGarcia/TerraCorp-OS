-- Cluster text frames and the wired modem transport.
--
-- Wire format (one line, at most 1 KB):
--
--   TC1 <VERB> key=value key=value ...
--
-- Values percent-escape %, space, tab, CR, LF, and =. The parser rejects
-- unknown verbs, duplicate or malformed keys, missing required fields, and
-- oversized frames. Protocol versioning lives in the `TC1` prefix, so a future
-- transport can reject old peers instead of misreading them.

local net = {}

net.PORT = 4200
net.MAX_FRAME = 1024
net.PROTOCOL = "TC1"
net.VERSION = 1

-- Required fields per verb. Extra scalar fields are allowed so a newer peer
-- can add data without breaking an older one. Field names start lowercase;
-- camelCase is allowed (`masterId`), but the first letter must stay lowercase.
local VERBS = {
  HELLO = { "id" },
  ASSIGN = { "id", "name", "role", "master", "masterId", "token" },
  ACK = { "token" },
  STATUS = { "id", "state" },
  PING = { "id" },
  PONG = { "id", "state" },
  LIST = { "id", "path" },
  FETCH = { "id", "path" },
  DIRS = { "id", "path" },
  DATA = { "id", "path" },
  MISS = { "id", "path" },
  PULL = { "id", "v" },
  JOB = { "id", "pub", "task" },
  CLAIM = { "id", "worker" },
  GRANT = { "id", "token" },
  RESULT = { "id", "token", "state" },
  CANCEL = { "id", "pub" },
  DRAIN = { "id" },
  VDISK = { "id" },
  VOPEN = { "id", "disk", "path", "size" },
  VDATA = { "id", "off" },
  VDACK = { "id", "off" },
  VDONE = { "id" },
  VERR = { "id" },
  VREAD = { "id", "disk", "path", "off" },
  VLST = { "id", "disk", "path" },
  VDIRS = { "id", "path" },
  VDEL = { "id", "disk", "path" },
}

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

local function escape(value)
  return (tostring(value):gsub("[%% \t\r\n=]", ESCAPES))
end

local function unescape(value)
  return (value:gsub("%%(%x%x)", function(code)
    return UNESCAPES[code:upper()] or string.char(tonumber(code, 16))
  end))
end

net.escape = escape
net.unescape = unescape

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

--- Encode one frame. Fields must be a flat table of scalar values.
-- Returns the frame, or nil and a reason.
function net.encode(verb, fields)
  if type(verb) ~= "string" or not verb:match("^[A-Z][A-Z0-9_]*$") then
    return nil, "invalid verb"
  end
  if not VERBS[verb] then
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

  local parts = { net.PROTOCOL, verb }
  local present = {}
  for _, key in ipairs(keys) do
    local value = scalar(fields[key])
    if value == nil then
      return nil, "invalid value for " .. key
    end
    present[key] = value
    parts[#parts + 1] = key .. "=" .. escape(value)
  end

  for _, key in ipairs(VERBS[verb]) do
    if present[key] == nil or present[key] == "" then
      return nil, "missing field: " .. key
    end
  end

  local frame = table.concat(parts, " ")
  if #frame > net.MAX_FRAME then
    return nil, "frame too large"
  end
  return frame
end

--- Decode one frame. Returns verb, fields, or nil and a reason.
function net.decode(frame)
  if type(frame) ~= "string" then
    return nil, "frame is not a string"
  end
  if #frame == 0 or #frame > net.MAX_FRAME then
    return nil, "invalid frame length"
  end
  if frame:find("[\r\n%z]") then
    return nil, "frame must be one line"
  end

  local protocol, verb, rest = frame:match("^(%S+)%s+(%S+)%s*(.*)$")
  if protocol ~= net.PROTOCOL then
    return nil, "unsupported protocol: " .. tostring(protocol)
  end
  if not VERBS[verb] then
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
    fields[key] = unescape(value)
  end

  for _, key in ipairs(VERBS[verb]) do
    if fields[key] == nil or fields[key] == "" then
      return nil, "missing field: " .. key
    end
  end

  return verb, fields
end

--- True when a signal name and its arguments look like a modem message.
function net.isModemMessage(name, count)
  return name == "modem_message" and (count or 0) >= 5
end

local modem = {}
modem.__index = modem

--- Create a transport over the first available modem. A wired card is
-- preferred; `opts.component` and `opts.computer` exist for the harness.
function net.newModem(opts)
  opts = opts or {}
  local self = setmetatable({}, modem)
  self.component = opts.component or component
  self.computer = opts.computer or computer
  self.port = opts.port or net.PORT
  self.address = nil
  return self
end

--- Locate a modem and open the cluster port.
-- Returns true, or nil and a reason.
function modem:open()
  if not self.component or type(self.component.list) ~= "function" then
    return nil, "component API unavailable"
  end

  local fallback
  for address in self.component.list("modem") do
    if not fallback then
      fallback = address
    end
    local ok, wired = pcall(self.component.invoke, address, "isWired")
    if ok and wired == true then
      self.address = address
      break
    end
  end

  if not self.address then
    -- Older builds omit isWired; keep working but let the caller warn.
    self.address = fallback
  end
  if not self.address then
    return nil, "no network card installed"
  end

  local ok, result = pcall(self.component.invoke, self.address, "open", self.port)
  if not ok then
    return nil, tostring(result)
  end
  if result == false then
    return nil, "could not open port " .. tostring(self.port)
  end
  return true
end

function modem:isWired()
  if not self.address then
    return nil
  end
  local ok, value = pcall(self.component.invoke, self.address, "isWired")
  if ok and type(value) == "boolean" then
    return value
  end
  return nil
end

function modem:close()
  if self.address then
    pcall(self.component.invoke, self.address, "close", self.port)
  end
end

local function dispatch(self, method, ...)
  if not self.address then
    return nil, "network card is not open"
  end
  local ok, result = pcall(self.component.invoke, self.address, method, ...)
  if not ok then
    return nil, tostring(result)
  end
  if result == false then
    return nil, method .. " was rejected"
  end
  return true
end

--- Send an encoded frame to `address` (a computer or modem node address).
function modem:send(address, verb, fields)
  local frame, reason = net.encode(verb, fields)
  if not frame then
    return nil, reason
  end
  if type(address) ~= "string" or address == "" then
    return nil, "missing destination address"
  end
  return dispatch(self, "send", address, self.port, frame)
end

--- Send an already encoded frame, used when the sender sizes the payload
-- itself (file transfers shrink chunks to fit the 1 KB limit).
function modem:sendFrame(address, frame)
  if type(frame) ~= "string" or #frame == 0 or #frame > net.MAX_FRAME then
    return nil, "invalid frame"
  end
  if type(address) ~= "string" or address == "" then
    return nil, "missing destination address"
  end
  return dispatch(self, "send", address, self.port, frame)
end

--- Broadcast an encoded frame on the cluster port.
function modem:broadcast(verb, fields)
  local frame, reason = net.encode(verb, fields)
  if not frame then
    return nil, reason
  end
  return dispatch(self, "broadcast", self.port, frame)
end

return net
