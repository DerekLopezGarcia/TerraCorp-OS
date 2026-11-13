-- Boot-volume file browser with navigation, file sizes, and text previews.

local files = {}
files.__index = files

files.id = "files"
files.title = "Files"
files.short = "Files"
files.icon = "FIL"
files.iconArt = {
  " ┌───┐   ",
  " │   │   ",
  " ├───┴──┐",
  " │      │",
  " └──────┘",
}
files.order = 2

local MAX_PREVIEW_BYTES = 65536
local MAX_PREVIEW_LINES = 2000

function files.create(ctx)
  local self = setmetatable({}, files)
  self.cwd = "/"
  self.index = 1
  self.offset = 1
  self.focus = "list"
  self.previewTop = 1
  self:reload(ctx)
  return self
end

function files:reload(ctx)
  local vfs = ctx.kernel.vfs
  local names, reason = vfs.list(self.cwd)
  if not names then
    self.entries = {}
    self.error = reason or "Could not read directory"
    return
  end

  self.error = nil
  local entries = {}
  for _, name in ipairs(names) do
    local path = ctx.util.join(self.cwd, name)
    local isDir = vfs.isDirectory(path)
    entries[#entries + 1] = {
      name = name,
      path = path,
      isDir = isDir,
      -- Query file size once per reload, not once per frame.
      size = isDir and nil or vfs.size(path),
    }
  end

  table.sort(entries, function(a, b)
    if a.isDir ~= b.isDir then
      return a.isDir
    end
    return a.name:lower() < b.name:lower()
  end)

  self.entries = entries
  self.index = math.max(1, math.min(self.index, #entries))
  self.offset = 1
  self.focus = "list"
  self:select(ctx, self.index)
end

function files:select(ctx, index)
  self.index = index
  self.preview = nil
  self.previewName = nil
  self.previewTop = 1

  local entry = self.entries[index]
  if not entry or entry.isDir then
    return
  end

  local vfs = ctx.kernel.vfs
  local size = entry.size
  if size == nil then
    -- The file appeared after the last reload, so query its size once.
    size = vfs.size(entry.path)
    entry.size = size
  end

  local content, reason, note
  if size and size > MAX_PREVIEW_BYTES then
    -- Read only the end: a long log stays openable without holding the whole
    -- body in memory.
    content, reason = vfs.readTail(entry.path, MAX_PREVIEW_BYTES)
    note = string.format("tail %d KB", math.floor(MAX_PREVIEW_BYTES / 1024))
  else
    content, reason = vfs.read(entry.path)
  end

  if not content then
    self.preview = { unreadable = true, reason = reason }
    self.previewName = entry.name
    return
  end

  local lines = ctx.util.split((content:gsub("\r", "")), "\n")
  local truncated = false
  if #lines > MAX_PREVIEW_LINES then
    lines = { table.unpack(lines, 1, MAX_PREVIEW_LINES) }
    truncated = true
  end

  self.preview = { lines = lines, truncated = truncated, note = note }
  self.previewName = entry.name
end

function files:open(ctx, index)
  local entry = self.entries[index]
  if not entry then
    return
  end

  self.focus = "list"
  if entry.isDir then
    self.cwd = entry.path
    self.index = 1
    self:reload(ctx)
  else
    self:select(ctx, index)
  end
end

function files:ensureVisible(rows)
  if self.index < self.offset then
    self.offset = self.index
  elseif self.index > self.offset + rows - 1 then
    self.offset = self.index - rows + 1
  end
end

-- Last valid top line of the preview for the current window height.
function files:previewLimit(ctx)
  local _, _, _, rows = self:layout(ctx)
  local lines = self.preview and self.preview.lines
  if not lines then
    return 1
  end
  return math.max(1, #lines - rows + 1)
end

function files:scrollPreview(ctx, delta)
  if not (self.preview and self.preview.lines) then
    return
  end
  self.previewTop = ctx.util.clamp((self.previewTop or 1) + delta, 1, self:previewLimit(ctx))
end

function files:layout(ctx)
  local showPreview = ctx.w >= 44
  local listWidth = showPreview and ctx.util.clamp(math.floor(ctx.w * 0.42), 18, ctx.w - 14) or ctx.w
  local bodyHeight = math.max(3, ctx.h - 2)
  return showPreview, listWidth, bodyHeight, math.max(1, bodyHeight - 2)
end

function files:draw(ctx)
  local c = ctx.colors
  local g = ctx.glyphs
  local v = ctx.view

  v:clear(" ", c.text, c.deep)

  local showPreview, listWidth, bodyHeight, rows = self:layout(ctx)

  v:put(1, 1, g.mark .. " " .. ctx.text.truncate(self.cwd, ctx.w - 20), c.accent, c.deep)
  local counter = tostring(#self.entries) .. ((#self.entries == 1) and " item" or " items")
  v:textRight(ctx.w, 1, counter, c.dim, c.deep)

  v:box(1, 2, listWidth, bodyHeight, { glyphs = g, fg = c.panel, bg = c.deep })

  self:ensureVisible(rows)

  if self.error then
    v:put(3, 4, ctx.text.truncate(self.error, listWidth - 4), c.danger, c.deep)
  elseif #self.entries == 0 then
    v:put(3, 4, "Directory is empty", c.dim, c.deep)
  end

  for row = 1, rows do
    local index = self.offset + row - 1
    local entry = self.entries[index]
    if not entry then
      break
    end

    local y = 2 + row
    local selected = index == self.index
    local fg = selected and c.onSelected or (entry.isDir and c.accent or c.text)
    local bg = selected and c.selected or c.deep

    if selected then
      v:fill(2, y, listWidth - 2, 1, " ", fg, bg)
    end

    local label = entry.isDir and (entry.name .. "/") or entry.name
    local size = ""
    if not entry.isDir then
      local bytes = entry.size
      if bytes and listWidth > 30 then
        if bytes < 1024 then
          size = ctx.util.padLeft(string.format("%d B", bytes), 9)
        else
          size = ctx.util.padLeft(ctx.util.humanSize(bytes / 1024), 9)
        end
      end
    end

    local room = listWidth - 3 - ctx.text.width(size)
    local prefix = entry.isDir and (g.arrow .. " ") or "  "
    v:put(2, y, prefix .. ctx.text.padRight(ctx.text.truncate(label, math.max(1, room)), math.max(1, room)), fg, bg)

    if size ~= "" then
      v:put(2 + listWidth - 2 - ctx.text.width(size), y, size, selected and c.onSelected or c.dim, bg)
    end
  end

  if showPreview then
    local previewX = listWidth + 2
    local previewWidth = ctx.w - previewX + 1
    local entry = self.entries[self.index]
    local lines = self.preview and self.preview.lines
    local visible = math.max(1, bodyHeight - 2)
    local top = 1
    local title = self.previewName or "Preview"

    if lines and #lines > 0 then
      top = ctx.util.clamp(self.previewTop or 1, 1, self:previewLimit(ctx))
      self.previewTop = top
      local last = math.min(#lines, top + visible - 1)
      title = string.format("%s · %d-%d/%d", title, top, last, #lines)
      if self.preview.note then
        title = title .. " · " .. self.preview.note
      elseif self.preview.truncated then
        title = title .. " · truncated"
      end
    end

    local focused = self.focus == "preview"
    v:box(previewX, 2, previewWidth, bodyHeight, {
      glyphs = g,
      fg = focused and c.accent or c.panel,
      bg = c.deep,
      title = title,
      titleFg = focused and c.accent or c.dim,
      titleBg = c.deep,
    })

    if not entry then
      v:put(previewX + 2, 4, "Nothing selected", c.dim, c.deep)
    elseif entry.isDir then
      v:put(previewX + 2, 4, "Directory", c.accent, c.deep)
      v:put(previewX + 2, 5, "Press Enter to open", c.dim, c.deep)
    elseif self.preview and self.preview.unreadable then
      v:put(previewX + 2, 4, "Could not read file", c.danger, c.deep)
      if self.preview.reason then
        v:put(previewX + 2, 5, ctx.text.truncate(tostring(self.preview.reason), previewWidth - 3), c.dim, c.deep)
      end
    elseif lines then
      for offset = 0, visible - 1 do
        local line = lines[top + offset]
        if not line then
          break
        end
        v:put(
          previewX + 2,
          3 + offset,
          ctx.text.truncate((line:gsub("\t", "    ")), previewWidth - 3),
          c.text,
          c.deep
        )
      end
    end
  end

  local hint
  if not showPreview then
    hint = "Up/Down move · Enter open · Backspace up · R reload"
  elseif self.focus == "preview" then
    hint = "Tab list · Up/Down scroll · PgUp/PgDn page · Home/End"
  else
    hint = "Up/Down move · Enter open · Tab preview · Backspace up · R reload"
  end
  v:put(1, ctx.h, ctx.text.truncate(hint, ctx.w), self.focus == "preview" and c.accent or c.dim, c.deep)
end

function files:handle(ctx, name, a, b, c)
  if name == "touch" then
    local localX, localY = a, b
    local showPreview, listWidth = self:layout(ctx)

    if localX >= 1 and localX <= listWidth and localY >= 3 and localY <= ctx.h - 1 then
      local rows = math.max(1, (ctx.h - 2) - 2)
      local index = self.offset + (localY - 3)
      if index <= #self.entries then
        self.focus = "list"
        if index == self.index then
          self:open(ctx, index)
        else
          self:select(ctx, index)
        end
        return true
      end
    elseif showPreview and localX > listWidth then
      self.focus = "preview"
      return true
    end
    return false
  end

  if name == "scroll" then
    local localX, direction = a, c
    local showPreview, listWidth, _, rows = self:layout(ctx)
    local step = (direction and direction > 0) and -1 or 1

    if showPreview and localX > listWidth then
      self.focus = "preview"
      self:scrollPreview(ctx, step)
    else
      self.focus = "list"
      local target = ctx.util.clamp(self.index + step, 1, math.max(1, #self.entries))
      if target ~= self.index then
        self:select(ctx, target)
        self:ensureVisible(rows)
      end
    end
    return true
  end

  if name ~= "key" then
    return false
  end

  local char, code = a, b
  local showPreview, _, _, rows = self:layout(ctx)

  -- The preview scrolls only while it holds focus, so Up/Down keep moving the
  -- file selection in the list.
  if showPreview and self.focus == "preview" then
    if code == 0x0F or code == 0x1C then
      self.focus = "list"
      return true
    elseif code == 0xC8 then
      self:scrollPreview(ctx, -1)
      return true
    elseif code == 0xD0 then
      self:scrollPreview(ctx, 1)
      return true
    elseif code == 0xC9 then
      self:scrollPreview(ctx, -rows)
      return true
    elseif code == 0xD1 then
      self:scrollPreview(ctx, rows)
      return true
    elseif code == 0xC7 then
      self.previewTop = 1
      return true
    elseif code == 0xCF then
      self.previewTop = self:previewLimit(ctx)
      return true
    end
  elseif code == 0x0F and showPreview then
    self.focus = "preview"
    return true
  end

  if code == 0xC8 then
    self:select(ctx, math.max(1, self.index - 1))
    self:ensureVisible(rows)
    return true
  elseif code == 0xD0 then
    self:select(ctx, math.min(#self.entries, self.index + 1))
    self:ensureVisible(rows)
    return true
  elseif code == 0xC9 then
    self:select(ctx, math.max(1, self.index - rows))
    self:ensureVisible(rows)
    return true
  elseif code == 0xD1 then
    self:select(ctx, math.min(#self.entries, self.index + rows))
    self:ensureVisible(rows)
    return true
  elseif code == 0x1C then
    self:open(ctx, self.index)
    return true
  elseif code == 0x0E then
    if self.cwd ~= "/" then
      self.cwd = ctx.util.parent(self.cwd)
      self.index = 1
      self:reload(ctx)
    end
    return true
  elseif char == "r" then
    self:reload(ctx)
    return true
  end

  return false
end

function files:close()
end

return files
