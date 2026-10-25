-- Operator console: a small shell for the boot volume and OS services.

local console = {}
console.__index = console

console.id = "console"
console.title = "Terminal"
console.short = "Terminal"
console.icon = "TRM"
console.iconArt = {
  "┌───────┐",
  "│ █ █ █ │",
  "├───────┤",
  "│ >_    │",
  "└───────┘",
}
console.order = 3

function console.create(ctx)
  local self = setmetatable({}, console)
  self.cwd = "/"
  self.lines = {}
  self.history = {}
  self.historyIndex = 0
  self.input = ""
  self.scroll = 0
  self.wrapped = nil
  self.wrappedWidth = 0

  self:push("TerraCorp OS - operator terminal", "accent")
  self:push("Type `help` to list available commands.", "dim")
  self:push("", "out")
  return self
end

function console:push(text, kind)
  self.lines[#self.lines + 1] = { text = text, kind = kind or "out" }
  if #self.lines > 400 then
    table.remove(self.lines, 1)
  end
  self.wrapped = nil
  self.scroll = 0
end

function console:reflow(ctx)
  if self.wrapped and self.wrappedWidth == ctx.w then
    return self.wrapped
  end

  local visual = {}
  for _, line in ipairs(self.lines) do
    if line.text == "" or ctx.text.width(line.text) <= ctx.w - 2 then
      visual[#visual + 1] = { text = line.text, kind = line.kind }
    else
      for _, piece in ipairs(ctx.text.wrap(line.text, math.max(8, ctx.w - 2))) do
        visual[#visual + 1] = { text = piece, kind = line.kind }
      end
    end
  end

  self.wrapped = visual
  self.wrappedWidth = ctx.w
  return visual
end

function console:colorFor(kind, colors)
  if kind == "err" then
    return colors.danger
  elseif kind == "ok" then
    return colors.ok
  elseif kind == "accent" then
    return colors.accent
  elseif kind == "dim" then
    return colors.dim
  end
  return colors.text
end

function console:draw(ctx)
  local c = ctx.colors
  local v = ctx.view

  v:clear(" ", c.text, c.deep)

  local visual = self:reflow(ctx)
  local rows = math.max(1, ctx.h - 2)

  local last = #visual - self.scroll
  local first = math.max(1, last - rows + 1)

  for row = 1, rows do
    local line = visual[first + row - 1]
    if not line then
      break
    end
    v:put(1, row, line.text, self:colorFor(line.kind, c), c.deep)
  end

  local prompt = ctx.kernel.hostname .. ":" .. self.cwd .. "$ "
  local row = ctx.h
  local available = math.max(1, ctx.w - ctx.text.width(prompt) - 1)
  local shown = ctx.text.slice(self.input, math.max(1, ctx.text.width(self.input) - available + 1))

  v:put(1, row, prompt .. shown, c.accent, c.deep)
  v:put(1 + ctx.text.width(prompt) + ctx.text.width(shown), row, "_", c.dim, c.deep)

  if self.scroll > 0 then
    local suffix = (self.scroll == 1) and " line back " or " lines back "
    v:textRight(ctx.w, 1, " " .. self.scroll .. suffix, c.onAccent, c.warn)
  end
end

function console:resolve(ctx, path)
  if not path or path == "" then
    return self.cwd
  end
  return ctx.util.join(self.cwd, path)
end

function console:command(ctx, line)
  local name, rest = line:match("^(%S+)%s*(.*)$")
  if not name then
    return
  end

  local kernel = ctx.kernel
  local vfs = kernel.vfs

  if name == "help" then
    self:push("Available commands:", "accent")
    for _, item in ipairs({
      "ls [path]      list directory",
      "cd <path>      change directory",
      "pwd            print working directory",
      "cat <file>     print file contents",
      "echo <text>    print text",
      "clear          clear the terminal",
      "uptime         show session uptime",
      "mem            show node memory",
      "comps          list connected components",
      "log [n]        show recent log entries",
      "dragtest       measure window-drag event rate",
      "apps           list available apps",
      "open <id>      open an app",
      "theme <name>   change the accent color",
      "whoami         show node identity",
      "reboot         restart the node",
      "poweroff       shut down the node",
      "exit           close the terminal",
    }) do
      self:push("  " .. item, "dim")
    end
    return
  end

  if name == "ls" then
    local path = self:resolve(ctx, rest)
    local names, reason = vfs.list(path)
    if not names then
      self:push("ls: " .. tostring(reason), "err")
      return
    end
    if #names == 0 then
      self:push("(empty)", "dim")
      return
    end
    for _, entry in ipairs(names) do
      local full = ctx.util.join(path, entry)
      if vfs.isDirectory(full) then
        self:push("  " .. entry .. "/", "accent")
      else
        local bytes = vfs.size(full) or 0
        local size
        if bytes < 1024 then
          size = string.format("%d B", bytes)
        else
          size = ctx.util.humanSize(bytes / 1024)
        end
        self:push(ctx.text.padRight("  " .. entry, 26) .. size, "out")
      end
    end
    return
  end

  if name == "cd" then
    local path = self:resolve(ctx, rest)
    if vfs.isDirectory(path) then
      self.cwd = path
    else
      self:push("cd: not a directory: " .. path, "err")
    end
    return
  end

  if name == "pwd" then
    self:push(self.cwd)
    return
  end

  if name == "cat" then
    local path = self:resolve(ctx, rest)
    if vfs.isDirectory(path) then
      self:push("cat: is a directory", "err")
      return
    end
    local content, reason = vfs.read(path)
    if not content then
      self:push("cat: " .. tostring(reason), "err")
      return
    end
    local count = 0
    for _, textLine in ipairs(ctx.util.split((content:gsub("\r", "")), "\n")) do
      count = count + 1
      if count > 200 then
        self:push("... (truncated to 200 lines)", "dim")
        break
      end
      self:push(textLine)
    end
    return
  end

  if name == "echo" then
    self:push(rest)
    return
  end

  if name == "clear" then
    self.lines = {}
    self.wrapped = nil
    return
  end

  if name == "uptime" then
    self:push("Session uptime: " .. ctx.util.humanTime(kernel:uptime()), "ok")
    return
  end

  if name == "mem" then
    local used, total = kernel:memory()
    self:push(string.format("Memory: %.1f / %.1f MB", used / 1048576, total / 1048576), "out")
    return
  end

  if name == "comps" then
    local summary = kernel:components()
    self:push(tostring(summary.total) .. " connected components", "accent")
    for _, entry in ipairs(summary.entries) do
      self:push(string.format("  %-16s %d", entry.kind, entry.count), "out")
    end
    return
  end

  if name == "log" then
    local count = tonumber(rest) or 10
    for _, entry in ipairs(kernel.log.tail(count)) do
      local kind = "out"
      if entry.level == 3 then
        kind = "dim"
      elseif entry.level == 4 then
        kind = "err"
      end
      self:push(string.format("%s %s %s", entry.time, entry.tag, entry.message), kind)
    end
    return
  end

  if name == "dragtest" then
    ctx.ui:armDragTest()
    self:push("Drag test armed. Drag this Terminal title bar for 5-10 seconds, then run `log 10`.", "ok")
    return
  end

  if name == "apps" then
    for _, module in ipairs(ctx.ui.order) do
      self:push(string.format("  %-12s %s", module.id, module.title), "out")
    end
    return
  end

  if name == "open" then
    local id = ctx.util.trim(rest)
    if id == "" then
      self:push("open: missing app id", "err")
      return
    end
    ctx.ui:open(id)
    return
  end

  if name == "theme" then
    if rest == "" then
      self:push("Current accent: " .. kernel.config.get("accent"), "out")
      return
    end
    if kernel.config.set("accent", rest) then
      kernel:applyTheme()
      kernel:saveConfig()
      self:push("Accent changed to " .. rest, "ok")
    else
      self:push("theme: unknown accent", "err")
    end
    return
  end

  if name == "whoami" then
    self:push(kernel.hostname .. " · " .. kernel.address, "out")
    return
  end

  if name == "reboot" then
    self:push("Restarting node...", "accent")
    kernel:poweroff(true)
    return
  end

  if name == "poweroff" then
    self:push("Shutting down node...", "accent")
    kernel:poweroff(false)
    return
  end

  if name == "exit" then
    ctx.ui:close(ctx.win)
    return
  end

  self:push(name .. ": unknown command. Try `help`.", "err")
end

function console:submit(ctx)
  local line = ctx.util.trim(self.input)
  self:push(self.cwd .. "$ " .. self.input, "accent")
  self.input = ""

  if line ~= "" then
    self.history[#self.history + 1] = line
    if #self.history > 60 then
      table.remove(self.history, 1)
    end
  end

  self.historyIndex = 0
  self.scroll = 0

  local ok, reason = pcall(self.command, self, ctx, line)
  if not ok then
    self:push("error: " .. tostring(reason), "err")
    ctx.log.error("console: " .. tostring(reason))
  end
end

-- Number of visible lines above the end of the buffer.
function console:maxScroll(ctx)
  local rows = math.max(1, ctx.h - 2)
  return math.max(0, #self:reflow(ctx) - rows)
end

function console:handle(ctx, name, a, b, c)
  if name == "scroll" then
    local direction = c
    if direction and direction > 0 then
      self.scroll = math.min(self:maxScroll(ctx), self.scroll + 1)
    else
      self.scroll = math.max(0, self.scroll - 1)
    end
    return true
  end

  if name ~= "key" then
    return false
  end

  local char, code = a, b

  if code == 0x0E then
    self.input = ctx.text.slice(self.input, 1, math.max(0, ctx.text.width(self.input) - 1))
    return true
  end

  if code == 0x1C then
    self:submit(ctx)
    return true
  end

  if code == 0xC8 then
    if #self.history > 0 then
      self.historyIndex = math.min(#self.history, self.historyIndex + 1)
      self.input = self.history[#self.history - self.historyIndex + 1]
    end
    return true
  end

  if code == 0xD0 then
    if self.historyIndex > 1 then
      self.historyIndex = self.historyIndex - 1
      self.input = self.history[#self.history - self.historyIndex + 1]
    else
      self.historyIndex = 0
      self.input = ""
    end
    return true
  end

  if code == 0xC9 then
    self.scroll = math.min(self:maxScroll(ctx), self.scroll + math.max(1, ctx.h - 3))
    return true
  end

  if code == 0xD1 then
    self.scroll = math.max(0, self.scroll - math.max(1, ctx.h - 3))
    return true
  end

  if char and #char > 0 and not char:match("^%c$") then
    self.input = self.input .. char
    return true
  end

  return false
end

function console:close()
end

return console
