-- Preferencias: acento, juego de caracteres, reloj, arranque y registro.

local settings = {}
settings.__index = settings

settings.id = "settings"
settings.title = "Ajustes"
settings.short = "Ajustes"
settings.order = 4

function settings.create()
  local self = setmetatable({}, settings)
  self.hits = {}
  return self
end

function settings:toggleBoolean(ctx, key)
  local value = ctx.config.get(key)
  ctx.config.set(key, not value)
  ctx.kernel:saveConfig()
end

function settings:apply(ctx, message)
  ctx.kernel:applyTheme()
  ctx.kernel:saveConfig()
  ctx.ui:notify("info", message)
end

local function buttonWidth(label)
  return #label + 4
end

function settings:draw(ctx)
  local c = ctx.colors
  local g = ctx.glyphs
  local v = ctx.view

  v:clear(" ", c.text, c.deep)

  self.hits = {}

  v:put(1, 1, "Preferencias de la estación", c.text, c.deep)
  v:put(1, 2, "Los cambios se aplican al momento y se guardan en " .. ctx.config.path, c.dim, c.deep)

  local rows = {
    {
      label = "Acento corporativo",
      value = ctx.config.get("accent"),
      action = function(context)
        context.config.cycle("accent", context.config.accents)
        self:apply(context, "Acento actualizado")
      end,
    },
    {
      label = "Juego de caracteres",
      value = ctx.config.get("charset"),
      action = function(context)
        context.config.cycle("charset", context.config.charsets)
        self:apply(context, "Caracteres actualizados")
      end,
    },
    {
      label = "Reloj",
      value = ctx.config.get("clock24") and "24 horas" or "12 horas",
      action = function(context)
        self:toggleBoolean(context, "clock24")
        self:apply(context, "Formato de hora actualizado")
      end,
    },
    {
      label = "Arranque animado",
      value = ctx.config.get("splash") and "activado" or "desactivado",
      action = function(context)
        self:toggleBoolean(context, "splash")
        self:apply(context, "Arranque actualizado")
      end,
    },
    {
      label = "Nivel de registro",
      value = ctx.config.get("logLevel"),
      action = function(context)
        context.config.cycle("logLevel", context.config.logLevels)
        self:apply(context, "Nivel de registro actualizado")
      end,
    },
  }

  local row = 4
  for index, option in ipairs(rows) do
    local y = row + (index - 1) * 2
    if y + 1 > ctx.h - 4 then
      break
    end

    v:put(2, y, option.label, c.dim, c.deep)
    local valueLabel = " [ " .. option.value .. " ] "
    local x = ctx.w - #valueLabel - 1
    v:put(x, y, valueLabel, c.onAccent, c.accent)
    self.hits[#self.hits + 1] = {
      x = math.max(1, x - 1),
      y = y,
      w = #valueLabel + 2,
      h = 1,
      action = option.action,
    }
  end

  local actionsY = math.max(row + #rows * 2 + 1, ctx.h - 3)
  if actionsY + 1 <= ctx.h then
    v:hline(1, actionsY - 1, ctx.w, g.h, c.panel, c.deep)

    local actions = {
      { label = "Guardar", action = function(context)
        context.kernel:saveConfig()
        context.ui:notify("info", "Preferencias guardadas")
      end },
      { label = "Restablecer", action = function(context)
        context.config.reset()
        context.kernel:applyTheme()
        context.kernel:saveConfig()
        context.ui:notify("warn", "Preferencias restablecidas")
      end },
      { label = "Reiniciar", action = function(context)
        context.kernel:poweroff(true)
      end },
      { label = "Apagar", action = function(context)
        context.kernel:poweroff(false)
      end },
    }

    local x = 2
    for _, action in ipairs(actions) do
      local label = " " .. action.label .. " "
      local width = buttonWidth(action.label)
      if x + width > ctx.w then
        break
      end
      v:put(x, actionsY, label, c.onAccent, c.accent)
      self.hits[#self.hits + 1] = {
        x = x,
        y = actionsY,
        w = width,
        h = 1,
        action = action.action,
      }
      x = x + width + 2
    end
  end

  v:put(1, ctx.h, "Clic en un valor para cambiarlo · Esc minimiza", c.dim, c.deep)
end

function settings:handle(ctx, name, a, b)
  if name ~= "touch" then
    return false
  end

  for _, hit in ipairs(self.hits) do
    if a >= hit.x and a < hit.x + hit.w and b == hit.y then
      hit.action(ctx)
      return true
    end
  end

  return false
end

function settings:close()
end

return settings
