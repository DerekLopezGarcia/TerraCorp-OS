-- Tests for tc.flash: writing the node installer medium from the master.
--
-- Run through tools/harness/test-flash.js. The master's volume and the floppies
-- are in memory; the round trip at the end feeds the flashed medium to the
-- installer to prove it installs.

local vfsModule = require("tc.vfs")
local installer = require("tc.installer")
local flash = require("tc.flash")
local payload = require("tc.payload")

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
    total = opts.total or 512 * 1024,
    readOnly = opts.readOnly or false,
    handles = {},
    nextHandle = 0,
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
  function volume.getLabel()
    return opts.label or ""
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
    if mode == "r" and volume.files[key] == nil then
      return nil, "no such file"
    end
    volume.nextHandle = volume.nextHandle + 1
    volume.handles[volume.nextHandle] = { path = key, mode = mode, pos = 1, buffer = "" }
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
    if entry.mode == "w" then
      volume.used = volume.used - #(volume.files[entry.path] or "")
      volume.files[entry.path] = entry.buffer
      volume.used = volume.used + #entry.buffer
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

--------------------------------------------------------------------------------
-- The master's own volume
--------------------------------------------------------------------------------

local MASTER_ADDRESS = "master-0001"

local function masterVolume()
  -- The master carries the node payload, so the fake must carry exactly the
  -- files tc.payload names: the flasher copies that list and nothing else.
  local files = {
    ["/etc/terracorp.cfg"] = "return { role = \"desktop\", name = \"master\" }\n",
    ["/var/log/tc.log"] = "master log\n",
    ["/var/plant/history.tsv"] = "samples\n",
  }
  for _, path in ipairs(payload.files) do
    files[path] = "-- payload stub for " .. path .. "\n"
  end
  return newVolume({
    total = 4 * 1024 * 1024,
    files = files,
    dirs = { "/boot", "/lib", "/lib/tc", "/apps", "/etc", "/var", "/var/log", "/var/plant" },
  })
end

local function newComponent(volumes, bootAddress)
  local state = { volumes = volumes }
  state.component = {
    list = function(kind)
      local addresses = {}
      if kind == "filesystem" then
        for address in pairs(volumes) do
          addresses[#addresses + 1] = address
        end
      end
      table.sort(addresses)
      local index = 0
      return function()
        index = index + 1
        local address = addresses[index]
        if address then
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
  state.bootAddress = bootAddress
  return state
end

local function newFlash(volumes, opts)
  opts = opts or {}
  local componentState = newComponent(volumes, opts.bootAddress or "fs-boot")
  return flash.new({
    kernel = { volumeAddress = opts.bootAddress or "fs-boot" },
    vfs = vfsModule.new(volumes[opts.bootAddress or "fs-boot"]),
    log = { info = function() end, warn = function() end },
    config = { get = function() return "" end },
    version = { version = "0.4.9" },
    computer = {
      address = function()
        return MASTER_ADDRESS
      end,
    },
    component = componentState.component,
  }), componentState
end

--------------------------------------------------------------------------------
-- Choosing the medium
--------------------------------------------------------------------------------

do
  local floppy = newVolume()
  local volumes = { ["fs-boot"] = masterVolume(), ["floppy-1"] = floppy }
  local flasher = newFlash(volumes)
  local mediums = flasher:mediums()
  equal(#mediums, 1, "the boot volume is never offered as a medium")
  equal(mediums[1] and mediums[1].address, "floppy-1", "the floppy is offered")

  local readOnly = newVolume({ readOnly = true })
  local volumes2 = { ["fs-boot"] = masterVolume(), ["readonly"] = readOnly }
  local flasher2 = newFlash(volumes2)
  equal(#flasher2:mediums(), 0, "a read-only medium is not offered")
end

--------------------------------------------------------------------------------
-- Writing the installer
--------------------------------------------------------------------------------

do
  local floppy = newVolume()
  local flasher = newFlash({ ["fs-boot"] = masterVolume(), ["floppy-1"] = floppy })
  local summary, reason = flasher:auto({})
  check(summary ~= nil, "the installer is written (" .. tostring(reason) .. ")")
  equal(summary and summary.state, "empty", "an empty medium is reported as empty")

  local written = vfsModule.new(floppy)
  check(written.exists("/init.lua"), "the entry point is on the medium")
  check(written.exists("/boot/kernel.lua"), "the kernel is on the medium")
  check(written.exists("/lib/tc/naming.lua"), "the libraries are on the medium")
  -- A line node has no desktop: carrying /apps is what made the medium 514 KB.
  check(not written.exists("/apps/nodes.lua"), "the desktop apps stay off the medium")
  check(written.exists("/installer.lua"), "the installer marker is written")
  check(written.exists("/etc/terracorp.cfg"), "the node configuration is written")
  check(not written.exists("/var/log/tc.log"), "the master's log never travels")
  check(not written.exists("/var/plant/history.tsv"), "the master's samples never travel")

  local config = written.read("/etc/terracorp.cfg")
  contains(config, 'role = "slave"', "the medium boots as a slave node")
  contains(config, "master = " .. '"' .. MASTER_ADDRESS .. '"', "the medium already knows its master")
end

do
  -- A medium flashed before is ours and may be rewritten; the marker proves it.
  local floppy = newVolume({ files = { ["/installer.lua"] = "-- old marker\n" } })
  local flasher = newFlash({ ["fs-boot"] = masterVolume(), ["floppy-1"] = floppy })
  local summary = flasher:auto({})
  check(summary ~= nil, "our own medium is rewritten")
  equal(summary and summary.state, "ours", "the medium is recognised as ours")
end

do
  local floppy = newVolume({ files = { ["/notes.txt"] = "mine\n" } })
  local flasher = newFlash({ ["fs-boot"] = masterVolume(), ["floppy-1"] = floppy })
  local summary, reason = flasher:auto({})
  check(summary == nil, "a medium with foreign data is refused")
  contains(reason, "already contains data", "the refusal says why")
  equal(floppy.files["notes.txt"], "mine\n", "the foreign data is untouched")
end

do
  local floppy = newVolume({ total = 2048 })
  local flasher = newFlash({ ["fs-boot"] = masterVolume(), ["floppy-1"] = floppy })
  local summary, reason = flasher:auto({})
  check(summary == nil, "an undersized medium is refused")
  contains(reason, "KB free", "the refusal names the shortfall")
end

do
  local flasher = newFlash({ ["fs-boot"] = masterVolume() })
  local summary, reason = flasher:auto({})
  check(summary == nil, "no medium means no flash")
  equal(reason, "no_medium", "the reason is no_medium")
end

--------------------------------------------------------------------------------
-- The medium really installs
--------------------------------------------------------------------------------

do
  local floppy = newVolume()
  local flasher = newFlash({ ["fs-boot"] = masterVolume(), ["floppy-1"] = floppy })
  check(flasher:auto({}) ~= nil, "the medium is flashed for the round trip")

  local hdd = newVolume({ total = 2 * 1024 * 1024 })
  local result, reason = installer.install(vfsModule.new(hdd), vfsModule.new(floppy), {})
  check(result ~= nil, "the flashed medium installs onto a disk (" .. tostring(reason) .. ")")

  local disk = vfsModule.new(hdd)
  check(disk.exists("/init.lua"), "the disk has the entry point")
  check(disk.exists("/boot/kernel.lua"), "the disk has the kernel")
  check(not disk.exists("/installer.lua"), "the marker stays off the disk")
  contains(disk.read("/etc/terracorp.cfg"), 'role = "slave"', "the disk keeps the node configuration")
end

if checked == 0 then
  failures[#failures + 1] = "no assertions ran"
end

return table.concat(failures, "\n")
