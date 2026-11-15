-- Gate setpoints and local interlocks.
--
-- A gate is one redstone output bound to a line. `set` stores the **desired**
-- state, never a toggle, so a retried frame cannot invert it and a reboot
-- restores the setpoint without asking the bridge. Reconciliation runs every
-- tick against the cached stock levels: no opening a line whose input is empty,
-- no feeding a full output. A line that refuses three times raises
-- `DISOBEDIENT LINE` and stops resending until the setpoint or the stock
-- changes.
--
-- The module never resolves components itself: the caller passes a redstone
-- proxy, which keeps the logic testable without a world.

local gate = {}
gate.__index = gate

gate.CONFIG_PATH = "/etc/gates.tsv"
gate.SETPOINTS_PATH = "/var/gates.tsv"
gate.MAX_LINES = 32
gate.REFUSALS = 3

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function splitTabs(value)
  local parts = {}
  for piece in (value .. "\t"):gmatch("([^\t]*)\t") do
    parts[#parts + 1] = piece
  end
  return parts
end

local function validName(value)
  return type(value) == "string" and value:match("^[%w_%-%.]+$") ~= nil
end

local function normalizeState(value)
  if value == 1 or value == true then
    return 1
  end
  if value == 0 or value == false then
    return 0
  end
  local text = tostring(value or ""):lower()
  if text == "1" or text == "on" or text == "true" then
    return 1
  end
  if text == "0" or text == "off" or text == "false" then
    return 0
  end
  return nil
end

gate.normalizeState = normalizeState

function gate.new(options)
  local self = setmetatable({}, gate)
  options = options or {}
  self.vfs = options.vfs
  self.log = options.log
  self.lines = {}
  self.order = {}
  self.errors = {}
  self.refusals = {}
  self.lastReason = {}
  self.disobedient = {}
  self.actual = {}
  self:load()
  return self
end

function gate:load()
  self.lines = {}
  self.order = {}
  self.errors = {}
  self.refusals = {}
  self.lastReason = {}
  self.disobedient = {}
  self.actual = {}

  if self.vfs then
    local text = self.vfs.read(gate.CONFIG_PATH)
    if type(text) == "string" then
      local number = 0
      for raw in text:gmatch("[^\r\n]+") do
        number = number + 1
        local value = trim(raw:gsub("#.*$", ""))
        if value ~= "" then
          local fields = splitTabs(value)
          local name, component = fields[1], fields[2]
          local side = tonumber(fields[3])
          if not validName(name) then
            self.errors[#self.errors + 1] = { line = number, message = "invalid gate line: " .. tostring(name) }
          elseif not component or component == "" then
            self.errors[#self.errors + 1] = { line = number, message = "missing gate component for " .. name }
          elseif not side or side < 0 or side > 5 or side ~= math.floor(side) then
            self.errors[#self.errors + 1] = { line = number, message = "face must be 0-5 for " .. name }
          elseif self.lines[name] then
            self.errors[#self.errors + 1] = { line = number, message = "duplicate gate line: " .. name }
          elseif #self.order >= gate.MAX_LINES then
            self.errors[#self.errors + 1] = { line = number, message = "too many gates (max " .. gate.MAX_LINES .. ")" }
          else
            local record = {
              line = name,
              component = component,
              side = side,
              input = fields[4] ~= "" and fields[4] or nil,
              output = fields[5] ~= "" and fields[5] or nil,
              desired = nil,
            }
            self.lines[name] = record
            self.order[#self.order + 1] = record
          end
        end
      end
    end
  end

  self:loadSetpoints()
  return true
end

function gate:loadSetpoints()
  if not self.vfs then
    return
  end
  local text = self.vfs.read(gate.SETPOINTS_PATH)
  if type(text) ~= "string" then
    return
  end
  for raw in text:gmatch("[^\r\n]+") do
    local value = trim(raw:gsub("#.*$", ""))
    if value ~= "" then
      local name, state = value:match("^(%S+)%s+(%d+)$")
      local normalized = normalizeState(state)
      local record = name and self.lines[name]
      if record and normalized then
        record.desired = normalized
        self.actual[name] = normalized
      end
    end
  end
end

function gate:saveSetpoints()
  if not self.vfs then
    return false
  end
  self.vfs.ensureDir("/var")
  local lines = { "# TerraCorp: gate setpoints (line, desired)" }
  for _, record in ipairs(self.order) do
    if record.desired ~= nil then
      lines[#lines + 1] = record.line .. "\t" .. tostring(record.desired)
    end
  end
  return self.vfs.write(gate.SETPOINTS_PATH, table.concat(lines, "\n") .. "\n")
end

function gate:line(name)
  return self.lines[name]
end

function gate:set(name, state)
  local record = self.lines[name]
  if not record then
    return nil, "unknown_line"
  end
  local desired = normalizeState(state)
  if desired == nil then
    return nil, "bad_state"
  end
  record.desired = desired
  self.refusals[name] = 0
  self.lastReason[name] = nil
  self.disobedient[name] = nil
  self:saveSetpoints()
  return { line = name, desired = desired }
end

--- Interlock verdict for a desired state. `context` is
-- `{ input = { total, min }, output = { total, max } }`; a missing side is not
-- checked, and `state = 0` is always allowed so a line can always close.
function gate:plan(name, state, context)
  local record = self.lines[name]
  if not record then
    return nil, "unknown_line"
  end
  local desired = normalizeState(state)
  if desired == nil then
    return nil, "bad_state"
  end
  if desired == 0 then
    return true
  end
  context = context or {}
  if context.input and context.input.total ~= nil then
    local minimum = tonumber(context.input.min) or 1
    if tonumber(context.input.total) < minimum then
      return nil, "input_empty"
    end
  end
  if context.output and context.output.max and tonumber(context.output.max) > 0 then
    if tonumber(context.output.total or 0) >= tonumber(context.output.max) then
      return nil, "output_full"
    end
  end
  return true
end

--- Apply the stored setpoint through `proxy`. A refusal is counted; after
-- `REFUSALS` identical failures the line is `disobedient` and stops resending
-- until `set` clears the state.
function gate:reconcile(name, proxy, context)
  local record = self.lines[name]
  if not record then
    return nil, "unknown_line"
  end
  if record.desired == nil then
    return nil, "no_setpoint"
  end

  local allowed, reason = self:plan(name, record.desired, context)
  if not allowed then
    self.lastReason[name] = reason
    self.refusals[name] = (self.refusals[name] or 0) + 1
    if self.refusals[name] >= gate.REFUSALS then
      self.disobedient[name] = true
    end
    return false, reason
  end

  if type(proxy) ~= "table" or type(proxy.setOutput) ~= "function" then
    return false, "gate_unavailable"
  end
  local ok, value = pcall(proxy.setOutput, record.side, record.desired)
  if not ok then
    self.lastReason[name] = "set_failed"
    return false, "set_failed"
  end
  if value == false then
    self.lastReason[name] = "refused_by_gate"
    return false, "refused_by_gate"
  end

  self.actual[name] = record.desired
  self.lastReason[name] = nil
  self.refusals[name] = 0
  self.disobedient[name] = nil
  return true, record.desired
end

function gate:alarms()
  local list = {}
  for _, record in ipairs(self.order) do
    if self.disobedient[record.line] then
      list[#list + 1] = {
        code = "DISOBEDIENT LINE",
        source = record.line,
        severity = "danger",
        message = tostring(self.lastReason[record.line] or "repeated refusal"),
      }
    end
  end
  return list
end

function gate:status()
  local list = {}
  for _, record in ipairs(self.order) do
    list[#list + 1] = {
      line = record.line,
      component = record.component,
      side = record.side,
      desired = record.desired,
      actual = self.actual[record.line],
      refusals = self.refusals[record.line] or 0,
      lastReason = self.lastReason[record.line],
      disobedient = self.disobedient[record.line] == true,
      input = record.input,
      output = record.output,
    }
  end
  return list
end

return gate
