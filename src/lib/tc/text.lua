-- Texto y UTF-8 sin dependencias.
--
-- OpenComputers dibuja una celda por carácter, así que necesitamos partir por
-- puntos de código (no por bytes) y asumir ancho 1. Los caracteres de doble
-- ancho (CJK, emoji) no están soportados: ver docs/opencomputers.md.

local text = {}

-- Longitud de la secuencia UTF-8 que empieza con el byte indicado.
local function sequenceLength(byte)
  if byte < 0x80 then
    return 1
  elseif byte < 0xE0 then
    return 2
  elseif byte < 0xF0 then
    return 3
  elseif byte < 0xF8 then
    return 4
  end
  return 1
end

-- Devuelve el siguiente índice y la secuencia completa a partir de `index`.
local function nextCharacter(value, index)
  local byte = value:byte(index)
  if not byte then
    return nil, nil
  end
  local length = sequenceLength(byte)
  local last = math.min(index + length - 1, #value)
  return last + 1, value:sub(index, last)
end

function text.width(value)
  local index, count = 1, 0
  while index <= #value do
    local following = nextCharacter(value, index)
    if not following then
      break
    end
    index = following
    count = count + 1
  end
  return count
end

-- Cada llamada devuelve el siguiente carácter (no un iterador de Lua).
function text.charAt(value, position)
  local index, count = 1, 0
  while index <= #value do
    local following, character = nextCharacter(value, index)
    if not following then
      return nil
    end
    count = count + 1
    if count == position then
      return character
    end
    index = following
  end
  return nil
end

function text.truncate(value, width, ellipsis)
  if text.width(value) <= width then
    return value
  end

  if width <= 0 then
    return ""
  end

  local suffix = ellipsis or ""
  local room = width - text.width(suffix)
  if room < 1 then
    return text.truncate(suffix, width, "")
  end

  local parts, index, count = {}, 1, 0
  while index <= #value and count < room do
    local following, character = nextCharacter(value, index)
    if not following then
      break
    end
    parts[#parts + 1] = character
    index = following
    count = count + 1
  end

  return table.concat(parts) .. suffix
end

function text.padRight(value, width)
  local length = text.width(value)
  if length >= width then
    return text.truncate(value, width)
  end
  return value .. string.rep(" ", width - length)
end

function text.padLeft(value, width)
  local length = text.width(value)
  if length >= width then
    return text.truncate(value, width)
  end
  return string.rep(" ", width - length) .. value
end

-- Tramo de `from` a `to` contando puntos de código (1-based, inclusivo).
function text.slice(value, from, to)
  local parts = {}
  local position = 1
  while true do
    local character = text.charAt(value, position)
    if not character then
      break
    end
    if position >= from and (to == nil or position <= to) then
      parts[#parts + 1] = character
    end
    if to ~= nil and position >= to then
      break
    end
    position = position + 1
  end
  return table.concat(parts)
end

-- Parte un texto en líneas de como máximo `width` caracteres.
function text.wrap(value, width)
  local lines = {}
  if width < 1 then
    return { value }
  end

  local current = ""
  for word in value:gmatch("%S+") do
    local candidate = (current == "") and word or (current .. " " .. word)
    if text.width(candidate) <= width then
      current = candidate
    else
      if current ~= "" then
        lines[#lines + 1] = current
      end
      while text.width(word) > width do
        lines[#lines + 1] = text.slice(word, 1, width)
        word = text.slice(word, width + 1)
      end
      current = word
    end
  end

  lines[#lines + 1] = current
  return lines
end

return text
