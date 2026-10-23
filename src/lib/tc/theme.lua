-- Paleta, colores semánticos y glifos.
--
-- OpenComputers solo tiene 16 colores fijos, así que el tema es una asignación
-- de tokens ("panel", "acento", "peligro") a índices de esa paleta.

local theme = {}

-- Índices de la paleta de OpenComputers (16 colores de Minecraft).
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
