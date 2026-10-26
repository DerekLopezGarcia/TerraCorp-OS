-- Node registry stored in /var/nodes.tsv.
--
-- One tab-separated line per node, in this order:
--
--   id  name  role  modem  state  mem  disk  lastSeen
--
-- `lastSeen` is the master's uptime in seconds for the current session. It is
-- not comparable across reboots, so loading the registry marks every node
-- offline and resets lastSeen. The updater preserves this file.

local registry = {}

registry.path = "/var/nodes.tsv"
registry.columns = { "id", "name", "role", "modem", "state", "mem", "disk", "lastSeen", "v", "jobs", "drain" }
registry.states = { online = true, offline = true, provisioning = true }
registry.roles = { worker = true, storage = true, node = true }
registry.MAX_NAME = 24

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
      role = "worker",
      modem = "",
      state = "offline",
      mem = 0,
      disk = 0,
      lastSeen = 0,
      v = "",
      jobs = 0,
      drain = "",
    }
    nodes[#nodes + 1] = node
    created = true
  end

  if record.name and record.name ~= "" then
    node.name = record.name
  end
  if record.role and registry.roles[record.role] then
    node.role = record.role
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
  if record.jobs ~= nil then
    node.jobs = number(record.jobs)
  end
  if record.drain ~= nil then
    if record.drain == true or record.drain == "true" then
      node.drain = "true"
    else
      node.drain = ""
    end
  end

  return node, created
end

function registry.load(vfs)
  local nodes = {}
  local source = vfs.read(registry.path)
  if not source then
    return nodes
  end

  for line in source:gmatch("[^\n]+") do
    line = line:gsub("\r$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local columns = split(line)
      -- Files written before the version, jobs, and drain columns have fewer
      -- fields; the updater preserves the registry, so every shape loads.
      if #columns >= 8 and columns[1] ~= "" then
        registry.upsert(nodes, {
          id = columns[1],
          name = columns[2],
          role = columns[3],
          modem = columns[4],
          -- A reboot invalidates the previous session's uptime, so never trust
          -- a persisted "online" state.
          state = "offline",
          mem = columns[6],
          disk = columns[7],
          lastSeen = 0,
          v = columns[9],
          jobs = columns[10],
          drain = columns[11],
        })
      end
    end
  end

  registry.sort(nodes)
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
      clean(node.role),
      clean(node.modem),
      clean(node.state),
      tostring(number(node.mem)),
      tostring(number(node.disk)),
      tostring(number(node.lastSeen)),
      clean(node.v),
      tostring(number(node.jobs)),
      clean(node.drain),
    }, "\t")
  end

  local data = ""
  if #lines > 0 then
    data = table.concat(lines, "\n") .. "\n"
  end
  return vfs.write(registry.path, data)
end

function registry.aggregate(nodes)
  local summary = {
    total = #nodes,
    online = 0,
    offline = 0,
    provisioning = 0,
    mem = 0,
    disk = 0,
    workers = 0,
    storage = 0,
  }

  for _, node in ipairs(nodes) do
    if node.state == "online" then
      summary.online = summary.online + 1
      summary.mem = summary.mem + (node.mem or 0)
      summary.disk = summary.disk + (node.disk or 0)
    elseif node.state == "provisioning" then
      summary.provisioning = summary.provisioning + 1
    else
      summary.offline = summary.offline + 1
    end

    if node.role == "worker" then
      summary.workers = summary.workers + 1
    elseif node.role == "storage" then
      summary.storage = summary.storage + 1
    end
  end

  return summary
end

function registry.setRole(nodes, id, role)
  if not registry.roles[role] then
    return nil, "invalid role"
  end
  local node = registry.find(nodes, id)
  if not node then
    return nil, "unknown node"
  end
  node.role = role
  return node
end

function registry.rename(nodes, id, name)
  if not registry.validName(name) then
    return nil, "invalid name"
  end
  local node = registry.find(nodes, id)
  if not node then
    return nil, "unknown node"
  end
  node.name = name:match("^%s*(.-)%s*$")
  return node
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
