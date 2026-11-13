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
local KEY_L = 0x26
local KEY_R = 0x13
local KEY_S = 0x1F

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
  self.replInput = ""
  self.replCaret = 0
  self.replScroll = 0
  self.replHistoryIndex = nil
  self.replDraft = ""
  self.replStatus = nil
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

function lab:replRows(ctx)
  -- Rows 3..h-2 hold the transcript; the input takes h-1 and the footer h.
  return math.max(1, ctx.h - 4)
end

-- `:new`, `:use` and `:drop` move the active session from inside the pane, so
-- every read goes through here and a switch resets the input and the scroll.
function lab:activeSession()
  local session = self.runner:repl()
  if session.name ~= self.sessionName then
    self.sessionName = session.name
    self.session = session
    self.replInput = ""
    self.replCaret = 0
    self.replScroll = 0
    self.replHistoryIndex = nil
    self.replDraft = ""
    self.replStatus = nil
  end
  return self.session
end

function lab:scrollRepl(ctx, amount)
  local rows = self:replRows(ctx)
  local maximum = math.max(0, #self:activeSession().transcript - rows)
  self.replScroll = ctx.util.clamp((self.replScroll or 0) + amount, 0, maximum)
end

function lab:submitRepl(ctx)
  local result = self:activeSession():submit(self.replInput)
  self.replInput = ""
  self.replCaret = 0
  self.replHistoryIndex = nil
  self.replDraft = ""

  if not result then
    return
  end
  if result.incomplete then
    self.replStatus = "block open: keep typing, Enter closes it"
    return
  end

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
  self.replInput = ""
  self.replCaret = 0
  self.replScroll = 0
  self.replHistoryIndex = nil
  self.replStatus = session.name .. " · every name dropped"
end

-- Up walks back through submitted lines, Down returns toward the draft.
function lab:recallRepl(ctx, direction)
  local history = self:activeSession().history
  if #history == 0 then
    return
  end

  local index = self.replHistoryIndex
  if not index then
    self.replDraft = self.replInput
    index = 0
  end

  index = ctx.util.clamp(index + direction, 0, #history)
  self.replHistoryIndex = index
  self.replInput = index == 0 and self.replDraft or history[#history - index + 1]
  self.replCaret = ctx.text.width(self.replInput)
end

function lab:handleRepl(ctx, char, code)
  if code == 0x1C then
    self:submitRepl(ctx)
  elseif code == 0x0E then
    if self.replCaret > 0 then
      self.replInput = ctx.text.slice(self.replInput, 1, self.replCaret - 1)
        .. ctx.text.slice(self.replInput, self.replCaret + 1)
      self.replCaret = self.replCaret - 1
    end
  elseif code == 0xD3 then
    if self.replCaret < ctx.text.width(self.replInput) then
      self.replInput = ctx.text.slice(self.replInput, 1, self.replCaret)
        .. ctx.text.slice(self.replInput, self.replCaret + 2)
    end
  elseif code == 0xCB then
    self.replCaret = math.max(0, self.replCaret - 1)
  elseif code == 0xCD then
    self.replCaret = math.min(ctx.text.width(self.replInput), self.replCaret + 1)
  elseif code == 0xC7 then
    self.replCaret = 0
  elseif code == 0xCF then
    self.replCaret = ctx.text.width(self.replInput)
  elseif code == 0xC8 then
    self:recallRepl(ctx, 1)
  elseif code == 0xD0 then
    self:recallRepl(ctx, -1)
  elseif code == 0xC9 then
    self:scrollRepl(ctx, self:replRows(ctx))
  elseif code == 0xD1 then
    self:scrollRepl(ctx, -self:replRows(ctx))
  elseif char and #char > 0 and not char:match("^%c$") then
    self.replInput = ctx.text.slice(self.replInput, 1, self.replCaret)
      .. char
      .. ctx.text.slice(self.replInput, self.replCaret + 1)
    self.replCaret = self.replCaret + 1
    self.replHistoryIndex = nil
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
  self.status = string.format(
    "run %d · %s · %d ms",
    self.runs,
    result.ok and "ok" or "error",
    math.floor(result.duration)
  )
end

function lab:scrollOutput(ctx, amount)
  local rows = self:visibleRows(ctx)
  local maximum = math.max(0, #self.output - rows)
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

  self.outScroll = ctx.util.clamp(self.outScroll or 0, 0, math.max(0, #self.output - rows))
  local last = #self.output - self.outScroll
  local first = math.max(1, last - rows + 1)

  for offset = 0, rows - 1 do
    local line = self.output[first + offset]
    if not line then
      break
    end
    local fg = c.text
    if line:sub(1, 3) == "===" then
      fg = c.accent
    elseif line:sub(1, 1) == "!" then
      fg = c.danger
    elseif line:sub(1, 3) == "..." then
      fg = c.dim
    end
    v:put(1, top + offset, ctx.text.truncate((line:gsub("\t", "  ")), ctx.w), fg, c.deep)
  end
end

function lab:drawRepl(ctx, top)
  local c = ctx.colors
  local v = ctx.view
  local rows = self:replRows(ctx)
  local session = self:activeSession()
  local transcript = session.transcript

  if #transcript == 0 then
    v:put(1, top, session.name .. " · type Lua, or :help for sessions.", c.dim, c.deep)
    v:put(1, top + 1, "Assignments persist between lines; `local` does not.", c.dim, c.deep)
  else
    self.replScroll = ctx.util.clamp(self.replScroll or 0, 0, math.max(0, #transcript - rows))
    local last = #transcript - self.replScroll
    local first = math.max(1, last - rows + 1)

    for offset = 0, rows - 1 do
      local line = transcript[first + offset]
      if not line then
        break
      end
      local fg = c.text
      if line:sub(1, 3) == "===" then
        fg = c.accent
      elseif line:sub(1, 1) == "!" then
        fg = c.danger
      elseif line:sub(1, 1) == ">" then
        fg = c.dim
      end
      v:put(1, top + offset, ctx.text.truncate((line:gsub("\t", "  ")), ctx.w), fg, c.deep)
    end
  end

  -- Input line: the prompt tells a fresh line from a block still open.
  local prompt = session:prompt()
  local y = ctx.h - 1
  local available = math.max(1, ctx.w - ctx.text.width(prompt) - 1)
  local start = 0
  if self.replCaret >= available then
    start = self.replCaret - available + 1
  end

  v:fill(1, y, ctx.w, 1, " ", c.text, c.panel)
  v:put(1, y, prompt, c.accent, c.panel)
  v:put(1 + ctx.text.width(prompt), y, ctx.text.slice(self.replInput, start + 1, start + available),
    c.text, c.panel)

  local caretX = 1 + ctx.text.width(prompt) + (self.replCaret - start)
  local glyph = ctx.text.charAt(self.replInput, self.replCaret + 1) or " "
  v:put(caretX, y, glyph, c.deep, c.accent)
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
      and "Enter continues the block · Ctrl+L clears the pane"
      or "Enter run · arrows history · Reset drops every name"
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
      end
      return true
    end
  end

  if self.tab == "repl" and y == ctx.h - 1 then
    -- Clicking the input places the caret where the pointer landed.
    local prompt = ctx.text.width(self:activeSession():prompt())
    self.replCaret = ctx.util.clamp(x - prompt, 0, ctx.text.width(self.replInput))
    return true
  end

  if self.tab == "script" and y >= 3 and y < ctx.h then
    local index = self.top + (y - 3)
    local line = self.lines[index]
    if line then
      self.row = index
      self.col = ctx.util.clamp(x - GUTTER - 1, 0, ctx.text.width(line))
      return true
    end
  end

  return false
end

function lab:handle(ctx, name, a, b, c)
  if name == "touch" then
    return self:touch(ctx, a, b)
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

  if name ~= "key" then
    return false
  end

  local char, code = a, b

  -- Ctrl arrives as its own event, so remember it for the next key.
  if code == KEY_CTRL_LEFT or code == KEY_CTRL_RIGHT then
    self.ctrl = true
    return true
  end

  if self.ctrl then
    self.ctrl = false
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
      self.output = {}
      self.outScroll = 0
      self.replScroll = 0
      self.status = "Log cleared"
      self.replStatus = "Log cleared"
      return true
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
    return true
  end

  if self.tab == "repl" then
    return self:handleRepl(ctx, char, code)
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
  if self.dirty then
    self:save(ctx)
  end
end

function lab:close(ctx)
  self:blur(ctx)
end

return lab
