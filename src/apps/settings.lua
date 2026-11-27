-- Preferences: station appearance and the DNS service on this desktop.

local keys = require("tc.keys")

local settings = {}
settings.__index = settings

settings.id = "settings"
settings.title = "Settings"
settings.short = "Settings"
settings.icon = "SET"
settings.iconArt = {
  "  █   █  ",
  " ███ ███ ",
  "███   ███",
  " ███ ███ ",
  "  █   █  ",
}
settings.order = 4

local MODES = { "off", "master", "client" }
local MODE_LABEL = { off = "Off", master = "Master", client = "Client" }
local TRANSPORTS = { "auto", "wired", "wireless" }
local UUID_PATTERN =
  "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local function validAddress(value)
  return type(value) == "string" and #value == 36 and value:match(UUID_PATTERN) ~= nil
end

local function shortAddress(value)
  value = tostring(value or "")
  if #value <= 22 then
    return value
  end
  return value:sub(1, 8) .. "…" .. value:sub(-4)
end

local function modeOf(master)
  if master == "" then
    return "off"
  elseif master == "self" then
    return "master"
  end
  return "client"
end

local function buttonWidth(label)
  return #label + 2
end

function settings.create()
  local self = setmetatable({}, settings)
  self.hits = {}
  self.tab = "station"
  self.dns = nil
  self.edit = nil
  self.buffer = ""
  self.message = nil
  self.messageKind = "info"
  self.confirmStop = false
  return self
end

function settings:setMessage(kind, text)
  self.messageKind = kind
  self.message = text
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

function settings:loadDns(ctx)
  local master = tostring(ctx.config.get("dnsMaster") or "")
  local mode = modeOf(master)
  self.dns = {
    mode = mode,
    master = mode == "client" and master or "",
    port = tonumber(ctx.config.get("dnsPort")) or 4201,
    transport = tostring(ctx.config.get("dnsTransport") or "auto"),
  }
  self.edit = nil
  self.buffer = ""
  self.confirmStop = false
end

function settings:switchTab(ctx, tab)
  if tab == self.tab then
    return
  end
  self.tab = tab
  self.edit = nil
  self.buffer = ""
  self.message = nil
  self.confirmStop = false
  if tab == "dns" and not self.dns then
    self:loadDns(ctx)
  end
end

function settings:cycleMode(ctx)
  local current = self.dns.mode
  local nextIndex = 1
  for index, value in ipairs(MODES) do
    if value == current then
      nextIndex = (index % #MODES) + 1
      break
    end
  end
  self.dns.mode = MODES[nextIndex]
  self.confirmStop = false
  self:setMessage("info", "Mode set to " .. MODE_LABEL[self.dns.mode] .. "; click Apply.")
end

function settings:cycleTransport(ctx)
  local current = self.dns.transport
  local nextIndex = 1
  for index, value in ipairs(TRANSPORTS) do
    if value == current then
      nextIndex = (index % #TRANSPORTS) + 1
      break
    end
  end
  self.dns.transport = TRANSPORTS[nextIndex]
  self.confirmStop = false
  self:setMessage("info", "Transport set to " .. self.dns.transport .. "; click Apply.")
end

function settings:startEdit(ctx, field)
  if field == "master" and self.dns.mode ~= "client" then
    self:setMessage("warn", "Switch the mode to Client before entering an address.")
    return
  end
  self.edit = field
  self.confirmStop = false
  if field == "master" then
    self.buffer = self.dns.master or ""
  else
    self.buffer = tostring(self.dns.port or 4201)
  end
  self.message = nil
end

function settings:commitEdit(ctx)
  if self.edit == "master" then
    local value = self.buffer:lower()
    if not validAddress(value) then
      self:setMessage("warn", "Enter the master's 36-character UUID.")
      return true
    end
    self.dns.master = value
    self:setMessage("info", "Address ready; click Apply.")
  elseif self.edit == "port" then
    local port = tonumber(self.buffer)
    local ok, reason = ctx.config.validate("dnsPort", port)
    if not ok then
      self:setMessage("warn", reason)
      return true
    end
    self.dns.port = port
    self:setMessage("info", "Port ready; click Apply.")
  end
  self.edit = nil
  self.buffer = ""
  self.confirmStop = false
  return true
end

function settings:desiredMaster()
  if self.dns.mode == "off" then
    return ""
  elseif self.dns.mode == "master" then
    return "self"
  end
  return self.dns.master
end

function settings:applyDns(ctx)
  if self.dns.mode == "client" and not validAddress(self.dns.master) then
    self:setMessage("warn", "Enter the master's 36-character UUID before applying.")
    return
  end

  local portOk, portReason = ctx.config.validate("dnsPort", self.dns.port)
  if not portOk then
    self:setMessage("warn", portReason)
    return
  end
  local transportOk, transportReason =
    ctx.config.validate("dnsTransport", self.dns.transport)
  if not transportOk then
    self:setMessage("warn", transportReason)
    return
  end

  -- Master owns the catalog. Going to Off or Client drops every client that is
  -- reading through this desktop, so make the first Apply ask and the second
  -- one act.
  local masterRunning = tostring(ctx.kernel:dnsStatus()):match("^Master") ~= nil
  if self.dns.mode ~= "master" and masterRunning and not self.confirmStop then
    self.confirmStop = true
    self:setMessage("warn",
      "Stopping Master stops serving the catalog. Press Enter again to confirm.")
    return
  end
  self.confirmStop = false

  local previous = {
    master = ctx.config.get("dnsMaster") or "",
    port = ctx.config.get("dnsPort") or 4201,
    transport = ctx.config.get("dnsTransport") or "auto",
  }

  local function write(master, port, transport)
    return ctx.config.set("dnsMaster", master)
      and ctx.config.set("dnsPort", port)
      and ctx.config.set("dnsTransport", transport)
  end

  if not write(self:desiredMaster(), self.dns.port, self.dns.transport) then
    write(previous.master, previous.port, previous.transport)
    self:loadDns(ctx)
    self:setMessage("error", "The DNS values are not accepted.")
    return
  end

  if ctx.kernel:saveConfig() == false then
    write(previous.master, previous.port, previous.transport)
    self:loadDns(ctx)
    self:setMessage("error", "Could not save the configuration.")
    return
  end

  local callOk, started, reason = pcall(ctx.kernel.restartDns, ctx.kernel)
  if not callOk then
    started, reason = nil, tostring(started)
  end
  if not started then
    write(previous.master, previous.port, previous.transport)
    ctx.kernel:saveConfig()
    pcall(ctx.kernel.restartDns, ctx.kernel)
    self:loadDns(ctx)
    self:setMessage("error", "DNS did not start; previous mode restored: " .. tostring(reason))
    return
  end

  self:setMessage("info", "DNS updated · " .. tostring(ctx.kernel:dnsStatus()))
  ctx.ui:notify("info", "DNS updated")
end

function settings:drawTabs(ctx)
  local c = ctx.colors
  local v = ctx.view
  v:put(1, 1, "Settings", c.text, c.deep)
  local x = 11
  for _, tab in ipairs({ { "station", "Station" }, { "dns", "DNS" } }) do
    local label = " " .. tab[2] .. " "
    local active = self.tab == tab[1]
    v:put(x, 1, label, active and c.onAccent or c.dim, active and c.accent or c.panel)
    self.hits[#self.hits + 1] = {
      id = "tab:" .. tab[1],
      x = x,
      y = 1,
      w = ctx.text.width(label),
      h = 1,
      action = function(context)
        self:switchTab(context, tab[1])
      end,
    }
    x = x + ctx.text.width(label) + 1
  end
end

function settings:drawStation(ctx)
  local c = ctx.colors
  local g = ctx.glyphs
  local v = ctx.view

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
    local valueLabel = " [ " .. tostring(option.value) .. " ] "
    local valueWidth = ctx.text.width(valueLabel)
    local x = ctx.w - valueWidth - 1
    v:put(x, y, valueLabel, c.onAccent, c.accent)
    self.hits[#self.hits + 1] = {
      id = "station:" .. option.label,
      x = math.max(1, x),
      y = y,
      w = valueWidth,
      h = 1,
      action = option.action,
    }
  end

  local actionsY = math.min(ctx.h - 2, math.max(row + #rows * 2 + 1, ctx.h - 3))
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
        id = "station:" .. action.label,
        x = x,
        y = actionsY,
        w = width,
        h = 1,
        action = action.action,
      }
      x = x + width + 1
    end
  end
end

function settings:drawDns(ctx)
  local c = ctx.colors
  local g = ctx.glyphs
  local v = ctx.view
  local dns = self.dns

  local rows = {
    {
      id = "mode",
      label = "Mode",
      value = MODE_LABEL[dns.mode],
      action = function(context)
        self:cycleMode(context)
      end,
    },
    {
      id = "master",
      label = dns.mode == "master" and "This machine" or "Master address",
      value = dns.mode == "client" and shortAddress(dns.master)
        or dns.mode == "master" and tostring(ctx.kernel.address or "unknown")
        or "only in Client mode",
      disabled = dns.mode ~= "client",
      action = function(context)
        self:startEdit(context, "master")
      end,
    },
    {
      id = "port",
      label = "Port",
      value = tostring(dns.port),
      action = function(context)
        self:startEdit(context, "port")
      end,
    },
    {
      id = "transport",
      label = "Transport",
      value = dns.transport,
      action = function(context)
        self:cycleTransport(context)
      end,
    },
  }

  -- A 40x16 window has only a handful of rows. Keep the mode and the effective
  -- port/transport visible; the keyboard shortcuts still reach every field.
  if ctx.w < 56 or ctx.h < 14 then
    local modeY = 3
    local option = rows[1]
    v:put(2, modeY, option.label, c.text, c.deep)
    local valueLabel = " [ " .. tostring(option.value) .. " ] "
    local valueWidth = ctx.text.width(valueLabel)
    local x = math.max(2, ctx.w - valueWidth - 1)
    v:put(x, modeY, valueLabel, c.onAccent, c.accent)
    self.hits[#self.hits + 1] = {
      id = "dns:mode",
      x = x,
      y = modeY,
      w = valueWidth,
      h = 1,
      action = option.action,
    }

    local configY = modeY + 1
    v:put(2, configY, ctx.text.truncate(
      "Port " .. tostring(dns.port) .. " · " .. tostring(dns.transport), ctx.w - 2
    ), c.dim, c.deep)

    local statusY = configY + 1
    if statusY < ctx.h - 1 then
      v:put(2, statusY, ctx.text.truncate(tostring(ctx.kernel:dnsStatus()), ctx.w - 2),
        c.text, c.deep)
    end

    local actionsY = ctx.h - 1
    if actionsY > statusY then
      local actions = {
        { label = "Apply", action = function(context)
          self:applyDns(context)
        end },
        { label = "Reset", action = function(context)
          self:loadDns(context)
          self:setMessage("info", "DNS fields reloaded.")
        end },
      }
      local actionX = 2
      for _, action in ipairs(actions) do
        local label = " " .. action.label .. " "
        local width = buttonWidth(action.label)
        if actionX + width - 1 <= ctx.w then
          v:put(actionX, actionsY, label, c.onAccent, c.accent)
          self.hits[#self.hits + 1] = {
            id = "dns:" .. action.label,
            x = actionX,
            y = actionsY,
            w = width,
            h = 1,
            action = action.action,
          }
          actionX = actionX + width + 1
        end
      end
    end
    return
  end

  local row = 4
  for index, option in ipairs(rows) do
    local y = row + (index - 1) * 2
    if y > ctx.h - 4 then
      break
    end

    v:put(2, y, option.label, option.disabled and c.dim or c.text, c.deep)
    local valueLabel = " [ " .. tostring(option.value) .. " ] "
    local valueWidth = ctx.text.width(valueLabel)
    local x = math.max(2, ctx.w - valueWidth - 1)
    v:put(x, y, valueLabel, option.disabled and c.dim or c.onAccent,
      option.disabled and c.panel or c.accent)
    if not option.disabled then
      self.hits[#self.hits + 1] = {
        id = "dns:" .. option.id,
        x = x,
        y = y,
        w = valueWidth,
        h = 1,
        action = option.action,
      }
    end
  end

  local statusY = math.min(ctx.h - 3, row + #rows * 2)
  v:put(2, statusY, "Status", c.dim, c.deep)
  local status = ctx.kernel:dnsStatus()
  v:put(11, statusY, ctx.text.truncate(tostring(status), ctx.w - 11), c.text, c.deep)

  local actionsY = math.min(ctx.h - 2, statusY + 2)
  if actionsY > statusY and actionsY <= ctx.h then
    v:hline(1, actionsY - 1, ctx.w, g.h, c.panel, c.deep)
    local actions = {
      { label = "Apply", action = function(context)
        self:applyDns(context)
      end },
      { label = "Reset", action = function(context)
        self:loadDns(context)
        self:setMessage("info", "DNS fields reloaded.")
      end },
    }
    local x = 2
    for _, action in ipairs(actions) do
      local label = " " .. action.label .. " "
      local width = buttonWidth(action.label)
      if x + width - 1 <= ctx.w then
        v:put(x, actionsY, label, c.onAccent, c.accent)
        self.hits[#self.hits + 1] = {
          id = "dns:" .. action.label,
          x = x,
          y = actionsY,
          w = width,
          h = 1,
          action = action.action,
        }
        x = x + width + 1
      end
    end
  end
end

function settings:draw(ctx)
  local c = ctx.colors
  local v = ctx.view

  v:clear(" ", c.text, c.deep)
  self.hits = {}
  self:drawTabs(ctx)

  if self.tab == "station" then
    v:put(1, 2, "Changes apply immediately and are saved to " .. ctx.config.path, c.dim, c.deep)
    self:drawStation(ctx)
  else
    if self.message then
      local color = c[self.messageKind] or (self.messageKind == "error" and c.danger) or c.text
      v:put(1, 2, ctx.text.truncate(self.message, ctx.w), color, c.deep)
    else
      v:put(1, 2, "DNS for this desktop. Apply starts the new mode in place.", c.dim, c.deep)
    end
    self:drawDns(ctx)
  end

  if self.edit then
    local y = ctx.h - 2
    local label = self.edit == "port" and "Port: " or "Master UUID: "
    v:fill(1, y, ctx.w, 1, " ", c.text, c.panel)
    v:put(1, y, ctx.text.truncate(label .. self.buffer .. "▏", ctx.w), c.accent, c.panel)
    v:put(1, ctx.h, ctx.text.truncate("Enter saves · Tab cancels", ctx.w), c.dim, c.deep)
  else
    local footer = "Click a value · Tab switches page"
    if self.tab == "dns" then
      footer = "M mode · T transport · A address · P port · Enter apply · Tab pages"
    end
    v:put(1, ctx.h, ctx.text.truncate(footer, ctx.w), c.dim, c.deep)
  end
end

function settings:handle(ctx, name, a, b)
  if name == "touch" then
    for _, hit in ipairs(self.hits) do
      if a >= hit.x and a < hit.x + hit.w and b == hit.y then
        hit.action(ctx)
        return true
      end
    end
    return false
  end

  if name ~= "key" then
    return false
  end

  local char, code = a, b

  if self.edit then
    if code == keys.enter then
      return self:commitEdit(ctx)
    elseif code == keys.tab then
      self.edit = nil
      self.buffer = ""
      self.message = nil
      return true
    elseif code == keys.back then
      self.buffer = self.buffer:sub(1, math.max(0, #self.buffer - 1))
      return true
    elseif type(char) == "string" then
      if self.edit == "port" then
        if char:match("^%d$") and #self.buffer < 5 then
          self.buffer = self.buffer .. char
        end
      elseif char:match("^[%x%-]$") and #self.buffer < 36 then
        self.buffer = (self.buffer .. char):lower()
      end
      return true
    end
    return true
  end

  if code == keys.tab then
    self:switchTab(ctx, self.tab == "station" and "dns" or "station")
    return true
  end

  if self.tab == "dns" then
    if char == "m" then
      self:cycleMode(ctx)
      return true
    elseif char == "t" then
      self:cycleTransport(ctx)
      return true
    elseif char == "a" then
      self:startEdit(ctx, "master")
      return true
    elseif char == "p" then
      self:startEdit(ctx, "port")
      return true
    elseif code == keys.enter then
      self:applyDns(ctx)
      return true
    end
  end

  return false
end

function settings:close()
end

return settings
