-- TerraCorp OS boot-time update applier.
--
-- Runs from /init.lua before the kernel starts, using only `component` and
-- `computer`. An install therefore survives a desktop failure, shows its own
-- progress screen, and cannot leave the running OS half-replaced without
-- restoring it first.
--
-- /var/update/pending is written by the About app:
--   version=0.1.9
--   tag=v0.1.9
--
-- The applier downloads that release, validates every file, installs it with
-- backups, verifies version.lua, and rolls back on any failure.

local env = ...
local component = env.component
local computer = env.computer
local invoke = env.invoke
local readSource = env.read

local OWNER = "DerekLopezGarcia"
local REPOSITORY = "TerraCorp-OS"
local RAW_URL = "https://raw.githubusercontent.com/" .. OWNER .. "/" .. REPOSITORY
local MARKER = "/var/update/pending"
local STATUS = "/var/update/status"
local STAGE_ROOT = "/var/update/stage"
local BACKUP_ROOT = "/var/update/backup"
local MAX_FILES = 64
local MAX_RESPONSE = 512 * 1024
local HTTP_TIMEOUT = 30

local function fs(method, ...)
  return invoke(env.address, method, ...)
end

local function readFile(path)
  local handle, reason = fs("open", path, "r")
  if not handle then
    return nil, reason or ("could not open " .. path)
  end
  local chunks = {}
  while true do
    local data, why = fs("read", handle, 4096)
    if type(data) ~= "string" or data == "" then
      fs("close", handle)
      if why then
        return nil, why
      end
      break
    end
    chunks[#chunks + 1] = data
  end
  fs("close", handle)
  return table.concat(chunks)
end

local function exists(path)
  local ok, value = pcall(fs, "exists", path)
  return ok and value == true
end

local function isDirectory(path)
  local ok, value = pcall(fs, "isDirectory", path)
  return ok and value == true
end

local function ensureDir(path)
  local current = ""
  for part in tostring(path):gmatch("[^/]+") do
    current = current .. "/" .. part
    if not exists(current) then
      local ok, reason = fs("makeDirectory", current)
      if not ok and not exists(current) then
        return nil, reason or ("could not create " .. current)
      end
    end
  end
  return true
end

local function writeFile(path, body)
  local dir = path:match("^(.*)/[^/]+$")
  if dir then
    local dirOk, dirError = ensureDir(dir)
    if not dirOk then
      return nil, dirError
    end
  end
  local handle, reason = fs("open", path, "wb")
  if not handle then
    return nil, reason or ("could not open " .. path)
  end
  for offset = 1, #body, 4096 do
    local ok, writeError = fs("write", handle, body:sub(offset, offset + 4095))
    if not ok then
      fs("close", handle)
      return nil, writeError or ("could not write " .. path)
    end
  end
  local ok, closeError = fs("close", handle)
  if not ok then
    return nil, closeError
  end
  return true
end

local function removeTree(path)
  if not exists(path) then
    return true
  end
  if isDirectory(path) then
    local entries, reason = fs("list", path)
    if not entries then
      return nil, reason
    end
    for _, entry in ipairs(entries) do
      local name = tostring(entry):gsub("/+$", "")
      local ok, removeError = removeTree(path .. "/" .. name)
      if not ok then
        return nil, removeError
      end
    end
  end
  return fs("remove", path)
end

-- ---------------------------------------------------------------------------
-- Progress screen
-- ---------------------------------------------------------------------------

local gpuAddress
local screenWidth, screenHeight = 80, 25

local function bindDisplay()
  gpuAddress = component.list("gpu")()
  local screen = component.list("screen")()
  if not gpuAddress or not screen then
    gpuAddress = nil
    return false
  end
  pcall(invoke, gpuAddress, "bind", screen)
  local ok, width, height = pcall(invoke, gpuAddress, "getResolution")
  if ok and type(width) == "number" and type(height) == "number" then
    screenWidth, screenHeight = width, height
  end
  return true
end

local function draw(phase, label, detail, fraction)
  if not gpuAddress then
    return
  end
  fraction = math.max(0, math.min(1, fraction or 0))
  pcall(function()
    invoke(gpuAddress, "setBackground", 0, true)
    invoke(gpuAddress, "setForeground", 15, true)
    invoke(gpuAddress, "fill", 1, 1, screenWidth, screenHeight, " ")
    invoke(gpuAddress, "setBackground", 0, true)
    invoke(gpuAddress, "setForeground", 12, true)
    invoke(gpuAddress, "set", 2, 2, "TERRACORP OS  ·  SYSTEM UPDATE")
    invoke(gpuAddress, "setForeground", 15, true)
    invoke(gpuAddress, "set", 2, 3, phase or "")

    local barWidth = math.max(10, math.min(screenWidth - 22, 46))
    local filled = math.floor(barWidth * fraction + 0.5)
    invoke(gpuAddress, "setForeground", 10, true)
    invoke(gpuAddress, "set", 2, 5, "[" .. string.rep("#", filled) .. string.rep("-", barWidth - filled) .. "]")
    invoke(gpuAddress, "setForeground", 15, true)
    invoke(gpuAddress, "set", 2 + barWidth + 3, 5, string.format("%3d%%", math.floor(fraction * 100 + 0.5)))
    invoke(gpuAddress, "setForeground", 8, true)
    if label then
      invoke(gpuAddress, "set", 2, 7, tostring(label):sub(1, screenWidth - 2))
    end
    if detail then
      invoke(gpuAddress, "set", 2, 8, tostring(detail):sub(1, screenWidth - 2))
    end
    invoke(gpuAddress, "setForeground", 8, true)
    invoke(gpuAddress, "set", 2, math.max(9, screenHeight - 1), "Do not power off the computer.")
  end)
end

-- ---------------------------------------------------------------------------
-- Network
-- ---------------------------------------------------------------------------

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
    computer.pullSignal(0.05)
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
    -- Older Internet Card handles publish the status through response().
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
        return nil, "Could not read HTTP response: " .. tostring(chunk)
      end
      if type(chunk) == "string" then
        local kept, keepError = keepChunk(chunk)
        if not kept then
          closeHandle()
          return nil, keepError
        end
      elseif chunk ~= nil then
        closeHandle()
        return nil, "Could not read HTTP response: " .. tostring(readError or chunk)
      end
      if computer.uptime() >= deadline then
        closeHandle()
        return nil, "HTTP request timed out after " .. HTTP_TIMEOUT .. " seconds."
      end
      waitBriefly()
    end
  end

  local okStatus, code = pcall(handle.response)
  if not okStatus or code ~= 200 then
    closeHandle()
    return nil, "The server returned " .. tostring(code) .. "."
  end

  while true do
    local okRead, chunk, readError = pcall(handle.read, 8192)
    if not okRead then
      closeHandle()
      return nil, "Could not read HTTP response: " .. tostring(chunk)
    end
    if chunk == nil then
      break
    end
    if type(chunk) ~= "string" then
      closeHandle()
      return nil, "Could not read HTTP response: " .. tostring(readError or chunk)
    end
    local kept, keepError = keepChunk(chunk)
    if not kept then
      closeHandle()
      return nil, keepError
    end
    if chunk == "" then
      waitBriefly()
    end
  end

  closeHandle()
  return table.concat(chunks)
end

local function manifestPaths(body)
  local paths, seen = {}, {}
  for line in body:gmatch("[^\r\n]+") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" and line:sub(1, 4) == "src/" then
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
  if #paths == 0 then
    return nil, "The release manifest contains no OS files."
  end
  for _, required in ipairs({ "src/init.lua", "src/boot/kernel.lua", "src/lib/tc/version.lua" }) do
    if not seen[required] then
      return nil, "The release manifest is missing " .. required .. "."
    end
  end
  return paths
end

-- ---------------------------------------------------------------------------
-- Install
-- ---------------------------------------------------------------------------

local function parseMarker(body)
  local version = body and body:match("version%s*=%s*([^\r\n]+)")
  local tag = body and body:match("tag%s*=%s*([^\r\n]+)")
  if not version or not tag then
    return nil, "The pending update marker is incomplete."
  end
  version = version:gsub("%s+$", "")
  tag = tag:gsub("%s+$", "")
  if not version:match("^%d+%.%d+%.%d+$") or tag ~= "v" .. version then
    return nil, "The pending update marker is invalid."
  end
  return version, tag
end

-- An interrupted install can leave originals in the backup tree. Restore them
-- before writing anything so the node is never stranded on a partial install.
local function restoreBackup(root)
  if not exists(root) then
    return true
  end

  local files, pending = {}, { { path = root, relative = "" } }
  while #pending > 0 do
    local current = table.remove(pending)
    local entries, reason = fs("list", current.path)
    if not entries then
      return nil, reason
    end
    for _, entry in ipairs(entries) do
      local name = tostring(entry):gsub("/+$", "")
      local full = current.path .. "/" .. name
      local relative = current.relative == "" and name or (current.relative .. "/" .. name)
      if isDirectory(full) then
        local children, childError = fs("list", full)
        if not children then
          return nil, childError
        end
        if #children > 0 then
          pending[#pending + 1] = { path = full, relative = relative }
        else
          local removed, removeError = fs("remove", full)
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
    if exists(item.target) then
      local removed, removeError = fs("remove", item.target)
      if not removed then
        return nil, removeError or item.target
      end
    end
    local moved, moveError = fs("rename", item.source, item.target)
    if not moved then
      return nil, moveError or item.target
    end
  end
  return removeTree(root)
end

local function rollback(changed)
  local errors = {}
  for index = #changed, 1, -1 do
    local item = changed[index]
    if item.installed and exists(item.target) then
      local ok, reason = fs("remove", item.target)
      if not ok then
        errors[#errors + 1] = tostring(reason or item.target)
      end
    end
    if item.backedUp and exists(item.backup) then
      local ok, reason = fs("rename", item.backup, item.target)
      if not ok then
        errors[#errors + 1] = tostring(reason or item.target)
      end
    end
  end
  return #errors == 0, table.concat(errors, ", ")
end

local function finish(ok, message)
  pcall(removeTree, MARKER)
  if ok then
    pcall(writeFile, STATUS, "Update complete: " .. tostring(message) .. " installed.")
  else
    pcall(writeFile, STATUS, "Update failed: " .. tostring(message))
    draw("Update failed", tostring(message), "TerraCorp OS will start with the previous version", 1)
    computer.pullSignal(3)
  end
end

local function failure(message, restored, restoreError)
  if restored then
    return message .. " The previous version was restored."
  end
  return message .. " Rollback also failed: " .. tostring(restoreError)
end

local function apply()
  local marker = readSource(MARKER)
  if not marker then
    return true, "no pending update"
  end

  local version, tag = parseMarker(marker)
  if not version then
    finish(false, tag or "invalid marker")
    return false, tag or "invalid marker"
  end

  bindDisplay()
  draw("Preparing update", "Checking the download source", "", 0.02)

  local base = RAW_URL .. "/" .. tag
  local manifest, manifestError = request(base .. "/tools/manifest.txt")
  if not manifest then
    finish(false, "could not download the manifest (" .. tostring(manifestError) .. ")")
    return false, manifestError
  end
  local paths, pathError = manifestPaths(manifest)
  if not paths then
    finish(false, pathError)
    return false, pathError
  end

  local stageRoot = STAGE_ROOT .. "/" .. version
  local backupRoot = BACKUP_ROOT .. "/" .. version
  local clearOk, clearError = removeTree(stageRoot)
  if not clearOk then
    finish(false, "could not clear the staging directory (" .. tostring(clearError) .. ")")
    return false, clearError
  end
  local restored, restoreError = restoreBackup(backupRoot)
  if not restored then
    finish(false, "could not recover the previous backup (" .. tostring(restoreError) .. ")")
    return false, restoreError
  end
  -- Backups from older releases are no longer needed once their own install
  -- completed. Freeing them keeps room for the staged release.
  removeTree(BACKUP_ROOT)

  local totalSteps = math.max(1, #paths * 2)
  local doneSteps = 0
  local function step(phase, label, detail)
    doneSteps = doneSteps + 1
    draw(phase, label, detail, doneSteps / totalSteps)
  end

  local staged, totalBytes, versionSource = {}, 0, nil
  for _, repositoryPath in ipairs(paths) do
    step("Downloading " .. version, repositoryPath, string.format("%d of %d files", #staged + 1, #paths))
    local body, downloadError = request(base .. "/" .. repositoryPath)
    if not body then
      removeTree(stageRoot)
      finish(false, "could not download " .. repositoryPath .. " (" .. tostring(downloadError) .. ")")
      return false, downloadError
    end
    if repositoryPath:sub(-4) == ".lua" then
      local chunk, syntaxError = load(body, "@" .. repositoryPath, "t", {})
      if not chunk then
        removeTree(stageRoot)
        finish(false, "invalid Lua file " .. repositoryPath .. " (" .. tostring(syntaxError) .. ")")
        return false, syntaxError
      end
    end
    local runtimePath = repositoryPath:sub(5)
    local stagePath = stageRoot .. "/" .. runtimePath
    local writeOk, writeError = writeFile(stagePath, body)
    if not writeOk then
      removeTree(stageRoot)
      finish(false, "could not stage " .. repositoryPath .. " (" .. tostring(writeError) .. ")")
      return false, writeError
    end
    local stored = readFile(stagePath)
    if stored ~= body then
      removeTree(stageRoot)
      finish(false, "verification failed for " .. repositoryPath)
      return false, "verification failed"
    end
    staged[#staged + 1] = {
      target = "/" .. runtimePath,
      staged = stagePath,
      backup = backupRoot .. "/" .. runtimePath,
    }
    totalBytes = totalBytes + #body
    if runtimePath == "lib/tc/version.lua" then
      versionSource = body
    end
  end

  local sourceVersion = versionSource and versionSource:match('version%s*=%s*"([^"]+)"')
  if sourceVersion ~= version then
    removeTree(stageRoot)
    finish(false, "the release tag and version.lua do not match")
    return false, "version mismatch"
  end

  local usedOk, used = pcall(fs, "spaceUsed")
  local capacityOk, capacity = pcall(fs, "spaceTotal")
  if usedOk and capacityOk and type(used) == "number" and type(capacity) == "number"
    and capacity - used < totalBytes + 16384 then
    removeTree(stageRoot)
    finish(false, "not enough free disk space")
    return false, "not enough free disk space"
  end

  local changed = {}
  for _, item in ipairs(staged) do
    step("Installing " .. version, item.target, string.format("%d of %d files", #changed + 1, #staged))
    local state = { target = item.target, backup = item.backup }
    changed[#changed + 1] = state

    local targetDir = item.target:match("^(.*)/[^/]+$")
    local targetDirOk, targetDirError = ensureDir(targetDir)
    if not targetDirOk then
      local restoredOk, restoreFailure = rollback(changed)
      removeTree(stageRoot)
      local message = failure("Could not prepare " .. tostring(targetDir) .. " (" .. tostring(targetDirError) .. ")", restoredOk, restoreFailure)
      finish(false, message)
      return false, message
    end

    if exists(item.target) then
      local dir = item.backup:match("^(.*)/[^/]+$")
      local dirOk, dirError = ensureDir(dir)
      if not dirOk then
        local restoredOk, restoreFailure = rollback(changed)
        removeTree(stageRoot)
        local message = failure("Could not prepare the backup (" .. tostring(dirError) .. ")", restoredOk, restoreFailure)
        finish(false, message)
        return false, message
      end
      local moved, moveError = fs("rename", item.target, item.backup)
      if not moved then
        local restoredOk, restoreFailure = rollback(changed)
        removeTree(stageRoot)
        local message = failure("Could not back up " .. item.target .. " (" .. tostring(moveError) .. ")", restoredOk, restoreFailure)
        finish(false, message)
        return false, message
      end
      state.backedUp = true
    end

    local installed, installError = fs("rename", item.staged, item.target)
    if not installed then
      local restoredOk, restoreFailure = rollback(changed)
      removeTree(stageRoot)
      local message = failure("Could not install " .. item.target .. " (" .. tostring(installError) .. ")", restoredOk, restoreFailure)
      finish(false, message)
      return false, message
    end
    state.installed = true
  end

  local installedVersion = readFile("/lib/tc/version.lua")
  local installedNumber = installedVersion and installedVersion:match('version%s*=%s*"([^"]+)"')
  if installedNumber ~= version then
    local restoredOk, restoreFailure = rollback(changed)
    removeTree(stageRoot)
    local message = failure("version.lua did not install correctly", restoredOk, restoreFailure)
    finish(false, message)
    return false, message
  end

  removeTree(stageRoot)
  draw("Update complete", version .. " installed", "Restarting TerraCorp OS", 1)
  finish(true, version)
  computer.pullSignal(0.4)
  return true, version
end

local ok, applied, reason = pcall(apply)
if not ok then
  -- An unexpected error outside the handled paths may have happened between a
  -- backup and its replacement. Restore the tree before booting the old build.
  local message = tostring(applied)
  local marker = readSource(MARKER)
  local version = marker and marker:match("version%s*=%s*([^\r\n]+)")
  if version then
    version = version:gsub("%s+$", "")
    pcall(restoreBackup, BACKUP_ROOT .. "/" .. version)
  end
  pcall(removeTree, STAGE_ROOT)
  finish(false, message)
  return false, message
end

return applied, reason
