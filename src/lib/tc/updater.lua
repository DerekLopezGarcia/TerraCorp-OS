-- GitHub Releases updater for the boot filesystem. It stages and validates all
-- files before replacing anything; existing files are retained as backups.

local updater = {}

local OWNER = "DerekLopezGarcia"
local REPOSITORY = "TerraCorp-OS"
local API_URL = "https://api.github.com/repos/" .. OWNER .. "/" .. REPOSITORY .. "/releases/latest"
local RAW_URL = "https://raw.githubusercontent.com/" .. OWNER .. "/" .. REPOSITORY
local MAX_RESPONSE = 512 * 1024
local MAX_FILES = 64
local HTTP_TIMEOUT = 30

local function parseVersion(value)
  if type(value) ~= "string" then
    return nil
  end
  local major, minor, patch = value:match("^v?(%d+)%.(%d+)%.(%d+)$")
  if not major then
    return nil
  end
  return { tonumber(major), tonumber(minor), tonumber(patch) }
end

local function compareVersions(left, right)
  for index = 1, 3 do
    if left[index] ~= right[index] then
      return left[index] < right[index] and -1 or 1
    end
  end
  return 0
end

local function request(url, limit)
  local internetAddress = component.list("internet")()
  if not internetAddress then
    return nil, "No Internet Card is connected."
  end

  local headers = {
    ["User-Agent"] = "TerraCorp-OS updater",
    ["Accept"] = "application/vnd.github+json",
  }
  local requestOk, handle, reason = pcall(
    component.invoke,
    internetAddress,
    "request",
    url,
    nil,
    headers
  )
  if not requestOk then
    return nil, "HTTP request failed: " .. tostring(handle)
  end
  if not handle then
    return nil, tostring(reason or "The request could not be started.")
  end

  local function closeHandle()
    pcall(handle.close)
  end

  local chunks, size = {}, 0
  local responseLimit = limit or MAX_RESPONSE
  local function keepChunk(chunk)
    if type(chunk) ~= "string" or chunk == "" then
      return true
    end
    size = size + #chunk
    if size > responseLimit then
      return nil, "The response is larger than the allowed limit."
    end
    chunks[#chunks + 1] = chunk
    return true
  end

  local function waitBriefly()
    if type(os) == "table" and type(os.sleep) == "function" then
      pcall(os.sleep, 0.05)
    else
      computer.pullSignal(0.05)
    end
  end

  local deadline = computer.uptime() + HTTP_TIMEOUT
  if type(handle.finishConnect) == "function" then
    while true do
      local okConnect, connected = pcall(handle.finishConnect)
      if not okConnect then
        closeHandle()
        return nil, "HTTP request failed: " .. tostring(connected)
      end
      if connected then
        break
      end
      if computer.uptime() >= deadline then
        closeHandle()
        return nil, "HTTP request timed out after " .. HTTP_TIMEOUT .. " seconds."
      end
      waitBriefly()
    end
  else
    -- Older Internet Card handles expose response/read but not finishConnect.
    -- Poll response and drain available bytes until the asynchronous request
    -- publishes its status; preserve any body chunks read while waiting.
    while true do
      local okResponse, status = pcall(handle.response)
      if not okResponse then
        closeHandle()
        return nil, "Could not read HTTP response status: " .. tostring(status)
      end
      if type(status) == "number" then
        break
      elseif status ~= nil then
        closeHandle()
        return nil, "Could not read HTTP response status: " .. tostring(status)
      end

      local okRead, chunk, readError = pcall(handle.read, 8192)
      if not okRead then
        closeHandle()
        return nil, "Download failed while waiting for response: " .. tostring(chunk)
      end
      if chunk == nil then
        closeHandle()
        return nil, "The HTTP connection closed before returning a status"
          .. (readError and (": " .. tostring(readError)) or ".")
      end
      local kept, keepError = keepChunk(chunk)
      if not kept then
        closeHandle()
        return nil, keepError
      end
      if computer.uptime() >= deadline then
        closeHandle()
        return nil, "HTTP request timed out after " .. HTTP_TIMEOUT .. " seconds."
      end
      waitBriefly()
    end
  end

  local okResponse, status, responseMessage = pcall(handle.response)
  if not okResponse or type(status) ~= "number" then
    closeHandle()
    local detail = okResponse and tostring(responseMessage or status) or tostring(status)
    return nil, "Could not read HTTP response status: " .. detail
  end
  if status ~= 200 then
    closeHandle()
    return nil, "HTTP " .. tostring(status)
  end

  while true do
    local okRead, chunk, readError = pcall(handle.read, 8192)
    if not okRead then
      closeHandle()
      return nil, "Download failed: " .. tostring(chunk)
    end
    if not chunk then
      closeHandle()
      if readError then
        return nil, "Download failed: " .. tostring(readError)
      end
      break
    end
    local kept, keepError = keepChunk(chunk)
    if not kept then
      closeHandle()
      return nil, keepError
    end
  end

  local body = table.concat(chunks)
  if body == "" then
    return nil, "The server returned an empty response."
  end
  return body
end

local function releaseTag(body)
  local tag = body:match('"tag_name"%s*:%s*"([^"\\]+)"')
  local versionText = tag and tag:match("^v(%d+%.%d+%.%d+)$")
  local version = parseVersion(versionText)
  if not version then
    return nil, nil, nil, "GitHub's latest release must use a vMAJOR.MINOR.PATCH tag."
  end
  return tag, version, versionText
end

local function manifestPaths(body)
  local paths, seen = {}, {}
  for line in body:gmatch("[^\r\n]+") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      -- The repository manifest also contains EEPROM and OpenOS tooling files.
      -- The updater installs only the OS tree, so ignore entries outside src/.
      if line:sub(1, 4) == "src/" then
        if not line:match("^src/[%w_%-./]+%.lua$")
          or line:find("..", 1, true)
          or line:find("//", 1, true) then
          return nil, "The release manifest contains an unsafe OS path."
        end
        if not seen[line] then
          seen[line] = true
          paths[#paths + 1] = line
          if #paths > MAX_FILES then
            return nil, "The release contains too many OS files."
          end
        end
      end
    end
  end
  if #paths == 0 then
    return nil, "The release manifest contains no OS files."
  end
  for _, required in ipairs({ "src/init.lua", "src/boot/kernel.lua", "src/lib/tc/version.lua" }) do
    if not seen[required] then
      return nil, "The release manifest is missing " .. required .. "."
    end
  end
  table.sort(paths)
  return paths
end

local function writeFile(vfs, volume, path, content)
  local directory = path:match("^(.*)/[^/]+$")
  if directory then
    local ok, reason = vfs.ensureDir(directory)
    if not ok then
      return nil, reason
    end
  end

  local handle, reason = volume.open(path, "w")
  if not handle then
    return nil, reason
  end

  local offset = 1
  while offset <= #content do
    local chunk = content:sub(offset, offset + 4095)
    local ok, writeError = pcall(volume.write, handle, chunk)
    if not ok or writeError == nil or writeError == false then
      pcall(volume.close, handle)
      return nil, tostring(writeError or "write failed")
    end
    offset = offset + #chunk
  end

  local closeOk, closeError = pcall(volume.close, handle)
  if not closeOk then
    return nil, tostring(closeError)
  end
  return true
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
      local name = entry:gsub("/+$", "")
      local ok, removeError = removeTree(vfs, path .. "/" .. name)
      if not ok then
        return nil, removeError
      end
    end
  end
  return vfs.remove(path)
end

-- A reset (power loss, crash, reboot) in the middle of an install can leave the
-- backup tree behind. Blocking forever would strand the node on an older build,
-- so restore those originals before a new attempt. Empty leftover directories
-- are simply removed.
local function restoreBackup(vfs, root)
  if not vfs.exists(root) then
    return true
  end

  local files, pending = {}, { { path = root, relative = "" } }
  while #pending > 0 do
    local current = table.remove(pending)
    local entries, reason = vfs.list(current.path)
    if not entries then
      return nil, reason
    end
    for _, entry in ipairs(entries) do
      local name = entry:gsub("/+$", "")
      local full = current.path .. "/" .. name
      local relative = current.relative == "" and name or (current.relative .. "/" .. name)
      if vfs.isDirectory(full) then
        local children, childError = vfs.list(full)
        if not children then
          return nil, childError
        end
        if #children > 0 then
          pending[#pending + 1] = { path = full, relative = relative }
        else
          local removed, removeError = vfs.remove(full)
          if not removed then
            return nil, removeError or full
          end
        end
      else
        files[#files + 1] = { source = full, target = "/" .. relative }
      end
    end
  end

  for _, item in ipairs(files) do
    if vfs.exists(item.target) then
      local removed, removeError = vfs.remove(item.target)
      if not removed then
        return nil, removeError or item.target
      end
    end
    local dir = item.target:match("^(.*)/[^/]+$")
    local dirOk, dirError = vfs.ensureDir(dir)
    if not dirOk then
      return nil, dirError
    end
    local moved, moveError = vfs.rename(item.source, item.target)
    if not moved then
      return nil, moveError or item.target
    end
  end

  return removeTree(vfs, root)
end

local function rollback(vfs, changed)
  local errors = {}
  for index = #changed, 1, -1 do
    local item = changed[index]
    if item.installed and vfs.exists(item.target) then
      local ok, reason = vfs.remove(item.target)
      if not ok then
        errors[#errors + 1] = tostring(reason or item.target)
      end
    end
    if item.backedUp and vfs.exists(item.backup) then
      local ok, reason = vfs.rename(item.backup, item.target)
      if not ok then
        errors[#errors + 1] = tostring(reason or item.target)
      end
    end
  end
  return #errors == 0, table.concat(errors, ", ")
end

function updater.check(currentVersion)
  local current = parseVersion(currentVersion)
  if not current then
    return nil, "The installed OS version is invalid."
  end

  local body, reason = request(API_URL, 128 * 1024)
  if not body then
    return nil, reason
  end
  local tag, latest, version, tagError = releaseTag(body)
  if not tag then
    return nil, tagError
  end

  return {
    tag = tag,
    version = version,
    available = compareVersions(current, latest) < 0,
    current = currentVersion,
  }
end

--- Resolve the OS file list of a release tag by downloading its manifest.
-- Returns the sorted runtime paths ("src/..." form), or nil and a reason.
function updater.releasePaths(tag)
  local manifest, reason = request(RAW_URL .. "/" .. tag .. "/tools/manifest.txt")
  if not manifest then
    return nil, "Could not download the release manifest: " .. tostring(reason)
  end
  local paths, manifestError = manifestPaths(manifest)
  if not paths then
    return nil, manifestError
  end
  return paths
end

--- Download one release file into `root` without installing anything.
-- Used by the master to stage a runtime tree for its nodes. Returns the byte
-- count of the stored file, or nil and a reason.
function updater.stageFile(vfs, volume, tag, repositoryPath, root)
  local body, reason = request(RAW_URL .. "/" .. tag .. "/" .. repositoryPath)
  if not body then
    return nil, "Download failed: " .. tostring(reason)
  end
  if repositoryPath:sub(-4) == ".lua" then
    local chunk, syntaxError = load(body, "@" .. repositoryPath, "t", {})
    if not chunk then
      return nil, "Invalid Lua file " .. repositoryPath .. ": " .. tostring(syntaxError)
    end
  end

  local runtimePath = repositoryPath:sub(5)
  local stagePath = root .. "/" .. runtimePath
  local writeOk, writeError = writeFile(vfs, volume, stagePath, body)
  if not writeOk then
    return nil, "Could not stage " .. repositoryPath .. ": " .. tostring(writeError)
  end
  local stored = vfs.read(stagePath)
  if stored ~= body then
    return nil, "Staged file verification failed: " .. repositoryPath
  end
  return #body, body
end

-- Queue a release for the boot-time applier (src/boot/apply.lua). The desktop
-- only records the target; downloading, verification, and installation happen
-- before the kernel starts, with their own progress screen.
function updater.schedule(release, currentVersion, vfs)
  local current = parseVersion(currentVersion)
  local target = release and parseVersion(release.version)
  if not current or not target or compareVersions(current, target) >= 0 then
    return nil, "There is no newer valid release to install."
  end
  if release.tag ~= "v" .. release.version then
    return nil, "The release tag does not match its version."
  end
  if not vfs.exists("/boot/apply.lua") then
    return nil, "This installation cannot stage a boot-time update."
  end

  local dirOk, dirError = vfs.ensureDir("/var/update")
  if not dirOk then
    return nil, "Could not prepare the update directory: " .. tostring(dirError)
  end
  local written, writeError = vfs.write(
    "/var/update/pending",
    "version=" .. release.version .. "\ntag=" .. release.tag .. "\n"
  )
  if not written then
    return nil, "Could not queue the update: " .. tostring(writeError)
  end
  return true
end

function updater.install(release, currentVersion, vfs, volume)
  local current = parseVersion(currentVersion)
  local targetVersion = release and parseVersion(release.version)
  if not current or not targetVersion or compareVersions(current, targetVersion) >= 0 then
    return nil, "There is no newer valid release to install."
  end
  if release.tag ~= "v" .. release.version then
    return nil, "The release tag does not match its version."
  end

  local base = RAW_URL .. "/" .. release.tag
  local manifest, reason = request(base .. "/tools/manifest.txt")
  if not manifest then
    return nil, "Could not download the release manifest: " .. tostring(reason)
  end
  local paths, manifestError = manifestPaths(manifest)
  if not paths then
    return nil, manifestError
  end

  local stageRoot = "/var/update/stage/" .. release.version
  local backupRoot = "/var/update/backup/" .. release.version
  local clearOk, clearError = removeTree(vfs, stageRoot)
  if not clearOk then
    return nil, "Could not clear the previous staging directory: " .. tostring(clearError)
  end
  local recovered, recoverError = restoreBackup(vfs, backupRoot)
  if not recovered then
    return nil, "Could not recover the previous update backup: " .. tostring(recoverError)
  end

  local staged, totalBytes, versionSource = {}, 0, nil
  for _, repositoryPath in ipairs(paths) do
    local body, downloadError = request(base .. "/" .. repositoryPath)
    if not body then
      removeTree(vfs, stageRoot)
      return nil, "Could not download " .. repositoryPath .. ": " .. tostring(downloadError)
    end
    if repositoryPath:sub(-4) == ".lua" then
      local chunk, syntaxError = load(body, "@" .. repositoryPath, "t", {})
      if not chunk then
        removeTree(vfs, stageRoot)
        return nil, "Invalid Lua file " .. repositoryPath .. ": " .. tostring(syntaxError)
      end
    end
    local runtimePath = repositoryPath:sub(5)
    local stagePath = stageRoot .. "/" .. runtimePath
    local writeOk, writeError = writeFile(vfs, volume, stagePath, body)
    if not writeOk then
      removeTree(vfs, stageRoot)
      return nil, "Could not stage " .. repositoryPath .. ": " .. tostring(writeError)
    end
    local stored = vfs.read(stagePath)
    if stored ~= body then
      removeTree(vfs, stageRoot)
      return nil, "Staged file verification failed: " .. repositoryPath
    end
    staged[#staged + 1] = {
      target = "/" .. runtimePath,
      staged = stagePath,
      backup = backupRoot .. "/" .. runtimePath,
    }
    if runtimePath == "lib/tc/version.lua" then
      versionSource = body
    end
    totalBytes = totalBytes + #body
  end

  local sourceVersion = versionSource and versionSource:match('version%s*=%s*"([^"]+)"')
  if sourceVersion ~= release.version then
    removeTree(vfs, stageRoot)
    return nil, "The release tag and version.lua do not match."
  end

  local usedOk, used = pcall(volume.spaceUsed)
  local capacityOk, capacity = pcall(volume.spaceTotal)
  if usedOk and capacityOk and type(used) == "number" and type(capacity) == "number"
    and capacity - used < totalBytes + 16384 then
    removeTree(vfs, stageRoot)
    return nil, "Not enough free disk space to stage the update."
  end

  local backupCleanupOk, backupCleanupError = removeTree(vfs, "/var/update/backup")
  if not backupCleanupOk then
    removeTree(vfs, stageRoot)
    return nil, "Could not clear old update backups: " .. tostring(backupCleanupError)
  end

  local changed = {}
  for _, item in ipairs(staged) do
    local state = { target = item.target, backup = item.backup }
    changed[#changed + 1] = state

    if vfs.exists(item.target) then
      local dir = item.backup:match("^(.*)/[^/]+$")
      local dirOk, dirError = vfs.ensureDir(dir)
      if not dirOk then
        local restored, restoreError = rollback(vfs, changed)
        return nil, "Could not prepare backup: " .. tostring(dirError)
          .. (restored and "" or "; rollback failed: " .. tostring(restoreError))
      end
      local moved, moveError = vfs.rename(item.target, item.backup)
      if not moved then
        local restored, restoreError = rollback(vfs, changed)
        return nil, "Could not back up " .. item.target .. ": " .. tostring(moveError)
          .. (restored and "" or "; rollback failed: " .. tostring(restoreError))
      end
      state.backedUp = true
    end

    local installed, installError = vfs.rename(item.staged, item.target)
    if not installed then
      local restored, restoreError = rollback(vfs, changed)
      return nil, "Could not install " .. item.target .. ": " .. tostring(installError)
        .. (restored and "" or "; rollback failed: " .. tostring(restoreError))
    end
    state.installed = true
  end

  removeTree(vfs, stageRoot)
  return true, #staged, totalBytes
end

return updater
