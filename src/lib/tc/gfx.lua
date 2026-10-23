-- Framebuffer virtual con doble búfer y volcado por diferencias.
--
-- Todo se dibuja en memoria y se envía a la GPU solo lo que cambió respecto al
-- frame anterior, agrupando celdas contiguas del mismo color. Así una pantalla
-- de 120x45 no cuesta 5400 llamadas por frame.

local text = require("tc.text")

local gfx = {}
local view = {}

local FALLBACK_BG = 15
local FALLBACK_FG = 0

local function sequenceLength(byte)
  if byte >= 0xF0 then
    return 4
  elseif byte >= 0xE0 then
    return 3
  elseif byte >= 0xC0 then
    return 2
  end
  return 1
end

function gfx.new(address)
  local self = setmetatable({}, { __index = gfx })
  self.address = address
  self.gpu = component.proxy(address)
  if not self:resize() then
    error("TerraCorp OS: la GPU " .. tostring(address) .. " no responde", 0)
  end
  return self
end

function gfx:resize()
  local ok, width, height = pcall(self.gpu.getResolution)
  if not ok or not width or not height then
    return false
  end

  self.w = width
  self.h = height
  self.ch, self.fg, self.bg = {}, {}, {}
  self.pch, self.pfg, self.pbg = {}, {}, {}

  for cell = 1, width * height do
    self.ch[cell] = " "
    self.fg[cell] = FALLBACK_FG
    self.bg[cell] = FALLBACK_BG
    self.pch[cell] = "\0"
    self.pfg[cell] = -1
    self.pbg[cell] = -1
  end

  return true
end

function gfx:clear(bg, fg)
  bg = bg or FALLBACK_BG
  fg = fg or FALLBACK_FG
  for cell = 1, self.w * self.h do
    self.ch[cell] = " "
    self.fg[cell] = fg
    self.bg[cell] = bg
  end
end

-- Escribe `value` en (x, y) recortando por ambos lados. Devuelve el ancho usado.
function gfx:put(x, y, value, fg, bg)
  if y < 1 or y > self.h then
    return 0
  end
  value = tostring(value)
  fg = fg or FALLBACK_FG
  bg = bg or FALLBACK_BG

  local index, count, written = 1, 0, 0
  while index <= #value do
    local length = sequenceLength(value:byte(index))
    local character = value:sub(index, index + length - 1)
    index = index + length
    count = count + 1

    local target = x + count - 1
    if target >= 1 and target <= self.w then
      local cell = (y - 1) * self.w + target
      self.ch[cell] = character
      self.fg[cell] = fg
      self.bg[cell] = bg
      written = written + 1
    end
  end

  return written
end

function gfx:fill(x, y, width, height, character, fg, bg)
  character = character or " "
  fg = fg or FALLBACK_FG
  bg = bg or FALLBACK_BG

  local x1 = math.max(1, x)
  local y1 = math.max(1, y)
  local x2 = math.min(self.w, x + width - 1)
  local y2 = math.min(self.h, y + height - 1)

  for row = y1, y2 do
    local base = (row - 1) * self.w
    for column = x1, x2 do
      local cell = base + column
      self.ch[cell] = character
      self.fg[cell] = fg
      self.bg[cell] = bg
    end
  end
end

-- Marco con relleno y título opcional en el borde superior.
function gfx:box(x, y, width, height, opts)
  opts = opts or {}
  if width < 2 or height < 2 then
    return
  end

  local g = opts.glyphs or { h = "─", v = "│", tl = "┌", tr = "┐", bl = "└", br = "┘" }
  local fg = opts.fg or FALLBACK_FG
  local bg = opts.bg or FALLBACK_BG

  self:fill(x, y, width, height, " ", fg, bg)
  self:put(x, y, g.tl .. string.rep(g.h, width - 2) .. g.tr, fg, bg)
  self:put(x, y + height - 1, g.bl .. string.rep(g.h, width - 2) .. g.br, fg, bg)

  for row = y + 1, y + height - 2 do
    self:put(x, row, g.v, fg, bg)
    self:put(x + width - 1, row, g.v, fg, bg)
  end

  if opts.title and width > 4 then
    local label = " " .. text.truncate(opts.title, width - 4) .. " "
    self:put(x + 2, y, label, opts.titleFg or fg, opts.titleBg or bg)
  end
end

-- Barra de progreso de 0 a 1.
function gfx:bar(x, y, width, ratio, fg, bg, glyph)
  ratio = math.max(0, math.min(1, ratio or 0))
  local filled = math.floor(width * ratio + 0.5)
  glyph = glyph or "█"
  self:fill(x, y, width, 1, " ", fg, bg)
  if filled > 0 then
    self:put(x, y, string.rep(glyph, filled), fg, bg)
  end
end

-- Subvista con origen propio y recorte: lo que usan las apps.
function gfx:view(x, y, width, height)
  return setmetatable({
    buf = self,
    x = x,
    y = y,
    w = width,
    h = height,
  }, { __index = view })
end

function view:put(x, y, value, fg, bg)
  if y < 1 or y > self.h then
    return 0
  end
  value = tostring(value)

  local offset = 1
  if x < 1 then
    offset = 2 - x
    x = 1
  end

  if offset > 1 then
    value = text.slice(value, offset)
  end

  local room = self.w - x + 1
  if room < 1 then
    return 0
  end
  if text.width(value) > room then
    value = text.slice(value, 1, room)
  end

  return self.buf:put(self.x + x - 1, self.y + y - 1, value, fg, bg)
end

function view:textRight(x, y, value, fg, bg)
  return self:put(x - text.width(value) + 1, y, value, fg, bg)
end

function view:textCenter(y, value, fg, bg)
  local column = math.max(1, math.floor((self.w - text.width(value)) / 2) + 1)
  return self:put(column, y, value, fg, bg)
end

function view:fill(x, y, width, height, character, fg, bg)
  local x1 = math.max(1, x)
  local y1 = math.max(1, y)
  local x2 = math.min(self.w, x + width - 1)
  local y2 = math.min(self.h, y + height - 1)
  if x2 < x1 or y2 < y1 then
    return
  end
  self.buf:fill(self.x + x1 - 1, self.y + y1 - 1, x2 - x1 + 1, y2 - y1 + 1, character, fg, bg)
end

-- Marco recortado al área de la subvista: nunca pinta fuera de la ventana.
function view:box(x, y, width, height, opts)
  local x1 = math.max(1, x)
  local y1 = math.max(1, y)
  local x2 = math.min(self.w, x + width - 1)
  local y2 = math.min(self.h, y + height - 1)
  if x2 < x1 or y2 < y1 then
    return
  end
  self.buf:box(self.x + x1 - 1, self.y + y1 - 1, x2 - x1 + 1, y2 - y1 + 1, opts)
end

function view:hline(x, y, width, character, fg, bg)
  self:fill(x, y, width, 1, character, fg, bg)
end

function view:bar(x, y, width, ratio, fg, bg, glyph)
  local x1 = math.max(1, x)
  local x2 = math.min(self.w, x + width - 1)
  if x2 < x1 then
    return
  end
  self:fill(x1, y, x2 - x1 + 1, 1, " ", fg, bg)
  local filled = math.floor((x2 - x1 + 1) * math.max(0, math.min(1, ratio or 0)) + 0.5)
  if filled > 0 then
    self:fill(x1, y, filled, 1, glyph or "█", fg, bg)
  end
end

function view:clear(character, fg, bg)
  self:fill(1, 1, self.w, self.h, character, fg, bg)
end

-- Volcado por diferencias: agrupa celdas contiguas con el mismo par fg/bg.
function gfx:flush()
  local gpu = self.gpu
  local width = self.w
  local written = 0

  for row = 1, self.h do
    local base = (row - 1) * width
    local column = 1

    while column <= width do
      local cell = base + column
      local changed = self.ch[cell] ~= self.pch[cell]
        or self.fg[cell] ~= self.pfg[cell]
        or self.bg[cell] ~= self.pbg[cell]

      if not changed then
        column = column + 1
      else
        local fg = self.fg[cell]
        local bg = self.bg[cell]
        local run = {}
        local cursor = column

        while cursor <= width do
          local current = base + cursor
          local sameColors = self.fg[current] == fg and self.bg[current] == bg
          local isDirty = self.ch[current] ~= self.pch[current]
            or self.fg[current] ~= self.pfg[current]
            or self.bg[current] ~= self.pbg[current]
          if not sameColors or not isDirty then
            break
          end
          run[#run + 1] = self.ch[current]
          cursor = cursor + 1
        end

        gpu.setBackground(bg)
        gpu.setForeground(fg)
        gpu.set(column, row, table.concat(run))

        for index = column, cursor - 1 do
          local current = base + index
          self.pch[current] = self.ch[current]
          self.pfg[current] = self.fg[current]
          self.pbg[current] = self.bg[current]
        end

        written = written + (cursor - column)
        column = cursor
      end
    end
  end

  return written
end

return gfx
