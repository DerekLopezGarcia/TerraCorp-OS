-- Write the netboot payload to the rack floppy.
--
-- The floppy layout is:
--
--   /init.lua      the standalone netboot installer (src/boot/netboot.lua)
--   /payload/      the complete runtime tree copied to the node's HDD
--   /install.log   progress written by the node during provisioning
--
-- Only those paths are touched. A floppy that contains anything else is
-- rejected so an unrelated disk is never overwritten.

local provision = {}

provision.payloadRoot = "/payload"
provision.readyPath = "/payload/.ready"
provision.netbootPath = "/boot/netboot.lua"
provision.logPath = "/install.log"
provision.markerPath = "/var/install-incomplete"
provision.maxPayload = 500 * 1024
provision.margin = 16 * 1024
provision.runtime = { "/init.lua", "/boot", "/lib", "/apps" }
provision.allowedRoot = { ["init.lua"] = true, ["payload"] = true, ["install.log"] = true }
provision.payloadSkip = { ["/.ready"] = true }

local function cleanName(name)
  return tostring(name):gsub("/+$", "")
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

function provision.removeTree(vfs, path)
  return removeTree(vfs, path)
end

--- Verify that a floppy holds only a previous TerraCorp payload.
function provision.checkTarget(vfs)
  local entries, reason = vfs.list("/")
  if not entries then
    return nil, reason or "could not inspect the floppy"
  end
  for _, entry in ipairs(entries) do
    local name = cleanName(entry)
    if name ~= "" and not provision.allowedRoot[name] then
      return nil, "the floppy contains other data (" .. name .. ")"
    end
  end
  return true
end

--- Read the runtime tree from the master's boot volume.
-- Returns a sorted list of { path, data, size } and the total byte count.
function provision.collect(source)
  local entries, total = {}, 0

  local function walk(path)
    if source.isDirectory(path) then
      local names, reason = source.list(path)
      if not names then
        return nil, reason
      end
      table.sort(names)
      for _, name in ipairs(names) do
        local child = path .. "/" .. cleanName(name)
        local ok, childError = walk(child)
        if not ok then
          return nil, childError
        end
      end
      return true
    end

    local data, reason = source.read(path)
    if not data then
      return nil, reason or ("could not read " .. path)
    end
    entries[#entries + 1] = { path = path, data = data, size = #data }
    total = total + #data
    return true
  end

  for _, root in ipairs(provision.runtime) do
    if not source.exists(root) then
      return nil, "missing runtime path " .. root
    end
    local ok, reason = walk(root)
    if not ok then
      return nil, reason
    end
  end

  table.sort(entries, function(a, b)
    return a.path < b.path
  end)
  return entries, total
end

local function capacity(vfs)
  local used, total = nil, nil
  if vfs.space then
    local usedKb, totalKb = vfs.space()
    if type(usedKb) == "number" and type(totalKb) == "number" then
      used, total = usedKb * 1024, totalKb * 1024
    end
  end
  return used, total
end

local function writeTree(target, entries, root)
  for _, entry in ipairs(entries) do
    local path = root .. entry.path
    local directory = path:match("^(.*)/[^/]+$")
    if directory then
      local ok, reason = target.ensureDir(directory)
      if not ok then
        return nil, reason
      end
    end
    local written, reason = target.write(path, entry.data)
    if not written then
      return nil, reason or ("could not write " .. path)
    end
  end
  return true
end

--- Prepare a floppy from the master's runtime.
-- `source` is the boot-volume VFS; `target` is the floppy VFS.
-- Returns { files, bytes, version } or nil and a reason.
function provision.prepare(source, target, opts)
  opts = opts or {}

  local safe, reason = provision.checkTarget(target)
  if not safe then
    return nil, reason
  end

  local entries, total = provision.collect(source)
  if not entries then
    return nil, total
  end
  if total > provision.maxPayload then
    return nil, string.format(
      "the runtime is too large for a floppy (%d KB)",
      math.floor(total / 1024 + 0.5)
    )
  end

  local used, size = capacity(target)
  if used and size and size - used < total + provision.margin then
    return nil, string.format(
      "the floppy needs %d KB free but only %d KB are available",
      math.floor((total + provision.margin) / 1024 + 0.5),
      math.floor((size - used) / 1024)
    )
  end

  local netboot = source.read(provision.netbootPath)
  if not netboot then
    return nil, "missing " .. provision.netbootPath
  end

  -- Remove the old entry point first so a server cannot boot a half-written
  -- payload while the floppy is being prepared.
  if target.exists("/init.lua") then
    local removed, removeError = target.remove("/init.lua")
    if not removed then
      return nil, removeError or "could not replace /init.lua"
    end
  end

  local cleared, clearError = removeTree(target, provision.payloadRoot)
  if not cleared then
    return nil, clearError
  end

  local dirOk, dirError = target.ensureDir(provision.payloadRoot)
  if not dirOk then
    return nil, dirError
  end
  local written, writeError = writeTree(target, entries, provision.payloadRoot)
  if not written then
    return nil, writeError
  end

  local version = tostring(opts.version or "unknown")
  local ready = string.format("version=%s\nfiles=%d\nbytes=%d\n", version, #entries, total)
  local readyOk, readyError = target.write(provision.readyPath, ready)
  if not readyOk then
    return nil, readyError or "could not write the payload marker"
  end

  local log = string.format(
    "TerraCorp %s · payload prepared\n%d files · %d KB\nWaiting for a server to netboot from this floppy.\n",
    version,
    #entries,
    math.floor(total / 1024 + 0.5)
  )
  local logOk, logError = target.write(provision.logPath, log)
  if not logOk then
    return nil, logError or "could not write the install log"
  end

  local initOk, initError = target.write("/init.lua", netboot)
  if not initOk then
    return nil, initError or "could not write the netboot script"
  end

  return {
    files = #entries,
    bytes = total,
    version = version,
    capacity = size,
  }
end

--- Read a payload tree below `root`, returning paths relative to that root.
-- The floppy's readiness marker is not part of the installed system.
function provision.tree(source, root)
  local entries, total = {}, 0

  local function walk(path)
    if source.isDirectory(path) then
      local names, reason = source.list(path)
      if not names then
        return nil, reason
      end
      table.sort(names)
      for _, name in ipairs(names) do
        local clean = cleanName(name)
        if clean ~= "" then
          local ok, childError = walk(path .. "/" .. clean)
          if not ok then
            return nil, childError
          end
        end
      end
      return true
    end

    local relative = path:sub(#root + 1)
    if relative == "" then
      relative = "/" .. path:match("[^/]+$")
    end
    if not provision.payloadSkip[relative] then
      local data, reason = source.read(path)
      if not data then
        return nil, reason or ("could not read " .. path)
      end
      entries[#entries + 1] = { path = relative, data = data, size = #data }
      total = total + #data
    end
    return true
  end

  local ok, reason = walk(root)
  if not ok then
    return nil, reason
  end

  table.sort(entries, function(a, b)
    return a.path < b.path
  end)
  return entries, total
end

--- Decide whether a target disk may receive an install.
-- An empty disk is safe. A disk left half-written by an interrupted install is
-- safe only because it carries the marker this module writes first. Anything
-- else is refused, so a floppy left in the drive cannot overwrite a working
-- node.
function provision.checkInstallTarget(target)
  if target.exists(provision.markerPath) then
    return true, true
  end

  local entries, reason = target.list("/")
  if not entries then
    return nil, reason or "could not inspect the target disk"
  end
  for _, entry in ipairs(entries) do
    local name = cleanName(entry)
    if name ~= "" then
      return nil, "the target disk already contains data (" .. name .. ")"
    end
  end
  return true, false
end

--- Install a prepared payload onto a node's system disk.
-- `target` is the node HDD VFS and `payload` is the floppy VFS. The completion
-- marker is removed only after the kernel, entry point, and configuration are
-- all on disk, so an interrupted copy can be retried.
function provision.install(target, payload, opts)
  opts = opts or {}

  local safe, existing = provision.checkInstallTarget(target)
  if not safe then
    return nil, existing
  end

  local entries, total = provision.tree(payload, provision.payloadRoot)
  if not entries then
    return nil, total
  end
  if #entries == 0 then
    return nil, "the installer payload is empty"
  end

  local used, size = capacity(target)
  if used and size and size - used < total + provision.margin then
    return nil, string.format(
      "the target disk needs %d KB free but only %d KB are available",
      math.floor((total + provision.margin) / 1024 + 0.5),
      math.floor(size - used)
    )
  end

  local marker = string.format(
    "version=%s\nstarted=1\n",
    tostring(opts.version or "unknown")
  )
  local dirOk, dirReason = target.ensureDir("/var")
  if not dirOk then
    return nil, dirReason
  end
  local marked, markReason = target.write(provision.markerPath, marker)
  if not marked then
    return nil, markReason or "could not write the install marker"
  end

  local written, writeReason = writeTree(target, entries, "")
  if not written then
    return nil, writeReason
  end

  if not target.exists("/boot/kernel.lua") or not target.exists("/init.lua") then
    return nil, "the copied runtime is incomplete"
  end

  if opts.configText then
    local etcOk, etcReason = target.ensureDir("/etc")
    if not etcOk then
      return nil, etcReason
    end
    local configOk, configReason = target.write("/etc/terracorp.cfg", opts.configText)
    if not configOk then
      return nil, configReason or "could not write the node configuration"
    end
  end

  local cleared, clearReason = target.remove(provision.markerPath)
  if not cleared then
    return nil, clearReason or "could not clear the install marker"
  end

  return {
    files = #entries,
    bytes = total,
    replaced = existing == true,
  }
end

--- Serialize a node's /etc/terracorp.cfg.
-- The format matches tc.config so the installed node boots with the same
-- validation rules as the master.
function provision.configText(values)
  values = values or {}
  local role = values.role
  if role ~= "worker" and role ~= "storage" and role ~= "node" then
    role = "worker"
  end

  local lines = {
    "-- TerraCorp OS: system preferences",
    "return {",
    string.format("  accent = %q,", "cyan"),
    string.format("  charset = %q,", "unicode"),
    "  clock24 = true,",
    string.format("  hostname = %q,", tostring(values.name or "")),
    string.format("  iconLayout = %q,", ""),
    string.format("  iconOrder = %q,", ""),
    string.format("  logLevel = %q,", "info"),
    string.format("  master = %q,", tostring(values.master or "")),
    string.format("  masterId = %q,", tostring(values.masterId or "")),
    string.format("  nodeRole = %q,", role),
    string.format("  role = %q,", "node"),
    "  splash = false,",
    "}",
  }
  return table.concat(lines, "\n") .. "\n"
end

return provision
