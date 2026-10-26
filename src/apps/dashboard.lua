-- Plant dashboard: node status, memory, power, peripherals, and log.

local dashboard = {}
dashboard.__index = dashboard

dashboard.id = "dashboard"
dashboard.title = "System"
dashboard.short = "System"
dashboard.icon = "SYS"
dashboard.iconArt = {
  "┌───────┐",
  "│ ▄▄▄▄▄ │",
  "│ █████ │",
  "└───┬───┘",
  "  ──┴──  ",
}
dashboard.iconStyle = "accent"
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
  self.tps = kernel:tps()
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

  local tpsColor = c.text
  if type(self.tps) == "number" then
    if self.tps < 15 then
      tpsColor = c.danger
    elseif self.tps < 19 then
      tpsColor = c.warn
    end
  end

  -- Cards follow reading order and wrap to the next row without leaving the window.
  local cards = {
    {
      title = "NODE",
      value = ctx.kernel.hostname,
      detail = ctx.kernel.address:sub(1, 8) .. " · " .. ctx.version.version,
      tint = c.text,
    },
    {
      title = "UPTIME",
      value = ctx.util.humanTime(self.uptime),
      detail = type(self.tps) == "number"
        and string.format("Site %.1f TPS", self.tps)
        or "Session active",
      tint = tpsColor,
    },
    {
      title = "MEMORY",
      value = string.format("%.1f / %.1f MB", self.memoryUsed, self.memoryTotal),
      detail = string.format("%.0f%% used", memoryRatio * 100),
      ratio = memoryRatio,
      tint = c.accent,
    },
  }

  if type(self.energyStored) == "number" and type(self.energyMaximum) == "number" and self.energyMaximum > 0 then
    cards[#cards + 1] = {
      title = "POWER",
      value = string.format("%.1f / %.1f kJ", self.energyStored / 1000, self.energyMaximum / 1000),
      detail = string.format("%.0f%% available", energyRatio * 100),
      ratio = energyRatio,
      tint = energyColor,
    }
  else
    cards[#cards + 1] = {
      title = "POWER",
      value = "unavailable",
      detail = "No power data reported",
      tint = c.warn,
    }
  end

  if not dense then
    cards[#cards + 1] = {
      title = "DEVICES",
      value = tostring(self.components.total) .. " components",
      detail = table.concat(topKinds, " · "),
      tint = c.text,
    }

    if self.storageTotal then
      cards[#cards + 1] = {
        title = "STORAGE",
        value = ctx.util.humanSize(self.storageUsed) .. " / " .. ctx.util.humanSize(self.storageTotal),
        detail = string.format("%.0f%% used", storageRatio * 100),
        ratio = storageRatio,
        tint = c.accent,
      }
    else
      cards[#cards + 1] = {
        title = "STORAGE",
        value = "unavailable",
        detail = "Could not read boot disk",
        tint = c.warn,
      }
    end
  end

  for index, card in ipairs(cards) do
    local column = ((index - 1) % columns) + 1
    local row = math.floor((index - 1) / columns) + 1
    local x = 1 + (column - 1) * (cardWidth + gap)
    local y = 1 + (row - 1) * (CARD_HEIGHT + gap)

    v:box(x, y, cardWidth, CARD_HEIGHT, {
      glyphs = g,
      fg = c.panel,
      bg = c.deep,
      title = card.title,
      titleFg = c.dim,
      titleBg = c.deep,
    })

    v:put(x + 2, y + 2, ctx.text.truncate(card.value, cardWidth - 4), card.tint or c.accent, c.deep)
    if card.ratio then
      v:bar(x + 2, y + 3, math.max(1, cardWidth - 4), card.ratio, card.tint or c.accent, c.deep, g.block)
    end
    v:put(x + 2, y + CARD_HEIGHT - 2, ctx.text.truncate(card.detail or "", cardWidth - 4), c.dim, c.deep)
  end

  local rowsUsed = math.ceil(#cards / columns)
  local cardsBottom = 1 + rowsUsed * (CARD_HEIGHT + gap)
  local logTop = cardsBottom + 1
  if logTop + 3 <= ctx.h then
    local logHeight = ctx.h - logTop + 1
    v:box(1, logTop, ctx.w, logHeight, {
      glyphs = g,
      fg = c.panel,
      bg = c.deep,
      title = "SYSTEM LOG",
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
  local now = ctx.kernel:uptime()
  local changed = self.uptime ~= now
  self.uptime = now

  -- Refresh expensive readings every two seconds, but keep the uptime display
  -- synchronized with the kernel's one-second UI tick.
  if now - self.samplesAt >= 2 then
    self:refresh(ctx)
    changed = true
  end
  return changed
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
