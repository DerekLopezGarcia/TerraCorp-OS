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
  local handle, reason = component.invoke(internetAddress, "request", url, nil, headers)
  if not handle then
    return nil, tostring(reason or "The request could not be started.")
  end

  if type(handle.finishConnect) ~= "function" then
    pcall(handle.close)
    return nil, "The HTTP handle cannot wait for its response."
  end

  local deadline = computer.uptime() + HTTP_TIMEOUT
  while true do
    local okConnect, connected, connectError = pcall(handle.finishConnect)
    if not okConnect then
      pcall(handle.close)
      return nil, "HTTP request failed: " .. tostring(connected)
    end
    if connected then
      break
    end
    if computer.uptime() >= deadline then
      pcall(handle.close)
      return nil, "HTTP request timed out after " .. HTTP_TIMEOUT .. " seconds."
    end

    if type(os) == "table" and type(os.sleep) == "function" then
      pcall(os.sleep, 0.05)
    else
      computer.pullSignal(0.05)
    end
  end

  local okResponse, status, responseMessage = pcall(handle.response)
  if not okResponse or type(status) ~= "number" then
    pcall(handle.close)
    local detail = okResponse and tostring(responseMessage or status) or tostring(status)
    return nil, "Could not read HTTP response status: " .. detail
  end
  if status ~= 200 then
    pcall(handle.close)
    return nil, "HTTP " .. tostring(status)
  end

  local chunks, size = {}, 0
  while true do
    local okRead, chunk, readError = pcall(handle.read, 8192)
    if not okRead then
      pcall(handle.close)
      return nil, "Download failed: " .. tostring(chunk)
    end
    if not chunk then
      pcall(handle.close)
      if readError then
        return nil, "Download failed: " .. tostring(readError)
      end
      break
    end
    size = size + #chunk
    if size > (limit or MAX_RESPONSE) then
      pcall(handle.close)
      return nil, "The response is larger than the allowed limit."
    end
    chunks[#chunks + 1] = chunk
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
      if not line:match("^src/[%w_%-./]+%.lua$") or line:find("..", 1, true) then
        return nil, "The release manifest contains an unsafe path."
      end
      if not seen[line] then
        seen[line] = true
        paths[#paths + 1] = line
        if #paths > MAX_FILES then
          return nil, "The release contains too many files."
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
  if vfs.exists(backupRoot) then
    return nil, "A backup for this release already exists; it was preserved."
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
