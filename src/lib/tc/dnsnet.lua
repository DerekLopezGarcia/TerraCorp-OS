-- DNS1 transport (port 4201): every modem, answer from the modem that heard it.
--
-- TC1 (`tc.net`, port 4200) is unchanged and keeps using the first wired
-- modem. DNS1 opens its port on every modem so a node with a wired and a
-- wireless card can answer on whichever card received the frame. OpenComputers
-- is assumed to emit `modem_message(receiverAddress, senderAddress, port,
-- distance, message)`: the first address is the receiving modem, which is the
-- one to answer from, and the second is the peer. That shape is pending the
-- in-game S9 probe; no transcript has been recorded yet. The parser below
-- locates the port and message by value, accepts either string as the receiver,
-- caches the receiver string per peer and answers through it, and falls back to
-- the side map or to every modem when that address cannot send. The real event
-- order, whether the receiver value is a valid send address, and the wireless
-- packet limit remain the S9 probe.

local frame = require("tc.frame")

local dnsnet = {}

dnsnet.PORT = 4201
dnsnet.MAX_TX = 900
dnsnet.MAX_RX = 8 * 1024
dnsnet.PROTOCOL = "DNS1"
dnsnet.DEDUPE_TTL = 5
dnsnet.DEDUPE_SIZE = 16

local VERBS = {
  HELLO = { "rid", "id", "node", "proto", "boot", "transports" },
  HELLOACK = { "rid", "id", "proto", "ver", "boot", "transports" },
  DESCRIBE = { "rid", "id", "target" },
  DESCRIBEACK = { "rid", "id" },
  EXEC = { "rid", "id", "target", "method" },
  EXECACK = { "rid", "id", "ok" },
  EDIT = { "rid", "id", "target", "field", "rev", "p" },
  EDITACK = { "rid", "id", "ok" },
  PUBLISH = { "rid", "id", "ver", "part", "p" },
  PUBLISHACK = { "rid", "id", "ver", "ok" },
  CATALOG = { "rid", "id" },
  CATALOGACK = { "rid", "id", "body", "stale" },
  WHO = { "rid", "id" },
  WHOACK = { "rid", "id", "node", "proto", "ver", "boot" },
  ERR = { "rid", "id", "err" },
}

dnsnet.VERBS = VERBS

-- Replies are not requests: an ACK/ERR is idempotent for the layer above and
-- must never share the request dedupe table. The node publishes with rids that
-- a client may reuse first (both start at 00000001); if PUBLISHACKs were
-- remembered as duplicates, the first relayed EXEC of that client would be
-- dropped by the node. Master and client use the same rule.
local RESPONSES = {
  HELLOACK = true,
  DESCRIBEACK = true,
  EXECACK = true,
  EDITACK = true,
  PUBLISHACK = true,
  CATALOGACK = true,
  WHOACK = true,
  ERR = true,
}

local SIDES = {
  north = true, south = true, east = true, west = true,
  up = true, down = true, top = true, bottom = true,
  front = true, back = true, left = true, right = true,
}

local function isSide(name)
  return type(name) == "string" and (SIDES[name] == true or name:match("^side_?%d+$") ~= nil)
end

local function eachComponent(list, callback)
  if type(list) == "function" then
    for address in list do
      callback(address)
    end
    return
  end
  if type(list) ~= "table" then
    return
  end
  for key, item in pairs(list) do
    if type(key) == "number" then
      callback(item)
    else
      callback(key)
    end
  end
end

local net = {}
net.__index = net

--- Create the DNS1 transport. `opts.transport` is auto, wired or wireless.
function dnsnet.new(opts)
  opts = opts or {}
  local self = setmetatable({}, net)
  self.computer = opts.computer or computer
  self.component = opts.component or component
  self.port = opts.port or dnsnet.PORT
  self.nodeId = opts.nodeId or (self.computer.address and self.computer.address()) or "node"
  self.ownAddress = self.computer.address and self.computer.address() or nil
  self.transport = opts.transport or "auto"
  self.log = opts.log
  self.debug = opts.debug

  self.modems = {}
  self.nodeSide = {}
  self.dedupe = {}
  self.dedupeOrder = {}
  self.onFrame = nil
  self.lastShape = nil
  self.warned = {}
  self.counters = {
    sent = 0,
    recv = 0,
    dropped = 0,
    dup = 0,
    sizeDrops = 0,
    openFailed = 0,
    sendFailed = 0,
  }
  return self
end

function net:now()
  local uptime = self.computer and self.computer.uptime
  if type(uptime) == "function" then
    local ok, value = pcall(uptime, self.computer)
    if ok and type(value) == "number" then
      return value
    end
  end
  return os.time()
end

function net:warnOnce(key, message)
  if self.warned[key] then
    return
  end
  self.warned[key] = true
  if self.log and type(self.log.warn) == "function" then
    self.log.warn(message)
  elseif self.log and type(self.log.error) == "function" then
    self.log.error(message)
  end
end

local function modemAllowed(self, modem)
  if self.transport == "wired" then
    return modem.wired ~= false
  elseif self.transport == "wireless" then
    return modem.wired ~= true
  end
  return true
end

--- Open the DNS1 port on every modem. A modem that fails is counted, not fatal.
function net:open()
  if not self.component or type(self.component.list) ~= "function" then
    return nil, "component API unavailable"
  end

  self.modems = {}
  local opened, attempted = 0, 0
  eachComponent(self.component.list("modem"), function(address)
    attempted = attempted + 1
    local ok, wired = pcall(self.component.invoke, address, "isWired")
    if not ok then
      wired = nil
    end
    local modem = { address = address, wired = wired }
    local okOpen, result = pcall(self.component.invoke, address, "open", self.port)
    if okOpen and result ~= false then
      modem.open = true
      opened = opened + 1
      self.modems[#self.modems + 1] = modem
    else
      self.counters.openFailed = self.counters.openFailed + 1
      if self.log and type(self.log.warn) == "function" then
        self.log.warn("DNS1: could not open port " .. tostring(self.port) ..
          " on " .. tostring(address) .. ": " .. tostring(result))
      end
    end
  end)

  if attempted == 0 then
    return nil, "no network card installed"
  end
  if opened == 0 then
    return nil, "could not open port " .. tostring(self.port)
  end
  return true
end

function net:close()
  for _, modem in ipairs(self.modems) do
    pcall(self.component.invoke, modem.address, "close", self.port)
  end
end

--- Sorted transports seen on this node, for HELLO and dns.status.
function net:transports()
  local seen, list = {}, {}
  for _, modem in ipairs(self.modems) do
    local name = modem.wired == false and "wireless" or "wired"
    if not seen[name] then
      seen[name] = true
      list[#list + 1] = name
    end
  end
  table.sort(list)
  return table.concat(list, ",")
end

function net:stats()
  return self.counters
end

--- The last `modem_message` shape seen, for the in-game S9 probe.
function net:shape()
  return self.lastShape
end

local function encodeFrame(self, verb, fields)
  return frame.encode(dnsnet.PROTOCOL, VERBS, verb, fields, { max = dnsnet.MAX_TX })
end

function net:encode(verb, fields)
  return encodeFrame(self, verb, fields)
end

local function invokeSend(self, address, target, text)
  local ok, result = pcall(self.component.invoke, address, "send", target, self.port, text)
  if ok and result then
    return true
  end
  return nil, tostring(result)
end

local function sendOnModem(self, modem, target, text)
  return invokeSend(self, modem.address, target, text)
end

--- Send an already encoded frame. Uses the cached node side first; otherwise
-- tries every allowed modem addressed to the node (the receiver dedupes by rid).
function net:sendFrame(target, text)
  if type(text) ~= "string" or #text == 0 or #text > dnsnet.MAX_TX then
    self.counters.sizeDrops = self.counters.sizeDrops + 1
    return nil, "too_large"
  end
  if type(target) ~= "string" or target == "" then
    return nil, "missing destination address"
  end

  local side = self.nodeSide[target]
  if side then
    local ok = invokeSend(self, side, target, text)
    if ok then
      self.counters.sent = self.counters.sent + 1
      return true
    end
    self:warnOnce("side:" .. tostring(side), "DNS1: ingress send failed for side " .. tostring(side))
  end

  local sent = 0
  for _, modem in ipairs(self.modems) do
    if modemAllowed(self, modem) then
      if sendOnModem(self, modem, target, text) then
        sent = sent + 1
      end
    end
  end
  if sent > 0 then
    self.counters.sent = self.counters.sent + sent
    return true
  end
  self.counters.sendFailed = self.counters.sendFailed + 1
  return nil, "no modem could send"
end

function net:send(target, verb, fields)
  local text, reason = encodeFrame(self, verb, fields)
  if not text then
    if reason == "frame too large" then
      self.counters.sizeDrops = self.counters.sizeDrops + 1
      return nil, "too_large"
    end
    return nil, reason
  end
  return self:sendFrame(target, text)
end

--- Broadcast on every allowed modem. Returns how many modems accepted it.
function net:broadcast(verb, fields)
  local text, reason = encodeFrame(self, verb, fields)
  if not text then
    if reason == "frame too large" then
      self.counters.sizeDrops = self.counters.sizeDrops + 1
      return 0, "too_large"
    end
    return 0, reason
  end
  local sent = 0
  for _, modem in ipairs(self.modems) do
    if modemAllowed(self, modem) then
      local ok, result = pcall(self.component.invoke, modem.address, "broadcast", self.port, text)
      if ok and result ~= false then
        sent = sent + 1
      end
    end
  end
  self.counters.sent = self.counters.sent + sent
  return sent
end

-- Encode an answer. When the answer itself is too large, send a minimal ERR so
-- the caller gets a code instead of waiting for a timeout; the original payload
-- is what was dropped, and the counter/warning record that.
local function answerText(self, verb, fields)
  local text, reason = encodeFrame(self, verb, fields)
  if text then
    return text
  end
  if verb ~= "ERR" and fields.rid and fields.id then
    local fallback = encodeFrame(self, "ERR", {
      rid = fields.rid,
      id = fields.id,
      err = "too_large",
    })
    if fallback then
      self.counters.sizeDrops = self.counters.sizeDrops + 1
      self:warnOnce("reply-too-large:" .. tostring(verb), "DNS1: " .. tostring(verb) ..
        " answer exceeded " .. tostring(dnsnet.MAX_TX) .. " B; sent ERR too_large")
      return fallback
    end
  end
  self.counters.sizeDrops = self.counters.sizeDrops + 1
  self:warnOnce("reply:" .. tostring(verb), "DNS1: response " .. tostring(verb) ..
    " does not fit in " .. tostring(dnsnet.MAX_TX) .. " B: " .. tostring(reason))
  return nil, reason
end

local function reply(self, side, from, verb, fields)
  local text, reason = answerText(self, verb, fields)
  if not text then
    return nil, reason
  end

  local tried = {}
  local function attempt(address)
    if not address or tried[address] then
      return false
    end
    tried[address] = true
    return invokeSend(self, address, from, text)
  end

  if attempt(side) then
    self.counters.sent = self.counters.sent + 1
    return true
  end
  for _, modem in ipairs(self.modems) do
    if modemAllowed(self, modem) and attempt(modem.address) then
      self.counters.sent = self.counters.sent + 1
      return true
    end
  end

  self:warnOnce("reply-side:" .. tostring(side), "DNS1: could not answer on side " .. tostring(side))
  self.counters.sendFailed = self.counters.sendFailed + 1
  return nil
end

local function sendError(self, side, from, rid, id, code, ref)
  local fields = { rid = rid, id = id, err = code }
  if ref then
    fields.ref = ref
  end
  return reply(self, side, from, "ERR", fields)
end

local function rememberSide(self, side, from)
  if side then
    self.nodeSide[from] = side
  end
end

local function dedupe(self, from, rid)
  local now = self:now()
  local key = tostring(from) .. "|" .. tostring(rid)
  local expiry = self.dedupe[key]
  if expiry and expiry >= now then
    return true
  end

  while #self.dedupeOrder > 0 do
    local oldest = self.dedupeOrder[1]
    if (self.dedupe[oldest] or 0) >= now then
      break
    end
    table.remove(self.dedupeOrder, 1)
    self.dedupe[oldest] = nil
  end

  self.dedupe[key] = now + dnsnet.DEDUPE_TTL
  self.dedupeOrder[#self.dedupeOrder + 1] = key
  while #self.dedupeOrder > dnsnet.DEDUPE_SIZE do
    local oldest = table.remove(self.dedupeOrder, 1)
    self.dedupe[oldest] = nil
  end
  return false
end

--- Parse one event pack. Returns side, from, text or nil.
function net:parse(pack)
  if type(pack) ~= "table" then
    return nil
  end
  -- The kernel and report pass the pack returned by table.pack(pcall(...)):
  -- pack[1] is the pcall status and pack[2] is the event name. Tests and
  -- hand-built events sometimes omit the status; accept both shapes.
  local offset
  if pack[2] == "modem_message" then
    offset = 3
  elseif pack[1] == "modem_message" then
    offset = 2
  else
    return nil
  end
  local last = pack.n or #pack
  local strings, numbers = {}, {}
  for index = offset, last do
    local item = pack[index]
    if type(item) == "string" then
      strings[#strings + 1] = item
    elseif type(item) == "number" then
      numbers[#numbers + 1] = item
    end
  end

  local message, messageIndex
  for index, item in ipairs(strings) do
    if item:sub(1, #dnsnet.PROTOCOL + 1) == dnsnet.PROTOCOL .. " " then
      message = item
      messageIndex = index
      break
    end
  end
  if not message then
    return nil
  end

  local port
  for _, item in ipairs(numbers) do
    if item == self.port then
      port = item
      break
    end
  end
  if not port then
    -- A DNS1 frame on another port is ours but ignored, not TC1 traffic.
    return { ignored = true }
  end

  local others = {}
  for index, item in ipairs(strings) do
    if index ~= messageIndex then
      others[#others + 1] = item
    end
  end
  if #others < 2 then
    return { ignored = true, shape = { strings = #strings, numbers = #numbers } }
  end

  local side, from
  if isSide(others[1]) and not isSide(others[2]) then
    side, from = others[1], others[2]
  elseif isSide(others[2]) and not isSide(others[1]) then
    side, from = others[2], others[1]
  else
    side, from = others[1], others[2]
  end

  self.lastShape = {
    strings = #strings,
    numbers = #numbers,
    first = others[1],
    second = others[2],
    side = side,
    from = from,
  }
  return { side = side, from = from, message = message }
end

--- Consume one pullSignal pack. Returns true when the event was DNS1 traffic.
function net:handle(pack)
  local event = self:parse(pack)
  if not event then
    return false
  end
  if event.ignored then
    self.counters.dropped = self.counters.dropped + 1
    if event.shape and not self.lastShape then
      self.lastShape = event.shape
    end
    return true
  end

  local side, from, message = event.side, event.from, event.message
  if from == self.nodeId or (self.ownAddress and from == self.ownAddress) then
    return true
  end

  rememberSide(self, side, from)
  self.counters.recv = self.counters.recv + 1

  local verb, fields = frame.decode(dnsnet.PROTOCOL, VERBS, message, { max = dnsnet.MAX_RX })
  if not verb then
    local loose, looseFields = frame.decode(dnsnet.PROTOCOL, VERBS, message, {
      max = dnsnet.MAX_RX,
      allowUnknown = true,
    })
    if loose and looseFields and looseFields.rid and looseFields.id then
      sendError(self, side, from, looseFields.rid, looseFields.id, "unknown_verb", loose)
    end
    self.counters.dropped = self.counters.dropped + 1
    return true
  end

  if not fields.rid or fields.rid == "" then
    self.counters.dropped = self.counters.dropped + 1
    return true
  end
  if not RESPONSES[verb] and dedupe(self, from, fields.rid) then
    self.counters.dup = self.counters.dup + 1
    return true
  end

  if type(self.onFrame) ~= "function" then
    return true
  end

  local ok, answerVerb, answerFields = pcall(self.onFrame, side, from, verb, fields)
  if not ok then
    if self.log and type(self.log.error) == "function" then
      self.log.error("DNS1 handler: " .. tostring(answerVerb))
    end
    sendError(self, side, from, fields.rid, fields.id, "internal", verb)
    return true
  end
  if answerVerb and answerFields then
    answerFields.rid = answerFields.rid or fields.rid
    answerFields.id = answerFields.id or fields.id or self.nodeId
    reply(self, side, from, answerVerb, answerFields)
  end
  return true
end

return dnsnet
