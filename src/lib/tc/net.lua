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
--
-- Accepted legacy (decision 25): 23 of the 34 verbs below are inert residues of
-- the rack, Relay and Vault, removed in 0.4.9. They stay parsed so an old peer
-- gets a clean `unknown verb`, not a parser surprise. The 23: ACK, LIST, FETCH,
-- DIRS, DATA, MISS, PULL, JOB, CLAIM, GRANT, RESULT, CANCEL, DRAIN, VDISK,
-- VOPEN, VDATA, VDACK, VDONE, VERR, VREAD, VLST, VDIRS, VDEL. The 11 live:
-- HELLO, ASSIGN, STATUS, PING, PONG, CFG, CFGACK, LINK, LREP, LDATA, LEND.

local frame = require("tc.frame")

local net = {}

net.PORT = 4200
net.MAX_FRAME = 8 * 1024
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
  -- Line node configuration pushed by the master. The node validates the file
  -- name against its own whitelist, writes it and reloads.
  CFG = { "id", "file", "body" },
  CFGACK = { "id", "file", "state" },
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
  -- External Link (docs/external-link.md). The bridge speaks these over HTTP.
  LINK = { "id", "token", "cmd" },
  LREP = { "id", "token", "state" },
  LDATA = { "id", "off" },
  LEND = { "id", "size" },
}

net.escape = frame.escape
net.unescape = frame.unescape

--- Encode one frame. Fields must be a flat table of scalar values.
-- Returns the frame, or nil and a reason.
function net.encode(verb, fields)
  return frame.encode(net.PROTOCOL, VERBS, verb, fields, { max = net.MAX_FRAME })
end

--- Decode one frame. Returns verb, fields, or nil and a reason.
function net.decode(text)
  return frame.decode(net.PROTOCOL, VERBS, text, { max = net.MAX_FRAME })
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
