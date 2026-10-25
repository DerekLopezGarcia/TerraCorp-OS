-- Tests for the 0.3.0 cluster foundation: tc.net framing/transport and the
-- /var/nodes.tsv registry. Run through tools/harness/test-cluster.js.

local net = require("tc.net")
local registry = require("tc.registry")

local failures = {}
local function fail(message)
  failures[#failures + 1] = message
end

local function check(condition, message)
  if not condition then
    fail(message)
  end
end

local function equal(actual, expected, message)
  if actual ~= expected then
    fail(message .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
  end
end

--------------------------------------------------------------------------------
-- Framing
--------------------------------------------------------------------------------

local frame = net.encode("HELLO", {
  id = "abc-123",
  name = "Rack 1 / N=2%",
  mem = 512,
  role = "worker",
})
check(frame ~= nil, "HELLO should encode")
check(#frame <= net.MAX_FRAME, "HELLO should fit the frame limit")

local verb, fields = net.decode(frame)
equal(verb, "HELLO", "decoded verb")
equal(fields.id, "abc-123", "decoded id")
equal(fields.name, "Rack 1 / N=2%", "escaped name round trip")
equal(fields.mem, "512", "numbers become text")
equal(fields.role, "worker", "decoded role")

local spaced = net.encode("STATUS", { id = "a b=c%", state = "online" })
local spacedVerb, spacedFields = net.decode(spaced)
equal(spacedVerb, "STATUS", "STATUS verb")
equal(spacedFields.id, "a b=c%", "space, equals, and percent survive")

check(net.encode("NOPE", { id = "x" }) == nil, "unknown verbs must not encode")
check(net.decode("TC1 NOPE id=x") == nil, "unknown verbs must not decode")
check(net.encode("STATUS", { id = "x" }) == nil, "missing required field")
check(net.decode("TC1 STATUS id=x") == nil, "missing required field on decode")
check(net.decode("TC1 PING id=a id=b") == nil, "duplicate fields are rejected")
check(net.decode("TC1 PING Id=a") == nil, "field names are lowercase")
check(net.decode("TC1 PING id=a\nid=b") == nil, "multi-line frames are rejected")
check(net.decode("TC2 PING id=a") == nil, "unknown protocol is rejected")
check(net.encode("HELLO", { id = string.rep("a", net.MAX_FRAME) }) == nil, "oversized frame")
check(net.decode(string.rep("a", net.MAX_FRAME + 1)) == nil, "oversized decode")

local injected = net.encode("HELLO", { id = "line\nbreak" })
check(injected ~= nil, "newlines are escaped, not rejected")
equal(net.decode(injected), "HELLO", "escaped newline decodes")
local _, injectedFields = net.decode(injected)
equal(injectedFields.id, "line\nbreak", "escaped newline round trip")

--------------------------------------------------------------------------------
-- Modem transport
--------------------------------------------------------------------------------

local calls = {}
local fakeComponent = {
  list = function(kind)
    local items = { "modem-wireless", "modem-wired" }
    local index = 0
    return function()
      index = index + 1
      local address = items[index]
      if address then
        return address, "modem"
      end
    end
  end,
  invoke = function(address, method, ...)
    if method == "isWired" then
      return address == "modem-wired"
    end
    calls[#calls + 1] = { address = address, method = method, args = table.pack(...) }
    return true
  end,
}

local modem = net.newModem({ component = fakeComponent })
local opened = modem:open()
check(opened == true, "wired modem opens")
equal(modem.address, "modem-wired", "wired card is preferred")

check(modem:send("target-1", "PING", { id = "node-1" }) == true, "send succeeds")
local sent = calls[#calls]
equal(sent.method, "send", "send method")
equal(sent.args[1], "target-1", "send target")
equal(sent.args[2], net.PORT, "cluster port")
local sentVerb, sentFields = net.decode(sent.args[3])
equal(sentVerb, "PING", "sent frame verb")
equal(sentFields.id, "node-1", "sent frame id")

check(modem:broadcast("PONG", { id = "node-1", state = "online" }) == true, "broadcast succeeds")
equal(calls[#calls].method, "broadcast", "broadcast method")
equal(calls[#calls].args[1], net.PORT, "broadcast port")

check(modem:send("", "PING", { id = "x" }) == nil, "send requires a target")

local missing = net.newModem({
  component = { list = function() return function() end end },
})
local missingOk, missingReason = missing:open()
check(missingOk == nil, "open fails without a modem")
check(tostring(missingReason):find("no network card") ~= nil, "missing modem reason")

--------------------------------------------------------------------------------
-- Registry
--------------------------------------------------------------------------------

local store = {}
local vfs = {
  read = function(path)
    return store[path]
  end,
  write = function(path, data)
    store[path] = data
    return true
  end,
}

local nodes = registry.load(vfs)
equal(#nodes, 0, "empty registry")

local node, created = registry.upsert(nodes, {
  id = "id-1",
  name = "TC-N1",
  role = "worker",
  modem = "modem-1",
  state = "online",
  mem = 1024,
  disk = 4096,
  lastSeen = 5,
})
check(created == true, "first upsert creates")
equal(node.name, "TC-N1", "stored name")

registry.upsert(nodes, { id = "id-1", state = "online", mem = 2048, lastSeen = 9 })
equal(#nodes, 1, "upsert by id merges")
equal(registry.find(nodes, "id-1").mem, 2048, "merged memory")

registry.upsert(nodes, { id = "id-2", name = "TC-N2", role = "storage" })
equal(#nodes, 2, "second node added")

local saved = registry.save(vfs, nodes)
check(saved == true, "registry saves")
check(store[registry.path] ~= nil and #store[registry.path] > 0, "registry file written")

local loaded = registry.load(vfs)
equal(#loaded, 2, "registry reloads")
local reloaded = registry.find(loaded, "id-1")
equal(reloaded.state, "offline", "reload forces offline")
equal(reloaded.mem, 2048, "memory survives reload")
equal(reloaded.disk, 4096, "disk survives reload")
equal(reloaded.lastSeen, 0, "lastSeen resets on reload")

reloaded.state = "online"
local summary = registry.aggregate(loaded)
equal(summary.total, 2, "summary total")
equal(summary.online, 1, "summary online")
equal(summary.offline, 1, "summary offline")
equal(summary.mem, 2048, "summary memory only counts online")
equal(summary.storage, 1, "summary storage role")

check(registry.rename(loaded, "id-2", "Rack 1") ~= nil, "rename succeeds")
equal(registry.find(loaded, "id-2").name, "Rack 1", "renamed node")
check(registry.rename(loaded, "id-2", "") == nil, "empty name is rejected")
check(registry.rename(loaded, "id-2", string.rep("x", registry.MAX_NAME + 1)) == nil, "long name is rejected")
check(registry.rename(loaded, "id-2", "bad\tname") == nil, "tab in name is rejected")

check(registry.setRole(loaded, "id-2", "storage") ~= nil, "valid role")
check(registry.setRole(loaded, "id-2", "boss") == nil, "invalid role is rejected")

store[registry.path] = "garbage\n"
  .. "id-3\tN3\tworker\tm3\tbogus\t10\t20\t30\n"
  .. "id-3\tN3b\tworker\tm3\tbogus\t10\t20\t30\n"
local odd = registry.load(vfs)
equal(#odd, 1, "malformed lines are skipped and duplicate ids merge")
equal(odd[1].state, "offline", "invalid state becomes offline")
equal(odd[1].role, "worker", "invalid role keeps the default")

--------------------------------------------------------------------------------
-- Fake filesystem components
--------------------------------------------------------------------------------

local vfsModule = require("tc.vfs")
local provision = require("tc.provision")
local clusterModule = require("tc.cluster")
local nodeModule = require("tc.node")
local netboot = require("boot.netboot")

local function slurp(relative)
  local data = SOURCES and SOURCES[relative]
  if not data then
    fail("could not read " .. relative)
    return ""
  end
  return data
end

local function normalize(path)
  path = tostring(path or "/")
  path = "/" .. path:gsub("^/+", "")
  if #path > 1 then
    path = path:gsub("/+$", "")
  end
  return path
end

local function parentOf(path)
  local parent = path:match("^(.*)/[^/]+$")
  if not parent or parent == "" then
    return "/"
  end
  return parent
end

-- Component-level volume with the OpenComputers filesystem callbacks.
local function newVolume(opts)
  opts = opts or {}
  local files = {}
  local dirs = { ["/"] = true }
  local handles = {}
  local nextHandle = 0
  local total = opts.total or 512 * 1024
  local volume = {}

  local function newHandle(path, kind)
    nextHandle = nextHandle + 1
    handles[nextHandle] = { path = path, kind = kind, position = 1 }
    return nextHandle
  end

  function volume.open(path, mode)
    path = normalize(path)
    mode = mode or "r"
    if mode == "r" then
      if files[path] == nil then
        return nil, "file not found"
      end
    elseif mode == "w" then
      files[path] = ""
    elseif mode == "a" then
      files[path] = files[path] or ""
    else
      return nil, "unsupported mode"
    end
    return newHandle(path, mode)
  end

  function volume.read(handle, count)
    local state = handles[handle]
    if not state or state.kind ~= "r" then
      return nil, "invalid handle"
    end
    local content = files[state.path] or ""
    if state.position > #content then
      return nil
    end
    count = count or #content
    local chunk = content:sub(state.position, state.position + count - 1)
    state.position = state.position + #chunk
    return chunk
  end

  function volume.write(handle, data)
    local state = handles[handle]
    if not state or state.kind == "r" then
      return nil, "invalid handle"
    end
    files[state.path] = (files[state.path] or "") .. data
    return true
  end

  function volume.close(handle)
    handles[handle] = nil
  end

  function volume.exists(path)
    path = normalize(path)
    return files[path] ~= nil or dirs[path] == true
  end

  function volume.isDirectory(path)
    return dirs[normalize(path)] == true
  end

  function volume.isReadOnly()
    return opts.readOnly == true
  end

  function volume.size(path)
    local data = files[normalize(path)]
    return data and #data or nil
  end

  function volume.list(path)
    path = normalize(path)
    local base = path == "/" and "/" or (path .. "/")
    local seen, names = {}, {}
    local function consider(full)
      if full:sub(1, #base) ~= base then
        return
      end
      local name = full:sub(#base + 1):match("^([^/]+)")
      if name and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
    for full in pairs(files) do
      consider(full)
    end
    for full in pairs(dirs) do
      if full ~= "/" then
        consider(full)
      end
    end
    table.sort(names)
    return names
  end

  function volume.makeDirectory(path)
    path = normalize(path)
    if dirs[path] or files[path] then
      return nil, "already exists"
    end
    dirs[path] = true
    return true
  end

  function volume.remove(path)
    path = normalize(path)
    if files[path] == nil and dirs[path] == nil then
      return nil, "not found"
    end
    files[path] = nil
    dirs[path] = nil
    return true
  end

  function volume.rename(from, to)
    from = normalize(from)
    to = normalize(to)
    if files[from] == nil and dirs[from] == nil then
      return nil, "not found"
    end
    files[to] = files[from]
    files[from] = nil
    dirs[to] = dirs[from]
    dirs[from] = nil
    return true
  end

  function volume.spaceUsed()
    local used = 0
    for _, data in pairs(files) do
      used = used + #data
    end
    return used
  end

  function volume.spaceTotal()
    return total
  end

  return volume
end

local function put(vfs, path, data)
  local parent = parentOf(path)
  local ok, reason = vfs.ensureDir(parent)
  if not ok then
    error("ensureDir " .. parent .. ": " .. tostring(reason))
  end
  local written, writeReason = vfs.write(path, data)
  if not written then
    error("write " .. path .. ": " .. tostring(writeReason))
  end
end

local sourceVolume = newVolume({ total = 1024 * 1024 })
local source = vfsModule.new(sourceVolume)
put(source, "/init.lua", "return true\n")
put(source, "/boot/kernel.lua", "-- test kernel\n")
put(source, "/boot/netboot.lua", slurp("src/boot/netboot.lua"))
put(source, "/lib/tc/vfs.lua", slurp("src/lib/tc/vfs.lua"))
put(source, "/lib/tc/provision.lua", slurp("src/lib/tc/provision.lua"))
put(source, "/lib/tc/net.lua", slurp("src/lib/tc/net.lua"))
put(source, "/apps/nodes.lua", "return {}\n")

--------------------------------------------------------------------------------
-- Floppy preparation and guarded installs
--------------------------------------------------------------------------------

local floppyVolume = newVolume()
local floppy = vfsModule.new(floppyVolume)
check(provision.checkTarget(floppy) == true, "an empty floppy is a valid target")

local prepared, prepareReason = provision.prepare(source, floppy, { version = "0.3.0" })
check(prepared ~= nil, "prepare writes the floppy: " .. tostring(prepareReason))
check(floppy.exists("/init.lua"), "prepare writes the netboot entry point")
check(floppy.exists("/payload/.ready"), "prepare writes the payload marker")
check(floppy.exists("/payload/boot/kernel.lua"), "prepare copies the runtime")
local ready = floppy.read("/payload/.ready") or ""
check(ready:find("version=0.3.0", 1, true) ~= nil, "payload marker names the version")

local dirtyVolume = newVolume()
local dirty = vfsModule.new(dirtyVolume)
put(dirty, "/photos/holiday.txt", "not ours")
local blocked, blockedReason = provision.prepare(source, dirty, { version = "0.3.0" })
check(blocked == nil, "prepare refuses a floppy with unrelated data")
check(tostring(blockedReason):find("other data") ~= nil, "unrelated data is named in the error")

local targetVolume = newVolume({ total = 2 * 1024 * 1024 })
local target = vfsModule.new(targetVolume)
local configText = provision.configText({
  name = "TC-N1",
  role = "storage",
  master = "modem-master",
  masterId = "master-computer",
})
local installed, installReason = provision.install(target, floppy, {
  version = "0.3.0",
  configText = configText,
})
check(installed ~= nil, "install copies the payload: " .. tostring(installReason))
check(target.exists("/boot/kernel.lua"), "install writes the kernel")
check(target.exists("/init.lua"), "install writes the entry point")
check(not target.exists("/payload/.ready"), "install does not copy the floppy marker")
check(not target.exists("/var/install-incomplete"), "a complete install clears the marker")
local storedConfig = target.read("/etc/terracorp.cfg") or ""
check(storedConfig:find('role = "node"', 1, true) ~= nil, "node config selects the node role")
check(storedConfig:find('nodeRole = "storage"', 1, true) ~= nil, "node config stores the assigned role")
check(storedConfig:find('master = "modem-master"', 1, true) ~= nil, "node config stores the master")

local safeAgain = provision.checkInstallTarget(target)
check(safeAgain == nil, "a complete install is not overwritten")

local retryVolume = newVolume({ total = 2 * 1024 * 1024 })
local retry = vfsModule.new(retryVolume)
put(retry, "/var/install-incomplete", "version=0.3.0\n")
put(retry, "/boot/kernel.lua", "-- partial\n")
local retried, retryReason = provision.install(retry, floppy, {
  version = "0.3.0",
  configText = configText,
})
check(retried ~= nil, "a marked partial install can be retried: " .. tostring(retryReason))
check(retried and retried.replaced == true, "a retry reports that it replaced a partial install")
check(not retry.exists("/var/install-incomplete"), "the retry clears the marker")

local fallbackConfig = provision.configText({ role = "boss" })
check(fallbackConfig:find('nodeRole = "worker"', 1, true) ~= nil, "invalid roles fall back to worker")

--------------------------------------------------------------------------------
-- Master cluster: installer, handshake, offline tracking, registry
--------------------------------------------------------------------------------

local masterVolume = newVolume({ total = 4 * 1024 * 1024 })
local master = vfsModule.new(masterVolume)
put(master, "/init.lua", "return true\n")
put(master, "/boot/kernel.lua", "-- master kernel\n")
put(master, "/boot/netboot.lua", slurp("src/boot/netboot.lua"))
put(master, "/lib/tc/vfs.lua", slurp("src/lib/tc/vfs.lua"))
put(master, "/lib/tc/provision.lua", slurp("src/lib/tc/provision.lua"))
put(master, "/lib/tc/net.lua", slurp("src/lib/tc/net.lua"))
put(master, "/apps/nodes.lua", "return {}\n")

local clusterFloppyVolume = newVolume()
local clusterFloppy = vfsModule.new(clusterFloppyVolume)
local clock = 100
local clusterCalls = {}
local clusterComponent = {
  list = function(kind)
    local items = ({
      modem = { "modem-master" },
      filesystem = { "fs-boot", "floppy-1" },
      disk_drive = { "drive-1" },
    })[kind] or {}
    local index = 0
    return function()
      index = index + 1
      if items[index] then
        return items[index], kind
      end
    end
  end,
  invoke = function(address, method, ...)
    if address == "drive-1" and method == "filesystem" then
      return "floppy-1"
    end
    if address == "modem-master" then
      if method == "isWired" then
        return true
      elseif method == "open" or method == "close" then
        return true
      elseif method == "send" or method == "broadcast" then
        clusterCalls[#clusterCalls + 1] = {
          method = method,
          args = table.pack(...),
        }
        return true
      end
    end
    if address == "floppy-1" and method == "spaceTotal" then
      return clusterFloppyVolume.spaceTotal()
    end
    return nil, "unknown component"
  end,
}
local clusterComputer = {
  address = function()
    return "master-computer"
  end,
}
local clusterKernel = {
  address = "master-computer",
  volumeAddress = "fs-boot",
  uptime = function()
    return clock
  end,
  mount = function(_, address)
    if address == "floppy-1" then
      return clusterFloppy
    end
    return nil
  end,
}
local cluster = clusterModule.new({
  kernel = clusterKernel,
  vfs = master,
  config = {},
  log = nil,
  version = { version = "0.3.0" },
  component = clusterComponent,
  computer = clusterComputer,
})
check(cluster:start() == true, "cluster starts with a wired modem")
check(cluster.modem ~= nil, "cluster opens the modem")

local armed, armedReason = cluster:prepareInstaller()
check(armed == true, "installer arms on a prepared floppy: " .. tostring(armedReason))
check(cluster:installerState().active == true, "installer reports an active window")

local hello = net.encode("HELLO", {
  id = "node-1",
  mem = 512,
  disk = 2048,
})
cluster:handle("modem_message", "modem-master", "node-modem-1", net.PORT, 0, hello)
local assign
for index = #clusterCalls, 1, -1 do
  local call = clusterCalls[index]
  if call.method == "send" then
    local verb, fields = net.decode(call.args[3])
    if verb == "ASSIGN" then
      assign = fields
      break
    end
  end
end
check(assign ~= nil, "HELLO receives an ASSIGN")
equal(assign and assign.id, "node-1", "ASSIGN targets the new node")
check(assign and assign.master == "modem-master", "ASSIGN names the master modem")
check(assign and assign.masterId == "master-computer", "ASSIGN names the master computer")
local assignedNode = registry.find(cluster:nodesList(), "node-1")
check(assignedNode ~= nil, "HELLO registers the node")
equal(assignedNode and assignedNode.state, "provisioning", "a new node is provisioning")
equal(assignedNode and assignedNode.modem, "node-modem-1", "registry stores the node modem")

local ack = net.encode("ACK", {
  token = assign and assign.token or "",
  id = "node-1",
  boot = "hdd-1",
  mem = 512,
  disk = 2048,
})
cluster:handle("modem_message", "modem-master", "node-modem-1", net.PORT, 0, ack)
equal(registry.find(cluster:nodesList(), "node-1").state, "provisioning", "ACK keeps the node provisioning")

local status = net.encode("STATUS", {
  id = "node-1",
  state = "online",
  mem = 512,
  disk = 2048,
})
cluster:handle("modem_message", "modem-master", "node-modem-1", net.PORT, 0, status)
equal(registry.find(cluster:nodesList(), "node-1").state, "online", "STATUS marks the node online")

local beforePing = #clusterCalls
cluster:handle("modem_message", "modem-master", "node-modem-1", net.PORT, 0, hello)
equal(#clusterCalls, beforePing, "a live node is not re-provisioned by a stale HELLO")

clock = clock + clusterModule.OFFLINE_AFTER + 1
cluster:tick()
local ping
for index = #clusterCalls, 1, -1 do
  local call = clusterCalls[index]
  if call.method == "send" then
    local verb, fields = net.decode(call.args[3])
    if verb == "PING" then
      ping = fields
      break
    end
  end
end
check(ping ~= nil, "a silent node is pinged")
equal(ping and ping.id, "node-1", "PING targets the node id")

clock = clock + clusterModule.OFFLINE_GRACE + 1
cluster:tick()
equal(registry.find(cluster:nodesList(), "node-1").state, "offline", "an unanswered ping marks the node offline")

local pong = net.encode("PONG", { id = "node-1", state = "online" })
cluster:handle("modem_message", "modem-master", "node-modem-1", net.PORT, 0, pong)
equal(registry.find(cluster:nodesList(), "node-1").state, "online", "PONG restores the node")

-- A second server on the same bus gets its own ASSIGN and registry entry.
local hello2 = net.encode("HELLO", {
  id = "node-2",
  mem = 256,
  disk = 1024,
})
cluster:handle("modem_message", "modem-master", "node-modem-2", net.PORT, 0, hello2)
local assign2
for index = #clusterCalls, 1, -1 do
  local call = clusterCalls[index]
  if call.method == "send" then
    local verb, fields = net.decode(call.args[3])
    if verb == "ASSIGN" and fields.id == "node-2" then
      assign2 = fields
      break
    end
  end
end
check(assign2 ~= nil, "a second node on the same bus receives an ASSIGN")
equal(assign2 and assign2.name, "TC-N2", "the second node gets its own name")
check(assign2 and assign2.token ~= (assign and assign.token), "each assignment gets its own token")
local secondNode = registry.find(cluster:nodesList(), "node-2")
check(secondNode ~= nil, "the second node is registered")
equal(secondNode and secondNode.modem, "node-modem-2", "the second node stores its own modem")
equal(#cluster:nodesList(), 2, "both nodes are listed")

local renamed, renameReason = cluster:rename("node-1", "Rack 1")
check(renamed == true, "cluster rename succeeds: " .. tostring(renameReason))
local roled, roleReason = cluster:setRole("node-1", "storage")
check(roled == true, "cluster role change succeeds: " .. tostring(roleReason))
equal(registry.find(cluster:nodesList(), "node-1").name, "Rack 1", "cluster stores the new name")
equal(registry.find(cluster:nodesList(), "node-1").role, "storage", "cluster stores the new role")
check((master.read(registry.path) or ""):find("Rack 1", 1, true) ~= nil, "the node registry persists")

clock = clock + clusterModule.INSTALL_WINDOW + 10
cluster:tick()
check(cluster:installerState().active == false, "the installer window expires")
local expiredCalls = #clusterCalls
local lateHello = net.encode("HELLO", { id = "node-3" })
cluster:handle("modem_message", "modem-master", "node-modem-3", net.PORT, 0, lateHello)
equal(#clusterCalls, expiredCalls, "an expired installer ignores HELLO")
check(registry.find(cluster:nodesList(), "node-3") == nil, "an ignored node is not registered")
cluster:shutdown()

--------------------------------------------------------------------------------
-- Node runtime: assignment, ACK, PING adoption, and heartbeats
--------------------------------------------------------------------------------

local nodeClock = 50
local nodeCalls = {}
local nodeConfigData = {
  hostname = "",
  nodeRole = "worker",
  master = "",
  masterId = "",
}
local nodeConfig = {
  get = function(key)
    return nodeConfigData[key]
  end,
  set = function(key, value)
    nodeConfigData[key] = value
  end,
}
local nodeComponent = {
  list = function(kind)
    local items = ({ modem = { "modem-node" } })[kind] or {}
    local index = 0
    return function()
      index = index + 1
      if items[index] then
        return items[index], kind
      end
    end
  end,
  invoke = function(address, method, ...)
    if address == "modem-node" then
      if method == "isWired" then
        return true
      elseif method == "open" or method == "close" then
        return true
      elseif method == "send" or method == "broadcast" then
        nodeCalls[#nodeCalls + 1] = {
          method = method,
          args = table.pack(...),
        }
        return true
      end
    end
    return nil, "unknown component"
  end,
}
local nodeComputer = {
  address = function()
    return "node-computer-1"
  end,
  uptime = function()
    return nodeClock
  end,
  totalMemory = function()
    return 2 * 1024 * 1024
  end,
}
local nodeKernel = {
  address = "node-computer-1",
  volumeAddress = "hdd-1",
  uptime = function()
    return nodeClock
  end,
  storage = function()
    return 0, 1024
  end,
  saveConfig = function()
    return true
  end,
}
local nodeRuntime = nodeModule.new({
  kernel = nodeKernel,
  config = nodeConfig,
  vfs = vfsModule.new(newVolume()),
  log = nil,
  version = { version = "0.3.0" },
  theme = { colors = { bg = 0, text = 0, dim = 0, accent = 0, ok = 0, warn = 0 } },
  gfxModule = nil,
  component = nodeComponent,
  computer = nodeComputer,
  os = {},
})

local applied = nodeRuntime:applyAssignment({
  id = "node-computer-1",
  name = "Rack A",
  role = "storage",
  master = "modem-master",
  masterId = "master-computer",
  token = "token-1",
}, "modem-master")
check(applied == true, "a node accepts its assignment")
equal(nodeRuntime.name, "Rack A", "the node adopts its name")
equal(nodeRuntime.role, "storage", "the node adopts its role")
equal(nodeRuntime.master, "modem-master", "the node stores its master")
equal(nodeConfigData.hostname, "Rack A", "the assignment is persisted")
check(#nodeCalls > 0, "the node acknowledges the assignment")
local ackCall = nodeCalls[#nodeCalls]
local ackVerb, ackFields = net.decode(ackCall.args[3])
equal(ackVerb, "ACK", "assignment sends ACK")
equal(ackFields.token, "token-1", "ACK carries the assignment token")
equal(ackCall.args[1], "modem-master", "ACK goes to the master")

local sentStatus = nodeRuntime:sendStatus()
check(sentStatus == true, "a provisioned node sends STATUS")
local statusCall = nodeCalls[#nodeCalls]
local statusVerb, statusFields = net.decode(statusCall.args[3])
equal(statusVerb, "STATUS", "heartbeat verb")
equal(statusFields.id, "node-computer-1", "heartbeat id")
equal(statusFields.state, "online", "heartbeat state")

local pingFrame = net.encode("PING", {
  id = "node-computer-1",
  master = "modem-new",
  masterId = "master-new",
})
nodeRuntime:handleModem("node-modem-1", "modem-new", net.PORT, 0, pingFrame)
equal(nodeRuntime.master, "modem-new", "a node adopts a replacement master")
equal(nodeRuntime.masterId, "master-new", "a node adopts the replacement master id")
local pongCall = nodeCalls[#nodeCalls]
local pongVerb, pongFields = net.decode(pongCall.args[3])
equal(pongVerb, "PONG", "PING receives PONG")
equal(pongCall.args[1], "modem-new", "PONG answers the pinging master")
equal(pongFields.state, "online", "PONG reports online")

local lostNode = nodeModule.new({
  kernel = nodeKernel,
  config = {
    get = function(key)
      if key == "hostname" then
        return "TC-N9"
      elseif key == "nodeRole" then
        return "worker"
      end
      return ""
    end,
    set = function() end,
  },
  vfs = vfsModule.new(newVolume()),
  log = nil,
  version = { version = "0.3.0" },
  theme = { colors = { bg = 0, text = 0, dim = 0, accent = 0, ok = 0, warn = 0 } },
  gfxModule = nil,
  component = nodeComponent,
  computer = nodeComputer,
  os = {},
})
local beforeHello = #nodeCalls
check(lostNode:sendHello() == true, "an unprovisioned node broadcasts HELLO")
local helloCall = nodeCalls[#nodeCalls]
local helloVerb, helloFields = net.decode(helloCall.args[2])
equal(helloVerb, "HELLO", "broadcast verb")
equal(helloFields.id, "node-computer-1", "HELLO carries the computer id")
check(#nodeCalls > beforeHello, "HELLO is transmitted")

--------------------------------------------------------------------------------
-- Netboot: full provisioning run against fake hardware
--------------------------------------------------------------------------------

local bootAddress = "floppy-1"
local netbootShutdown = false
local netbootCalls = {}
local netbootPull = {}
local netbootClock = 0
local netbootFloppyVolume = newVolume()
local netbootFloppy = vfsModule.new(netbootFloppyVolume)
local netbootTargetVolume = newVolume({ total = 2 * 1024 * 1024 })
local netbootTarget = vfsModule.new(netbootTargetVolume)
local volumes = {
  ["floppy-1"] = netbootFloppyVolume,
  ["hdd-1"] = netbootTargetVolume,
}

local preparedInstall, preparedReason = provision.prepare(source, netbootFloppy, { version = "0.3.0" })
check(preparedInstall ~= nil, "the netboot test floppy is prepared: " .. tostring(preparedReason))

local netbootComponent = {
  list = function(kind)
    local items = ({
      filesystem = { "floppy-1", "hdd-1" },
      modem = { "modem-master" },
      gpu = {},
    })[kind] or {}
    local index = 0
    return function()
      index = index + 1
      if items[index] then
        return items[index], kind
      end
    end
  end,
  proxy = function(address)
    return volumes[address]
  end,
  invoke = function(address, method, ...)
    if address == "modem-master" then
      if method == "isWired" then
        return true
      elseif method == "open" or method == "close" then
        return true
      elseif method == "send" or method == "broadcast" then
        netbootCalls[#netbootCalls + 1] = {
          method = method,
          args = table.pack(...),
        }
        return true
      end
    end
    local volume = volumes[address]
    if volume and type(volume[method]) == "function" then
      return volume[method](...)
    end
    return nil, "unknown component"
  end,
}
local netbootComputer = {
  address = function()
    return "node-computer-1"
  end,
  uptime = function()
    return netbootClock
  end,
  totalMemory = function()
    return 2 * 1024 * 1024
  end,
  getBootAddress = function()
    return bootAddress
  end,
  setBootAddress = function(address)
    bootAddress = address
    return true
  end,
  pullSignal = function(timeout)
    netbootClock = netbootClock + (timeout or 0)
    local item = table.remove(netbootPull, 1)
    if item then
      return table.unpack(item, 1, item.n)
    end
    return "shutdown"
  end,
  shutdown = function()
    netbootShutdown = true
    return true
  end,
}

netbootPull[1] = table.pack(
  "modem_message",
  "node-modem-1",
  "modem-master",
  net.PORT,
  0,
  net.encode("ASSIGN", {
    id = "node-computer-1",
    name = "TC-N1",
    role = "worker",
    master = "modem-master",
    masterId = "master-computer",
    token = "netboot-token",
  })
)

local netbootOk, netbootResult = pcall(netboot.run, {
  component = netbootComponent,
  computer = netbootComputer,
  os = { sleep = function() end },
  version = "0.3.0",
  noScreen = true,
})
check(netbootOk, "netboot runs without an error: " .. tostring(netbootResult))
check(netbootResult == true, "netboot completes the install")
equal(bootAddress, "hdd-1", "netboot sets the boot address to the target disk")
check(netbootTarget.exists("/boot/kernel.lua"), "netboot installs the kernel")
check(netbootTarget.exists("/init.lua"), "netboot installs the entry point")
check(not netbootTarget.exists("/var/install-incomplete"), "netboot clears the install marker")
local netbootConfig = netbootTarget.read("/etc/terracorp.cfg") or ""
check(netbootConfig:find('role = "node"', 1, true) ~= nil, "netboot writes a node configuration")
check(netbootConfig:find('master = "modem-master"', 1, true) ~= nil, "netboot stores the master modem")
check(netbootConfig:find('hostname = "TC-N1"', 1, true) ~= nil, "netboot stores the assigned name")
check(netbootShutdown == true, "netboot reboots after the install")

local installLog = netbootFloppy.read("/install.log") or ""
check(installLog:find("OK ", 1, true) ~= nil, "netboot writes an install log")
local ackSent = false
for _, call in ipairs(netbootCalls) do
  if call.method == "send" then
    local verb, fields = net.decode(call.args[3])
    if verb == "ACK" and fields.token == "netboot-token" then
      ackSent = true
      equal(call.args[1], "modem-master", "netboot ACK goes to the master")
    end
  end
end
check(ackSent, "netboot acknowledges the install")

return table.concat(failures, "\n")
