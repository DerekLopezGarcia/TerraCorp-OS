-- Minimal DNS1 client for M0.
--
-- The client owns one request at a time. It sends through tc.dnsnet, waits on
-- `computer.pullSignal`, and lets the transport's dedupe/decoder run before the
-- matching response is captured. When a master is configured the client asks
-- the master; otherwise it resolves the node directly, learning its side from a
-- WHO exchange first.

local value = require("tc.value")

local dnsclient = {}

dnsclient.TIMEOUT = 2
dnsclient.WHO_TIMEOUT = 1
dnsclient.PROTOCOL = "DNS1"

local function nowOf(self)
  if self.computer and type(self.computer.uptime) == "function" then
    local ok, current = pcall(self.computer.uptime, self.computer)
    if ok and type(current) == "number" then
      return current
    end
  end
  return os.time()
end

local function truthy(item)
  return item == true or item == "true"
end

local client = {}
client.__index = client

function dnsclient.new(opts)
  opts = opts or {}
  local self = setmetatable({}, client)
  self.computer = opts.computer or computer
  self.net = opts.net
  self.master = opts.master
  if self.master == "self" then
    self.master = nil
  end
  self.timeout = opts.timeout or dnsclient.TIMEOUT
  self.id = opts.id or (self.computer.address and self.computer.address()) or "client"
  self.log = opts.log
  self.ridGenerator = opts.ridGenerator
  self.ridCounter = 0
  self.pending = nil
  self.previousOnFrame = nil
  self.attached = false
  self:attach()
  return self
end

function client:now()
  return nowOf(self)
end

function client:nextRid()
  if type(self.ridGenerator) == "function" then
    return self.ridGenerator()
  end
  self.ridCounter = self.ridCounter + 1
  return string.format("%08x", self.ridCounter)
end

function client:route()
  if self.master and self.master ~= "" then
    return "master", self.master
  end
  return "direct"
end

--- Answer addresses: the master on the master route, the node otherwise.
function client:expectFor(node)
  local mode, target = self:route()
  if mode == "master" then
    return target
  end
  return node
end

local function matches(pending, verb, fields)
  if not pending.expect then
    return true
  end
  if fields.id == pending.expect then
    return true
  end
  if verb == "WHOACK" and fields.node == pending.expect then
    return true
  end
  return false
end

function client:dispatch(side, from, verb, fields)
  local pending = self.pending
  if pending and fields and fields.rid == pending.rid and matches(pending, verb, fields) then
    pending.verb = verb
    pending.fields = fields
    pending.done = true
    return nil
  end
  if type(self.previousOnFrame) == "function" then
    return self.previousOnFrame(side, from, verb, fields)
  end
  return nil
end

function client:attach()
  if self.attached or not self.net then
    return
  end
  self.previousOnFrame = self.net.onFrame
  local owner = self
  self.net.onFrame = function(side, from, verb, fields)
    return owner:dispatch(side, from, verb, fields)
  end
  self.attached = true
end

function client:detach()
  if self.attached and self.net then
    self.net.onFrame = self.previousOnFrame
  end
  self.attached = false
end

local function pull(self, timeout)
  if not self.computer or type(self.computer.pullSignal) ~= "function" then
    return nil
  end
  local pack = table.pack(pcall(self.computer.pullSignal, math.max(0, timeout)))
  if not pack[1] then
    return nil, tostring(pack[2])
  end
  return pack
end

--- Send one request and wait for its response. `expect` is the address whose
-- answer counts; nil accepts the first response with the same rid.
function client:request(target, verb, fields, timeout, expect)
  fields = fields or {}
  local rid = fields.rid or self:nextRid()
  fields.rid = rid
  fields.id = fields.id or self.id

  local pending = {
    rid = rid,
    expect = expect,
    done = false,
    at = self:now(),
  }
  self.pending = pending

  local ok, reason = self.net:send(target, verb, fields)
  if not ok then
    self.pending = nil
    return nil, reason
  end

  local deadline = self:now() + (timeout or self.timeout)
  while not pending.done do
    local remaining = deadline - self:now()
    if remaining <= 0 then
      break
    end
    local pack, pullError = pull(self, remaining)
    if pullError then
      self.pending = nil
      return nil, pullError
    end
    if pack and pack[2] then
      self.net:handle(pack)
    end
  end

  self.pending = nil
  if not pending.done then
    return nil, "timeout"
  end
  if pending.verb == "ERR" then
    return nil, pending.fields.err or "error"
  end
  return pending.fields, nil, pending.verb
end

--- Broadcast WHO and return the first WHOACK. With `want`, only that node's
-- answer counts, which is how a direct client learns the node's side.
function client:who(timeout, want)
  local fields = {
    rid = self:nextRid(),
    id = self.id,
  }
  local pending = {
    rid = fields.rid,
    expect = want,
    done = false,
    at = self:now(),
  }
  self.pending = pending
  local sent, reason = self.net:broadcast("WHO", fields)
  if not sent or sent == 0 then
    self.pending = nil
    return nil, reason or "no modem could send"
  end

  local deadline = self:now() + (timeout or dnsclient.WHO_TIMEOUT)
  while not pending.done do
    local remaining = deadline - self:now()
    if remaining <= 0 then
      break
    end
    local pack, pullError = pull(self, remaining)
    if pullError then
      self.pending = nil
      return nil, pullError
    end
    if pack and pack[2] then
      self.net:handle(pack)
    end
  end
  self.pending = nil
  if not pending.done then
    return nil, "timeout"
  end
  return pending.fields, nil
end

local function decodeBody(fields)
  if not fields.body then
    return nil, "bad_value"
  end
  local body, code = value.decode(fields.body)
  if body == nil and code then
    return nil, code
  end
  return body
end

local function directReason(reason)
  return reason == "timeout" or reason == "no modem could send"
    or reason == "no network card installed"
end

-- A master that has not seen the node answers offline; that is also a reason to
-- ask the node directly, not a reason to give up.
local function masterMiss(response, reason)
  if not response then
    return directReason(reason)
  end
  return response.ok == "false" and response.err == "offline"
end

function client:describe(node, target)
  local mode, via = self:route()
  local fields = { target = target or "node" }
  local response, reason
  if mode == "master" then
    fields.node = node
    response, reason = self:request(via, "DESCRIBE", fields, self.timeout, via)
    if masterMiss(response, reason) then
      fields.node = nil
    end
  end
  if mode ~= "master" or masterMiss(response, reason) then
    if not self.net.nodeSide[node] then
      self:who(dnsclient.WHO_TIMEOUT, node)
    end
    response, reason = self:request(node, "DESCRIBE", { target = target or "node" },
      self.timeout, node)
  end
  if not response then
    return nil, reason
  end
  return decodeBody(response)
end

function client:exec(node, target, method, args)
  local encoded, code = value.encode(args or {})
  if not encoded then
    return nil, code
  end

  local mode, via = self:route()
  local fields = {
    target = target,
    method = method,
    p = encoded,
  }
  local response, reason
  if mode == "master" then
    fields.node = node
    response, reason = self:request(via, "EXEC", fields, self.timeout, via)
  end
  if mode ~= "master" or masterMiss(response, reason) then
    if not self.net.nodeSide[node] then
      self:who(dnsclient.WHO_TIMEOUT, node)
    end
    response, reason = self:request(node, "EXEC", {
      target = target,
      method = method,
      p = encoded,
    }, self.timeout, node)
  end
  if not response then
    return nil, reason
  end
  if not truthy(response.ok) then
    return nil, response.err or "failed"
  end
  return decodeBody(response)
end

--- Edit an endpoint document. `rev` is the revision the caller read; a stale
-- revision returns `{ok=false, err="conflict", rev=<current>, body=<current>}`
-- instead of overwriting a newer edit. Only docs and tags are editable.
function client:edit(node, target, field, newValue, rev)
  local encoded, code = value.encode(newValue)
  if not encoded then
    return nil, code
  end
  local fields = {
    target = target,
    field = field,
    rev = tostring(rev),
    p = encoded,
  }
  local mode, via = self:route()
  local response, reason
  if mode == "master" then
    fields.node = node
    response, reason = self:request(via, "EDIT", fields, self.timeout, via)
  end
  if mode ~= "master" or masterMiss(response, reason) then
    if not self.net.nodeSide[node] then
      self:who(dnsclient.WHO_TIMEOUT, node)
    end
    response, reason = self:request(node, "EDIT", {
      target = target,
      field = field,
      rev = tostring(rev),
      p = encoded,
    }, self.timeout, node)
  end
  if not response then
    return nil, reason
  end
  local result = {
    ok = truthy(response.ok),
    err = response.err,
    rev = tonumber(response.rev),
  }
  if response.body then
    result.body = value.decode(response.body)
  end
  return result
end

function client:catalog(cursor, page)
  local mode, via = self:route()
  if mode ~= "master" then
    return nil, "no master configured"
  end
  local response, reason = self:request(via, "CATALOG", {
    cursor = cursor,
    page = page and tostring(page) or nil,
  }, self.timeout, via)
  if not response then
    return nil, reason
  end
  return decodeBody(response)
end

function client:nodes(cursor, page)
  local body, reason = self:catalog(cursor, page)
  if not body then
    return nil, reason
  end
  return body.nodes or {}, body
end

return dnsclient
