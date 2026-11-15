-- Line-boundary stock reader.
--
-- A stock is one or more containers at the edge of a line. The reader walks
-- them with a one-component-call-per-tick budget, caches the answer, and serves
-- snapshots from that cache. It never reads a machine buffer inside the line
-- (decision 24). A container that cannot be read makes the stock coarse or
-- unbound; the OS never reports a count it did not read.

local addr = require("tc.addr")
local path = require("tc.path")
local driver = require("tc.driver")
local tank = require("tc.tank")

local stock = {}
stock.__index = stock

stock.STOCKS_PATH = "/etc/stocks.tsv"
stock.DEFAULT_POLL = 10
stock.MAX_TANKS = 16

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function stock.new(options)
  local self = setmetatable({}, stock)
  options = options or {}
  self.vfs = options.vfs
  self.log = options.log
  self.addr = options.addr or addr.new({ vfs = self.vfs, log = self.log })
  self.driver = options.driver or driver.new()
  self.pollInterval = options.pollInterval or stock.DEFAULT_POLL
  self.maxTanks = options.maxTanks or stock.MAX_TANKS
  self.stocks = {}
  self.errors = {}
  self.generation = 0
  self.calls = 0
  self.scanning = false
  self.scan = nil
  self.nextScan = 0
  self.updatedAt = nil
  self.configured = false
  self:reload()
  return self
end

local function parseStockConfig(self)
  local errors = {}
  local items = {}
  if not self.vfs then
    return items, errors
  end
  local text, reason = self.vfs.read(stock.STOCKS_PATH)
  if not text then
    if self.vfs.exists(stock.STOCKS_PATH) then
      errors[#errors + 1] = { line = 0, message = "cannot read " .. stock.STOCKS_PATH .. ": " .. tostring(reason) }
    end
    return items, errors
  end

  local seen = {}
  local number = 0
  for line in text:gmatch("[^\r\n]+") do
    number = number + 1
    local value = trim(line:gsub("#.*$", ""))
    if value ~= "" then
      local name, kind, pathName = value:match("^(%S+)%s+(%S+)%s*(%S*)$")
      if not name then
        errors[#errors + 1] = { line = number, message = "expected <stock> <item|fluid> [path]" }
      elseif kind ~= "item" and kind ~= "fluid" then
        errors[#errors + 1] = { line = number, message = "kind must be item or fluid: " .. kind }
      elseif not path.valid(name) then
        errors[#errors + 1] = { line = number, message = "invalid stock name: " .. name }
      elseif seen[name] then
        errors[#errors + 1] = { line = number, message = "duplicate stock: " .. name }
      else
        pathName = pathName ~= "" and pathName or name
        if not path.valid(pathName) then
          errors[#errors + 1] = { line = number, message = "invalid path: " .. pathName }
        else
          seen[name] = true
          items[#items + 1] = { name = name, kind = kind, path = pathName, line = number }
        end
      end
    end
  end
  return items, errors
end

--- Reload /etc/paths.tsv and /etc/stocks.tsv. Old cache stays visible while the
-- new configuration is built; the next scan replaces it.
function stock:reload()
  if self.addr and self.addr.load then
    self.addr:load()
  end
  local pathErrors
  self.paths, pathErrors = path.load(self.vfs)
  local configs, configErrors = parseStockConfig(self)

  self.errors = {}
  for _, item in ipairs(pathErrors or {}) do
    self.errors[#self.errors + 1] = item
  end
  for _, item in ipairs(configErrors or {}) do
    self.errors[#self.errors + 1] = item
  end

  local nextStocks = {}
  for _, config in ipairs(configs) do
    local item = {
      name = config.name,
      kind = config.kind,
      path = config.path,
      state = "pending",
      entries = {},
      total = 0,
      members = {},
      version = 0,
      updatedAt = nil,
      error = nil,
    }
    local entry, why = path.resolve(self.paths, config.path)
    if not entry then
      item.state = "unbound"
      item.error = tostring(why)
    else
      item.cardinality = entry.cardinality
      for _, address in ipairs(entry.members) do
        local record, parseWhy = addr.parse(address)
        item.members[#item.members + 1] = {
          address = address,
          record = record,
          error = record and nil or tostring(parseWhy),
        }
      end
      if #item.members == 0 then
        item.state = "unbound"
        item.error = "no members"
      end
    end
    nextStocks[#nextStocks + 1] = item
  end

  self.stocks = nextStocks
  self.configured = #nextStocks > 0
  self.generation = self.generation + 1
  self.scanning = false
  self.scan = nil
  self.nextScan = 0
  self.calls = 0
  self.updatedAt = nil
  self.lastError = nil
  return true
end

function stock:setPollInterval(seconds)
  local value = tonumber(seconds)
  if value and value > 0 then
    self.pollInterval = value
  end
end

local function setPhase(self)
  local item = self.stocks[self.scan.index]
  if not item then
    return
  end
  self.scan.phase = item.kind == "fluid" and "count" or "name"
  self.scan.tank = 1
end

local function advance(self)
  local scan = self.scan
  local item = self.stocks[scan.index]
  scan.member = scan.member + 1
  if not item or scan.member > #item.members then
    scan.index = scan.index + 1
    scan.member = 1
    setPhase(self)
  end
  if scan.index > #self.stocks then
    scan.done = true
  end
end

local function memberError(self, item, member, reason)
  member.error = tostring(reason or "read failed")
  item.pendingErrors = (item.pendingErrors or 0) + 1
  item.pendingError = item.pendingError or member.error
  return "done"
end

local function descriptorFor(self, member)
  local kind
  local ok, value = pcall(component.type, member.record.component)
  if ok and type(value) == "string" then
    kind = value
  end
  if kind == "tank_controller" then
    return driver.get(self.driver, "tank_controller")
  elseif kind == "power_substation" then
    return driver.get(self.driver, "power_substation")
  end
  return driver.get(self.driver, "transposer")
end

local function mergeInventory(self, item, member, all)
  local array = all
  if type(all) == "table" and type(all.getAll) == "function" then
    local ok, value = pcall(all.getAll, all)
    if ok and type(value) == "table" then
      array = value
    end
  end
  if type(array) ~= "table" then
    return nil, "invalid inventory"
  end

  for _, stack in ipairs(array) do
    if type(stack) == "table" then
      local count = tonumber(stack.size)
      local name = stack.name
      if count and count > 0 and type(name) == "string" and name ~= "minecraft:air" then
        local damage = tonumber(stack.damage) or 0
        local key = name .. "@" .. tostring(damage)
        local entry = item.pendingEntries[key]
        if not entry then
          entry = {
            kind = "item",
            key = name,
            damage = damage,
            label = stack.label or name,
            count = 0,
            hasTag = stack.hasTag == true,
            members = {},
          }
          item.pendingEntries[key] = entry
        end
        entry.count = entry.count + count
        entry.members[member.address] = (entry.members[member.address] or 0) + count
        item.pendingTotal = item.pendingTotal + count
        if stack.hasTag then
          entry.tagged = true
          item.pendingTagged = true
        end
      end
    end
  end
  return true
end

local function stepMember(self, item, member, proxy)
  local scan = self.scan
  local descriptor = descriptorFor(self, member)
  if not descriptor then
    return memberError(self, item, member, "unknown component kind")
  end
  local capabilities = descriptor.capabilities or {}
  local side = member.record.face

  if item.kind == "item" then
    local capability = capabilities.inventory
    if not capability then
      return memberError(self, item, member, "no inventory capability")
    end
    if scan.phase == "name" then
      local name, reason = driver.invoke(proxy, capability.name, { side = side })
      self.calls = self.calls + 1
      if not name then
        return memberError(self, item, member, reason or "no inventory")
      end
      member.faceName = name
      if driver.faceKind(name) == "transfer" then
        return memberError(self, item, member, "pipe is transport, not stock")
      end
      scan.phase = "size"
      return "wait"
    elseif scan.phase == "size" then
      local size, reason = driver.invoke(proxy, capability.size, { side = side })
      self.calls = self.calls + 1
      if type(size) ~= "number" or size < 1 then
        return memberError(self, item, member, reason or "no inventory size")
      end
      member.size = size
      scan.phase = "all"
      return "wait"
    elseif scan.phase == "all" then
      local all, reason = driver.invoke(proxy, capability.all, { side = side })
      self.calls = self.calls + 1
      if not all then
        return memberError(self, item, member, reason or "inventory read failed")
      end
      local ok, why = mergeInventory(self, item, member, all)
      if not ok then
        return memberError(self, item, member, why)
      end
      member.ok = true
      return "done"
    end
    return memberError(self, item, member, "invalid inventory phase")
  end

  local capability = capabilities.tank
  if not capability then
    return memberError(self, item, member, "no tank capability")
  end
  if scan.phase == "count" then
    local count, reason = driver.invoke(proxy, capability.count, { side = side })
    self.calls = self.calls + 1
    if type(count) ~= "number" or count < 1 then
      return memberError(self, item, member, reason or "no tank")
    end
    member.tankCount = math.min(count, self.maxTanks)
    scan.tank = 1
    scan.phase = "fluid"
    return "wait"
  elseif scan.phase == "fluid" then
    local value, reason = driver.invoke(proxy, capability.fluid, {
      side = side,
      tank = scan.tank,
    })
    self.calls = self.calls + 1
    if not value then
      return memberError(self, item, member, reason or "tank read failed")
    end
    local entry = type(value) == "table" and (value[1] or value) or nil
    if type(entry) ~= "table" then
      return memberError(self, item, member, "no fluid entry")
    end
    local merged = tank.merge(item.pendingEntries, entry)
    if not merged then
      return memberError(self, item, member, "invalid fluid entry")
    end
    item.pendingTotal = item.pendingTotal + (tonumber(merged.amount) or 0)
    scan.tank = scan.tank + 1
    if scan.tank > member.tankCount then
      member.ok = true
      return "done"
    end
    return "wait"
  end
  return memberError(self, item, member, "invalid tank phase")
end

local function step(self)
  local scan = self.scan
  while scan.index <= #self.stocks do
    local item = self.stocks[scan.index]
    if #item.members == 0 then
      advance(self)
    else
      local member = item.members[scan.member]
      if not member.record then
        memberError(self, item, member, member.error or "invalid address")
        advance(self)
      else
        local proxy, reason = addr.proxy(member.record)
        if not proxy then
          memberError(self, item, member, reason or "component unavailable")
          advance(self)
        else
          local result = stepMember(self, item, member, proxy)
          if result == "done" then
            advance(self)
          end
          if scan.done then
            return true
          end
          return false
        end
      end
    end
  end
  return true
end

local function beginScan(self, now)
  self.scan = {
    index = 1,
    member = 1,
    phase = "name",
    tank = 1,
    started = now,
    done = false,
  }
  self.scanning = true
  for _, item in ipairs(self.stocks) do
    item.pendingEntries = {}
    item.pendingTotal = 0
    item.pendingErrors = 0
    item.pendingError = nil
    item.pendingTagged = false
    for _, member in ipairs(item.members) do
      member.error = nil
      member.faceName = nil
      member.size = nil
      member.tankCount = nil
      member.ok = nil
    end
  end
  setPhase(self)
end

local function finishScan(self, now)
  for _, item in ipairs(self.stocks) do
    local state
    if #item.members == 0 or (item.pendingErrors or 0) >= #item.members then
      state = "unbound"
    elseif (item.pendingErrors or 0) > 0 then
      state = "coarse"
    elseif item.pendingTagged then
      state = "coarse"
    else
      state = "exact"
    end
    item.state = state
    item.entries = item.pendingEntries or {}
    item.total = item.pendingTotal or 0
    item.updatedAt = now
    item.version = (item.version or 0) + 1
    if state == "exact" then
      item.error = nil
    else
      item.error = item.pendingError or item.error or state
    end
    item.pendingEntries = nil
    item.pendingTotal = nil
    item.pendingErrors = nil
    item.pendingError = nil
    item.pendingTagged = nil
  end
  self.updatedAt = now
  self.generation = self.generation + 1
  self.scanning = false
  self.scan = nil
  self.nextScan = now + self.pollInterval
  self.lastError = nil
  for _, item in ipairs(self.stocks) do
    if item.error then
      self.lastError = item.error
      break
    end
  end
end

--- Advance at most one component call. Returns true when a scan finished.
function stock:tick(now)
  now = now or computer.uptime()
  if #self.stocks == 0 then
    return false
  end
  if not self.scanning then
    if now < (self.nextScan or 0) then
      return false
    end
    beginScan(self, now)
  end
  local finished = step(self)
  if finished then
    finishScan(self, now)
    return true
  end
  return false
end

local function copyEntries(item)
  local list = {}
  for _, entry in pairs(item.entries or {}) do
    list[#list + 1] = {
      kind = entry.kind,
      key = entry.key,
      damage = entry.damage,
      label = entry.label,
      count = entry.count,
      amount = entry.amount,
      capacity = entry.capacity,
      hasTag = entry.hasTag,
      tagged = entry.tagged,
      members = entry.members,
    }
  end
  table.sort(list, function(a, b)
    local left = a.count or a.amount or 0
    local right = b.count or b.amount or 0
    if left == right then
      return tostring(a.label or a.key) < tostring(b.label or b.key)
    end
    return left > right
  end)
  return list
end

function stock:snapshot()
  local now = computer.uptime()
  local list = {}
  for _, item in ipairs(self.stocks) do
    list[#list + 1] = {
      name = item.name,
      kind = item.kind,
      path = item.path,
      cardinality = item.cardinality,
      state = item.state,
      total = item.total,
      entries = copyEntries(item),
      age = item.updatedAt and math.max(0, now - item.updatedAt) or nil,
      updatedAt = item.updatedAt,
      error = item.error,
      members = #item.members,
      version = item.version,
    }
  end
  return {
    at = self.updatedAt,
    generation = self.generation,
    scanning = self.scanning,
    calls = self.calls,
    stocks = list,
    errors = self.errors,
    configured = self.configured,
  }
end

--- A minimal delta contract for 0.4.2. A cursor that is not the current
-- generation asks for a resync instead of guessing what changed.
function stock:delta(cursor)
  if cursor == self.generation then
    return { generation = self.generation, changes = {} }
  end
  return {
    generation = self.generation,
    resync = true,
    snapshot = self:snapshot(),
  }
end

function stock:status()
  return {
    stocks = #self.stocks,
    calls = self.calls,
    scanning = self.scanning,
    generation = self.generation,
    configured = self.configured,
    nextScanIn = math.max(0, (self.nextScan or 0) - computer.uptime()),
    errors = self.errors,
  }
end

return stock
