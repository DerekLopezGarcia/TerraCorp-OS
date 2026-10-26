-- Vault pool browser: navigate the shared namespace, read files into the
-- cache, copy in from /var/vault-in, and copy out to /var/vault-out.

local vaultApp = {}
vaultApp.__index = vaultApp

vaultApp.id = "vault"
vaultApp.title = "Vault"
vaultApp.short = "Vault"
vaultApp.icon = "VLT"
vaultApp.iconArt = {
  " ┌─────┐ ",
  " │▓▓▓▓▓│ ",
  " │▓▓▓▓▓│ ",
  " │▓▓▓▓▓│ ",
  " └─────┘ ",
}
vaultApp.order = 8

local INBOX = "/var/vault-in"
local OUTBOX = "/var/vault-out"
local MAX_PREVIEW_LINES = 200

function vaultApp.create(ctx)
  local self = setmetatable({}, vaultApp)
  self.mode = "vault"
  self.vpath = "/"
  self.entries = {}
  self.index = 1
  self.top = 1
  self.waiting = nil
  self.message = "Select a file and press Enter to read it."
  self:reload(ctx)
  return self
end

function vaultApp:cluster(ctx)
  return ctx.kernel.cluster
end

function vaultApp:reload(ctx)
  local cluster = self:cluster(ctx)
  local entries = {}
  if self.mode == "vault" then
    local detail = cluster and cluster:vaultList(self.vpath) or nil
    if detail then
      for _, name in ipairs(detail.dirs) do
        entries[#entries + 1] = { name = name .. "/", isDir = true, path = self.vpath .. name .. "/" }
      end
      for _, file in ipairs(cluster:vaultDetail(self.vpath).files) do
        entries[#entries + 1] = {
          name = file.name,
          isDir = false,
          path = self.vpath .. file.name,
          size = file.size,
        }
      end
      self.message = #entries > 0 and nil or "The vault is empty."
    else
      self.message = "The cluster service is unavailable."
    end
  else
    local vfs = ctx.kernel.vfs
    local names = vfs.list(INBOX)
    if names then
      for _, name in ipairs(names) do
        if not vfs.isDirectory(INBOX .. "/" .. name) then
          entries[#entries + 1] = {
            name = name,
            isDir = false,
            path = INBOX .. "/" .. name,
            size = vfs.size(INBOX .. "/" .. name) or 0,
          }
        end
      end
      self.message = #entries > 0 and nil or INBOX .. " is empty."
    else
      self.message = INBOX .. " does not exist yet."
    end
  end

  table.sort(entries, function(a, b)
    if a.isDir ~= b.isDir then
      return a.isDir
    end
    return a.name:lower() < b.name:lower()
  end)
  self.entries = entries
  self.index = math.max(1, math.min(self.index, math.max(1, #entries)))
  self.selected = nil
  self.preview = nil
end

function vaultApp:notify(message)
  self.message = message
end

function vaultApp:selected()
  return self.entries[self.index]
end

--- Open the selected entry: directories navigate; files start a read and
-- show the cached body as soon as it lands.
function vaultApp:open(ctx)
  local cluster = self:cluster(ctx)
  local entry = self:selected()
  if not entry then
    return
  end

  if entry.isDir then
    self.vpath = entry.path
    self.index = 1
    self:reload(ctx)
    return
  end

  if self.mode == "inbox" then
    self:put(ctx, entry)
    return
  end

  if not cluster then
    return self:notify("The cluster service is unavailable.")
  end
  self.selected = entry.path
  local body = cluster:vaultBody(entry.path)
  if body then
    self:showPreview(ctx, entry, body)
    return
  end
  local ok, reason = cluster:vaultRead(entry.path)
  if ok then
    self.waiting = entry.path
    self:notify("Fetching " .. entry.path .. " ...")
  else
    self:notify(tostring(reason or "Could not start the read."))
  end
end

function vaultApp:showPreview(ctx, entry, body)
  local lines = ctx.util.split((tostring(body):gsub("\r", "")), "\n")
  if #lines > MAX_PREVIEW_LINES then
    lines = { table.unpack(lines, 1, MAX_PREVIEW_LINES) }
    lines[#lines + 1] = "... (truncated)"
  end
  self.preview = lines
  self.previewPath = entry.path
  self:notify(nil)
end

--- Copy the selected local file into the pool as /<name>.
function vaultApp:put(ctx, entry)
  local cluster = self:cluster(ctx)
  if not cluster then
    return self:notify("The cluster service is unavailable.")
  end
  local body = ctx.kernel.vfs.read(entry.path)
  if type(body) ~= "string" then
    return self:notify("Could not read " .. entry.path)
  end
  local ok, reason = cluster:vaultWrite("/" .. entry.name, body)
  if ok then
    self:notify("Storing /" .. entry.name .. " (" .. #body .. " B) ...")
  else
    self:notify(tostring(reason or "Could not start the write."))
  end
end

--- Save the cached body of the selected file to /var/vault-out.
function vaultApp:saveOut(ctx)
  local entry = self:selected()
  if self.mode ~= "vault" or not entry or entry.isDir then
    return
  end
  local cluster = self:cluster(ctx)
  local body = cluster and cluster:vaultBody(entry.path) or nil
  if type(body) ~= "string" then
    return self:notify("Read the file first (Enter), then save it.")
  end
  local vfs = ctx.kernel.vfs
  vfs.ensureDir(OUTBOX)
  local ok, reason = vfs.write(OUTBOX .. "/" .. entry.name, body)
  if ok then
    self:notify("Saved to " .. OUTBOX .. "/" .. entry.name)
  else
    self:notify(tostring(reason or "Could not save the copy."))
  end
end

--- Delete the selected file from the pool.
function vaultApp:remove(ctx)
  local entry = self:selected()
  if self.mode ~= "vault" or not entry or entry.isDir then
    return
  end
  local cluster = self:cluster(ctx)
  if not cluster then
    return self:notify("The cluster service is unavailable.")
  end
  local ok, reason = cluster:vaultRemove(entry.path)
  if ok then
    self:notify("Deleting " .. entry.path .. " ...")
  else
    self:notify(tostring(reason or "Could not start the delete."))
  end
end

function vaultApp:move(ctx, delta)
  local count = math.max(1, #self.entries)
  self.index = math.max(1, math.min(count, self.index + delta))
end

function vaultApp:tick(ctx)
  local cluster = self:cluster(ctx)
  if self.waiting and cluster then
    local body = cluster:vaultBody(self.waiting)
    if body then
      local path = self.waiting
      self.waiting = nil
      for _, entry in ipairs(self.entries) do
        if entry.path == path and not entry.isDir then
          self:showPreview(ctx, entry, body)
          break
        end
      end
      if not self.preview then
        self:showPreview(ctx, { path = path, name = path }, body)
      end
    end
  end
end

function vaultApp:handle(ctx, name, a, b, c)
  local keys = ctx.keys
  if name == "key_down" then
    if a == keys.up then
      self:move(ctx, -1)
      return true
    elseif a == keys.down then
      self:move(ctx, 1)
      return true
    elseif a == keys.enter then
      self:open(ctx)
      return true
    elseif a == keys.back then
      if self.mode == "inbox" then
        self.mode = "vault"
      elseif self.vpath ~= "/" then
        self.vpath = self.vpath:match("^(.*/)[^/]+/$") or "/"
      end
      self.index = 1
      self:reload(ctx)
      return true
    end

    local char = type(b) == "number" and string.char(b) or nil
    if char == "r" then
      self:reload(ctx)
      self:notify("Refreshed.")
      return true
    elseif char == "p" then
      self.mode = self.mode == "inbox" and "vault" or "inbox"
      self.index = 1
      self:reload(ctx)
      return true
    elseif char == "d" then
      self:remove(ctx)
      return true
    elseif char == "s" then
      self:saveOut(ctx)
      return true
    end
  end
  return false
end

local function humanKB(value)
  return string.format("%.1f KB", (tonumber(value) or 0) / 1024)
end

function vaultApp:draw(ctx)
  local c = ctx.colors
  local v = ctx.view
  v:clear(" ", c.text, c.deep)
  if ctx.h < 4 then
    return
  end

  v:put(1, 1, self.mode == "inbox" and "Vault · local inbox" or "Vault pool", c.accent, c.deep)
  local cluster = self:cluster(ctx)
  local usage = cluster and cluster:vaultUsage() or nil
  if usage and usage.total > 0 then
    v:textRight(ctx.w, 1, string.format(
      "%s / %s · %d file(s) · %d disk(s)",
      humanKB(usage.used),
      humanKB(usage.total),
      usage.files,
      #usage.disks
    ), c.dim, c.deep)
  end

  local listWidth = math.min(ctx.w - 2, math.max(24, math.floor(ctx.w * 0.45)))
  for row = 2, ctx.h - 2 do
    local entryIndex = self.top + row - 2
    local entry = self.entries[entryIndex]
    if not entry then
      break
    end
    local selected = entryIndex == self.index
    local fg = selected and c.onSelected or c.text
    local bg = selected and c.selected or c.deep
    local label = entry.name
    if not entry.isDir and entry.size then
      label = label .. "  (" .. humanKB(entry.size) .. ")"
    end
    v:put(1, row, ctx.text.truncate(" " .. label, listWidth), fg, bg)
  end
  v:fill(listWidth + 1, 2, 1, ctx.h - 3, "│", c.dim, c.deep)

  local pane = listWidth + 3
  local width = ctx.w - pane + 1
  if self.message then
    v:put(pane, 2, ctx.text.truncate(tostring(self.message), width), c.warn, c.deep)
  end
  if self.waiting then
    v:put(pane, 3, ctx.text.truncate("Fetching " .. self.waiting .. " ...", width), c.warn, c.deep)
  end
  if self.preview then
    for row = 5, ctx.h - 2 do
      local line = self.preview[row - 4]
      if line == nil then
        break
      end
      v:put(pane, row, ctx.text.truncate(line, width), c.text, c.deep)
    end
  end

  local hints = self.mode == "inbox"
    and "Enter stores · P pool · R refresh"
    or "Enter read · S save out · P inbox · D delete · Back up"
  v:fill(1, ctx.h, ctx.w, 1, " ", c.dim, c.panel)
  v:put(1, ctx.h, ctx.text.truncate(hints, ctx.w), c.dim, c.panel)
end

return vaultApp
