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

-- The version column is optional: registry files written before it still
-- load, and newer files round-trip the version.
store[registry.path] = "legacy-1\tTC-L1\tworker\tmodem-1\toffline\t128\t1024\t5\n"
local legacyNodes = registry.load(vfs)
equal(#legacyNodes, 1, "a legacy registry line loads")
equal(legacyNodes[1].v, "", "a legacy line has no version")

local removed = registry.remove(loaded, "id-2")
check(removed ~= nil, "remove returns the dropped record")
equal(registry.find(loaded, "id-2"), nil, "the removed node is gone")

registry.upsert(loaded, { id = "id-1", v = "0.3.1" })
registry.save(vfs, loaded)
local versioned = registry.load(vfs)
equal(registry.find(versioned, "id-1").v, "0.3.1", "the version survives a save/reload")

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
put(source, "/boot/netfetch.lua", slurp("src/boot/netfetch.lua"))
put(source, "/lib/tc/vfs.lua", slurp("src/lib/tc/vfs.lua"))
put(source, "/lib/tc/provision.lua", slurp("src/lib/tc/provision.lua"))
put(source, "/lib/tc/net.lua", slurp("src/lib/tc/net.lua"))
put(source, "/lib/tc/pull.lua", slurp("src/lib/tc/pull.lua"))
put(source, "/apps/nodes.lua", "return {}\n")

--------------------------------------------------------------------------------
-- Floppy preparation and guarded installs
--------------------------------------------------------------------------------

local floppyVolume = newVolume()
local floppy = vfsModule.new(floppyVolume)
check(provision.checkTarget(floppy) == true, "an empty floppy is a valid target")

local prepared, prepareReason = provision.prepare(source, floppy, { version = "0.3.0" })
check(prepared ~= nil, "prepare writes the floppy: " .. tostring(prepareReason))
check(floppy.exists("/init.lua"), "prepare writes the pull bootstrap")
check(floppy.exists("/net.lua"), "prepare writes tc.net for the bootstrap")
check(floppy.exists("/ready.txt"), "prepare writes the readiness marker")
check(not floppy.exists("/payload"), "prepare no longer copies the runtime payload")
local ready = floppy.read("/ready.txt") or ""
check(ready:find("version=0.3.0", 1, true) ~= nil, "the readiness marker names the version")
check(
  floppy.read("/init.lua") == slurp("src/boot/netfetch.lua"),
  "prepare stages the netfetch bootstrap as /init.lua"
)
check(floppy.read("/net.lua") == slurp("src/lib/tc/net.lua"), "prepare stages tc.net as /net.lua")

-- Re-preparing reuses the bootstrap for the same version.
local readyMarker = floppy.read("/ready.txt")
local reused, reuseReason = provision.prepare(source, floppy, { version = "0.3.0", reuse = true })
check(reused ~= nil, "prepare reuses a same-version bootstrap: " .. tostring(reuseReason))
check(reused and reused.reused == true, "a reused prepare reports reused")
check(floppy.read("/ready.txt") == readyMarker, "reuse keeps the readiness marker")
check(floppy.exists("/init.lua"), "reuse keeps the bootstrap entry point")

-- A legacy payload floppy is converted: the payload tree is dropped and the
-- bootstrap is written in its place, even on a nearly full floppy.
local legacyVolume = newVolume({ total = 640 * 1024 })
local legacy = vfsModule.new(legacyVolume)
put(legacy, "/payload/lib/tc/vfs.lua", string.rep("x", 512 * 1024))
local converted, convertReason = provision.prepare(source, legacy, { version = "0.3.0", reuse = true })
check(converted ~= nil, "a full legacy floppy is converted: " .. tostring(convertReason))
check(not legacy.exists("/payload/lib/tc/vfs.lua"), "the legacy payload is removed")
check(legacy.exists("/init.lua") and legacy.exists("/net.lua"), "the bootstrap replaces the payload")

-- A broken readiness marker is not trusted; the bootstrap is rebuilt.
local brokenVolume = newVolume()
local broken = vfsModule.new(brokenVolume)
put(broken, "/ready.txt", "garbage")
local repaired, repairedReason = provision.prepare(source, broken, { version = "0.3.0", reuse = true })
check(repaired ~= nil, "a broken readiness marker is rebuilt: " .. tostring(repairedReason))
check(repaired and not repaired.reused, "a broken marker does not count as a bootstrap")

local dirtyVolume = newVolume()
local dirty = vfsModule.new(dirtyVolume)
put(dirty, "/photos/holiday.txt", "not ours")
local blocked, blockedReason = provision.prepare(source, dirty, { version = "0.3.0" })
check(blocked == nil, "prepare refuses a floppy with unrelated data")
check(tostring(blockedReason):find("other data") ~= nil, "unrelated data is named in the error")

-- provision.install still serves the classic payload path; build that floppy
-- by hand because prepare now writes the pull bootstrap.
local payloadFloppyVolume = newVolume()
local payloadFloppy = vfsModule.new(payloadFloppyVolume)
put(payloadFloppy, "/payload/.ready", "version=0.3.0\nfiles=3\nbytes=64\n")
put(payloadFloppy, "/payload/init.lua", "return true\n")
put(payloadFloppy, "/payload/boot/kernel.lua", "-- kernel\n")
put(payloadFloppy, "/payload/lib/tc/vfs.lua", "-- vfs\n")
put(payloadFloppy, "/payload/lib/tc/provision.lua", "-- provision\n")
put(payloadFloppy, "/payload/lib/tc/net.lua", "-- net\n")

local targetVolume = newVolume({ total = 2 * 1024 * 1024 })
local target = vfsModule.new(targetVolume)
local configText = provision.configText({
  name = "TC-N1",
  role = "storage",
  master = "modem-master",
  masterId = "master-computer",
})
local installed, installReason = provision.install(target, payloadFloppy, {
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
local retried, retryReason = provision.install(retry, payloadFloppy, {
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

do
local masterVolume = newVolume({ total = 4 * 1024 * 1024 })
local master = vfsModule.new(masterVolume)
put(master, "/init.lua", "return true\n")
put(master, "/boot/kernel.lua", "-- master kernel\n")
put(master, "/boot/netboot.lua", slurp("src/boot/netboot.lua"))
put(master, "/boot/netfetch.lua", slurp("src/boot/netfetch.lua"))
put(master, "/lib/tc/vfs.lua", slurp("src/lib/tc/vfs.lua"))
put(master, "/lib/tc/provision.lua", slurp("src/lib/tc/provision.lua"))
put(master, "/lib/tc/net.lua", slurp("src/lib/tc/net.lua"))
put(master, "/lib/tc/pull.lua", slurp("src/lib/tc/pull.lua"))
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

-- Re-arming with the bootstrap already on the floppy reuses it instead of
-- rewriting it.
local armedMarker = clusterFloppy.read("/ready.txt")
local rearmed, rearmedReason = cluster:prepareInstaller()
check(rearmed == true, "re-arming a prepared floppy succeeds: " .. tostring(rearmedReason))
check(
  tostring(rearmedReason):find("already on the floppy", 1, true) ~= nil,
  "re-arming reports the reused bootstrap"
)
check(clusterFloppy.read("/ready.txt") == armedMarker, "re-arming does not rewrite the bootstrap")

-- While the installer window is armed, the master serves its runtime tree to
-- booting servers. The filesystem root itself is never served; runtime
-- directories are listable and files come back in chunks.
local serveCalls = #clusterCalls
cluster:handle("modem_message", "modem-master", "node-modem-9", net.PORT, 0,
  net.encode("LIST", { id = "probe", path = "/" }))
local refusedRoot = false
for index = serveCalls + 1, #clusterCalls do
  local call = clusterCalls[index]
  if call.method == "send" then
    local verb = net.decode(call.args[3])
    if verb == "MISS" then
      refusedRoot = true
    end
  end
end
check(refusedRoot, "the filesystem root is never served")

local serveCalls2 = #clusterCalls
cluster:handle("modem_message", "modem-master", "node-modem-9", net.PORT, 0,
  net.encode("LIST", { id = "probe", path = "/boot" }))
local servedDirs
for index = serveCalls2 + 1, #clusterCalls do
  local call = clusterCalls[index]
  if call.method == "send" then
    local verb, fields = net.decode(call.args[3])
    if verb == "DIRS" then
      servedDirs = fields
    end
  end
end
check(servedDirs ~= nil, "a LIST receives a DIRS reply")
check(
  servedDirs and servedDirs.files == "kernel.lua,netboot.lua,netfetch.lua",
  "the directory listing names the runtime files"
)

local serveCalls3 = #clusterCalls
cluster:handle("modem_message", "modem-master", "node-modem-9", net.PORT, 0,
  net.encode("FETCH", { id = "probe", path = "/init.lua", off = 0 }))
local servedFile
for index = serveCalls3 + 1, #clusterCalls do
  local call = clusterCalls[index]
  if call.method == "send" then
    local verb, fields = net.decode(call.args[3])
    if verb == "DATA" then
      servedFile = fields
    end
  end
end
check(servedFile ~= nil, "a FETCH receives a DATA reply")
equal(servedFile and servedFile.data, "return true\n", "DATA carries the file content")
equal(servedFile and tonumber(servedFile.size), 12, "DATA names the file size")

cluster:handle("modem_message", "modem-master", "node-modem-9", net.PORT, 0,
  net.encode("FETCH", { id = "probe", path = "/etc/terracorp.cfg", off = 0 }))
local refused = false
for index = serveCalls3 + 1, #clusterCalls do
  local call = clusterCalls[index]
  if call.method == "send" then
    local verb = net.decode(call.args[3])
    if verb == "MISS" then
      refused = true
    end
  end
end
check(refused, "a path outside the runtime tree is refused")

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
check(
  registry.find(cluster:nodesList(), "node-1") == nil,
  "HELLO does not register the node before it boots"
)

local ack = net.encode("ACK", {
  token = assign and assign.token or "",
  id = "node-1",
  boot = "hdd-1",
  mem = 512,
  disk = 2048,
})
cluster:handle("modem_message", "modem-master", "node-modem-1", net.PORT, 0, ack)
check(
  registry.find(cluster:nodesList(), "node-1") == nil,
  "an ACK still does not register the node"
)

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
check(
  registry.find(cluster:nodesList(), "node-2") == nil,
  "the second node is not registered before it boots"
)
-- It joins the list only once it boots, passes the check, and reports STATUS.
local status2 = net.encode("STATUS", {
  id = "node-2",
  state = "online",
  mem = 256,
  disk = 1024,
})
cluster:handle("modem_message", "modem-master", "node-modem-2", net.PORT, 0, status2)
local secondNode = registry.find(cluster:nodesList(), "node-2")
check(secondNode ~= nil, "a verified STATUS registers the second node")
equal(secondNode and secondNode.modem, "node-modem-2", "the second node stores its own modem")
equal(#cluster:nodesList(), 2, "both nodes are listed")

local renamed, renameReason = cluster:rename("node-1", "Rack 1")
check(renamed == true, "cluster rename succeeds: " .. tostring(renameReason))
local roled, roleReason = cluster:setRole("node-1", "storage")
check(roled == true, "cluster role change succeeds: " .. tostring(roleReason))
equal(registry.find(cluster:nodesList(), "node-1").name, "Rack 1", "cluster stores the new name")
equal(registry.find(cluster:nodesList(), "node-1").role, "storage", "cluster stores the new role")
check((master.read(registry.path) or ""):find("Rack 1", 1, true) ~= nil, "the node registry persists")

-- Refresh pings every node with a known modem address.
local refreshBefore = #clusterCalls
local refreshed, refreshReason = cluster:refreshNodes()
check(refreshed == true, "refresh pings the known nodes: " .. tostring(refreshReason))
local refreshPings = 0
for index = refreshBefore + 1, #clusterCalls do
  local call = clusterCalls[index]
  if call.method == "send" then
    local verb = net.decode(call.args[3])
    if verb == "PING" then
      refreshPings = refreshPings + 1
    end
  end
end
check(refreshPings == 2, "refresh pings both known nodes")

-- A node can be dropped from the registry once it is gone.
local forgot, forgotReason = cluster:forget("node-2")
check(forgot == true, "forget removes a node: " .. tostring(forgotReason))
check(registry.find(cluster:nodesList(), "node-2") == nil, "the forgotten node is gone")
equal(#cluster:nodesList(), 1, "only the remaining node is listed")

-- Arm an update: without an internet card the release check is unavailable,
-- so the master falls back to serving its own runtime and offers it.
local armOk, armReason = cluster:armUpdate()
check(armOk == true, "armUpdate starts: " .. tostring(armReason))
cluster:tick()
local update = cluster:updateState()
check(update.phase == "ready", "without a release check the update serves the master's version")
equal(update.target, "0.3.0", "the update target is the master version")
local pullOffered = false
for _, call in ipairs(clusterCalls) do
  if call.method == "send" then
    local verb, fields = net.decode(call.args[3])
    if verb == "PULL" and fields.id == "node-1" and fields.v == "0.3.0" then
      pullOffered = true
    end
  end
end
check(pullOffered, "arming the update offers PULL to the known node")

-- STATUS records the node version, and the registry persists it.
cluster:handle("modem_message", "modem-master", "node-modem-1", net.PORT, 0,
  net.encode("STATUS", { id = "node-1", state = "online", mem = 512, disk = 2048, v = "0.3.1" }))
equal(registry.find(cluster:nodesList(), "node-1").v, "0.3.1", "STATUS records the node version")
check((master.read(registry.path) or ""):find("0.3.1", 1, true) ~= nil, "the node version persists")

clock = clock + clusterModule.INSTALL_WINDOW + 10
cluster:tick()
check(cluster:installerState().active == false, "the installer window expires")
local expiredCalls = #clusterCalls
local lateHello = net.encode("HELLO", { id = "node-3" })
cluster:handle("modem_message", "modem-master", "node-modem-3", net.PORT, 0, lateHello)
equal(#clusterCalls, expiredCalls, "an expired installer ignores HELLO")
check(registry.find(cluster:nodesList(), "node-3") == nil, "an ignored node is not registered")
cluster:shutdown()

end

--------------------------------------------------------------------------------
-- Node runtime: assignment, ACK, PING adoption, and heartbeats
--------------------------------------------------------------------------------

do
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
        local packed = table.pack(...)
        nodeCalls[#nodeCalls + 1] = {
          method = method,
          args = packed,
        }
        if method == "send" then
          nodeRespond(packed[3])
        end
        return true
      end
    end
    return nil, "unknown component"
  end,
}
-- The fake master answers LIST/FETCH from a small runtime tree so the node
-- can stage an update without any real network.
local nodeServed = {
  ["/init.lua"] = "return true\n",
  ["/boot/kernel.lua"] = "-- kernel update\n",
}
local nodePullQueue = {}
function nodeRespond(frame)
  local verb, fields = net.decode(frame)
  if verb == "LIST" then
    local files, dirs = "", ""
    if fields.path == "/" then
      files = "init.lua"
      dirs = "boot"
    elseif fields.path == "/boot" then
      files = "kernel.lua"
    end
    nodePullQueue[#nodePullQueue + 1] = table.pack(
      "modem_message",
      "node-modem",
      "modem-master",
      net.PORT,
      0,
      net.encode("DIRS", {
        id = fields.id,
        path = fields.path,
        files = files,
        dirs = dirs,
      })
    )
  elseif verb == "FETCH" then
    local body = nodeServed[fields.path] or ""
    local off = tonumber(fields.off) or 0
    nodePullQueue[#nodePullQueue + 1] = table.pack(
      "modem_message",
      "node-modem",
      "modem-master",
      net.PORT,
      0,
      net.encode("DATA", {
        id = fields.id,
        path = fields.path,
        off = off,
        size = #body,
        data = body:sub(off + 1, off + 512),
      })
    )
  end
end
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
  pullSignal = function(timeout)
    nodeClock = nodeClock + (timeout or 0)
    local item = table.remove(nodePullQueue, 1)
    if item then
      return table.unpack(item, 1, item.n)
    end
    return nil
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

-- The boot check gates reporting: a broken system stays silent.
nodeRuntime.healthy = false
check(nodeRuntime:sendPong("modem-new") == nil, "a node that failed the check does not answer PING")
local silentCalls = #nodeCalls
nodeRuntime:tick()
equal(#nodeCalls, silentCalls, "an unhealthy node sends no heartbeat")
nodeRuntime.healthy = nil

local checkOk, checkFailures = nodeRuntime:verify()
check(checkOk == false, "an empty system fails the boot check")
check(type(checkFailures) == "table" and #checkFailures > 0, "the boot check names what is missing")

-- A complete system passes the check and would report normally.
local checkedVolume = newVolume()
local checked = vfsModule.new(checkedVolume)
put(checked, "/init.lua", "return true\n")
put(checked, "/boot/kernel.lua", "-- kernel\n")
put(checked, "/lib/tc/vfs.lua", "-- vfs\n")
put(checked, "/lib/tc/net.lua", "-- net\n")
put(checked, "/lib/tc/node.lua", "-- node\n")
put(checked, "/lib/tc/config.lua", "-- config\n")
put(checked, "/etc/terracorp.cfg", "return {}\n")
local checkedNode = nodeModule.new({
  kernel = nodeKernel,
  config = nodeConfig,
  vfs = checked,
  log = nil,
  version = { version = "0.3.0" },
  theme = { colors = { bg = 0, text = 0, dim = 0, accent = 0, ok = 0, warn = 0 } },
  gfxModule = nil,
  component = nodeComponent,
  computer = nodeComputer,
  os = {},
})
check(checkedNode:verify() == true, "a complete system passes the boot check")

-- A node stages a master-offered update and marks it for the boot applier.
nodeRuntime:openModem()
local pulledOk, pulledCount = nodeRuntime:pullUpdate({
  v = "0.3.1",
  master = "modem-master",
}, "modem-master")
check(pulledOk == true, "the node stages a master update: " .. tostring(pulledCount))
check(pulledCount == 2, "the pull stages every served file")
local pendingMarker = nodeRuntime.vfs.read("/var/update/pending") or ""
check(pendingMarker:find("version=0.3.1", 1, true) ~= nil, "the pull marks the pending update")
check(pendingMarker:find("source=master", 1, true) ~= nil, "the pull names the master source")
check(
  nodeRuntime.vfs.read("/var/update/stage/0.3.1/init.lua") == "return true\n",
  "the pull stages the runtime files"
)

-- A PULL frame triggers the same staging and adopts the master address.
nodeRuntime:handleModem("node-modem-1", "modem-master", net.PORT, 0,
  net.encode("PULL", {
    id = "node-computer-1",
    v = "0.3.2",
    master = "modem-master",
    masterId = "master-2",
  }))
check(
  (nodeRuntime.vfs.read("/var/update/pending") or ""):find("version=0.3.2", 1, true) ~= nil,
  "a PULL frame stages the offered update"
)
equal(nodeRuntime.master, "modem-master", "a PULL adopts the master address")

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

end

--------------------------------------------------------------------------------
-- Netboot: full provisioning run against fake hardware
--------------------------------------------------------------------------------

do
local bootAddress = "floppy-1"
local bootSetComplete = false
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

-- The classic installer expects a payload floppy; prepare now writes the
-- pull bootstrap, so build the payload by hand.
put(netbootFloppy, "/payload/.ready", "version=0.3.0\nfiles=3\nbytes=64\n")
put(netbootFloppy, "/payload/init.lua", "return true\n")
put(netbootFloppy, "/payload/boot/kernel.lua", "-- kernel\n")
put(netbootFloppy, "/payload/lib/tc/vfs.lua", slurp("src/lib/tc/vfs.lua"))
put(netbootFloppy, "/payload/lib/tc/provision.lua", slurp("src/lib/tc/provision.lua"))
put(netbootFloppy, "/payload/lib/tc/net.lua", slurp("src/lib/tc/net.lua"))

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
    local log = netbootFloppy.read("/install.log") or ""
    bootSetComplete = netbootTarget.exists("/init.lua")
      and log:find("OK ", 1, true) ~= nil
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
check(bootSetComplete == true, "the boot address is set only after a complete copy")
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

-- A refused target disk never takes the boot address, so an interrupted or
-- failed install cannot leave the server unable to boot.
bootAddress = "floppy-1"
bootSetComplete = false
netbootShutdown = false
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
    token = "netboot-token-2",
  })
)
local refusedOk, refusedResult = pcall(netboot.run, {
  component = netbootComponent,
  computer = netbootComputer,
  os = { sleep = function() end },
  version = "0.3.0",
  noScreen = true,
})
check(refusedOk == true, "the refused retry runs without an error: " .. tostring(refusedResult))
check(refusedResult == false, "a refused target stops at the failure screen")
equal(bootAddress, "floppy-1", "a failed install leaves the boot address alone")
check(bootSetComplete == false, "a failed install never sets the boot address")

end

--------------------------------------------------------------------------------
-- Netfetch: full pull-based provisioning run against fake hardware
--------------------------------------------------------------------------------

do
local netfetch = require("boot.netfetch")

local nfBootAddress = ""
local nfBootComplete = false
local nfShutdown = false
local nfCalls = {}
local nfPull = {}
local nfClock = 0
local nfFloppyVolume = newVolume()
local nfFloppy = vfsModule.new(nfFloppyVolume)
local nfTargetVolume = newVolume({ total = 2 * 1024 * 1024 })
local nfTarget = vfsModule.new(nfTargetVolume)
local nfVolumes = {
  ["floppy-2"] = nfFloppyVolume,
  ["hdd-2"] = nfTargetVolume,
}

put(nfFloppy, "/ready.txt", "version=0.3.0\nfiles=2\nbytes=64\n")
put(nfFloppy, "/net.lua", slurp("src/lib/tc/net.lua"))

-- The fake master serves its runtime tree (the shared `source` volume).
local function nfRespond(frame)
  local verb, fields = net.decode(frame)
  if verb ~= "LIST" and verb ~= "FETCH" then
    return
  end
  local reply = nil
  if verb == "LIST" then
    local entries = source.list(fields.path)
    local files, dirs = {}, {}
    for _, name in ipairs(entries or {}) do
      local clean = tostring(name):gsub("/+$", "")
      if source.isDirectory(fields.path .. "/" .. clean) then
        dirs[#dirs + 1] = clean
      else
        files[#files + 1] = clean
      end
    end
    reply = net.encode("DIRS", {
      id = fields.id,
      path = fields.path,
      files = table.concat(files, ","),
      dirs = table.concat(dirs, ","),
    })
  else
    local body = source.read(fields.path) or ""
    local off = tonumber(fields.off) or 0
    reply = net.encode("DATA", {
      id = fields.id,
      path = fields.path,
      off = off,
      size = #body,
      data = body:sub(off + 1, off + 512),
    })
  end
  if reply then
    nfPull[#nfPull + 1] = table.pack(
      "modem_message",
      "node-modem",
      "modem-master",
      net.PORT,
      0,
      reply
    )
  end
end

local nfComponent = {
  list = function(kind)
    local items = ({
      filesystem = { "floppy-2", "hdd-2" },
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
    return nfVolumes[address]
  end,
  invoke = function(address, method, ...)
    if address == "modem-master" then
      if method == "isWired" then
        return true
      elseif method == "open" or method == "close" then
        return true
      elseif method == "send" or method == "broadcast" then
        local packed = table.pack(...)
        nfCalls[#nfCalls + 1] = { method = method, args = packed }
        nfRespond(packed[3])
        return true
      end
    end
    local volume = nfVolumes[address]
    if volume and type(volume[method]) == "function" then
      return volume[method](...)
    end
    return nil, "unknown component"
  end,
}
local nfComputer = {
  address = function()
    return "node-computer-2"
  end,
  uptime = function()
    return nfClock
  end,
  totalMemory = function()
    return 2 * 1024 * 1024
  end,
  getBootAddress = function()
    return nfBootAddress
  end,
  setBootAddress = function(address)
    nfBootAddress = address
    local log = nfFloppy.read("/install.log") or ""
    nfBootComplete = nfTarget.exists("/init.lua")
      and log:find("OK ", 1, true) ~= nil
    return true
  end,
  pullSignal = function(timeout)
    nfClock = nfClock + (timeout or 0)
    local item = table.remove(nfPull, 1)
    if item then
      return table.unpack(item, 1, item.n)
    end
    return nil
  end,
  shutdown = function()
    nfShutdown = true
    return true
  end,
}

nfPull[1] = table.pack(
  "modem_message",
  "node-modem",
  "modem-master",
  net.PORT,
  0,
  net.encode("ASSIGN", {
    id = "node-computer-2",
    name = "TC-N1",
    role = "worker",
    master = "modem-master",
    masterId = "master-computer",
    token = "netfetch-token",
  })
)

local nfOk, nfResult = pcall(netfetch.run, {
  component = nfComponent,
  computer = nfComputer,
  os = { sleep = function() end },
  version = "0.3.0",
  noScreen = true,
})
check(nfOk == true, "netfetch runs without an error: " .. tostring(nfResult))
check(nfResult == true, "netfetch completes the pull install")
equal(nfBootAddress, "hdd-2", "netfetch sets the boot address to the target disk")
check(nfBootComplete == true, "netfetch sets the boot address only after a complete copy")
check(nfTarget.exists("/boot/kernel.lua"), "netfetch installs the kernel")
check(nfTarget.exists("/init.lua"), "netfetch installs the entry point")
check(nfTarget.exists("/lib/tc/pull.lua"), "netfetch installs the pull client")
check(nfTarget.exists("/etc/terracorp.cfg"), "netfetch writes the node configuration")
check(not nfTarget.exists("/var/install-incomplete"), "netfetch clears the install marker")
local nfConfig = nfTarget.read("/etc/terracorp.cfg") or ""
check(nfConfig:find('hostname = "TC-N1"', 1, true) ~= nil, "netfetch stores the assigned name")
check(nfConfig:find('master = "modem-master"', 1, true) ~= nil, "netfetch stores the master modem")
check(nfShutdown == true, "netfetch reboots after the install")
local nfLog = nfFloppy.read("/install.log") or ""
check(nfLog:find("OK ", 1, true) ~= nil, "netfetch writes an install log")
local nfAck = false
for _, call in ipairs(nfCalls) do
  if call.method == "send" then
    local verb, fields = net.decode(call.args[3])
    if verb == "ACK" and fields.token == "netfetch-token" then
      nfAck = true
      equal(call.args[1], "modem-master", "netfetch ACK goes to the master")
    end
  end
end
check(nfAck, "netfetch acknowledges the install")

end

--------------------------------------------------------------------------------
-- Relay: job queue without a coordinator
--------------------------------------------------------------------------------

do
local jobs = require("tc.jobs")

-- Framing of the six Relay verbs.
local relayFrames = {
  { "JOB",    { id = "j-1", pub = "pub-1", task = "fs.check", args = "", ttl = 300, att = 1 } },
  { "CLAIM",  { id = "j-1", worker = "node-1", jobs = 0 } },
  { "GRANT",  { id = "j-1", token = "j-1:1:1", lease = 45 } },
  { "RESULT", { id = "j-1", token = "j-1:1:1", state = "done", out = "ok" } },
  { "CANCEL", { id = "j-1", pub = "pub-1" } },
  { "DRAIN",  { id = "node-1", drain = "true" } },
}
for _, item in ipairs(relayFrames) do
  local encoded, encodeReason = net.encode(item[1], item[2])
  check(encoded ~= nil, item[1] .. " encodes: " .. tostring(encodeReason))
  local decodedVerb, decodedFields = net.decode(encoded)
  equal(decodedVerb, item[1], item[1] .. " round-trips")
  equal(decodedFields.id, item[2].id, item[1] .. " keeps the job id")
end

local jqClock = 1000
local pubOut = {}
local journalVfs = vfsModule.new(newVolume())

local function makePublisher()
  return jobs.newPublisher({
    id = "pub-computer",
    vfs = journalVfs,
    log = nil,
    now = function()
      return jqClock
    end,
    send = function(address, verb, fields)
      pubOut[#pubOut + 1] = { to = address, verb = verb, fields = fields }
      return true
    end,
    broadcast = function(verb, fields)
      pubOut[#pubOut + 1] = { to = "*", verb = verb, fields = fields }
      return true
    end,
  })
end

local function lastOut(verb)
  for index = #pubOut, 1, -1 do
    if pubOut[index].verb == verb then
      return pubOut[index]
    end
  end
  return nil
end

local function countOut(verb)
  local count = 0
  for _, item in ipairs(pubOut) do
    if item.verb == verb then
      count = count + 1
    end
  end
  return count
end

local pub = makePublisher()

-- Publishing queues the job, broadcasts JOB, and appends the journal.
local job, publishReason = pub:publish("fs.check", "")
check(job ~= nil, "publish queues the job: " .. tostring(publishReason))
check(job.state == "queued" and job.attempts == 1, "a new job is queued at attempt 1")
local offer = lastOut("JOB")
check(offer ~= nil and offer.fields.task == "fs.check" and offer.fields.att == 1,
  "publish broadcasts JOB at attempt 1")
check((journalVfs.read("/var/jobs.tsv") or ""):find(job.id, 1, true) ~= nil,
  "publish appends the job to the journal")

check(pub:publish("", "") == nil, "an empty task name is refused")
check(pub:publish("bad task!", "") == nil, "an invalid task name is refused")

-- The first live claim wins; later claims are ignored.
pub:handleClaim({ id = job.id, worker = "node-1" }, "modem-1")
equal(job.state, "granted", "the first claim grants the job")
local grant = lastOut("GRANT")
check(grant ~= nil and grant.to == "modem-1" and grant.fields.token == job.token,
  "the grant goes to the claimant with the lease token")
pub:handleClaim({ id = job.id, worker = "node-2" }, "modem-2")
equal(countOut("GRANT"), 1, "a second claim on a granted job is ignored")

-- A result with the live token closes the job; a stale token is dropped.
pub:handleResult({ id = job.id, token = job.token, state = "done", out = "ok" })
equal(job.state, "done", "a live-token result completes the job")
equal(job.result, "ok", "the result output is recorded")

local job2 = pub:publish("disk.report", "")
pub:handleClaim({ id = job2.id, worker = "node-1" }, "modem-1")
pub:handleResult({ id = job2.id, token = "j-1:1:1", state = "done", out = "stale" })
equal(job2.state, "granted", "a stale token result is ignored")

-- Lease expiry re-offers with a new attempt; the retry budget fails the job.
jqClock = jqClock + jobs.LEASE + 1
pub:tick()
equal(job2.attempts, 2, "an expired lease is re-offered as attempt 2")
equal(job2.state, "queued", "the re-offer clears the grant")
equal(countOut("JOB"), 3, "the re-offer broadcasts JOB again")
pub:handleClaim({ id = job2.id, worker = "node-3" }, "modem-3")
local grant2 = lastOut("GRANT")
check(grant2 ~= nil and grant2.fields.token == job2.token,
  "the second attempt grants a fresh token")
jqClock = jqClock + jobs.LEASE + 1
pub:tick()
equal(job2.attempts, 3, "the second expiry re-offers attempt 3")
pub:handleClaim({ id = job2.id, worker = "node-4" }, "modem-4")
jqClock = jqClock + jobs.LEASE + 1
pub:tick()
equal(job2.state, "failed", "a job past the retry budget fails")
equal(job2.result, "no claimant", "the failed job records the reason")

-- A queued job with no claimant also re-offers and eventually fails.
local job3 = pub:publish("log.tail", "5")
jqClock = jqClock + jobs.LEASE + 1
pub:tick()
equal(job3.attempts, 2, "an unclaimed job is re-offered")
jqClock = jqClock + jobs.LEASE + 1
pub:tick()
jqClock = jqClock + jobs.LEASE + 1
pub:tick()
equal(job3.state, "failed", "an unclaimed job fails after the retry budget")
equal(job3.result, "no claimant", "the no-claimant reason is recorded")

-- A job older than its TTL fails outright.
local job4 = pub:publish("comp.count", "")
jqClock = jqClock + jobs.TTL + 1
pub:tick()
equal(job4.state, "failed", "a job past its TTL fails")
equal(job4.result, "expired", "the TTL reason is recorded")

-- Cancel marks the job and tells claimants to drop it.
local job5 = pub:publish("fs.check", "")
local canceled = pub:cancel(job5.id)
check(canceled ~= nil, "cancel returns the canceled job")
equal(job5.state, "canceled", "cancel marks the job")
check(lastOut("CANCEL") ~= nil, "cancel broadcasts CANCEL")
check(pub:cancel(job5.id) == nil, "a closed job cannot be canceled again")

-- A fresh publisher over the same journal resumes unfinished work and keeps
-- minting unique ids. The clock moves to a fresh slot so the resumed job is
-- not past its TTL.
jqClock = 5000
local job6 = pub:publish("fs.check", "")
local pub2 = makePublisher()
check(pub2:start() == true, "a fresh publisher loads the journal")
local summary = pub2:summary()
check(summary.queued == 1, "the unfinished job is queued after a restart: "
  .. tostring(summary.queued))
jqClock = jqClock + jobs.REOFFER + 1
pub2:tick()
local resumed = lastOut("JOB")
check(resumed ~= nil and resumed.fields.id == job6.id and tonumber(resumed.fields.att) == 2,
  "a resumed publisher re-offers the queued job")
local job7 = pub2:publish("fs.check", "")
check(job7.id ~= job6.id, "a resumed publisher mints fresh ids")

--------------------------------------------------------------------------------
-- Worker side: claim, run, and answer named tasks
--------------------------------------------------------------------------------

local workerClock = 10
local workerCalls = {}
local workerConfigData = {
  hostname = "TC-W1",
  nodeRole = "worker",
  master = "modem-master",
  masterId = "master-computer",
  drain = "",
}
local workerConfig = {
  get = function(key)
    return workerConfigData[key]
  end,
  set = function(key, value)
    workerConfigData[key] = value
  end,
  save = function()
    return true
  end,
}
local workerVfs = vfsModule.new(newVolume())
for _, path in ipairs(nodeModule.CHECK_PATHS) do
  workerVfs.write(path, "-- ok\n")
end
local workerComponent = {
  list = function(kind)
    local items = ({ modem = { "modem-w1" } })[kind] or {}
    local index = 0
    return function()
      index = index + 1
      if items[index] then
        return items[index], kind
      end
    end
  end,
  invoke = function(address, method, ...)
    if address == "modem-w1" then
      if method == "isWired" then
        return true
      elseif method == "open" or method == "close" then
        return true
      elseif method == "send" or method == "broadcast" then
        workerCalls[#workerCalls + 1] = {
          to = select(1, ...),
          verb = net.decode((select(3, ...))),
          frame = (select(3, ...)),
        }
        return true
      end
    end
    return nil, "unknown component"
  end,
}
local workerComputer = {
  address = function()
    return "worker-computer-1"
  end,
  uptime = function()
    return workerClock
  end,
  totalMemory = function()
    return 2 * 1024 * 1024
  end,
}
local worker = nodeModule.new({
  kernel = {
    address = "worker-computer-1",
    volumeAddress = "hdd-w",
    uptime = function()
      return workerClock
    end,
    storage = function()
      return 0, 2 * 1024 * 1024
    end,
    saveConfig = function()
      return true
    end,
  },
  config = workerConfig,
  vfs = workerVfs,
  log = nil,
  version = { version = "0.3.1" },
  theme = { colors = { bg = 0, text = 0, dim = 0, accent = 0, ok = 0, warn = 0 } },
  gfxModule = nil,
  component = workerComponent,
  computer = workerComputer,
  os = {},
})
worker.healthy = true
worker:openModem()
check(worker.modem ~= nil, "the worker node opens its modem")

local function workerSends(verb)
  local found = nil
  for _, call in ipairs(workerCalls) do
    if type(call.verb) == "string" and call.verb == verb then
      found = call
    end
  end
  return found
end

-- A known task with a free slot is claimed.
worker:handleModem("modem-w1", "modem-master", net.PORT, 0,
  net.encode("JOB", { id = "jobA", pub = "pub-1", task = "fs.check", args = "", att = 1 }))
local claimCall = workerSends("CLAIM")
check(claimCall ~= nil, "a known task is claimed")
check(claimCall and net.decode(claimCall.frame) and
  select(2, net.decode(claimCall.frame)).worker == "worker-computer-1",
  "the claim names the worker")

-- An unknown task and a draining node are not claimed.
worker:handleModem("modem-w1", "modem-master", net.PORT, 0,
  net.encode("JOB", { id = "jobB", pub = "pub-1", task = "not.a.task", args = "", att = 1 }))
local stillA = workerSends("CLAIM")
equal(stillA and select(2, net.decode(stillA.frame)).id, "jobA",
  "an unknown task is not claimed")

-- The grant runs the task and answers the granting address.
worker:handleModem("modem-w1", "modem-master", net.PORT, 0,
  net.encode("GRANT", { id = "jobA", token = "jobA:1:1", lease = 45 }))
local resultCall = workerSends("RESULT")
check(resultCall ~= nil, "the granted task answers with RESULT")
equal(resultCall.to, "modem-master", "the result goes back to the granter")
local resultVerb, resultFields = net.decode(resultCall.frame)
equal(resultFields.state, "done", "a healthy node runs fs.check to done")
equal(resultFields.out, "ok", "the fs.check output is recorded")

-- DRAIN persists the flag and stops claiming.
worker:handleModem("modem-w1", "modem-master", net.PORT, 0,
  net.encode("DRAIN", { id = "worker-computer-1", drain = "true" }))
equal(workerConfigData.drain, "true", "the drain flag persists in the config")
local statusFields = worker:statusFields()
equal(statusFields.drain, "true", "STATUS reports the drain flag")
worker:handleModem("modem-w1", "modem-master", net.PORT, 0,
  net.encode("JOB", { id = "jobC", pub = "pub-1", task = "fs.check", args = "", att = 1 }))
local drainClaim = workerSends("CLAIM")
equal(drainClaim and select(2, net.decode(drainClaim.frame)).id, "jobA",
  "a draining node does not claim new work")

-- Undraining accepts work again; CANCEL drops a pending claim.
worker:handleModem("modem-w1", "modem-master", net.PORT, 0,
  net.encode("DRAIN", { id = "worker-computer-1", drain = "false" }))
equal(worker:statusFields().drain, "false", "undraining clears the flag")
worker:handleModem("modem-w1", "modem-master", net.PORT, 0,
  net.encode("JOB", { id = "jobD", pub = "pub-1", task = "comp.count", args = "", att = 1 }))
local claimD = workerSends("CLAIM")
check(claimD ~= nil and select(2, net.decode(claimD.frame)).id == "jobD",
  "an undrained node claims again")
worker:handleModem("modem-w1", "modem-master", net.PORT, 0,
  net.encode("CANCEL", { id = "jobD", pub = "pub-1" }))
check(worker.claims["jobD"] == nil, "CANCEL drops the pending claim")

-- Expired claims are forgotten by the tick sweep.
worker:handleModem("modem-w1", "modem-master", net.PORT, 0,
  net.encode("JOB", { id = "jobE", pub = "pub-1", task = "fs.check", args = "", att = 1 }))
check(worker.claims["jobE"] ~= nil, "a new claim is pending")
workerClock = workerClock + nodeModule.CLAIM_TTL + 1
worker:tick()
check(worker.claims["jobE"] == nil, "the tick sweep forgets expired claims")

--------------------------------------------------------------------------------
-- Master wiring: CLAIM and RESULT reach the publisher through cluster:handle
--------------------------------------------------------------------------------

local mClock = 2000
local mCalls = {}
local mComponent = {
  list = function(kind)
    local items = ({ modem = { "modem-m" } })[kind] or {}
    local index = 0
    return function()
      index = index + 1
      if items[index] then
        return items[index], kind
      end
    end
  end,
  invoke = function(address, method, ...)
    if address == "modem-m" then
      if method == "isWired" then
        return true
      elseif method == "open" or method == "close" then
        return true
      elseif method == "send" or method == "broadcast" then
        mCalls[#mCalls + 1] = {
          to = (select(1, ...)),
          verb = (net.decode((select(3, ...)))),
          frame = (select(3, ...)),
        }
        return true
      end
    end
    return nil, "unknown component"
  end,
}
local mCluster = clusterModule.new({
  kernel = {
    address = "m-computer",
    volumeAddress = "fs-m",
    uptime = function()
      return mClock
    end,
    mount = function()
      return nil
    end,
  },
  vfs = vfsModule.new(newVolume()),
  config = {},
  log = nil,
  version = { version = "0.3.1" },
  component = mComponent,
  computer = { address = function() return "m-computer" end },
})
check(mCluster:start() == true, "the master starts for the jobs test")

local mJob, mReason = mCluster:publishJob("fs.check", "")
check(mJob ~= nil, "cluster:publishJob queues the job: " .. tostring(mReason))
mCluster:handle("modem_message", "modem-m", "modem-w", net.PORT, 0,
  net.encode("CLAIM", { id = mJob.id, worker = "wk-1" }))
equal(mJob.state, "granted", "a CLAIM routes to the publisher")
local mGrant = nil
for _, call in ipairs(mCalls) do
  if call.verb == "GRANT" then
    mGrant = call
  end
end
check(mGrant ~= nil, "the publisher grants through cluster:send")
mCluster:handle("modem_message", "modem-m", "modem-w", net.PORT, 0,
  net.encode("RESULT", { id = mJob.id, token = mJob.token, state = "done", out = "ok" }))
equal(mJob.state, "done", "a RESULT routes to the publisher")
check(mCluster:cancelJob(mJob.id) == nil, "a closed job cannot be canceled again")
local mCounts = mCluster:jobsSummary()
equal(mCounts.done, 1, "the cluster summary counts the finished job")

end

return table.concat(failures, "\n")
