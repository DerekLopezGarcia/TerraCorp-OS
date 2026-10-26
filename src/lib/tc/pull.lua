-- Pull a runtime tree from the master over tc.net.
--
-- The master serves /init.lua, /boot, /lib, and /apps while its installer or
-- update window is armed. Files are fetched in chunks with retries and
-- validated before use. The node runtime stages an update for the boot-time
-- applier with this module; the rack bootstrap installs a fresh system with
-- the same request loop.

local net = require("tc.net")
local provision = require("tc.provision")

local pull = {}

pull.CHUNK = 512
pull.TIMEOUT = 5
pull.RETRIES = 3
pull.MAX_FILE = 256 * 1024

--- Build a request loop over an open modem. `env` needs modem, master,
-- computer, and id. Every request retries and waits for a reply frame whose
-- verb matches and whose id is this node's; a MISS aborts.
function pull.requestLoop(env)
  local computer = env.computer
  local modem = env.modem
  local id = tostring(env.id or "")

  return function(verb, fields, expect)
    fields.id = id
    for _ = 1, pull.RETRIES do
      local sent = modem:send(env.master, verb, fields)
      if sent then
        local deadline = computer.uptime() + pull.TIMEOUT
        while computer.uptime() < deadline do
          local pack = table.pack(pcall(computer.pullSignal, 0.5))
          if pack[1] and pack[2] == "modem_message" then
            local port, message = pack[5], pack[7]
            if tonumber(port) == modem.port then
              local replyVerb, reply = net.decode(message)
              if replyVerb == expect and reply.id == id then
                return reply
              elseif replyVerb == "MISS" and reply.id == id then
                return nil, tostring(reply.reason
                  or ("the master refused " .. tostring(fields.path or "")))
              end
            end
          end
        end
      end
    end
    return nil, "no answer from the master"
  end
end

--- Fetch one whole file with chunked FETCH requests.
function pull.fetchFile(request, path)
  local chunks = {}
  local size = nil
  local off = 0
  while true do
    local reply, reason = request("FETCH", { path = path, off = off }, "DATA")
    if not reply then
      return nil, reason
    end
    size = tonumber(reply.size) or size
    local data = tostring(reply.data or "")
    if data == "" then
      break
    end
    chunks[#chunks + 1] = data
    off = off + #data
    if size and off >= size then
      break
    end
  end
  local body = table.concat(chunks)
  if size and #body ~= size then
    return nil, "incomplete transfer of " .. path
  end
  return body
end

--- List one directory on the master. Returns files, dirs, or nil and a reason.
function pull.listDir(request, path)
  local reply, reason = request("LIST", { path = path }, "DIRS")
  if not reply then
    return nil, reason
  end
  local files, dirs = {}, {}
  for name in tostring(reply.files or ""):gmatch("[^,]+") do
    files[#files + 1] = name
  end
  for name in tostring(reply.dirs or ""):gmatch("[^,]+") do
    dirs[#dirs + 1] = name
  end
  return files, dirs
end

--- Walk the master's runtime tree and fetch every file. `roots` fixes which
-- top-level paths are pulled (the filesystem root itself is never served).
-- `writer(path, body)` stores each file; a nil return aborts the walk.
function pull.walk(request, writer, roots)
  roots = roots or {}
  local pending = {}
  for _, dir in ipairs(roots.dirs or {}) do
    pending[#pending + 1] = dir
  end
  for _, file in ipairs(roots.files or {}) do
    local body, fetchError = pull.fetchFile(request, file)
    if not body then
      return nil, fetchError
    end
    if #body > pull.MAX_FILE then
      return nil, file .. " is too large to pull"
    end
    local ok, writeError = writer(file, body)
    if not ok then
      return nil, writeError
    end
  end
  while #pending > 0 do
    local dir = table.remove(pending)
    local files, dirs, reason = pull.listDir(request, dir)
    if not files then
      return nil, reason
    end
    for _, name in ipairs(dirs) do
      pending[#pending + 1] = (dir == "/" and "/" or (dir .. "/")) .. name
    end
    for _, name in ipairs(files) do
      local path = (dir == "/" and "/" or (dir .. "/")) .. name
      local body, fetchError = pull.fetchFile(request, path)
      if not body then
        return nil, fetchError
      end
      if #body > pull.MAX_FILE then
        return nil, path .. " is too large to pull"
      end
      local ok, writeError = writer(path, body)
      if not ok then
        return nil, writeError
      end
    end
  end
  return true
end

--- Stage a runtime tree for the boot-time applier (source=master).
-- `env` needs modem, master, computer, id, vfs, and version. Returns true and
-- the staged file count, or nil and a reason.
function pull.run(env)
  local vfs = env.vfs
  local version = tostring(env.version or "")
  if version == "" then
    return nil, "the master did not name a version"
  end
  if #version > 16 or version:match("^[%w%.%-]+$") == nil then
    return nil, "the master sent an invalid version"
  end
  if not env.modem or not env.modem.address then
    return nil, "the network card is not open"
  end

  local request = pull.requestLoop(env)
  local stageRoot = "/var/update/stage/" .. version
  local function abort(reason)
    provision.removeTree(vfs, stageRoot)
    return nil, reason
  end

  if not provision.removeTree(vfs, stageRoot) then
    return nil, "could not clear the staging directory"
  end

  local staged, total = 0, 0
  local function writer(path, body)
    if path:sub(-4) == ".lua" then
      local chunk = load(body, "@" .. path, "t", {})
      if not chunk then
        return nil, "invalid Lua in " .. path
      end
    end
    local target = stageRoot .. path
    local parent = target:match("^(.*)/[^/]+$")
    if parent then
      local ok, reason = vfs.ensureDir(parent)
      if not ok then
        return nil, reason
      end
    end
    local written, writeReason = vfs.write(target, body)
    if not written then
      return nil, writeReason
    end
    if vfs.read(target) ~= body then
      return nil, "staged verification failed for " .. path
    end
    staged = staged + 1
    total = total + #body
    return true
  end

  local walked, walkError = pull.walk(request, writer, {
    files = { "/init.lua" },
    dirs = { "/boot", "/lib", "/apps" },
  })
  if not walked then
    return abort(walkError)
  end
  if staged == 0 then
    return abort("the master served no files")
  end

  local dirOk, dirError = vfs.ensureDir("/var/update")
  if not dirOk then
    return abort(dirError)
  end
  local markerOk, markerError = vfs.write(
    "/var/update/pending",
    "version=" .. version .. "\ntag=v" .. version .. "\nsource=master\n"
  )
  if not markerOk then
    return abort(markerError)
  end

  return true, staged, total
end

return pull
