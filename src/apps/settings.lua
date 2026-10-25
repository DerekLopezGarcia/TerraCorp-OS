-- Preferences: accent color, character set, clock, startup, and logging.

local settings = {}
settings.__index = settings

settings.id = "settings"
settings.title = "Settings"
settings.short = "Settings"
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

-- Buttons are drawn as " label ", two columns wider than the text.
local function buttonWidth(label)
  return #label + 2
end

function settings:draw(ctx)
  local c = ctx.colors
  local g = ctx.glyphs
  local v = ctx.view

  v:clear(" ", c.text, c.deep)

  self.hits = {}

  v:put(1, 1, "Station preferences", c.text, c.deep)
  v:put(1, 2, "Changes apply immediately and are saved to " .. ctx.config.path, c.dim, c.deep)

  local rows = {
    {
      label = "Accent color",
      value = ctx.config.get("accent"),
      action = function(context)
        context.config.cycle("accent", context.config.accents)
        self:apply(context, "Accent updated")
      end,
    },
    {
      label = "Character set",
      value = ctx.config.get("charset"),
      action = function(context)
        context.config.cycle("charset", context.config.charsets)
        self:apply(context, "Character set updated")
      end,
    },
    {
      label = "Clock",
      value = ctx.config.get("clock24") and "24-hour" or "12-hour",
      action = function(context)
        self:toggleBoolean(context, "clock24")
        self:apply(context, "Clock format updated")
      end,
    },
    {
      label = "Boot splash",
      value = ctx.config.get("splash") and "enabled" or "disabled",
      action = function(context)
        self:toggleBoolean(context, "splash")
        self:apply(context, "Boot splash updated")
      end,
    },
    {
      label = "Log level",
      value = ctx.config.get("logLevel"),
      action = function(context)
        context.config.cycle("logLevel", context.config.logLevels)
        self:apply(context, "Log level updated")
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
    local valueWidth = ctx.text.width(valueLabel)
    local x = ctx.w - valueWidth - 1
    v:put(x, y, valueLabel, c.onAccent, c.accent)
    self.hits[#self.hits + 1] = {
      x = math.max(1, x),
      y = y,
      w = valueWidth,
      h = 1,
      action = option.action,
    }
  end

  local actionsY = math.max(row + #rows * 2 + 1, ctx.h - 3)
  if actionsY + 1 <= ctx.h then
    v:hline(1, actionsY - 1, ctx.w, g.h, c.panel, c.deep)

    local actions = {
      { label = "Save", action = function(context)
        context.kernel:saveConfig()
        context.ui:notify("info", "Preferences saved")
      end },
      { label = "Reset", action = function(context)
        context.config.reset()
        context.kernel:applyTheme()
        context.kernel:saveConfig()
        context.ui:notify("warn", "Preferences reset")
      end },
      { label = "Restart", action = function(context)
        context.kernel:poweroff(true)
      end },
      { label = "Shut down", action = function(context)
        context.kernel:poweroff(false)
      end },
    }

    local x = 2
    for _, action in ipairs(actions) do
      local label = " " .. action.label .. " "
      local width = buttonWidth(action.label)
      if x + width - 1 > ctx.w then
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
      x = x + width + 1
    end
  end

  v:put(1, ctx.h, "Click a value to change it · Esc minimizes", c.dim, c.deep)
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
