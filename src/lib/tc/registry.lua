-- Node registry stored in /var/nodes.tsv.
--
-- One tab-separated line per node, in this order:
--
--   id  name  state  mem  disk  lastSeen  v  modem  stocks  alarms  uptime
--
-- `lastSeen` is the master's uptime in seconds for the current session. It is
-- not comparable across reboots, so loading the registry marks every node
-- offline and resets lastSeen. The updater preserves this file.
--
-- `modem` is the address the master sends to; it is the one rack-era field with
-- a live reader (`master.lua:147,193,221,243,393`). `role`, `jobs` and `drain`
-- were removed in 0.4.9 (F20): nothing read them, and `role` duplicated the
-- runtime role that `config.lua` owns. A file written before that carries 14 or
-- 8 columns; `load` decodes either shape and rewrites the file once in the
-- current one, so an upgraded machine migrates at its first boot.

local registry = {}

registry.path = "/var/nodes.tsv"
registry.columns = { "id", "name", "state", "mem", "disk", "lastSeen", "v", "modem", "stocks", "alarms", "uptime" }
registry.states = { online = true, offline = true, provisioning = true, conflict = true }
registry.MAX_NAME = 24

-- Column positions by row width. Row shapes that ever shipped:
--   8  id name role modem state mem disk lastSeen            (0.3.x)
--   14 id name role modem state mem disk lastSeen v jobs drain stocks alarms uptime (0.4.0-0.4.9)
--   11 the current shape
local SHAPES = {
  [8] = { id = 1, name = 2, modem = 4, state = 5, mem = 6, disk = 7 },
  [14] = { id = 1, name = 2, modem = 4, state = 5, mem = 6, disk = 7, v = 9, stocks = 12, alarms = 13, uptime = 14 },
  [11] = { id = 1, name = 2, state = 3, mem = 4, disk = 5, v = 7, modem = 8, stocks = 9, alarms = 10, uptime = 11 },
}

local function split(line)
  local columns = {}
  local start = 1
  while true do
    local at = line:find("\t", start, true)
    if not at then
      columns[#columns + 1] = line:sub(start)
      return columns
    end
    columns[#columns + 1] = line:sub(start, at - 1)
    start = at + 1
  end
end

local function clean(value)
  return (tostring(value or ""):gsub("[\t\r\n]", " "))
end

local function number(value)
  local parsed = tonumber(value)
  if not parsed or parsed < 0 then
    return 0
  end
  return math.floor(parsed)
end

function registry.validName(name)
  if type(name) ~= "string" then
    return false
  end
  local trimmed = name:match("^%s*(.-)%s*$")
  if trimmed == "" or #trimmed > registry.MAX_NAME then
    return false
  end
  return trimmed:match("^[%w][%w _%.%-]*$") ~= nil
end

function registry.find(nodes, id)
  if not id then
    return nil
  end
  for _, node in ipairs(nodes) do
    if node.id == id then
      return node
    end
  end
  return nil
end

--- Insert a record or merge it into the existing node with the same id.
-- Returns the stored node and whether it was created.
function registry.upsert(nodes, record)
  if type(record) ~= "table" or type(record.id) ~= "string" or record.id == "" then
    return nil, false
  end

  local node = registry.find(nodes, record.id)
  local created = false
  if not node then
    node = {
      id = record.id,
      name = record.name or record.id:sub(1, 8),
      state = "offline",
      mem = 0,
      disk = 0,
      lastSeen = 0,
      v = "",
      modem = "",
      stocks = 0,
      alarms = 0,
      uptime = 0,
    }
    nodes[#nodes + 1] = node
    created = true
  end

  if record.name and record.name ~= "" then
    node.name = record.name
  end
  if record.modem ~= nil then
    node.modem = clean(record.modem)
  end
  if record.state and registry.states[record.state] then
    node.state = record.state
  end
  if record.mem ~= nil then
    node.mem = number(record.mem)
  end
  if record.disk ~= nil then
    node.disk = number(record.disk)
  end
  if record.lastSeen ~= nil then
    node.lastSeen = number(record.lastSeen)
  end
  if record.v ~= nil then
    node.v = clean(record.v)
  end
  if record.stocks ~= nil then
    node.stocks = number(record.stocks)
  end
  if record.alarms ~= nil then
    node.alarms = number(record.alarms)
  end
  if record.uptime ~= nil then
    node.uptime = number(record.uptime)
  end

  return node, created
end

function registry.load(vfs)
  local nodes = {}
  local source = vfs.read(registry.path)
  if not source then
    return nodes
  end

  local width = #registry.columns
  local migrated = false

  for line in source:gmatch("[^\n]+") do
    line = line:gsub("\r$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local columns = split(line)
      local shape = SHAPES[#columns]
      if not shape then
        -- An unknown width is not guessed at: skipping a row loses a node,
        -- reading the wrong columns writes a wrong record for it.
        migrated = true
      elseif columns[1] ~= "" then
        if #columns ~= width then
          migrated = true
        end
        registry.upsert(nodes, {
          id = columns[shape.id],
          name = columns[shape.name],
          -- Kept so the master can still reach a node after the upgrade.
          modem = shape.modem and columns[shape.modem],
          -- A reboot invalidates the previous session's uptime, so never trust
          -- a persisted "online" state.
          state = "offline",
          mem = shape.mem and columns[shape.mem],
          disk = shape.disk and columns[shape.disk],
          lastSeen = 0,
          v = shape.v and columns[shape.v],
          stocks = shape.stocks and columns[shape.stocks],
          alarms = shape.alarms and columns[shape.alarms],
          uptime = shape.uptime and columns[shape.uptime],
        })
      end
    end
  end

  registry.sort(nodes)

  -- Migrate on the first boot that reads an old file: the registry is the only
  -- copy of the plant's names, so it is rewritten before anything can fail.
  if migrated then
    registry.save(vfs, nodes)
  end

  return nodes
end

function registry.sort(nodes)
  table.sort(nodes, function(a, b)
    local left = (a.name or ""):lower()
    local right = (b.name or ""):lower()
    if left == right then
      return a.id < b.id
    end
    return left < right
  end)
end

function registry.save(vfs, nodes)
  registry.sort(nodes)
  local lines = {}
  for _, node in ipairs(nodes) do
    lines[#lines + 1] = table.concat({
      clean(node.id),
      clean(node.name),
      clean(node.state),
      tostring(number(node.mem)),
      tostring(number(node.disk)),
      tostring(number(node.lastSeen)),
      clean(node.v),
      clean(node.modem),
      tostring(number(node.stocks)),
      tostring(number(node.alarms)),
      tostring(number(node.uptime)),
    }, "\t")
  end

  local data = ""
  if #lines > 0 then
    data = table.concat(lines, "\n") .. "\n"
  end
  return vfs.write(registry.path, data)
end

--- Remove a node record entirely. Returns the removed record or nil.
function registry.remove(nodes, id)
  for index, node in ipairs(nodes) do
    if node.id == id then
      return table.remove(nodes, index)
    end
  end
  return nil
end

return registry
