-- Lab: a Lua scratchpad that runs scripts against the running OS, plus a
-- persistent interpreter.
--
-- The script lives at /var/lab/script.lua and every run is appended to
-- /var/log/lab.log, so Files and the Terminal can read the output back.
-- Scripts use the live kernel: kernel, vfs, component, computer, and the OS
-- libraries are available. There is no preemption, so a runaway loop blocks
-- the node until it reboots.
--
-- The Lua tab is the same environment, kept alive: a name assigned on one line
-- is visible on the next. A script run stays fresh every time on purpose; do
-- not merge the two, or a script can start working because of leftover state.

local lab = {}
lab.__index = lab

lab.id = "lab"
lab.title = "Lab"
lab.short = "Lab"
lab.icon = "LAB"
lab.iconArt = {
  "  ┌───┐  ",
  "  │   │  ",
  "  │░░░│  ",
  "  │░░░│  ",
  "  └───┘  ",
}
lab.order = 10

local SCRIPT = "/var/lab/script.lua"
local GUTTER = 4
local MAX_OUTPUT_LINES = 400
local AUTOSAVE_EDITS = 10

local KEY_CTRL_LEFT = 0x1D
local KEY_CTRL_RIGHT = 0x9D
local KEY_SHIFT_LEFT = 0x2A
local KEY_SHIFT_RIGHT = 0x36
local KEY_L = 0x26
local KEY_R = 0x13
local KEY_S = 0x1F
local KEY_C = 0x2E
local KEY_V = 0x2F

-- Tabs are one cell in the buffer but two on screen; every column count and
-- every slice must use the same text the operator sees, or a selection lands
-- one cell off.
local function shown(line)
  return (tostring(line or ""):gsub("\t", "  "))
end

local STARTER = table.concat({
  "-- Lab: this script runs inside TerraCorp OS. print() is captured.",
  'print("node " .. kernel.hostname .. " · " .. version.product)',
  'for _, kind in ipairs({ "gpu", "screen", "filesystem" }) do',
  "  local count = 0",
  "  for _ in component.list(kind) do",
  "    count = count + 1",
  "  end",
  '  print(string.format("%-11s %d", kind, count))',
  "end",
}, "\n")

function lab.create(ctx)
  local self = setmetatable({}, lab)
  self.hits = {}
  self.lines = { "" }
  self.row = 1
  self.col = 0
  self.top = 1
  self.tab = "script"
  self.output = {}
  self.outScroll = 0
  self.runs = 0
  self.edits = 0
  self.dirty = false
  self.ctrl = false
  self.status = nil

  self.runner = ctx.kernel.require("tc.lab").new(ctx.kernel)
  self.session = self.runner:repl()
  self.sessionName = self.session.name
  self.replCell = { "" }
  self.replRow = 1
  self.replCol = 0
  self.replCellTop = 1
  self.replScroll = 0
  self.replHistoryIndex = nil
  self.replDraft = ""
  self.replStatus = nil
  self.selAnchor = nil
  self.selCursor = nil
  self:adoptRequestedTab(ctx)

  local vfs = ctx.kernel.vfs
  vfs.ensureDir("/var/lab")
  if vfs.exists(SCRIPT) then
    local content, reason = vfs.read(SCRIPT)
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
      self.status = "Could not read " .. SCRIPT .. ": " .. tostring(reason)
    end
  else
    self.lines = ctx.util.split(STARTER, "\n")
    self.dirty = true
    self.status = "Starter script"
  end

  self.row = #self.lines
  self.col = ctx.text.width(self.lines[self.row])

  local history = self.runner:tail(80)
  for _, line in ipairs(history) do
    self.output[#self.output + 1] = line
  end
  if #history > 0 then
    self.status = string.format("%d log %s", #history, #history == 1 and "line" or "lines")
  end

  return self
end

--------------------------------------------------------------------------------
-- Interpreter
--------------------------------------------------------------------------------

-- The Terminal's `lua` asks for the interpreter tab through the module, so it
-- works whether the window was closed or already open: the tab is adopted on
-- the next draw and the request is cleared.
function lab:adoptRequestedTab(ctx)
  if not ctx.kernel.require then
    return
  end
  local module = ctx.kernel.require("tc.lab")
  local wanted = module and module.openTab
  if not wanted then
    return
  end
  module.openTab = nil
  if self.tab ~= wanted then
    self.tab = wanted
    self.outScroll = 0
    self.replScroll = 0
  end
end

-- The input cell grows with the text: Shift+Enter adds a line, so a table or a
-- function can be written the way it would be in a file. Enter runs the cell.
function lab:replCellRows(ctx)
  local limit = math.max(1, ctx.h - 4)
  return math.max(1, math.min(#self.replCell, limit))
end

function lab:replRows(ctx)
  -- Rows 3..h-2 belong to the pane; the input cell sits above the footer.
  return math.max(1, ctx.h - 3 - self:replCellRows(ctx))
end

-- `:new`, `:use` and `:drop` move the active session from inside the pane, so
-- every read goes through here and a switch resets the cell and the scroll.
function lab:activeSession()
  local session = self.runner:repl()
  if session.name ~= self.sessionName then
    self.sessionName = session.name
    self.session = session
    self:cellReset()
    self.replScroll = 0
    self.replHistoryIndex = nil
    self.replDraft = ""
    self.replStatus = nil
    -- Selection indices point into the old session's transcript.
    self:clearSelection()
  end
  return self.session
end

function lab:scrollRepl(ctx, amount)
  -- Scroll counts logical lines; each one occupies at least one screen row, so
  -- the last line must stay reachable.
  local maximum = math.max(0, #self:activeSession().transcript - 1)
  self.replScroll = ctx.util.clamp((self.replScroll or 0) + amount, 0, maximum)
end

--------------------------------------------------------------------------------
-- Selection
--
-- Shift+arrows walk a cursor over the pane text, a mouse drag selects what the
-- pointer crosses, and Ctrl+C copies that span to the OS clipboard, which
-- Ctrl+V pastes into the input. OpenComputers has no clipboard API to write
-- to, so this stays inside TerraCorp: getting text out of the game is a
-- different problem (the mod only sends clipboard text in).
--------------------------------------------------------------------------------

-- The text that can be selected, by tab. The script editor selects its code;
-- the two panes select their transcript.
function lab:transcriptFor(tab)
  if tab == "output" then
    return self.output
  elseif tab == "repl" then
    return self:activeSession().transcript
  elseif tab == "script" then
    return self.lines
  end
  return nil
end

-- The text as it is measured: panes draw tabs expanded, the editor draws the
-- line as it is, so columns must use the same string in both directions.
function lab:displayFor(tab, line)
  if tab == "script" then
    return tostring(line or "")
  end
  return shown(line)
end

function lab:clearSelection()
  self.selAnchor = nil
  self.selCursor = nil
  self.selecting = false
end

function lab:selectionActive()
  return self.selAnchor ~= nil and self.selCursor ~= nil
end

function lab:orderedSelection()
  local anchor, cursor = self.selAnchor, self.selCursor
  if anchor.line < cursor.line or (anchor.line == cursor.line and anchor.col <= cursor.col) then
    return anchor, cursor
  end
  return cursor, anchor
end

function lab:moveSelection(ctx, code)
  local lines = self:transcriptFor(self.tab)
  if not lines or #lines == 0 then
    return false
  end

  if not self:selectionActive() then
    if self.tab == "script" then
      -- In the editor the caret is the anchor, the way a text cursor works.
      self.selAnchor = { line = self.row, col = self.col }
      self.selCursor = { line = self.row, col = self.col }
    else
      local last = self:displayFor(self.tab, lines[#lines])
      self.selAnchor = { line = #lines, col = ctx.text.width(last) }
      self.selCursor = { line = #lines, col = ctx.text.width(last) }
    end
  end

  local cursor = self.selCursor
  local width = ctx.text.width(self:displayFor(self.tab, lines[cursor.line] or ""))

  if code == 0xCD then
    cursor.col = cursor.col + 1
    if cursor.col > width and cursor.line < #lines then
      cursor.line = cursor.line + 1
      cursor.col = 0
    else
      cursor.col = math.min(cursor.col, width)
    end
  elseif code == 0xCB then
    cursor.col = cursor.col - 1
    if cursor.col < 0 and cursor.line > 1 then
      cursor.line = cursor.line - 1
      cursor.col = ctx.text.width(self:displayFor(self.tab, lines[cursor.line] or ""))
    else
      cursor.col = math.max(0, cursor.col)
    end
  elseif code == 0xD0 then
    cursor.line = math.min(#lines, cursor.line + 1)
    cursor.col = math.min(cursor.col, ctx.text.width(self:displayFor(self.tab, lines[cursor.line] or "")))
  elseif code == 0xC8 then
    cursor.line = math.max(1, cursor.line - 1)
    cursor.col = math.min(cursor.col, ctx.text.width(self:displayFor(self.tab, lines[cursor.line] or "")))
  elseif code == 0xC7 then
    cursor.col = 0
  elseif code == 0xCF then
    cursor.col = width
  else
    return false
  end

  return true
end

-- Wrap one displayed line at the pane width. Character wrapping, not word
-- wrapping: a table row or a stack trace keeps its own layout.
local function wrapLine(ctx, text, width)
  if text == "" or width < 1 then
    return { text }
  end

  local pieces = {}
  local position, count = 1, ctx.text.width(text)
  while position <= count do
    local piece = ctx.text.slice(text, position, position + width - 1)
    pieces[#pieces + 1] = piece
    position = position + ctx.text.width(piece)
  end
  return pieces
end

-- Visual rows that fill `rows` from the end of `lines`, skipping `scroll`
-- logical lines. Each entry is one screen row: { text, index, start }.
function lab:visualRows(ctx, lines, rows, scroll)
  local collected = {}
  local filled = 0
  local index = #lines - (scroll or 0)

  while index >= 1 and filled < rows do
    local pieces = wrapLine(ctx, shown(lines[index]), ctx.w)
    for offset = #pieces, 1, -1 do
      table.insert(collected, 1, {
        text = pieces[offset],
        index = index,
        start = (offset - 1) * ctx.w,
      })
    end
    filled = filled + #pieces
    index = index - 1
  end

  return collected
end

-- Draw the selected span of one screen row if its logical line is selected.
-- `row.start` is the first column of the row inside the logical line, so a
-- wrapped row paints only its own intersection with the selection.
function lab:paintSelection(ctx, row, y)
  if not self:selectionActive() then
    return
  end

  local from, to = self:orderedSelection()
  local index = row.index
  if index < from.line or index > to.line then
    return
  end

  local rowWidth = ctx.text.width(row.text)
  local startCol = index == from.line and from.col or 0
  local endCol = index == to.line and to.col or math.huge
  local first = math.max(startCol, row.start)
  local last = math.min(endCol, row.start + rowWidth)
  if last <= first then
    return
  end

  local span = ctx.text.slice(row.text, first - row.start + 1, last - row.start)
  if span ~= "" then
    ctx.view:put(1 + first, y, span, ctx.colors.deep, ctx.colors.accent)
  end
end

-- Draw a transcript or output pane with wrapping, newest lines at the bottom.
function lab:drawPaneText(ctx, lines, top, rows, scroll)
  local visual = self:visualRows(ctx, lines, rows, scroll)
  local from = math.max(1, #visual - rows + 1)

  for position = from, #visual do
    local row = visual[position]
    local line = lines[row.index]
    local fg = ctx.colors.text
    if line:sub(1, 3) == "===" then
      fg = ctx.colors.accent
    elseif line:sub(1, 1) == "!" then
      fg = ctx.colors.danger
    elseif line:sub(1, 1) == ">" or line:sub(1, 3) == "..." then
      fg = ctx.colors.dim
    end

    local y = top + (position - from)
    ctx.view:put(1, y, row.text, fg, ctx.colors.deep)
    self:paintSelection(ctx, row, y)
  end
end

function lab:copySelection(ctx)
  local lines = self:transcriptFor(self.tab)
  local message

  if not lines then
    message = "nothing to select in this tab"
  elseif not self:selectionActive() then
    message = "no selection: drag the mouse or hold Shift and use the arrows"
  else
    local from, to = self:orderedSelection()
    local parts = {}
    for index = from.line, to.line do
      local line = self:displayFor(self.tab, lines[index] or "")
      local startCol = index == from.line and from.col or 0
      local endCol = index == to.line and to.col or ctx.text.width(line)
      if endCol > startCol then
        parts[#parts + 1] = ctx.text.slice(line, startCol + 1, endCol)
      else
        parts[#parts + 1] = ""
      end
    end
    local text = table.concat(parts, "\n")
    local count = self.runner:copy(text)
    message = string.format("copied %d %s to the OS clipboard", count, count == 1 and "char" or "chars")
  end

  self.status = message
  self.replStatus = message
end

function lab:pasteClipboard(ctx)
  local text = self.runner:clipped()
  if text == "" then
    self.status = "OS clipboard empty · Insert pastes from Minecraft"
    self.replStatus = self.status
    return
  end

  if self.tab == "repl" then
    self:cellPaste(ctx, text)
  elseif self.tab == "script" then
    self:scriptPaste(ctx, text)
  else
    self.status = "switch to Lua or Script to paste"
    self.replStatus = self.status
  end
end

function lab:cellReset()
  self.replCell = { "" }
  self.replRow = 1
  self.replCol = 0
  self.replCellTop = 1
end

function lab:cellSource()
  return table.concat(self.replCell, "\n")
end

function lab:cellSet(ctx, text)
  self.replCell = ctx.util.split(tostring(text or ""), "\n")
  if #self.replCell == 0 then
    self.replCell = { "" }
  end
  self.replRow = #self.replCell
  self.replCol = ctx.text.width(self.replCell[self.replRow])
  self.replCellTop = math.max(1, self.replRow - (ctx.h - 5))
end

function lab:cellInsert(ctx, value)
  local line = self.replCell[self.replRow]
  self.replCell[self.replRow] = ctx.text.slice(line, 1, self.replCol)
    .. value
    .. ctx.text.slice(line, self.replCol + 1)
  self.replCol = self.replCol + 1
  self.replHistoryIndex = nil
end

-- Split the line at the caret and keep the indentation, opening a block one
-- level deeper when the line ends in `{`, `(` or `then`.
function lab:cellNewline(ctx)
  local line = self.replCell[self.replRow]
  local before = ctx.text.slice(line, 1, self.replCol)
  local after = ctx.text.slice(line, self.replCol + 1)

  local indent = before:match("^( *)") or ""
  if before:match("[%(%[{]%s*$") or before:match("%f[%a](then|do|else|repeat)%s*$") then
    indent = indent .. "  "
  end

  self.replCell[self.replRow] = before
  table.insert(self.replCell, self.replRow + 1, indent .. after)
  self.replRow = self.replRow + 1
  self.replCol = #indent
  self.replHistoryIndex = nil
end

function lab:cellBackspace(ctx)
  if self.replCol > 0 then
    local line = self.replCell[self.replRow]
    self.replCell[self.replRow] = ctx.text.slice(line, 1, self.replCol - 1)
      .. ctx.text.slice(line, self.replCol + 1)
    self.replCol = self.replCol - 1
  elseif self.replRow > 1 then
    local previous = self.replCell[self.replRow - 1]
    self.replCol = ctx.text.width(previous)
    self.replCell[self.replRow - 1] = previous .. self.replCell[self.replRow]
    table.remove(self.replCell, self.replRow)
    self.replRow = self.replRow - 1
  end
  self.replHistoryIndex = nil
end

function lab:cellDelete(ctx)
  local line = self.replCell[self.replRow]
  if self.replCol < ctx.text.width(line) then
    self.replCell[self.replRow] = ctx.text.slice(line, 1, self.replCol)
      .. ctx.text.slice(line, self.replCol + 2)
  elseif self.replRow < #self.replCell then
    self.replCell[self.replRow] = line .. self.replCell[self.replRow + 1]
    table.remove(self.replCell, self.replRow + 1)
  end
  self.replHistoryIndex = nil
end

-- Pasted text keeps its own line breaks: it already carries the layout the
-- author wrote, so no auto-indent here.
function lab:cellPaste(ctx, text)
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\t", "  ")
  local lines = ctx.util.split(text, "\n")

  for index, line in ipairs(lines) do
    if index > 1 then
      local current = self.replCell[self.replRow]
      self.replCell[self.replRow] = ctx.text.slice(current, 1, self.replCol)
      table.insert(self.replCell, self.replRow + 1, ctx.text.slice(current, self.replCol + 1))
      self.replRow = self.replRow + 1
      self.replCol = 0
    end
    if line ~= "" then
      local current = self.replCell[self.replRow]
      self.replCell[self.replRow] = ctx.text.slice(current, 1, self.replCol)
        .. line
        .. ctx.text.slice(current, self.replCol + 1)
      self.replCol = self.replCol + ctx.text.width(line)
    end
  end

  self.replHistoryIndex = nil
end

function lab:scriptPaste(ctx, text)
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\t", "  ")
  local lines = ctx.util.split(text, "\n")
  local line = self.lines[self.row]
  local before = ctx.text.slice(line, 1, self.col)
  local after = ctx.text.slice(line, self.col + 1)

  self.lines[self.row] = before .. lines[1]
  for index = 2, #lines do
    table.insert(self.lines, self.row + index - 1, lines[index])
  end
  self.row = self.row + #lines - 1
  self.lines[self.row] = self.lines[self.row] .. after
  self.col = ctx.text.width(self.lines[self.row])
  self:changed(ctx)
end

function lab:submitRepl(ctx)
  local source = self:cellSource()
  local result = self:activeSession():submit(source)
  if not result then
    self:cellReset()
    return
  end
  if result.incomplete then
    -- Keep the block visible in the cell and continue it on a new line. The
    -- source stays whole, so the next Enter compiles all of it again.
    self:cellNewline(ctx)
    self.replStatus = "block open · Enter closes it · Shift+Enter newline"
    return
  end

  self:cellReset()
  self:clearSelection()
  self.replHistoryIndex = nil
  self.replDraft = ""

  -- The command may have moved the cursor to another session.
  local session = self:activeSession()
  self.replScroll = 0
  self.replStatus = string.format(
    "%s · lua %d · %s · %d ms",
    session.name,
    session.submissions,
    result.ok and "ok" or "error",
    math.floor(result.duration)
  )
end

function lab:resetRepl(ctx)
  local session = self:activeSession()
  session:reset()
  self:cellReset()
  self.replScroll = 0
  self.replHistoryIndex = nil
  self.replStatus = session.name .. " · every name dropped"
end

-- Up walks back through submitted cells, Down returns toward the draft.
function lab:recallRepl(ctx, direction)
  local history = self:activeSession().history
  if #history == 0 then
    return
  end

  local index = self.replHistoryIndex
  if not index then
    self.replDraft = self:cellSource()
    index = 0
  end

  index = ctx.util.clamp(index + direction, 0, #history)
  self.replHistoryIndex = index
  self:cellSet(ctx, index == 0 and self.replDraft or history[#history - index + 1])
end

function lab:handleRepl(ctx, char, code, shifted, ctrlHeld)
  if code == 0x1C then
    if shifted or ctrlHeld then
      self:cellNewline(ctx)
    else
      self:submitRepl(ctx)
    end
  elseif code == 0x0E then
    self:cellBackspace(ctx)
  elseif code == 0xD3 then
    self:cellDelete(ctx)
  elseif code == 0xCB then
    if self.replCol > 0 then
      self.replCol = self.replCol - 1
    elseif self.replRow > 1 then
      self.replRow = self.replRow - 1
      self.replCol = ctx.text.width(self.replCell[self.replRow])
    end
  elseif code == 0xCD then
    if self.replCol < ctx.text.width(self.replCell[self.replRow]) then
      self.replCol = self.replCol + 1
    elseif self.replRow < #self.replCell then
      self.replRow = self.replRow + 1
      self.replCol = 0
    end
  elseif code == 0xC7 then
    self.replCol = 0
  elseif code == 0xCF then
    self.replCol = ctx.text.width(self.replCell[self.replRow])
  elseif code == 0xC8 then
    if self.replHistoryIndex ~= nil then
      -- Browsing history recalls a whole entry, not the lines of one.
      self:recallRepl(ctx, 1)
    elseif self.replRow > 1 then
      self.replRow = self.replRow - 1
      self.replCol = math.min(self.replCol, ctx.text.width(self.replCell[self.replRow]))
    else
      self:recallRepl(ctx, 1)
    end
  elseif code == 0xD0 then
    if self.replHistoryIndex ~= nil then
      self:recallRepl(ctx, -1)
    elseif self.replRow < #self.replCell then
      self.replRow = self.replRow + 1
      self.replCol = math.min(self.replCol, ctx.text.width(self.replCell[self.replRow]))
    else
      self:recallRepl(ctx, -1)
    end
  elseif code == 0xC9 then
    self:scrollRepl(ctx, self:replRows(ctx))
  elseif code == 0xD1 then
    self:scrollRepl(ctx, -self:replRows(ctx))
  elseif char and #char > 0 and not char:match("^%c$") then
    self:cellInsert(ctx, char)
  else
    return false
  end
  return true
end

--------------------------------------------------------------------------------
-- Editing
--------------------------------------------------------------------------------

function lab:save(ctx)
  local ok, reason = ctx.kernel.vfs.write(SCRIPT, table.concat(self.lines, "\n") .. "\n")
  if not ok then
    self.status = "Could not save: " .. tostring(reason)
    return false
  end

  self.dirty = false
  self.edits = 0
  self.status = "Saved " .. ctx.util.formatClock(true)
  return true
end

function lab:changed(ctx)
  self.dirty = true
  self.edits = self.edits + 1
  if self.edits >= AUTOSAVE_EDITS then
    self:save(ctx)
  end
end

function lab:insert(ctx, value)
  local line = self.lines[self.row]
  self.lines[self.row] = ctx.text.slice(line, 1, self.col)
    .. value
    .. ctx.text.slice(line, self.col + 1)
  self.col = self.col + ctx.text.width(value)
  self:changed(ctx)
end

-- Copy the current indentation into the new line, and open a block one level
-- deeper. Tab switches panes, so indentation must come from here.
function lab:newline(ctx)
  local line = self.lines[self.row]
  local before = ctx.text.slice(line, 1, self.col)
  local after = ctx.text.slice(line, self.col + 1)

  local indent = before:match("^( *)") or ""
  if before:match("[%(%[{]%s*$") or before:match("%f[%a](then|do|else|repeat)%s*$") then
    indent = indent .. "  "
  end

  self.lines[self.row] = before
  table.insert(self.lines, self.row + 1, indent .. after)
  self.row = self.row + 1
  self.col = #indent
  self:save(ctx)
end

function lab:backspace(ctx)
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

function lab:deleteForward(ctx)
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

function lab:visibleRows(ctx)
  return math.max(1, ctx.h - 3)
end

function lab:ensureVisible(ctx)
  local visible = self:visibleRows(ctx)
  if self.row < self.top then
    self.top = self.row
  elseif self.row >= self.top + visible then
    self.top = self.row - visible + 1
  end

  local maxTop = math.max(1, #self.lines - visible + 1)
  self.top = ctx.util.clamp(self.top, 1, maxTop)
end

--------------------------------------------------------------------------------
-- Running
--------------------------------------------------------------------------------

function lab:run(ctx)
  self:save(ctx)
  self.runs = self.runs + 1

  local result = self.runner:execute(table.concat(self.lines, "\n"), SCRIPT)
  for _, line in ipairs(result.lines) do
    self.output[#self.output + 1] = line
  end
  while #self.output > MAX_OUTPUT_LINES do
    table.remove(self.output, 1)
  end

  self.tab = "output"
  self.outScroll = 0
  self:clearSelection()
  self.status = string.format(
    "run %d · %s · %d ms",
    self.runs,
    result.ok and "ok" or "error",
    math.floor(result.duration)
  )
end

function lab:scrollOutput(ctx, amount)
  local maximum = math.max(0, #self.output - 1)
  self.outScroll = ctx.util.clamp((self.outScroll or 0) + amount, 0, maximum)
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

function lab:drawTabs(ctx)
  local c = ctx.colors
  local v = ctx.view
  local x = 1

  for _, item in ipairs({
    { id = "script", label = " Script " },
    { id = "repl", label = " Lua " },
    { id = "output", label = " Output " },
  }) do
    local active = self.tab == item.id
    local label = "[" .. item.label .. "]"
    local width = ctx.text.width(label)
    if x + width - 1 > ctx.w then
      break
    end
    v:put(x, 1, label, active and c.onAccent or c.dim, active and c.accent or c.deep)
    self.hits[#self.hits + 1] = { x = x, y = 1, w = width, action = "tab:" .. item.id }
    x = x + width + 1
  end

  -- The interpreter has no Run button: Enter submits. It offers the one
  -- action a transcript cannot: throwing the environment away.
  local action
  if self.tab == "repl" then
    action = { label = "[ Reset ]", hit = "repl-reset", bg = c.warn }
  else
    action = { label = "[ Run ]", hit = "run", bg = c.ok }
  end

  local actionWidth = ctx.text.width(action.label)
  local actionX = ctx.w - actionWidth + 1
  if actionX > x + 1 then
    v:put(actionX, 1, action.label, c.onAccent, action.bg)
    self.hits[#self.hits + 1] = { x = actionX, y = 1, w = actionWidth, action = action.hit }
  end
end

function lab:drawScript(ctx, top)
  local c = ctx.colors
  local v = ctx.view
  local rows = self:visibleRows(ctx)

  self:ensureVisible(ctx)
  local width = math.max(1, ctx.w - GUTTER)
  for index = self.top, math.min(#self.lines, self.top + rows - 1) do
    local y = top + (index - self.top)
    v:fill(1, y, GUTTER, 1, " ", c.dim, c.panel)
    v:put(1, y, string.format("%3d", index), c.dim, c.panel)

    local line = self.lines[index]
    local start = 0
    if index == self.row and self.col >= width then
      -- Keep the caret on screen for long lines without wrapping.
      start = self.col - width + 1
    end
    v:put(GUTTER + 1, y, ctx.text.slice(line, start + 1, start + width), c.text, c.deep)

    -- Mouse or Shift selection: paint the intersection with the visible slice
    -- before the caret so the caret stays on top.
    if self:selectionActive() then
      local from, to = self:orderedSelection()
      if index >= from.line and index <= to.line then
        local lineWidth = ctx.text.width(line)
        local startCol = index == from.line and from.col or 0
        local endCol = index == to.line and to.col or lineWidth
        local first = math.max(startCol, start)
        local last = math.min(endCol, start + width)
        if last > first then
          local span = ctx.text.slice(line, first + 1, last)
          v:put(GUTTER + 1 + (first - start), y, span, c.deep, c.accent)
        end
      end
    end

    if index == self.row then
      local caret = self.col - start
      local glyph = ctx.text.charAt(line, self.col + 1) or " "
      v:put(GUTTER + 1 + caret, y, glyph, c.deep, c.accent)
    end
  end
end

function lab:drawOutput(ctx, top)
  local c = ctx.colors
  local v = ctx.view
  local rows = self:visibleRows(ctx)

  if #self.output == 0 then
    v:put(1, top, "No runs yet: press Run or Ctrl+R.", c.dim, c.deep)
    return
  end

  self.outScroll = ctx.util.clamp(self.outScroll or 0, 0, math.max(0, #self.output - 1))
  self:drawPaneText(ctx, self.output, top, rows, self.outScroll)
end

function lab:drawRepl(ctx, top)
  local c = ctx.colors
  local v = ctx.view
  local rows = self:replRows(ctx)
  local cellRows = self:replCellRows(ctx)
  local session = self:activeSession()
  local transcript = session.transcript

  if #transcript == 0 then
    v:put(1, top, session.name .. " · type Lua, or :help for sessions.", c.dim, c.deep)
    if rows > 1 then
      v:put(1, top + 1, "Shift+Enter adds a line; Enter runs the cell.", c.dim, c.deep)
      if rows > 2 then
        v:put(1, top + 2, "Assignments persist; `local` does not.", c.dim, c.deep)
      end
    end
  else
    self.replScroll = ctx.util.clamp(self.replScroll or 0, 0, math.max(0, #transcript - 1))
    self:drawPaneText(ctx, transcript, top, rows, self.replScroll)
  end

  -- Input cell: the last line sits on h-1 and extra lines grow upwards. The
  -- prompt tells a fresh cell from a block the interpreter is still waiting on.
  local prompt = session:prompt()
  local promptWidth = ctx.text.width(prompt)
  local inputTop = (ctx.h - 1) - cellRows + 1

  if self.replRow < self.replCellTop then
    self.replCellTop = self.replRow
  elseif self.replRow >= self.replCellTop + cellRows then
    self.replCellTop = self.replRow - cellRows + 1
  end

  for offset = 0, cellRows - 1 do
    local index = self.replCellTop + offset
    local line = self.replCell[index]
    if not line then
      break
    end

    local y = inputTop + offset
    v:fill(1, y, ctx.w, 1, " ", c.text, c.panel)
    if index == 1 then
      v:put(1, y, prompt, c.accent, c.panel)
    else
      v:put(1, y, "  .. ", c.dim, c.panel)
    end

    local available = math.max(1, ctx.w - promptWidth - 1)
    local start = 0
    if index == self.replRow and self.replCol >= available then
      start = self.replCol - available + 1
    end
    v:put(1 + promptWidth, y, ctx.text.slice(line, start + 1, start + available), c.text, c.panel)

    if index == self.replRow then
      local caretX = 1 + promptWidth + (self.replCol - start)
      local glyph = ctx.text.charAt(line, self.replCol + 1) or " "
      v:put(caretX, y, glyph, c.deep, c.accent)
    end
  end
end

function lab:drawFooter(ctx)
  local c = ctx.colors
  local v = ctx.view
  local y = ctx.h

  local status
  if self.tab == "repl" then
    -- The editor's unsaved marker has nothing to say about the interpreter.
    local session = self:activeSession()
    status = self.replStatus or (session.name .. " · ready")
  else
    status = self.dirty and "Unsaved · Ctrl+S saves" or (self.status or "")
  end
  status = ctx.text.truncate(status, ctx.w)
  v:put(1, y, status, self.dirty and self.tab ~= "repl" and c.warn or c.dim, c.deep)

  local hint
  if self.tab == "output" then
    local rows = self:visibleRows(ctx)
    local last = #self.output - (self.outScroll or 0)
    local first = math.max(1, last - rows + 1)
    hint = #self.output > rows
      and string.format("Tab: script · %d-%d/%d · PgUp/PgDn", first, math.max(first, last), #self.output)
      or "Tab: script"
  elseif self.tab == "repl" then
    hint = #self:activeSession().pending > 0
      and "Enter continues the block · Shift+Enter newline"
      or "Enter run · Shift+Enter newline · :help"
  else
    hint = "Tab: lua · Ctrl+R run · Ctrl+S save"
  end

  if ctx.w >= ctx.text.width(hint) + ctx.text.width(status) + 3 then
    v:textRight(ctx.w, y, hint, c.dim, c.deep)
  end
end

function lab:draw(ctx)
  local c = ctx.colors
  local g = ctx.glyphs
  local v = ctx.view

  v:clear(" ", c.text, c.deep)
  self.hits = {}
  self:adoptRequestedTab(ctx)

  if ctx.h < 4 then
    v:put(1, 1, "Window too small", c.warn, c.deep)
    return
  end

  self:drawTabs(ctx)
  v:hline(1, 2, ctx.w, g.h, c.panel, c.deep)

  if self.tab == "output" then
    self:drawOutput(ctx, 3)
  elseif self.tab == "repl" then
    self:drawRepl(ctx, 3)
  else
    self:drawScript(ctx, 3)
  end

  self:drawFooter(ctx)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

-- The visual row at content row `y`, with the same window the draw uses.
function lab:visualRowAt(ctx, lines, top, rows, scroll, y)
  if #lines == 0 or y < top then
    return nil
  end
  local visual = self:visualRows(ctx, lines, rows, scroll)
  local from = math.max(1, #visual - rows + 1)
  return visual[from + (y - top)]
end

-- Map a pointer position to a logical character position in the current tab.
function lab:pointAt(ctx, x, y)
  if self.tab == "repl" then
    local rows = self:replRows(ctx)
    if y < 3 or y > 2 + rows then
      return nil
    end
    local lines = self:activeSession().transcript
    local row = self:visualRowAt(ctx, lines, 3, rows, self.replScroll, y)
    if not row then
      return nil
    end
    local width = ctx.text.width(row.text)
    return { line = row.index, col = ctx.util.clamp(row.start + (x - 1), row.start, row.start + width) }
  elseif self.tab == "output" then
    local rows = self:visibleRows(ctx)
    if y < 3 or y > ctx.h - 1 then
      return nil
    end
    local row = self:visualRowAt(ctx, self.output, 3, rows, self.outScroll, y)
    if not row then
      return nil
    end
    local width = ctx.text.width(row.text)
    return { line = row.index, col = ctx.util.clamp(row.start + (x - 1), row.start, row.start + width) }
  elseif self.tab == "script" then
    if y < 3 or y > ctx.h - 1 or #self.lines == 0 then
      return nil
    end
    local index = ctx.util.clamp(self.top + (y - 3), 1, #self.lines)
    local line = self.lines[index]
    local visible = math.max(1, ctx.w - GUTTER)
    local start = 0
    if index == self.row and self.col >= visible then
      start = self.col - visible + 1
    end
    local col = ctx.util.clamp(start + (x - GUTTER - 1), 0, ctx.text.width(line))
    return { line = index, col = col }
  end
  return nil
end

-- Clamp a drag past the pane edge to the nearest row so the selection keeps
-- extending instead of freezing.
function lab:edgePoint(ctx, x, y)
  local low, high = 3, ctx.h - 1
  if self.tab == "repl" then
    high = 2 + self:replRows(ctx)
  end
  local point = self:pointAt(ctx, x, ctx.util.clamp(y, low, high))
  if point then
    return point
  end
  return self:pointAt(ctx, x, math.max(3, high))
end

function lab:startSelection(point)
  self.selAnchor = { line = point.line, col = point.col }
  self.selCursor = { line = point.line, col = point.col }
  self.selecting = true
end

-- Drag the mouse over a pane or the editor: the anchor stays where the press
-- landed and the cursor follows the pointer.
function lab:dragSelection(ctx, x, y)
  if not self.selecting then
    return false
  end
  local point = self:pointAt(ctx, x, y) or self:edgePoint(ctx, x, y)
  if point then
    self.selCursor = { line = point.line, col = point.col }
  end
  return true
end

function lab:dropSelection(ctx)
  if not self.selecting then
    return false
  end
  self.selecting = false
  -- A press without movement is a click: place the caret, leave no selection.
  if self:selectionActive()
    and self.selAnchor.line == self.selCursor.line
    and self.selAnchor.col == self.selCursor.col then
    self:clearSelection()
  end
  return true
end

function lab:touch(ctx, x, y)
  for _, hit in ipairs(self.hits) do
    if y == hit.y and x >= hit.x and x < hit.x + hit.w then
      if hit.action == "run" then
        self:run(ctx)
      elseif hit.action == "repl-reset" then
        self:resetRepl(ctx)
      else
        self.tab = hit.action:sub(5)
        self.outScroll = 0
        self.replScroll = 0
        self:clearSelection()
      end
      return true
    end
  end

  if self.tab == "repl" and y >= ctx.h - self:replCellRows(ctx) and y <= ctx.h - 1 then
    -- Clicking the input places the caret on the cell line the pointer landed.
    local promptWidth = ctx.text.width(self:activeSession():prompt())
    local index = self.replCellTop + (y - ((ctx.h - 1) - self:replCellRows(ctx) + 1))
    self.replRow = ctx.util.clamp(index, 1, #self.replCell)
    self.replCol = ctx.util.clamp(x - promptWidth, 0, ctx.text.width(self.replCell[self.replRow]))
    self:clearSelection()
    return true
  end

  local point = self:pointAt(ctx, x, y)
  if point then
    if self.tab == "script" then
      self.row = point.line
      self.col = point.col
    end
    self:startSelection(point)
    return true
  end

  return false
end

function lab:handle(ctx, name, a, b, c)
  if name == "touch" then
    return self:touch(ctx, a, b)
  end

  if name == "drag" then
    return self:dragSelection(ctx, a, b)
  end

  if name == "drop" then
    return self:dropSelection(ctx)
  end

  if name == "scroll" then
    if self.tab == "output" then
      self:scrollOutput(ctx, (c and c > 0) and 1 or -1)
      return true
    elseif self.tab == "repl" then
      self:scrollRepl(ctx, (c and c > 0) and 1 or -1)
      return true
    end
    return false
  end

  if name == "key_up" then
    -- A modifier that was let go must not stay held for the next key.
    if b == KEY_CTRL_LEFT or b == KEY_CTRL_RIGHT then
      self.ctrl = false
    elseif b == KEY_SHIFT_LEFT or b == KEY_SHIFT_RIGHT then
      self.shift = false
    end
    return true
  end

  if name == "paste" then
    if self.tab == "repl" then
      self:cellPaste(ctx, a)
    elseif self.tab == "script" then
      self:scriptPaste(ctx, a)
    else
      self.status = "switch to Lua or Script to paste"
      self.replStatus = self.status
    end
    return true
  end

  if name ~= "key" then
    return false
  end

  local char, code = a, b

  -- Ctrl and Shift arrive as their own events and stay held until key_up.
  -- OpenComputers does not resend them, so clearing the flag after the first
  -- key would drop a modifier the player is still pressing: the second
  -- Shift+Enter would submit, and the second Shift+arrow would stop selecting.
  if code == KEY_CTRL_LEFT or code == KEY_CTRL_RIGHT then
    self.ctrl = true
    return true
  end

  if code == KEY_SHIFT_LEFT or code == KEY_SHIFT_RIGHT then
    self.shift = true
    return true
  end

  -- A printable key is never a Ctrl chord in OpenComputers (chords arrive with
  -- no text), so clear a Ctrl that never reported its release. Shift is not
  -- cleared: it legitimately stays down while the operator types capitals.
  if char ~= nil then
    self.ctrl = false
  end

  -- A chord key arrives without text; a printable key is never a shortcut.
  local ctrlHeld = self.ctrl == true and char == nil
  local shifted = self.shift == true

  if ctrlHeld then
    if code == KEY_R then
      if self.tab == "repl" then
        self:submitRepl(ctx)
      else
        self:run(ctx)
      end
      return true
    elseif code == KEY_S then
      self:save(ctx)
      return true
    elseif code == KEY_L then
      self.runner:clear()
      self.runner:clearSessionTranscripts()
      self:clearSelection()
      self.output = {}
      self.outScroll = 0
      self.replScroll = 0
      self.status = "Log cleared"
      self.replStatus = "Log cleared"
      return true
    elseif code == KEY_C then
      self:copySelection(ctx)
      return true
    elseif code == KEY_V then
      self:pasteClipboard(ctx)
      return true
    end
  end

  -- Shift+arrows select over the pane text instead of scrolling it.
  if shifted and (code == 0xCB or code == 0xCD or code == 0xC8 or code == 0xD0
      or code == 0xC7 or code == 0xCF) then
    if self:moveSelection(ctx, code) then
      return true
    end
  elseif not shifted and code then
    -- Any other key drops the selection, so the pane scrolls normally again.
    if code ~= 0x0F then
      self:clearSelection()
    end
  end

  if code == 0x0F then
    if self.tab == "script" then
      self.tab = "repl"
    elseif self.tab == "repl" then
      self.tab = "output"
    else
      self.tab = "script"
    end
    self.outScroll = 0
    self.replScroll = 0
    self:clearSelection()
    return true
  end

  if self.tab == "repl" then
    return self:handleRepl(ctx, char, code, shifted, ctrlHeld)
  end

  if self.tab == "output" then
    local rows = self:visibleRows(ctx)
    if code == 0xC8 then
      self:scrollOutput(ctx, 1)
    elseif code == 0xD0 then
      self:scrollOutput(ctx, -1)
    elseif code == 0xC9 then
      self:scrollOutput(ctx, rows)
    elseif code == 0xD1 then
      self:scrollOutput(ctx, -rows)
    elseif code == 0xC7 then
      self:scrollOutput(ctx, #self.output)
    elseif code == 0xCF then
      self.outScroll = 0
    elseif code == 0x1C then
      self.tab = "script"
    else
      return false
    end
    return true
  end

  if code == 0x1C then
    self:newline(ctx)
    return true
  elseif code == 0x0E then
    self:backspace(ctx)
    return true
  elseif code == 0xD3 then
    self:deleteForward(ctx)
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

function lab:blur(ctx)
  -- Key releases are only routed to the focused app, so leaving the window
  -- must not carry a held modifier into the next app.
  self.ctrl = false
  self.shift = false
  self.selecting = false
  if self.dirty then
    self:save(ctx)
  end
end

function lab:close(ctx)
  self:blur(ctx)
end

return lab
