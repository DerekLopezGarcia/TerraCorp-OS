-- DNS: browse and edit the DNS1 registry from a tablet or desktop.
--
-- The app never talks to a modem directly. It uses the kernel's DNS client when
-- this computer is a client, or reads the local master cache when this computer
-- owns the registry. Network work happens in tick and in response to a key, not
-- in draw, so a slow peer cannot freeze an open window.

local keys = require("tc.keys")

local dns = {}
dns.__index = dns

dns.id = "dns"
dns.title = "DNS"
dns.short = "DNS"
dns.icon = "DNS"
dns.iconArt = {
  "╔═══════╗",
  "║ ▪ name║",
  "║  ▪ ▪  ║",
  "║ ▪ ▪ ▪ ║",
  "╚═══════╝",
}
dns.order = 12

local function stateColor(colors, state)
  if state == "online" then
    return colors.ok
  elseif state == "stale" then
    return colors.warn
  elseif state == "offline" then
    return colors.danger
  end
  return colors.dim
end

local function endpointCount(row)
  local list = row.endpoints
  if type(list) == "table" then
    return #list
  end
  return tonumber(list) or 0
end

local function normalizeDetail(body)
  if type(body) ~= "table" or type(body.node) ~= "table" then
    return body
  end
  local node = body.node
  return {
    id = node.id,
    name = node.name,
    ver = node.ver,
    boot = node.boot,
    proto = node.proto,
    transports = node.transports,
    tags = node.tags,
    docs = node.docs,
    v = body.v,
    endpoints = body.endpoints,
    paths = body.paths,
  }
end

local function endpointNames(detail)
  local names = {}
  for _, item in ipairs(detail and detail.endpoints or {}) do
    names[#names + 1] = item.name
  end
  table.sort(names)
  return names
end

function dns.create()
  local self = setmetatable({}, dns)
  self.index = 1
  self.top = 0
  self.rows = {}
  self.detail = nil
  self.message = "Loading registry…"
  self.lastRefresh = 0
  self.mode = "list"
  self.buffer = ""
  self.rev = 0
  self.cursor = ""
  self.cursorStack = {}
  self.nextCursor = "-"
  return self
end

function dns:client(ctx)
  return ctx.kernel.dnsclient
end

function dns:master(ctx)
  return ctx.kernel.dnsmaster
end

function dns:selected()
  return self.rows[self.index]
end

function dns:notify(ctx, kind, message)
  self.message = message
  if ctx.ui and type(ctx.ui.notify) == "function" then
    ctx.ui:notify(kind, message)
  end
  return true
end

function dns:loadDetail(ctx)
  local node = self:selected()
  if not node then
    self.detail = nil
    return
  end
  local body, reason
  local client = self:client(ctx)
  if client then
    body, reason = client:describe(node.id, "node")
  else
    local master = self:master(ctx)
    if master then
      body, reason = master:describe(node.id, "node")
    end
  end
  if not body then
    self.detail = nil
    self.message = "No answer from " .. tostring(node.name or node.id) .. ": " .. tostring(reason)
    return
  end
  self.detail = normalizeDetail(body)
end

function dns:refresh(ctx)
  local nodes, body, reason
  local client = self:client(ctx)
  if client then
    nodes, body = client:nodes(self.cursor, 8)
    if not nodes then
      self.rows = {}
      self.detail = nil
      self.message = tostring(body or "No answer from the master.")
      return true
    end
  else
    local master = self:master(ctx)
    if not master then
      self.rows = {}
      self.detail = nil
      self.message = "No DNS master configured on this computer."
      return true
    end
    body = master:catalog(self.cursor, 8)
    nodes = body and body.nodes or {}
  end

  self.nextCursor = body and body.next or "-"
  if #nodes == 0 and self.cursor ~= "" then
    self.cursor = ""
    self.cursorStack = {}
    return self:refresh(ctx)
  end

  local selectedId = self:selected() and self:selected().id
  self.rows = nodes
  self.index = math.max(1, math.min(self.index, math.max(1, #nodes)))
  if selectedId then
    for index, row in ipairs(nodes) do
      if row.id == selectedId then
        self.index = index
        break
      end
    end
  end
  self.lastRefresh = os.time()
  self:loadDetail(ctx)
  if #self.rows == 0 then
    self.message = "The registry is empty. A node publishes when it boots."
  elseif body and body.total then
    self.message = string.format("%d node%s in the registry.", body.total,
      body.total == 1 and "" or "s")
  else
    self.message = "Registry refreshed."
  end
  return true
end

function dns:nextPage(ctx)
  if not self.nextCursor or self.nextCursor == "-" then
    return self:notify(ctx, "info", "This is the last page.")
  end
  table.insert(self.cursorStack, self.cursor)
  self.cursor = self.nextCursor
  self.index = 1
  self.top = 0
  return self:refresh(ctx)
end

function dns:prevPage(ctx)
  if #self.cursorStack == 0 then
    return self:notify(ctx, "info", "This is the first page.")
  end
  self.cursor = table.remove(self.cursorStack)
  self.index = 1
  self.top = 0
  return self:refresh(ctx)
end

function dns:startEdit(ctx)
  if not self.detail then
    return self:notify(ctx, "warn", "Select a registered node first.")
  end
  if not self:client(ctx) then
    return self:notify(ctx, "warn", "Editing needs a DNS client; this computer is the master.")
  end
  self.mode = "edit"
  self.buffer = tostring(self.detail.docs or "")
  self.rev = tonumber(self.detail.v) or 0
  return true
end

function dns:commitEdit(ctx)
  local node = self:selected()
  local client = self:client(ctx)
  self.mode = "list"
  if not node or not client then
    return true
  end
  if #self.buffer > 1024 then
    return self:notify(ctx, "error", "The document is longer than 1024 characters.")
  end
  local answer, reason = client:edit(node.id, "node", "docs", self.buffer, self.rev)
  if not answer then
    return self:notify(ctx, "error", "Edit failed: " .. tostring(reason))
  end
  if not answer.ok then
    if answer.err == "conflict" then
      return self:notify(ctx, "warn",
        "Another edit won; the document now ends with revision " .. tostring(answer.rev) .. ".")
    end
    return self:notify(ctx, "error", "Edit refused: " .. tostring(answer.err))
  end
  self:refresh(ctx)
  return self:notify(ctx, "info", "Document saved at revision " .. tostring(answer.rev) .. ".")
end

function dns:ping(ctx)
  local node = self:selected()
  local client = self:client(ctx)
  if not node or not client then
    return self:notify(ctx, "warn", "A DNS client and a selected node are required.")
  end
  local status, reason = client:exec(node.id, "endpoint:dns.status", "status", {})
  if not status then
    return self:notify(ctx, "error", "Ping failed: " .. tostring(reason))
  end
  return self:notify(ctx, "info", string.format("%s: snapshot %s, published %s, calls %s.",
    tostring(node.name), tostring(status.snapshot), tostring(status.published),
    tostring(status.calls)))
end

function dns:emptyText(ctx)
  if not self:client(ctx) and not self:master(ctx) then
    return "No DNS master configured on this computer."
  end
  if #self.rows == 0 then
    return self.message
  end
  return ""
end

function dns:draw(ctx)
  local c = ctx.colors
  local v = ctx.view
  v:clear(" ", c.text, c.deep)

  v:put(1, 1, "DNS registry", c.accent, c.deep)
  local count = string.format("%d node%s", #self.rows, #self.rows == 1 and "" or "s")
  if ctx.w > 24 then
    v:textRight(ctx.w, 1, count, c.dim, c.deep)
  end

  local detailRows = ctx.h < 14 and 3 or 6
  local bodyTop = 3
  local bodyBottom = math.max(bodyTop, ctx.h - detailRows - 1)
  local visible = math.max(1, bodyBottom - bodyTop + 1)

  if #self.rows == 0 then
    v:put(2, bodyTop, ctx.text.truncate(self:emptyText(ctx), ctx.w - 3), c.dim, c.deep)
  end

  local maximum = math.max(0, #self.rows - visible)
  if self.index - 1 > self.top + visible - 1 then
    self.top = self.index - visible
  elseif self.index - 1 < self.top then
    self.top = self.index - 1
  end
  self.top = math.max(0, math.min(self.top, maximum))

  for line = 1, visible do
    local row = self.rows[self.top + line]
    if not row then
      break
    end
    local selected = (self.top + line) == self.index
    if selected then
      v:fill(1, bodyTop + line - 1, ctx.w, 1, " ", c.deep, c.panel)
    end
    local name = tostring(row.name or row.id)
    local state = tostring(row.state or (row.stale and "stale") or "online")
    local endpoints = endpointCount(row)
    local text = string.format("%s %-16s %-7s %d endpoint%s",
      selected and ">" or " ", name:sub(1, 16), state, endpoints,
      endpoints == 1 and "" or "s")
    v:put(1, bodyTop + line - 1, ctx.text.truncate(text, ctx.w),
      selected and c.text or stateColor(c, state), selected and c.panel or c.deep)
  end

  local detail = ctx.h - detailRows
  v:fill(1, detail, ctx.w, 1, " ", c.text, c.panel)
  local node = self:selected()
  if self.mode == "edit" then
    v:put(1, detail, "Node document (Enter saves, Esc cancels):", c.accent, c.panel)
    v:put(1, detail + 1, ctx.text.truncate(self.buffer .. "▏", ctx.w), c.text, c.panel)
  elseif node and self.detail then
    local names = endpointNames(self.detail)
    v:put(1, detail, ctx.text.truncate(string.format("%s · %s · v%s · %s",
      tostring(self.detail.name or node.name), tostring(self.detail.id or node.id),
      tostring(self.detail.ver or "?"),
      tostring(self.detail.boot or "?"):sub(1, 10)), ctx.w), c.text, c.panel)
    local docs = tostring(self.detail.docs or "")
    v:put(1, detail + 1, ctx.text.truncate(docs ~= "" and docs or "(no document)", ctx.w),
      c.dim, c.panel)
    v:put(1, detail + 2, ctx.text.truncate("endpoints: " .. table.concat(names, ", "), ctx.w),
      c.dim, c.panel)
  else
    v:put(1, detail, ctx.text.truncate(self:emptyText(ctx), ctx.w), c.dim, c.panel)
  end

  if self.mode ~= "edit" then
    local footer
    if ctx.w >= 58 then
      footer = "↑↓ select · ←→ page · R refresh · E edit docs · P status"
    elseif ctx.w >= 40 then
      footer = "↑↓ · ←→ page · R · E edit · P status"
    else
      footer = "↑↓ · ←→ · R · E · P"
    end
    v:put(1, ctx.h, ctx.text.truncate(footer, ctx.w), c.dim, c.deep)
  end
end

function dns:handle(ctx, name, a, b)
  if name == "scroll" then
    local delta = tonumber(b) or 0
    self.index = math.max(1, self.index + (delta < 0 and 1 or -1))
    self:loadDetail(ctx)
    return true
  end
  if name ~= "key" then
    return false
  end
  local char, code = a, b

  if self.mode == "edit" then
    if code == keys.esc then
      self.mode = "list"
      return true
    elseif code == keys.enter then
      return self:commitEdit(ctx)
    elseif code == keys.back then
      self.buffer = self.buffer:sub(1, math.max(0, #self.buffer - 1))
      return true
    elseif type(char) == "string" and #char == 1 and char:byte() >= 32 and char:byte() <= 126 then
      if #self.buffer < 1024 then
        self.buffer = self.buffer .. char
      end
      return true
    end
    return true
  end

  if char == "r" then
    return self:refresh(ctx)
  elseif char == "e" then
    return self:startEdit(ctx)
  elseif char == "p" then
    return self:ping(ctx)
  elseif code == keys.up then
    self.index = math.max(1, self.index - 1)
    self:loadDetail(ctx)
    return true
  elseif code == keys.down then
    self.index = math.min(math.max(1, #self.rows), self.index + 1)
    self:loadDetail(ctx)
    return true
  elseif code == keys.left then
    return self:prevPage(ctx)
  elseif code == keys.right then
    return self:nextPage(ctx)
  elseif code == keys.pageUp then
    self.index = math.max(1, self.index - 6)
    self:loadDetail(ctx)
    return true
  elseif code == keys.pageDown then
    self.index = math.min(math.max(1, #self.rows), self.index + 6)
    self:loadDetail(ctx)
    return true
  elseif code == keys.home then
    self.index = 1
    self:loadDetail(ctx)
    return true
  elseif code == keys["end"] then
    self.index = math.max(1, #self.rows)
    self:loadDetail(ctx)
    return true
  end
  return false
end

function dns:tick(ctx)
  if self.mode == "edit" then
    return false
  end
  if os.time() - self.lastRefresh < 5 then
    return false
  end
  return self:refresh(ctx)
end

function dns:close()
end

return dns
