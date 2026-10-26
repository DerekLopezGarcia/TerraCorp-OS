-- System preferences stored in /etc/terracorp.cfg.
-- The file contains a serialized Lua table loaded in an empty environment,
-- so it needs neither OpenOS `require` nor `serialization`.

local config = {}

config.path = "/etc/terracorp.cfg"

config.defaults = {
  accent = "cyan",
  charset = "unicode",
  clock24 = true,
  splash = true,
  logLevel = "info",
  hostname = "",
  iconOrder = "",
  iconLayout = "",
  role = "desktop",
  nodeRole = "worker",
  master = "",
  masterId = "",
  nodeFloppyPayload = true,
  nodeAutoUpdate = true,
  nodeFloppyAddress = "",
}

config.data = {}

local ACCENTS = { "cyan", "orange", "lime", "lightblue", "yellow", "purple" }
local CHARSETS = { "unicode", "ascii" }
local LOG_LEVELS = { "debug", "info", "warn", "error" }
local ROLES = { desktop = true, node = true }
local NODE_ROLES = { worker = true, storage = true, node = true }

config.accents = ACCENTS
config.charsets = CHARSETS
config.logLevels = LOG_LEVELS
config.roles = ROLES
config.nodeRoles = NODE_ROLES

local function copyDefaults()
  local data = {}
  for key, value in pairs(config.defaults) do
    data[key] = value
  end
  return data
end

local function serialize(data)
  local lines = { "-- TerraCorp OS: system preferences", "return {" }
  local names = {}
  for key in pairs(data) do
    names[#names + 1] = key
  end
  table.sort(names)

  for _, key in ipairs(names) do
    local value = data[key]
    local encoded
    if type(value) == "boolean" then
      encoded = tostring(value)
    elseif type(value) == "number" then
      encoded = tostring(value)
    else
      encoded = string.format("%q", tostring(value))
    end
    lines[#lines + 1] = string.format("  %s = %s,", key, encoded)
  end

  lines[#lines + 1] = "}"
  return table.concat(lines, "\n")
end

local function accepted(key, value)
  if key == "accent" then
    for _, name in ipairs(ACCENTS) do
      if name == value then
        return true
      end
    end
    return false
  end
  if key == "charset" then
    return value == "unicode" or value == "ascii"
  end
  if key == "logLevel" then
    for _, name in ipairs(LOG_LEVELS) do
      if name == value then
        return true
      end
    end
    return false
  end
  if key == "clock24" or key == "splash" then
    return type(value) == "boolean"
  end
  if key == "nodeFloppyPayload" or key == "nodeAutoUpdate" then
    return type(value) == "boolean"
  end
  if key == "role" then
    return ROLES[value] == true
  end
  if key == "nodeRole" then
    return NODE_ROLES[value] == true
  end
  return type(value) == "string"
end

function config.reset()
  config.data = copyDefaults()
  return config.data
end

function config.load(vfs)
  config.reset()
  local source = vfs.read(config.path)
  if not source then
  return false, "preferences file not found"
  end

  local chunk = load(source, "=terracorp.cfg", "t", {})
  if not chunk then
    return false, "could not parse preferences"
  end

  local ok, parsed = pcall(chunk)
  if not ok or type(parsed) ~= "table" then
    return false, "invalid preferences"
  end

  for key, value in pairs(parsed) do
    if config.defaults[key] ~= nil and accepted(key, value) then
      config.data[key] = value
    end
  end

  return true
end

function config.save(vfs)
  local ok, reason = vfs.write(config.path, serialize(config.data) .. "\n")
  return ok, reason
end

function config.get(key)
  local value = config.data[key]
  if value == nil then
    return config.defaults[key]
  end
  return value
end

function config.set(key, value)
  if config.defaults[key] == nil or not accepted(key, value) then
    return false
  end
  config.data[key] = value
  return true
end

-- Return the next value from a closed option list (used by settings controls).
function config.cycle(key, options)
  local current = config.get(key)
  local nextIndex = 1
  for index, value in ipairs(options) do
    if value == current then
      nextIndex = (index % #options) + 1
      break
    end
  end
  config.set(key, options[nextIndex])
  return options[nextIndex]
end

return config
