-- Virtual double-buffered framebuffer with differential flush.
--
-- Draw into memory and send only changed cells to the GPU, grouping adjacent
-- cells that share colors. This avoids one GPU call per screen cell.

local text = require("tc.text")
local theme = require("tc.theme")

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
  -- Tier 3 starts with an editable grayscale palette, unlike the tier 2
  -- Minecraft palette. Set classic OpenComputers colors when supported.
  for index, color in pairs(theme.paletteRGB) do
    pcall(self.gpu.setPaletteColor, index, color)
  end
  if not self:resize() then
    error("TerraCorp OS: GPU " .. tostring(address) .. " is not responding", 0)
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

-- Write `value` at (x, y), clipping both sides. Return the number of cells used.
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

  -- Draw a filled frame with an optional title in its top border.
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

-- Progress bar from 0 to 1.
function gfx:bar(x, y, width, ratio, fg, bg, glyph)
  ratio = math.max(0, math.min(1, ratio or 0))
  local filled = math.floor(width * ratio + 0.5)
  glyph = glyph or "█"
  self:fill(x, y, width, 1, " ", fg, bg)
  if filled > 0 then
    self:put(x, y, string.rep(glyph, filled), fg, bg)
  end
end

  -- Clipped subview with a local origin, used by apps.
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

  -- Clip the frame to the subview so it never draws outside the window.
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

  -- Differential flush groups adjacent cells with the same foreground/background.
function gfx:flush()
  local gpu = self.gpu
  local width = self.w
  local written = 0
  local failed = 0
  local lastFg, lastBg = nil, nil

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

        -- The GPU may reject a write (for example, due to power or no screen)
        -- and return nil. Do not mark rejected cells as drawn; retry later.
        local colorsOk = true
        if bg ~= lastBg then
          local callOk, result = pcall(gpu.setBackground, bg, true)
          colorsOk = callOk and result ~= nil and result ~= false
          if colorsOk then lastBg = bg else lastBg = nil end
        end
        if fg ~= lastFg then
          local callOk, result = pcall(gpu.setForeground, fg, true)
          colorsOk = colorsOk and callOk and result ~= nil and result ~= false
          if callOk and result ~= nil and result ~= false then lastFg = fg else lastFg = nil end
        end

        local callOk, result = pcall(gpu.set, column, row, table.concat(run))
        local wrote = colorsOk and callOk and result ~= nil and result ~= false

        if wrote then
          for index = column, cursor - 1 do
            local current = base + index
            self.pch[current] = self.ch[current]
            self.pfg[current] = self.fg[current]
            self.pbg[current] = self.bg[current]
          end

          written = written + (cursor - column)
        else
          failed = failed + 1
          -- The GPU color state is now unknown; resend it on the next span.
          lastFg, lastBg = nil, nil
        end

        column = cursor
      end
    end
  end

  return written, failed
end

return gfx
