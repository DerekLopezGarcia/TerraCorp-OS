-- About: product identity, platform information, and credits.

local updater = require("tc.updater")

local about = {}
about.__index = about

about.id = "about"
about.title = "About"
about.short = "About"
about.order = 5

function about.create()
  return setmetatable({ updateState = "check", updateStatus = "Check GitHub Releases for a stable update." }, about)
end

local CREDITS = {
  "TerraCorp OS is original software, not a MineOS fork.",
  "MineOS (Igor Timofeev, MIT) inspired the architecture",
  "and desktop experience for OpenComputers.",
  "",
  "Target platform: Minecraft 1.12.2 + Forge + OpenComputers,",
  "in the Supersymmetry modpack (Susy-Core, GPLv3).",
  "Susy-Core is used as an environment; it is not modified or redistributed.",
  "",
  "This project is licensed under the MIT License. See LICENSE.",
}

function about:draw(ctx)
  local c = ctx.colors
  local v = ctx.view

  v:clear(" ", c.text, c.deep)

  v:put(1, 1, "TERRACORP", c.accent, c.deep)
  v:put(11, 1, "OS", c.text, c.deep)
  local buttonRow = math.max(4, ctx.h - 2)

  if ctx.h >= 9 then
    v:put(1, 2, ctx.version.company .. " · " .. ctx.version.tagline, c.dim, c.deep)
    local info = {
      { "Version", ctx.version.version .. " " .. ctx.version.codename },
      { "App API", tostring(ctx.version.api) },
      { "Node", ctx.kernel.hostname },
      { "Address", ctx.kernel.address },
      { "Boot volume", ctx.kernel.volume.address },
      { "Resolution", ctx.view.w .. "x" .. ctx.view.h },
      { "License", ctx.version.license },
    }

    local row = 4
    for _, pair in ipairs(info) do
      if row >= buttonRow - 1 then
        break
      end
      v:put(2, row, pair[1], c.dim, c.deep)
      v:put(16, row, pair[2], c.text, c.deep)
      row = row + 1
    end

    if ctx.h >= 20 then
      local dividerRow = 12
      v:hline(1, dividerRow, ctx.w, ctx.glyphs.h, c.panel, c.deep)
      for index, line in ipairs(CREDITS) do
        local creditRow = dividerRow + index
        if creditRow >= buttonRow - 1 then
          break
        end
        if line ~= "" then
          v:put(2, creditRow, ctx.text.truncate(line, ctx.w - 2), c.dim, c.deep)
        end
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

function about:updateLabel()
  if self.updateState == "install" and self.release then
    return "Install " .. self.release.version
  elseif self.updateState == "restart" then
    return "Restart to finish update"
  end
  return "Check for updates"
end

function about:handle(ctx, name, x, y)
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
  elseif self.updateState == "install" and self.release then
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

function about:close()
end

return about
