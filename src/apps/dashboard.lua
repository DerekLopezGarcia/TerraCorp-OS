-- Panel de planta: estado del nodo, memoria, energía, enlaces y registro.

local dashboard = {}
dashboard.__index = dashboard

dashboard.id = "dashboard"
dashboard.title = "Panel de planta"
dashboard.short = "Panel"
dashboard.order = 1

local CARD_HEIGHT = 6

local function megabytes(bytes)
  return (tonumber(bytes) or 0) / 1048576
end

function dashboard.create(ctx)
  local self = setmetatable({}, dashboard)
  self.samplesAt = 0
  self:refresh(ctx)
  return self
end

function dashboard:refresh(ctx)
  local kernel = ctx.kernel

  local usedMemory, totalMemory = kernel:memory()
  self.memoryUsed = megabytes(usedMemory)
  self.memoryTotal = megabytes(totalMemory)

  self.energyStored, self.energyMaximum = kernel:energy()
  self.storageUsed, self.storageTotal = kernel:storage()
  self.components = kernel:components()
  self.uptime = kernel:uptime()
  self.samplesAt = kernel:uptime()
end

function dashboard:draw(ctx)
  local c = ctx.colors
  local g = ctx.glyphs
  local v = ctx.view

  v:clear(" ", c.text, c.deep)

  local dense = ctx.h < 26
  local columns = (ctx.w >= 62) and 2 or 1
  local gap = 1
  local cardWidth = math.floor((ctx.w - gap * (columns - 1)) / columns)

  local function card(column, row, title, value, detail, ratio, tint)
    local x = 1 + (column - 1) * (cardWidth + gap)
    local y = 1 + (row - 1) * (CARD_HEIGHT + gap)

    v:box(x, y, cardWidth, CARD_HEIGHT, {
      glyphs = g,
      fg = c.panel,
      bg = c.deep,
      title = title,
      titleFg = c.dim,
      titleBg = c.deep,
    })

    v:put(x + 2, y + 2, ctx.text.truncate(value, cardWidth - 4), tint or c.accent, c.deep)
    if ratio then
      v:bar(x + 2, y + 3, math.max(1, cardWidth - 4), ratio, tint or c.accent, c.deep, g.block)
    end
    v:put(x + 2, y + CARD_HEIGHT - 2, ctx.text.truncate(detail or "", cardWidth - 4), c.dim, c.deep)
  end

  local memoryRatio = 0
  if self.memoryTotal > 0 then
    memoryRatio = self.memoryUsed / self.memoryTotal
  end

  local energyRatio = 0
  if self.energyStored and self.energyMaximum and self.energyMaximum > 0 then
    energyRatio = self.energyStored / self.energyMaximum
  end

  local energyColor = c.ok
  if energyRatio < 0.15 then
    energyColor = c.danger
  elseif energyRatio < 0.4 then
    energyColor = c.warn
  end

  local storageRatio = 0
  if self.storageUsed and self.storageTotal and self.storageTotal > 0 then
    storageRatio = self.storageUsed / self.storageTotal
  end

  local topKinds = {}
  for index = 1, math.min(2, #self.components.entries) do
    local entry = self.components.entries[index]
    topKinds[#topKinds + 1] = entry.kind .. " x" .. entry.count
  end

  card(1, 1, "NODO", ctx.kernel.hostname,
    ctx.kernel.address:sub(1, 8) .. " · " .. ctx.version.version, nil, c.text)

  card(2, 1, "ACTIVIDAD", ctx.util.humanTime(self.uptime),
    "Sesión en curso", nil, c.text)

  card(1, 2, "MEMORIA", string.format("%.1f / %.1f MB", self.memoryUsed, self.memoryTotal),
    string.format("%.0f%% ocupada", memoryRatio * 100), memoryRatio, c.accent)

  if self.energyStored then
    card(2, 2, "ENERGÍA",
      string.format("%.1f / %.1f kJ", self.energyStored / 1000, self.energyMaximum / 1000),
      string.format("%.0f%% disponible", energyRatio * 100), energyRatio, energyColor)
  else
    card(2, 2, "ENERGÍA", "sin lectura", "El nodo no reporta energía", nil, c.warn)
  end

  if not dense then
    card(1, 3, "ENLACES", tostring(self.components.total) .. " componentes",
      table.concat(topKinds, " · "), nil, c.text)

    if self.storageTotal then
      card(2, 3, "ALMACENAMIENTO",
        ctx.util.humanSize(self.storageUsed) .. " / " .. ctx.util.humanSize(self.storageTotal),
        string.format("%.0f%% del volumen", storageRatio * 100), storageRatio, c.accent)
    else
      card(2, 3, "ALMACENAMIENTO", "sin volumen", "No se pudo leer el disco", nil, c.warn)
    end
  end

  local cardsBottom = dense and (1 + 2 * (CARD_HEIGHT + gap)) or (1 + 3 * (CARD_HEIGHT + gap))
  local logTop = cardsBottom + 1
  if logTop + 3 <= ctx.h then
    local logHeight = ctx.h - logTop + 1
    v:box(1, logTop, ctx.w, logHeight, {
      glyphs = g,
      fg = c.panel,
      bg = c.deep,
      title = "REGISTRO",
      titleFg = c.dim,
      titleBg = c.deep,
    })

    local visible = logHeight - 2
    local entries = ctx.log.tail(visible)
    for index, entry in ipairs(entries) do
      local color = c.text
      if entry.level == 3 then
        color = c.warn
      elseif entry.level == 4 then
        color = c.danger
      end
      local line = string.format("%s  %s  %s", entry.time, entry.tag, entry.message)
      v:put(2, logTop + index, ctx.text.truncate(line, ctx.w - 3), color, c.deep)
    end
  end
end

function dashboard:tick(ctx)
  if ctx.kernel:uptime() - self.samplesAt >= 2 then
    self:refresh(ctx)
  end
  return true
end

function dashboard:handle(ctx, name, char)
  if name == "key" and char == "r" then
    self:refresh(ctx)
    return true
  end
  return false
end

function dashboard:close()
end

return dashboard
