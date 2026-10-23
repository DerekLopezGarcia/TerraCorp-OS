-- Acerca de: identidad del producto, plataforma y créditos.

local about = {}
about.__index = about

about.id = "about"
about.title = "Acerca de"
about.short = "Acerca"
about.order = 5

function about.create()
  return setmetatable({}, about)
end

local CREDITS = {
  "TerraCorp OS es software propio: no es un fork de MineOS.",
  "MineOS (Igor Timofeev, MIT) se usa como referencia de arquitectura",
  "y de experiencia de escritorio para OpenComputers.",
  "",
  "Plataforma objetivo: Minecraft 1.12.2 + Forge + OpenComputers,",
  "dentro del modpack Supersymmetry (coremod Susy-Core, GPLv3).",
  "Susy-Core no se modifica ni se redistribuye: solo se usa como entorno.",
  "",
  "Licencia de este proyecto: MIT. Ver LICENSE en el repositorio.",
}

function about:draw(ctx)
  local c = ctx.colors
  local v = ctx.view

  v:clear(" ", c.text, c.deep)

  v:put(1, 1, "TERRACORP", c.accent, c.deep)
  v:put(10, 1, "OS", c.text, c.deep)
  v:put(1, 2, ctx.version.company .. " · " .. ctx.version.tagline, c.dim, c.deep)

  local info = {
    { "Versión", ctx.version.version .. " " .. ctx.version.codename },
    { "API de apps", tostring(ctx.version.api) },
    { "Nodo", ctx.kernel.hostname },
    { "Dirección", ctx.kernel.address },
    { "Arranque", ctx.kernel.volume.address },
    { "Resolución", ctx.view.w .. "x" .. ctx.view.h },
    { "Licencia", ctx.version.license },
  }

  local row = 4
  for _, pair in ipairs(info) do
    v:put(2, row, pair[1], c.dim, c.deep)
    v:put(16, row, pair[2], c.text, c.deep)
    row = row + 1
  end

  row = row + 1
  v:hline(1, row - 1, ctx.w, ctx.glyphs.h, c.panel, c.deep)

  for _, line in ipairs(CREDITS) do
    if row > ctx.h then
      break
    end
    v:put(2, row, ctx.text.truncate(line, ctx.w - 2), c.dim, c.deep)
    row = row + 1
  end

  if row <= ctx.h then
    v:put(1, ctx.h, "Repositorio: github.com/DerekLopezGarcia/TerraCorp-OS", c.dim, c.deep)
  end
end

function about:handle()
  return false
end

function about:close()
end

return about
