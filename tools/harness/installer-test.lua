-- Tests for the line node installer: the engine (tc.installer) and the entry
-- that runs from the floppy (boot/install.lua). Run through
-- tools/harness/test-installer.js.
--
-- The volumes are in memory and behave like a filesystem component. Two things
-- matter here: the floppy is only ever read, and nothing half-written survives
-- as a bootable disk.

local vfs = require("tc.vfs")
local installer = require("tc.installer")

local failures, checked = {}, 0

local function check(condition, message)
  checked = checked + 1
  if not condition then
    failures[#failures + 1] = message
  end
end

local function equal(actual, expected, message)
  checked = checked + 1
  if actual ~= expected then
    failures[#failures + 1] = message ..
      " (got " .. tostring(actual) .. ", expected " .. tostring(expected) .. ")"
  end
end

local function contains(text, needle, message)
  checked = checked + 1
  if type(text) ~= "string" or not text:find(needle, 1, true) then
    failures[#failures + 1] = message .. " (looked for " .. tostring(needle) .. ")"
  end
end

--------------------------------------------------------------------------------
-- An in-memory filesystem component
--------------------------------------------------------------------------------

local function newVolume(opts)
  opts = opts or {}
  local volume = {
    files = {},
    dirs = { [""] = true },
    used = 0,
    total = opts.total or 1024 * 1024,
    readOnly = opts.readOnly or false,
    handles = {},
    nextHandle = 0,
    truncate = opts.truncate,
  }

  local function norm(value)
    return tostring(value or ""):gsub("^/+", "")
  end

  for file, data in pairs(opts.files or {}) do
    volume.files[norm(file)] = data
    volume.used = volume.used + #data
  end
  for _, dir in ipairs(opts.dirs or {}) do
    volume.dirs[norm(dir)] = true
  end

  function volume.exists(value)
    local key = norm(value)
    return volume.files[key] ~= nil or volume.dirs[key] == true
  end

  function volume.isDirectory(value)
    return volume.dirs[norm(value)] == true
  end

  function volume.isReadOnly()
    return volume.readOnly
  end

  function volume.list(value)
    local base = norm(value)
    if not volume.dirs[base] then
      return nil, "not a directory"
    end
    local prefix = base == "" and "" or (base .. "/")
    local seen, names = {}, {}
    local function add(entry)
      if entry:sub(1, #prefix) ~= prefix then
        return
      end
      local rest = entry:sub(#prefix + 1)
      local name = rest:match("^([^/]+)")
      if name and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
    for file in pairs(volume.files) do
      add(file)
    end
    for dir in pairs(volume.dirs) do
      if dir ~= "" then
        add(dir)
      end
    end
    table.sort(names)
    return names
  end

  function volume.open(value, mode)
    local key = norm(value)
    if mode == "r" then
      if volume.files[key] == nil then
        return nil, "no such file"
      end
    elseif mode ~= "w" and mode ~= "a" then
      return nil, "bad mode"
    end
    volume.nextHandle = volume.nextHandle + 1
    volume.handles[volume.nextHandle] = {
      path = key,
      mode = mode,
      pos = 1,
      buffer = "",
    }
    return volume.nextHandle
  end

  function volume.read(handle, count)
    local entry = volume.handles[handle]
    if not entry then
      return nil, "bad handle"
    end
    local data = volume.files[entry.path] or ""
    local chunk = data:sub(entry.pos, entry.pos + count - 1)
    entry.pos = entry.pos + count
    if chunk == "" then
      return nil
    end
    return chunk
  end

  function volume.write(handle, data)
    local entry = volume.handles[handle]
    if not entry then
      return nil, "bad handle"
    end
    entry.buffer = entry.buffer .. data
    return true
  end

  function volume.close(handle)
    local entry = volume.handles[handle]
    if not entry then
      return nil, "bad handle"
    end
    if entry.mode == "w" or entry.mode == "a" then
      local body = entry.buffer
      local shrink = volume.truncate and volume.truncate:gsub("^/+", "")
      if shrink and entry.path:find(shrink, 1, true) and #body > 1 then
        body = body:sub(1, #body - 1)
      end
      volume.used = volume.used - #(volume.files[entry.path] or "")
      if entry.mode == "a" then
        body = (volume.files[entry.path] or "") .. body
      end
      volume.files[entry.path] = body
      volume.used = volume.used + #body
    end
    volume.handles[handle] = nil
    return true
  end

  function volume.makeDirectory(value)
    volume.dirs[norm(value)] = true
    return true
  end

  function volume.remove(value)
    local key = norm(value)
    if volume.files[key] then
      volume.used = volume.used - #volume.files[key]
      volume.files[key] = nil
      return true
    end
    if volume.dirs[key] then
      volume.dirs[key] = nil
      return true
    end
    return nil, "no such file"
  end

  function volume.rename()
    return nil, "unsupported"
  end

  function volume.spaceUsed()
    return volume.used
  end

  function volume.spaceTotal()
    return volume.total
  end

  return volume
end

local function snapshot(volume)
  local copy, keys = {}, {}
  for key in pairs(volume.files) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    copy[key] = volume.files[key]
  end
  return copy
end

local function sameFiles(left, right)
  for key, value in pairs(left) do
    if right[key] ~= value then
      return false, key
    end
  end
  for key in pairs(right) do
    if left[key] == nil then
      return false, key
    end
  end
  return true
end

--------------------------------------------------------------------------------
-- The installer image and the target disks
--------------------------------------------------------------------------------

local function image(opts)
  opts = opts or {}
  local files = {
    ["/installer.lua"] = "-- installer marker\n",
    ["/install.log"] = "stale log\n",
    ["/init.lua"] = "return true\n",
    ["/boot/kernel.lua"] = "return { start = function() end }\n",
    ["/boot/install.lua"] = _INSTALL_SOURCE, -- the real entry, as a payload file
    ["/lib/tc/version.lua"] = _SRC_VERSION,
    ["/lib/tc/vfs.lua"] = _SRC_VFS,
    ["/lib/tc/installer.lua"] = _SRC_INSTALLER,
    ["/lib/tc/naming.lua"] = "return {}\n",
    ["/etc/terracorp.cfg"] = "return { role = \"line\" }\n",
  }
  for file, data in pairs(opts.extra or {}) do
    files[file] = data
  end
  return newVolume({
    files = files,
    dirs = { "/boot", "/lib", "/lib/tc", "/etc" },
    readOnly = true,
  }), files
end

local function floppyVfs()
  return vfs.new(image())
end

--------------------------------------------------------------------------------
-- collect: what the image carries, and what it never installs
--------------------------------------------------------------------------------

do
  local volume, files = image()
  local expectedCount, expectedBytes = 0, 0
  for path, data in pairs(files) do
    if path ~= "/installer.lua" and path ~= "/install.log" then
      expectedCount = expectedCount + 1
      expectedBytes = expectedBytes + #data
    end
  end

  local entries, total = installer.collect(vfs.new(volume))
  check(entries ~= nil, "collect reads the image")
  equal(#entries, expectedCount, "the scaffolding is skipped, the rest installs")
  local paths = {}
  for _, entry in ipairs(entries) do
    paths[entry.path] = true
    check(entry.path:sub(1, 1) == "/", "every entry is an absolute path")
  end
  check(paths["/init.lua"], "the entry point is installed")
  check(paths["/boot/kernel.lua"], "the kernel is installed")
  check(paths["/lib/tc/vfs.lua"], "the filesystem module is installed")
  check(paths["/etc/terracorp.cfg"], "a prepared configuration travels with the image")
  check(not paths["/installer.lua"], "the installer marker is not installed")
  check(not paths["/install.log"], "the installer log is not installed")
  equal(total, expectedBytes, "collect reports the exact byte count")
  check(entries[1].path <= entries[#entries].path, "entries come back sorted")
end

--------------------------------------------------------------------------------
-- checkTarget: what may be written
--------------------------------------------------------------------------------

do
  local empty = vfs.new(newVolume())
  local allowed, state = installer.checkTarget(empty)
  check(allowed, "an empty disk may be installed")
  equal(state, "empty", "an empty disk reports empty")

  local partial = vfs.new(newVolume({ files = { ["/var/install-incomplete"] = "x" } }))
  local resume, resumeState = installer.checkTarget(partial)
  check(resume, "an interrupted install may be resumed")
  equal(resumeState, "incomplete", "the marker names the interrupted install")

  local used = vfs.new(newVolume({
    files = { ["/boot/kernel.lua"] = "old", ["/init.lua"] = "old" },
  }))
  local refused, why = installer.checkTarget(used)
  check(not refused, "a disk with a runtime is not overwritten")
  equal(why, "installed", "the refusal names the reason")

  local stranger = vfs.new(newVolume({ files = { ["/notes.txt"] = "mine" } }))
  check(not installer.checkTarget(stranger), "a disk with foreign data is refused")
end

--------------------------------------------------------------------------------
-- install: the happy path, and the floppy is never written
--------------------------------------------------------------------------------

do
  local floppy, files = image()
  local before = snapshot(floppy)
  local target = vfs.new(newVolume())

  local expected = 0
  for path in pairs(files) do
    if path ~= "/installer.lua" and path ~= "/install.log" then
      expected = expected + 1
    end
  end

  local result, reason = installer.install(target, vfs.new(floppy), { version = "0.4.9" })
  check(result ~= nil, "the install succeeds on an empty disk (" .. tostring(reason) .. ")")
  equal(result and result.files, expected, "every image file lands on the target")
  check(target.exists("/init.lua"), "the entry point is on the disk")
  check(target.exists("/boot/kernel.lua"), "the kernel is on the disk")
  check(target.exists("/lib/tc/naming.lua"), "the libraries are on the disk")
  check(target.exists("/etc/terracorp.cfg"), "the configuration is on the disk")
  check(not target.exists("/installer.lua"), "the installer marker stays off the disk")
  check(not target.exists("/install.log"), "the installer log stays off the disk")
  check(not target.exists(installer.markerPath), "the install marker is cleared")

  local same, difference = sameFiles(before, snapshot(floppy))
  check(same, "the installer medium is untouched (changed: " .. tostring(difference) .. ")")
end

--------------------------------------------------------------------------------
-- install: refusing, reinstalling and what survival means
--------------------------------------------------------------------------------

do
  local target = vfs.new(newVolume({
    files = {
      ["/boot/kernel.lua"] = "old kernel",
      ["/init.lua"] = "old entry",
      ["/lib/tc/legacy.lua"] = "old module",
      ["/var/plant/history.tsv"] = "sample",
      ["/etc/stocks.tsv"] = "casing/item/in",
    },
    dirs = { "/boot", "/lib", "/lib/tc", "/var", "/var/plant", "/etc" },
  }))

  local refused, why = installer.install(target, floppyVfs(), {})
  check(not refused, "an installed disk is refused without force")
  equal(why, "installed", "the refusal is the installed state")
  equal(target.read("/boot/kernel.lua"), "old kernel", "the refused install wrote nothing")

  local result = installer.install(target, floppyVfs(), { force = true })
  check(result ~= nil, "a forced install replaces the runtime")
  equal(result and result.state, "reinstalled", "the result names the reinstall")
  check(not target.exists("/lib/tc/legacy.lua"), "the old runtime is gone")
  equal(target.read("/var/plant/history.tsv"), "sample", "the sample ring survives a reinstall")
  equal(target.read("/etc/stocks.tsv"), "casing/item/in", "the line configuration survives")
  check(target.exists("/boot/kernel.lua"), "the new kernel is in place")
end

--------------------------------------------------------------------------------
-- install: the failures that must not leave a bootable disk
--------------------------------------------------------------------------------

do
  local small = vfs.new(newVolume({ total = 2048 }))
  local result, reason = installer.install(small, floppyVfs(), {})
  check(not result, "an undersized disk is refused")
  contains(reason, "KB free", "the capacity error names the shortfall")

  local volume = newVolume({ truncate = "/boot/kernel.lua" })
  local result2, reason2 = installer.install(vfs.new(volume), floppyVfs(), {})
  check(not result2, "a short write fails the install")
  contains(reason2, "verification failed", "the failure names verification")

  local broken = image({ extra = { ["/lib/tc/broken.lua"] = "this is not lua" } })
  local result3, reason3 = installer.install(vfs.new(newVolume()), vfs.new(broken), {})
  check(not result3, "a Lua file that does not compile fails the install")
  contains(reason3, "invalid Lua", "the failure names the file")
end

--------------------------------------------------------------------------------
-- configText: what an unconfigured image writes
--------------------------------------------------------------------------------

do
  local text = installer.configText({ name = "casing", master = "abc" })
  contains(text, 'role = "line"', "the node boots in the line role")
  contains(text, 'name = "casing"', "the name is written")
  contains(text, 'master = "abc"', "the master address is written")
  contains(installer.configText({}), 'name = ""', "an unnamed node starts with an empty name")
end

--------------------------------------------------------------------------------
-- boot/install.lua: the entry that runs from the floppy
--------------------------------------------------------------------------------

local function loadEntry()
  local body = _INSTALL_SOURCE
  if type(body) ~= "string" or body == "" then
    return nil, "the runner did not inject src/boot/install.lua"
  end
  local chunk, reason = load(body, "=boot/install.lua", "t")
  if not chunk then
    return nil, reason
  end
  return chunk()
end

local function fakeComputer()
  local state = { boot = nil, shutdown = nil, clock = 0 }
  state.computer = {
    address = function()
      return "floppy-owner"
    end,
    uptime = function()
      return state.clock
    end,
    pullSignal = function()
      return nil
    end,
    setBootAddress = function(address)
      state.boot = address
      return true
    end,
    getBootAddress = function()
      return state.boot
    end,
    shutdown = function(reboot)
      state.shutdown = reboot and "reboot" or "off"
    end,
  }
  return state
end

local function fakeComponent(volumes)
  return {
    list = function(kind)
      local kindIndex = 0
      local addresses = {}
      for address in pairs(volumes) do
        addresses[#addresses + 1] = address
      end
      table.sort(addresses)
      return function()
        kindIndex = kindIndex + 1
        local address = addresses[kindIndex]
        if address and kind == "filesystem" then
          return address, "filesystem"
        end
        return nil
      end
    end,
    proxy = function(address)
      return volumes[address]
    end,
    invoke = function(address, method, ...)
      local volume = volumes[address]
      if not volume or type(volume[method]) ~= "function" then
        return nil, "no such method"
      end
      return volume[method](...)
    end,
  }
end

local function runEntry(floppyVolume, targetVolume)
  local entry, reason = loadEntry()
  if not entry then
    failures[#failures + 1] = "install.lua did not load: " .. tostring(reason)
    return nil
  end
  local volumes = { ["floppy"] = floppyVolume, ["hdd"] = targetVolume }
  local state = fakeComputer()
  local floppy = vfs.new(floppyVolume)
  local ok, why = pcall(entry.run, {
    address = "floppy",
    component = fakeComponent(volumes),
    computer = state.computer,
    read = function(path)
      return floppy.read(path)
    end,
  })
  if not ok then
    failures[#failures + 1] = "install.lua crashed: " .. tostring(why)
    return nil
  end
  return state, why
end

do
  local target = newVolume()
  local state = runEntry(image(), target)
  check(state ~= nil, "the entry runs on a fresh computer")
  equal(state and state.boot, "hdd", "the boot address moves to the disk")
  equal(state and state.shutdown, "reboot", "the computer reboots into the node")
  local installed = vfs.new(target)
  check(installed.exists("/boot/kernel.lua"), "the runtime is on the disk after the entry run")
  check(not installed.exists("/installer.lua"), "the marker never reaches the disk")
end

do
  -- No screen and an existing node: the entry cannot ask, so it must not touch it.
  local target = newVolume({
    files = {
      ["/boot/kernel.lua"] = "old kernel",
      ["/init.lua"] = "old entry",
    },
    dirs = { "/boot" },
  })
  local state = runEntry(image(), target)
  check(state ~= nil, "the entry runs against an installed disk")
  equal(state and state.boot, nil, "an existing node keeps its boot address")
  equal(state and state.shutdown, nil, "an existing node is not rebooted")
  equal(target.files["boot/kernel.lua"], "old kernel", "the existing runtime is untouched")
end

if checked == 0 then
  failures[#failures + 1] = "no assertions ran"
end

return table.concat(failures, "\n")
