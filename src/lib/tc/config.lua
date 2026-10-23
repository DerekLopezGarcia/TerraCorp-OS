-- Preferencias del sistema en /etc/terracorp.cfg.
-- El fichero es una tabla Lua serializada que se carga en un entorno vacío:
-- así se puede leer sin `require` ni `serialization`.

local config = {}

config.path = "/etc/terracorp.cfg"

config.defaults = {
  accent = "cyan",
  charset = "unicode",
  clock24 = true,
  splash = true,
  logLevel = "info",
  hostname = "",
}

config.data = {}

local ACCENTS = { "cyan", "orange", "lime", "lightblue", "yellow", "purple" }
local CHARSETS = { "unicode", "ascii" }
local LOG_LEVELS = { "debug", "info", "warn", "error" }

config.accents = ACCENTS
config.charsets = CHARSETS
config.logLevels = LOG_LEVELS

local function copyDefaults()
  local data = {}
  for key, value in pairs(config.defaults) do
    data[key] = value
  end
  return data
end

local function serialize(data)
  local lines = { "-- TerraCorp OS: preferencias del sistema", "return {" }
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
    return false, "sin fichero de preferencias"
  end

  local chunk = load(source, "=terracorp.cfg", "t", {})
  if not chunk then
    return false, "preferencias ilegibles"
  end

  local ok, parsed = pcall(chunk)
  if not ok or type(parsed) ~= "table" then
    return false, "preferencias inválidas"
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

-- Devuelve el siguiente valor de una lista cerrada (para botones de ajustes).
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
