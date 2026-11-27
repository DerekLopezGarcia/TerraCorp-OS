-- Line node installer engine.
--
-- The floppy holds this runtime at its root plus `/installer.lua`; the installer
-- copies the tree to the computer's HDD, writes the node configuration there and
-- leaves the floppy untouched, so one floppy commissions every node.
--
-- This is the generic half of the old rack provisioning: recursive copy, target
-- guard, capacity check, byte verification and config serialization. Nothing here
-- knows about racks, masters or ASSIGN, and it has no dependencies so the
-- installer can load it in the minimal BIOS environment.

local installer = {}

installer.entryPath = "/installer.lua"
installer.markerPath = "/var/install-incomplete"
installer.configPath = "/etc/terracorp.cfg"
installer.margin = 16 * 1024

-- The image's own scaffolding is never part of the installed system.
installer.skip = {
  ["installer.lua"] = true,
  ["install.log"] = true,
}

local function cleanName(name)
  return tostring(name):gsub("/+$", "")
end

local function join(base, name)
  if base == "" or base == "/" then
    return "/" .. name
  end
  return base .. "/" .. name
end

local function capacity(vfs)
  if not vfs.space then
    return nil, nil
  end
  local usedKb, totalKb = vfs.space()
  if type(usedKb) ~= "number" or type(totalKb) ~= "number" then
    return nil, nil
  end
  return usedKb * 1024, totalKb * 1024
end

local function removeTree(vfs, path)
  if not vfs.exists(path) then
    return true
  end
  if vfs.isDirectory(path) then
    local entries, reason = vfs.list(path)
    if not entries then
      return nil, reason
    end
    for _, entry in ipairs(entries) do
      local name = cleanName(entry)
      if name ~= "" then
        local ok, removeError = removeTree(vfs, path .. "/" .. name)
        if not ok then
          return nil, removeError
        end
      end
    end
  end
  return vfs.remove(path)
end

function installer.removeTree(vfs, path)
  return removeTree(vfs, path)
end

--- Read the whole installer image as `{ path, data, size }` entries.
-- The scaffolding (`/installer.lua`, `/install.log`) is skipped, so the image
-- can carry it without installing it.
function installer.collect(source, skip)
  skip = skip or installer.skip
  local entries, total = {}, 0

  local function walk(path, relative)
    if source.isDirectory(path) then
      local names, reason = source.list(path)
      if not names then
        return nil, reason or ("could not list " .. tostring(path))
      end
      table.sort(names)
      for _, raw in ipairs(names) do
        local name = cleanName(raw)
        if name ~= "" then
          local childRelative = relative == "" and name or (relative .. "/" .. name)
          local ok, why = walk(join(path, name), childRelative)
          if not ok then
            return nil, why
          end
        end
      end
      return true
    end

    if skip[relative] then
      return true
    end

    local data, reason = source.read(path)
    if not data then
      return nil, reason or ("could not read " .. tostring(relative))
    end
    entries[#entries + 1] = { path = "/" .. relative, data = data, size = #data }
    total = total + #data
    return true
  end

  local ok, why = walk("/", "")
  if not ok then
    return nil, why
  end
  table.sort(entries, function(a, b)
    return a.path < b.path
  end)
  return entries, total
end

--- Whether a target disk already holds a TerraCorp runtime.
function installer.hasInstall(target)
  return target.exists("/boot/kernel.lua") and target.exists("/init.lua")
end

--- Decide whether a target may receive an install.
-- Empty: safe. Carrying this module's marker: safe, it is an interrupted install
-- and the marker is what proves it. Anything else: refused, so a floppy left in
-- the drive cannot quietly replace a working node.
function installer.checkTarget(target)
  if target.exists(installer.markerPath) then
    return true, "incomplete"
  end
  if installer.hasInstall(target) then
    return nil, "installed"
  end
  local entries, reason = target.list("/")
  if not entries then
    return nil, reason or "could not inspect the target disk"
  end
  for _, entry in ipairs(entries) do
    if cleanName(entry) ~= "" then
      return nil, "installed"
    end
  end
  return true, "empty"
end

--- Remove the runtime from a target that is being reinstalled.
-- `/etc` and `/var` stay: the node configuration and the sample ring are the
-- operator's data, not part of the runtime.
function installer.wipe(target)
  for _, root in ipairs({ "/init.lua", "/boot", "/lib", "/apps" }) do
    local ok, reason = removeTree(target, root)
    if not ok then
      return nil, reason
    end
  end
  return true
end

local function writeEntry(target, entry, verify)
  local directory = entry.path:match("^(.*)/[^/]+$")
  if directory and directory ~= "" then
    local ok, reason = target.ensureDir(directory)
    if not ok then
      return nil, reason
    end
  end

  local written, reason = target.write(entry.path, entry.data)
  if not written then
    return nil, reason or ("could not write " .. entry.path)
  end

  if verify then
    -- A truncated write or a full disk fails here instead of at boot, and a Lua
    -- file that does not compile is caught before it becomes the next boot.
    local readBack = target.read(entry.path)
    if readBack ~= entry.data then
      return nil, "verification failed for " .. entry.path
    end
    if entry.path:sub(-4) == ".lua" then
      local chunk = load(entry.data, "@" .. entry.path, "t", {})
      if not chunk then
        return nil, "invalid Lua in " .. entry.path
      end
    end
  end
  return true
end

--- Install the image onto a target HDD.
-- `target` is the destination VFS, `source` the installer image. The completion
-- marker is removed only after the runtime and the configuration are on disk, so
-- an interrupted install is retried instead of being mistaken for a good one.
function installer.install(target, source, opts)
  opts = opts or {}

  local allowed, state = installer.checkTarget(target)
  if not allowed and not opts.force then
    return nil, state
  end
  if opts.force then
    local wiped, reason = installer.wipe(target)
    if not wiped then
      return nil, reason
    end
    state = "reinstalled"
  end

  local entries, total = installer.collect(source)
  if not entries then
    return nil, total
  end
  if #entries == 0 then
    return nil, "the installer image is empty"
  end

  local used, size = capacity(target)
  if used and size and size - used < total + installer.margin then
    return nil, string.format(
      "the target disk needs %d KB free but only %d KB are available",
      math.floor((total + installer.margin) / 1024 + 0.5),
      math.floor((size - used) / 1024)
    )
  end

  local varOk, varReason = target.ensureDir("/var")
  if not varOk then
    return nil, varReason
  end
  local marked, markReason = target.write(installer.markerPath, string.format(
    "version=%s\nstarted=1\n",
    tostring(opts.version or "unknown")
  ))
  if not marked then
    return nil, markReason or "could not write the install marker"
  end

  for _, entry in ipairs(entries) do
    local ok, reason = writeEntry(target, entry, true)
    if not ok then
      return nil, reason
    end
  end

  if not installer.hasInstall(target) then
    return nil, "the copied runtime is incomplete"
  end

  if opts.configText then
    local etcOk, etcReason = target.ensureDir("/etc")
    if not etcOk then
      return nil, etcReason
    end
    local wrote, writeReason = target.write(installer.configPath, opts.configText)
    if not wrote then
      return nil, writeReason or "could not write the node configuration"
    end
  end

  local cleared, clearReason = target.remove(installer.markerPath)
  if not cleared then
    return nil, clearReason or "could not clear the install marker"
  end

  return {
    files = #entries,
    bytes = total,
    state = state,
  }
end

--- Serialize a node's /etc/terracorp.cfg.
-- The format matches tc.config, so an installed node boots with the same
-- validation rules as the master.
function installer.configText(values)
  values = values or {}
  local lines = {
    "-- TerraCorp OS: system preferences",
    "return {",
    string.format("  charset = %q,", "unicode"),
    "  clock24 = true,",
    string.format("  logLevel = %q,", "info"),
    string.format("  master = %q,", tostring(values.master or "")),
    string.format("  name = %q,", tostring(values.name or "")),
    string.format("  role = %q,", "slave"),
    "  splash = false,",
    "}",
  }
  return table.concat(lines, "\n") .. "\n"
end

return installer
