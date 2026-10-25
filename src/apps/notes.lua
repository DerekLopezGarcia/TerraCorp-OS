-- Notes: a persistent scratchpad kept on the boot volume at /var/notes.txt.

local notes = {}
notes.__index = notes

notes.id = "notes"
notes.title = "Notes"
notes.short = "Notes"
notes.icon = "NTS"
notes.iconArt = {
  " ┌────┐  ",
  " │    │╲ ",
  " │ ▄▄ │ │",
  " │ ▄▄ │ │",
  " └────┘─┘",
}
notes.order = 5

local PATH = "/var/notes.txt"
local GUTTER = 4
local FIRST_ROW = 3
local AUTOSAVE_EDITS = 10

function notes.create(ctx)
  local self = setmetatable({}, notes)

  self.hits = {}
  self.top = 1
  self.row = 1
  self.col = 0
  self.edits = 0
  self.dirty = false
  self.saveRect = nil
  self.lines = { "" }

  if ctx.kernel.vfs.exists(PATH) then
    local content, reason = ctx.kernel.vfs.read(PATH)
    if content then
      content = content:gsub("\r", ""):gsub("\n$", "")
      self.lines = ctx.util.split(content, "\n")
      if #self.lines == 0 then
        self.lines = { "" }
      end
      self.status = string.format(
        "Loaded %d %s",
        #self.lines,
        #self.lines == 1 and "line" or "lines"
      )
    else
      self.status = "Could not read notes: " .. tostring(reason)
    end
  else
    self.status = "New note"
  end

  self.row = #self.lines
  self.col = ctx.text.width(self.lines[self.row])
  return self
end

function notes:save(ctx)
  local ok, reason = ctx.kernel.vfs.write(PATH, table.concat(self.lines, "\n") .. "\n")
  if not ok then
    self.status = "Could not save: " .. tostring(reason)
    return false
  end

  self.dirty = false
  self.edits = 0
  self.status = string.format(
    "Saved %s · %d %s",
    os.date("%H:%M"),
    #self.lines,
    #self.lines == 1 and "line" or "lines"
  )
  return true
end

function notes:changed(ctx)
  self.dirty = true
  self.edits = self.edits + 1
  if self.edits >= AUTOSAVE_EDITS then
    self:save(ctx)
  end
end

function notes:insert(ctx, value)
  local line = self.lines[self.row]
  self.lines[self.row] = ctx.text.slice(line, 1, self.col)
    .. value
    .. ctx.text.slice(line, self.col + 1)
  self.col = self.col + ctx.text.width(value)
  self:changed(ctx)
end

function notes:newline(ctx)
  local line = self.lines[self.row]
  local before = ctx.text.slice(line, 1, self.col)
  local after = ctx.text.slice(line, self.col + 1)

  self.lines[self.row] = before
  table.insert(self.lines, self.row + 1, after)
  self.row = self.row + 1
  self.col = 0
  self:save(ctx)
end

function notes:backspace(ctx)
  if self.col > 0 then
    local line = self.lines[self.row]
    self.lines[self.row] = ctx.text.slice(line, 1, self.col - 1)
      .. ctx.text.slice(line, self.col + 1)
    self.col = self.col - 1
  elseif self.row > 1 then
    local previous = self.lines[self.row - 1]
    self.col = ctx.text.width(previous)
    self.lines[self.row - 1] = previous .. self.lines[self.row]
    table.remove(self.lines, self.row)
    self.row = self.row - 1
  else
    return
  end
  self:changed(ctx)
end

function notes:deleteForward(ctx)
  local line = self.lines[self.row]
  if self.col < ctx.text.width(line) then
    self.lines[self.row] = ctx.text.slice(line, 1, self.col)
      .. ctx.text.slice(line, self.col + 2)
  elseif self.row < #self.lines then
    self.lines[self.row] = line .. self.lines[self.row + 1]
    table.remove(self.lines, self.row + 1)
  else
    return
  end
  self:changed(ctx)
end

function notes:visibleRows(ctx)
  return math.max(1, ctx.h - FIRST_ROW)
end

function notes:ensureVisible(ctx)
  local visible = self:visibleRows(ctx)
  if self.row < self.top then
    self.top = self.row
  elseif self.row >= self.top + visible then
    self.top = self.row - visible + 1
  end

  local maxTop = math.max(1, #self.lines - visible + 1)
  if self.top > maxTop then
    self.top = maxTop
  end
  if self.top < 1 then
    self.top = 1
  end
end

function notes:draw(ctx)
  local c = ctx.colors
  local v = ctx.view

  v:clear(" ", c.text, c.deep)
  if ctx.h < 2 then
    return
  end

  v:put(1, 1, "Station notes", c.accent, c.deep)
  self.saveRect = nil

  local saveLabel = " [ Save ] "
  local saveWidth = ctx.text.width(saveLabel)
  if ctx.w >= saveWidth + 16 then
    local saveX = ctx.w - saveWidth + 1
    v:put(saveX, 1, saveLabel, c.onAccent, c.accent)
    self.saveRect = { x = saveX, y = 1, w = saveWidth }
  end

  v:hline(1, 2, ctx.w, ctx.glyphs.h, c.panel, c.deep)

  local visible = self:visibleRows(ctx)
  self:ensureVisible(ctx)
  local available = math.max(1, ctx.w - GUTTER)

  for index = self.top, math.min(#self.lines, self.top + visible - 1) do
    local y = FIRST_ROW + (index - self.top)
    v:put(1, y, string.format("%3d", index), c.dim, c.panel)

    local line = self.lines[index]
    local start = 0
    if index == self.row and self.col >= available then
      -- Keep the caret on screen for long lines without wrapping the buffer.
      start = self.col - available + 1
    end

    v:put(GUTTER + 1, y, ctx.text.slice(line, start + 1, start + available), c.text, c.deep)

    if index == self.row then
      local caret = self.col - start
      local glyph = ctx.text.charAt(line, self.col + 1) or " "
      v:put(GUTTER + 1 + caret, y, glyph, c.deep, c.accent)
    end
  end

  local footer = self.dirty and "Unsaved changes · Enter saves" or self.status
  footer = ctx.text.truncate(footer or "", ctx.w)
  v:put(1, ctx.h, footer, self.dirty and c.warn or c.dim, c.deep)

  local hint = "PgUp/PgDn scroll"
  local hintWidth = ctx.text.width(hint)
  if ctx.w >= hintWidth + ctx.text.width(footer) + 3 then
    v:textRight(ctx.w, ctx.h, hint, c.dim, c.deep)
  end
end

function notes:touch(ctx, x, y)
  local saveRect = self.saveRect
  if saveRect and y == saveRect.y and x >= saveRect.x and x < saveRect.x + saveRect.w then
    self:save(ctx)
    return true
  end

  if y >= FIRST_ROW and y < ctx.h then
    local index = self.top + (y - FIRST_ROW)
    local line = self.lines[index]
    if line then
      self.row = index
      local column = x - GUTTER - 1
      self.col = math.max(0, math.min(column, ctx.text.width(line)))
      return true
    end
  end

  return false
end

function notes:handle(ctx, name, a, b)
  if name == "touch" then
    return self:touch(ctx, a, b)
  end

  if name ~= "key" then
    return false
  end

  local char, code = a, b

  if code == 0x1C then
    self:newline(ctx)
    return true
  elseif code == 0x0E then
    self:backspace(ctx)
    return true
  elseif code == 0xD3 then
    self:deleteForward(ctx)
    return true
  elseif code == 0x0F then
    self:insert(ctx, "  ")
    return true
  elseif code == 0xCB then
    if self.col > 0 then
      self.col = self.col - 1
    elseif self.row > 1 then
      self.row = self.row - 1
      self.col = ctx.text.width(self.lines[self.row])
    end
    return true
  elseif code == 0xCD then
    if self.col < ctx.text.width(self.lines[self.row]) then
      self.col = self.col + 1
    elseif self.row < #self.lines then
      self.row = self.row + 1
      self.col = 0
    end
    return true
  elseif code == 0xC8 then
    if self.row > 1 then
      self.row = self.row - 1
      self.col = math.min(self.col, ctx.text.width(self.lines[self.row]))
    end
    return true
  elseif code == 0xD0 then
    if self.row < #self.lines then
      self.row = self.row + 1
      self.col = math.min(self.col, ctx.text.width(self.lines[self.row]))
    end
    return true
  elseif code == 0xC7 then
    self.col = 0
    return true
  elseif code == 0xCF then
    self.col = ctx.text.width(self.lines[self.row])
    return true
  elseif code == 0xC9 then
    self.row = math.max(1, self.row - self:visibleRows(ctx))
    self.col = math.min(self.col, ctx.text.width(self.lines[self.row]))
    return true
  elseif code == 0xD1 then
    self.row = math.min(#self.lines, self.row + self:visibleRows(ctx))
    self.col = math.min(self.col, ctx.text.width(self.lines[self.row]))
    return true
  end

  if char and #char > 0 and not char:match("^%c$") then
    self:insert(ctx, char)
    return true
  end

  return false
end

function notes:blur(ctx)
  if self.dirty then
    self:save(ctx)
  end
end

function notes:close(ctx)
  self:blur(ctx)
end

return notes
