-- Update: product version, system information, and GitHub Releases updates.

local updater = require("tc.updater")

local update = {}
update.__index = update

update.id = "update"
update.title = "Update"
update.short = "Update"
update.icon = "UPD"
update.iconArt = {
  "    │    ",
  "    ▼    ",
  "  ═════  ",
  " ┌─────┐ ",
  " └─────┘ ",
}
update.order = 6

function update.create(ctx)
  local self = setmetatable({ updateState = "check", updateStatus = "Check GitHub Releases for a stable update." }, update)
  self:refreshSystem(ctx)
  return self
end

function update:refreshSystem(ctx)
  local used, total = ctx.kernel:memory()
  local storageUsed, storageTotal = ctx.kernel:storage()
  local components = ctx.kernel:components()
  self.system = {
    memoryUsed = (tonumber(used) or 0) / 1048576,
    memoryTotal = (tonumber(total) or 0) / 1048576,
    storageUsed = storageUsed,
    storageTotal = storageTotal,
    devices = (components and components.total) or 0,
  }
end

local UPDATE_NOTES = {
  "SOURCE: GitHub Releases · stable channel",
  "Updates replace OS files only.",
  "Settings, notes, and the desktop layout are preserved.",
  "The boot volume and BIOS/EEPROM are never rewritten.",
  "Install and restart: the boot applier shows progress.",
}

function update:draw(ctx)
  local c = ctx.colors
  local v = ctx.view

  if not self.statusChecked then
    self.statusChecked = true
    local notice = ctx.kernel.vfs.read("/var/update/status")
    if type(notice) == "string" and notice ~= "" then
      self.updateStatus = notice:gsub("%s+$", "")
      pcall(ctx.kernel.vfs.remove, "/var/update/status")
    end
  end

  if not self.system then
    self:refreshSystem(ctx)
  end

  v:clear(" ", c.text, c.deep)

  v:put(1, 1, "TERRACORP", c.accent, c.deep)
  v:put(11, 1, "UPDATE", c.text, c.deep)
  local buttonRow = math.max(4, ctx.h - 2)

  if ctx.h >= 9 then
    v:put(1, 2, ctx.version.company .. " · " .. ctx.version.tagline, c.dim, c.deep)

    local storage = "unavailable"
    if type(self.system.storageTotal) == "number" and self.system.storageTotal > 0 then
      storage = ctx.util.humanSize(self.system.storageUsed)
        .. " / " .. ctx.util.humanSize(self.system.storageTotal)
    end

    local screen = "unknown"
    local gfx = ctx.kernel.gfx
    if gfx and gfx.w and gfx.h then
      screen = gfx.w .. "x" .. gfx.h
    end

    local product = {
      { "Version", ctx.version.version .. " " .. ctx.version.codename },
      { "App API", tostring(ctx.version.api) .. " · " .. ctx.version.license },
    }
    local system = {
      { "Node", ctx.kernel.hostname },
      { "Memory", string.format("%.1f / %.1f MB",
        self.system.memoryUsed, self.system.memoryTotal) },
      { "Storage", storage },
      { "Screen", screen },
      { "Devices", tostring(self.system.devices) .. " components" },
      { "Boot", ctx.kernel.volumeAddress or "unknown" },
      { "Address", ctx.kernel.address },
    }

    local row = 4
    local showHeaders = ctx.h >= 22
    local function drawPairs(pairs)
      for _, pair in ipairs(pairs) do
        if row >= buttonRow then
          return
        end
        v:put(2, row, pair[1], c.dim, c.deep)
        v:put(16, row, ctx.text.truncate(pair[2], math.max(1, ctx.w - 16)), c.text, c.deep)
        row = row + 1
      end
    end

    if showHeaders then
      v:put(2, row, "RELEASE", c.accent, c.deep)
      row = row + 1
    end
    drawPairs(product)

    if showHeaders then
      if row <= buttonRow - 2 then
        v:put(2, row, "SYSTEM", c.accent, c.deep)
        row = row + 1
      end
    end
    drawPairs(system)

    -- Update notes are secondary. Show them only when the window has room for
    -- the system details, a divider, and a useful part of the notes.
    if ctx.h >= 30 and row <= buttonRow - 3 then
      v:hline(1, row, ctx.w, ctx.glyphs.h, c.panel, c.deep)
      row = row + 1
      for _, line in ipairs(UPDATE_NOTES) do
        if row > buttonRow - 2 then
          break
        end
        v:put(2, row, ctx.text.truncate(line, ctx.w - 2), c.dim, c.deep)
        row = row + 1
      end
    end
  else
    v:put(1, 2, "v" .. ctx.version.version .. " " .. ctx.version.codename, c.dim, c.deep)
  end

  local buttonLabel = "[ " .. self:updateLabel() .. " ]"
  v:textCenter(buttonRow, buttonLabel, c.onAccent, c.accent)
  if buttonRow + 1 < ctx.h then
    v:put(2, buttonRow + 1, ctx.text.truncate(self.updateStatus, ctx.w - 2), c.dim, c.deep)
  end
  if ctx.h >= 9 and ctx.h > 0 then
    v:put(1, ctx.h, "github.com/DerekLopezGarcia/TerraCorp-OS", c.dim, c.deep)
  end
end

function update:updateLabel()
  if self.updateState == "install" and self.release then
    return "Install " .. self.release.version .. " and restart"
  elseif self.updateState == "restart" then
    return "Restart to finish update"
  end
  return "Check for updates"
end

function update:handle(ctx, name, x, y)
  if name == "key" then
    if x == "r" then
      self:refreshSystem(ctx)
      return true
    end
    return false
  end
  if name ~= "touch" then
    return false
  end

  local buttonRow = math.max(4, ctx.h - 2)
  local label = "[ " .. self:updateLabel() .. " ]"
  local buttonX = math.max(1, math.floor((ctx.w - ctx.text.width(label)) / 2) + 1)
  if y ~= buttonRow or x < buttonX or x >= buttonX + ctx.text.width(label) then
    return false
  end

  if self.updateState == "check" then
    local result, reason = updater.check(ctx.version.version)
    if not result then
      self.updateStatus = tostring(reason)
    elseif result.available then
      self.release = result
      self.updateState = "install"
      self.updateStatus = "Version " .. result.version .. " is available."
    else
      self.updateStatus = "TerraCorp OS is up to date (" .. ctx.version.version .. ")."
    end
    return true
  elseif self.updateState == "restart" then
    ctx.kernel:poweroff(true)
    return true
  elseif self.updateState == "install" and self.release then
    if ctx.kernel.vfs.exists("/boot/apply.lua") then
      local queued, reason = updater.schedule(self.release, ctx.version.version, ctx.kernel.vfs)
      if queued then
        -- Close the desktop and reboot into the boot-time applier, which owns
        -- the screen and shows its own progress bar.
        self.updateState = "restart"
        ctx.kernel:poweroff(true)
      else
        self.updateState = "check"
        self.updateStatus = tostring(reason)
      end
      return true
    end

    local ok, count, bytes = updater.install(
      self.release,
      ctx.version.version,
      ctx.kernel.vfs,
      ctx.kernel.volume
    )
    if ok then
      self.updateState = "restart"
      local fileWord = count == 1 and "file" or "files"
      self.updateStatus = string.format("Installed %d %s (%d bytes). Restart to apply.", count, fileWord, bytes)
    else
      self.updateState = "check"
      self.updateStatus = tostring(count)
    end
    return true
  elseif self.updateState == "restart" then
    ctx.kernel:poweroff(true)
    return true
  end

  return false
end

function update:close()
end

return update
