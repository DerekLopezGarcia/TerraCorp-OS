-- Palette, semantic colors, and glyphs.
--
-- OpenComputers has a 16-color palette, so themes map semantic tokens such as
-- "panel", "accent", and "danger" to palette indexes.

local theme = {}

-- OpenComputers palette indexes (the 16 Minecraft colors).
local PALETTE = {
  white = 0,
  orange = 1,
  magenta = 2,
  lightblue = 3,
  yellow = 4,
  lime = 5,
  pink = 6,
  gray = 7,
  lightgray = 8,
  cyan = 9,
  purple = 10,
  blue = 11,
  brown = 12,
  green = 13,
  red = 14,
  black = 15,
}

theme.palette = PALETTE

-- Classic OpenComputers palette (indexes 0-15). Tier 3 screens start with an
-- editable grayscale palette, so the OS initializes it before drawing.
theme.paletteRGB = {
  [0] = 0xF0F0F0, -- white
  [1] = 0xF2B233, -- orange
  [2] = 0xE57FD8, -- magenta
  [3] = 0x99B2F2, -- lightblue
  [4] = 0xDEDE6C, -- yellow
  [5] = 0x7FCC19, -- lime
  [6] = 0xF2B2CC, -- pink
  [7] = 0x4C4C4C, -- gray
  [8] = 0x999999, -- lightgray
  [9] = 0x4C99B2, -- cyan
  [10] = 0xB266E5, -- purple
  [11] = 0x3366CC, -- blue
  [12] = 0x7F664C, -- brown
  [13] = 0x57A64E, -- green
  [14] = 0xCC4C4C, -- red
  [15] = 0x111111, -- black
}

theme.accents = {
  cyan = PALETTE.cyan,
  orange = PALETTE.orange,
  lime = PALETTE.lime,
  lightblue = PALETTE.lightblue,
  yellow = PALETTE.yellow,
  purple = PALETTE.purple,
}

local GLYPHS = {
  unicode = {
    h = "─",
    v = "│",
    tl = "┌",
    tr = "┐",
    bl = "└",
    br = "┘",
    ml = "├",
    mr = "┤",
    block = "█",
    shade = "░",
    bar = "▓",
    bullet = "•",
    arrow = "►",
    mark = "■",
    close = "×",
    dash = "—",
  },
  ascii = {
    h = "-",
    v = "|",
    tl = "+",
    tr = "+",
    bl = "+",
    br = "+",
    ml = "+",
    mr = "+",
    block = "#",
    shade = ":",
    bar = "=",
    bullet = "*",
    arrow = ">",
    mark = "#",
    close = "x",
    dash = "-",
  },
}

theme.glyphs = GLYPHS

function theme.build(config)
  local accentName = config.get("accent")
  local accent = theme.accents[accentName] or PALETTE.cyan
  local charset = config.get("charset")

  return {
    name = accentName,
    accent = accent,
    glyphs = GLYPHS[charset] or GLYPHS.unicode,
    colors = {
      bg = PALETTE.black,
      panel = PALETTE.gray,
      deep = PALETTE.black,
      text = PALETTE.white,
      dim = PALETTE.lightgray,
      line = PALETTE.lightgray,
      accent = accent,
      onAccent = PALETTE.black,
      ok = PALETTE.lime,
      warn = PALETTE.yellow,
      danger = PALETTE.red,
      onDanger = PALETTE.black,
      selected = accent,
      onSelected = PALETTE.black,
    },
  }
end

return theme
