-- Utilidades sin dependencias: números, cadenas, rutas y formatos.

local util = {}

function util.clamp(value, minimum, maximum)
  if value < minimum then
    return minimum
  end
  if value > maximum then
    return maximum
  end
  return value
end

function util.startsWith(text, prefix)
  return text:sub(1, #prefix) == prefix
end

function util.trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function util.split(text, separator)
  local parts = {}
  local from = 1
  while true do
    local at = text:find(separator, from, true)
    if not at then
      parts[#parts + 1] = text:sub(from)
      break
    end
    parts[#parts + 1] = text:sub(from, at - 1)
    from = at + #separator
  end
  return parts
end

-- Une dos tramos de ruta y resuelve "." y "..". Siempre devuelve ruta absoluta.
function util.join(base, name)
  local raw = base
  if name and name ~= "" then
    if name:sub(1, 1) == "/" then
      raw = name
    elseif base == "/" then
      raw = "/" .. name
    else
      raw = base .. "/" .. name
    end
  end

  local stack = {}
  for _, part in ipairs(util.split(raw, "/")) do
    if part == ".." then
      if #stack > 0 then
        stack[#stack] = nil
      end
    elseif part ~= "" and part ~= "." then
      stack[#stack + 1] = part
    end
  end

  return "/" .. table.concat(stack, "/")
end

function util.basename(path)
  if path == "/" then
    return "/"
  end
  return path:match("([^/]+)/*$") or path
end

function util.parent(path)
  if path == "/" then
    return "/"
  end
  return util.join(path, "..")
end

function util.padLeft(text, width)
  text = tostring(text)
  if #text >= width then
    return text
  end
  return string.rep(" ", width - #text) .. text
end

function util.padRight(text, width)
  text = tostring(text)
  if #text >= width then
    return text
  end
  return text .. string.rep(" ", width - #text)
end

-- Duración en formato de planta: "3d 04h", "2h 07m", "58s".
function util.humanTime(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  local days = math.floor(seconds / 86400)
  local hours = math.floor((seconds % 86400) / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local rest = seconds % 60

  if days > 0 then
    return string.format("%dd %02dh", days, hours)
  end
  if hours > 0 then
    return string.format("%dh %02dm", hours, minutes)
  end
  if minutes > 0 then
    return string.format("%dm %02ds", minutes, rest)
  end
  return string.format("%ds", rest)
end

-- Tamaños expresados en kilobytes (así los devuelve OpenComputers).
function util.humanSize(kilobytes)
  local value = tonumber(kilobytes) or 0
  if value >= 1048576 then
    return string.format("%.1f GB", value / 1048576)
  end
  if value >= 1024 then
    return string.format("%.1f MB", value / 1024)
  end
  return string.format("%d KB", math.floor(value))
end

function util.formatClock(clock24)
  local ok, real = pcall(os.date, clock24 and "%H:%M" or "%I:%M %p")
  if ok then
    return real
  end
  return "--:--"
end

function util.count(tbl)
  local total = 0
  for _ in pairs(tbl) do
    total = total + 1
  end
  return total
end

function util.contains(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

return util
