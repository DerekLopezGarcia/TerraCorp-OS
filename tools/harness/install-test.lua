-- Test tools/install.lua under simulated OpenOS (without Minecraft).
-- The runner injects FILES (path -> content) with the source tree.
-- Usage: node test-install.js <repo> <scenario>
local repo, scenario = ...
local FILES = FILES

local out, err, bootAddress, copiedTo = {}, {}, nil, {}
local reads = {}
local answers = {}

local function write(list, value) list[#list + 1] = tostring(value) end

-- ---------------------------------------------------------------------------
-- Volumes and mounts
-- ---------------------------------------------------------------------------
local volumes, mounts = {}, {}

local function volume(address, opts)
  opts = opts or {}
  volumes[address] = {
    address = address,
    label = opts.label,
    readOnly = opts.readOnly or false,
    files = opts.files or {},
    dirs = opts.dirs or {},
    size = opts.size or 1048576,
  }
end

local function addMount(prefix, address)
  for index, mount in ipairs(mounts) do
    if mount.prefix == prefix then
      mounts[index] = { prefix = prefix, address = address }
      return
    end
  end
  mounts[#mounts + 1] = { prefix = prefix, address = address }
  table.sort(mounts, function(a, b) return #a.prefix > #b.prefix end)
end

local function resolvePath(path)
  local best
  for _, mount in ipairs(mounts) do
    local under = (mount.prefix == "/")
      or path == mount.prefix
      or path:sub(1, #mount.prefix + 1) == mount.prefix .. "/"
    if under and (not best or #mount.prefix > #best.prefix) then
      best = mount
    end
  end
  if not best then
    return nil
  end
  local rel
  if best.prefix == "/" then
    rel = path:sub(2)
  else
    rel = path:sub(#best.prefix + 1):gsub("^/", "")
  end
  return volumes[best.address], rel
end

local function isDir(v, rel)
  if rel == "" then return true end
  return v.dirs[rel] == true
end

local function dirNames(v, rel)
  local prefix = (rel == "") and "" or (rel .. "/")
  local seen, names = {}, {}
  for path in pairs(v.files) do
    if path:sub(1, #prefix) == prefix then
      local name = path:sub(#prefix + 1):match("^([^/]+)")
      if name and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end
  for path in pairs(v.dirs) do
    if path ~= rel and path:sub(1, #prefix) == prefix then
      local name = path:sub(#prefix + 1):match("^([^/]+)")
      if name and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end
  table.sort(names)
  return names
end

local filesystem = {}

function filesystem.concat(a, b)
  return (tostring(a):gsub("/+$", "")) .. "/" .. tostring(b):gsub("^/+", "")
end

function filesystem.get(path)
  local v, rel = resolvePath(path)
  if not v or rel ~= "" then
    return nil, "no such file system"
  end
  return componentProxy(v), path
end

function filesystem.exists(path)
  local v, rel = resolvePath(path)
  if not v then return false end
  return v.files[rel] ~= nil or isDir(v, rel)
end

function filesystem.isDirectory(path)
  local v, rel = resolvePath(path)
  return v and isDir(v, rel) or false
end

function filesystem.makeDirectory(path)
  local v, rel = resolvePath(path)
  if not v then return nil, "no volume" end
  local current = ""
  for part in rel:gmatch("[^/]+") do
    current = (current == "") and part or (current .. "/" .. part)
    v.dirs[current] = true
  end
  return true
end

function filesystem.list(path)
  local v, rel = resolvePath(path)
  if not v or not isDir(v, rel) then
    return function() return nil end
  end
  local names = dirNames(v, rel)
  local index = 0
  return function()
    index = index + 1
    return names[index]
  end
end

function filesystem.open(path, mode)
  local v, rel = resolvePath(path)
  if not v then return nil, "no volume" end
  if mode == "rb" then
    local content = v.files[rel]
    if not content then return nil, "no such file" end
    local position = 1
    return {
      -- Match the component: `read` expects an integer and returns nil at
      -- EOF. Using "*a" would fail in-game, as it does in OpenOS.
      read = function(self, count)
        if type(count) ~= "number" then
          error("bad argument #2 (integer expected, got " .. type(count) .. ")", 2)
        end
        if position > #content then return nil end
        local chunk = content:sub(position, position + count - 1)
        position = position + #chunk
        return chunk
      end,
      close = function() return true end,
    }
  end
  v.files[rel] = ""
  return {
    write = function(self, data) v.files[rel] = v.files[rel] .. data; return true end,
    close = function() return true end,
  }
end

function filesystem.mount(proxy, point)
  addMount(point, proxy.address)
  return true
end

function filesystem.umount(point)
  for index, mount in ipairs(mounts) do
    if mount.prefix == point then
      table.remove(mounts, index)
      return true
    end
  end
  return nil, "not mounted"
end

-- ---------------------------------------------------------------------------
-- Components
-- ---------------------------------------------------------------------------
local order = {}

function componentProxy(v)
  return {
    address = v.address,
    type = "filesystem",
    isReadOnly = function() return v.readOnly end,
    getLabel = function() return v.label end,
    spaceUsed = function() return 1024 end,
    spaceTotal = function() return v.size end,
    exists = function(path)
      local rel = (path:gsub("^/", ""))
      return v.files[rel] ~= nil or isDir(v, rel)
    end,
    list = function(path)
      local rel = (path or ""):gsub("^/", "")
      return dirNames(v, rel)
    end,
  }
end

local component = {}
function component.list(kind)
  local index = 0
  return function()
    index = index + 1
    local address = order[index]
    if address then return address, "filesystem" end
  end
end
function component.proxy(address)
  local v = volumes[address]
  if not v then return nil end
  return componentProxy(v)
end
function component.invoke() return true end
function component.isAvailable() return true end

local computer = {
  setBootAddress = function(address) bootAddress = address; return true end,
  address = function() return "0000-1111" end,
}

local shell = {
  resolve = function(path) return path end,
  parse = function(...) return ARGS, OPTIONS end,
}

local term = { write = function() end }

function require(name)
  return ({ component = component, computer = computer, filesystem = filesystem, shell = shell, term = term })[name]
end

-- Capture output
local rawPrint = print
print = function(...)
  local parts = {}
  for index = 1, select("#", ...) do parts[#parts + 1] = tostring((select(index, ...))) end
  write(out, table.concat(parts, "\t") .. "\n")
end
io.write = function(value) write(out, value) end
io.read = function() return table.remove(answers, 1) or "" end
io.stderr = { write = function(self, value) write(err, value) end }

-- ---------------------------------------------------------------------------
-- Scenarios
-- ---------------------------------------------------------------------------
local function repoVolume()
  local files = {}
  for path, content in pairs(FILES) do
    files["home/TerraCorp-OS/" .. path] = content
  end
  volume("root-0000", { label = "OpenOS", files = files, dirs = {
    home = true,
    ["home/TerraCorp-OS"] = true,
    ["home/TerraCorp-OS/src"] = true,
    ["home/TerraCorp-OS/src/boot"] = true,
    ["home/TerraCorp-OS/eeprom"] = true,
  } })
  addMount("/", "root-0000")
end

repoVolume()

if scenario == "floppy" then
  ARGS, OPTIONS = { "/home/TerraCorp-OS" }, {}
  answers = { "y" }
  order = { "root-0000", "floppy-01" }
  volume("floppy-01", { label = "TC" })
elseif scenario == "multiple" then
  ARGS, OPTIONS = { "/home/TerraCorp-OS" }, {}
  answers = { "2", "y" }
  order = { "root-0000", "floppy-01", "hdd-02" }
  volume("floppy-01", { label = "nuevo" })
  volume("hdd-02", { label = "terracorp", files = { ["boot/kernel.lua"] = "x" }, dirs = { boot = true } })
elseif scenario == "multiple_yes" then
  ARGS, OPTIONS = { "/home/TerraCorp-OS" }, { yes = true }
  order = { "root-0000", "floppy-01", "hdd-02" }
  volume("floppy-01", { label = "nuevo" })
  volume("hdd-02", { label = "otro", files = { ["boot/kernel.lua"] = "x" }, dirs = { boot = true } })
elseif scenario == "data_disk" then
  ARGS, OPTIONS = { "/home/TerraCorp-OS" }, {}
  order = { "root-0000", "hdd-02", "ro-03" }
  volume("hdd-02", { label = "datos", files = { ["hola.txt"] = "x" } })
  volume("ro-03", { label = "ro", readOnly = true, files = { ["a"] = "x" } })
elseif scenario == "explicit" then
  ARGS, OPTIONS = { "/home/TerraCorp-OS", "hdd-02" }, {}
  answers = { "y" }
  order = { "root-0000", "hdd-02" }
  volume("hdd-02", { label = "datos", files = { ["hola.txt"] = "x" } })
elseif scenario == "small_disk" then
  -- Place a small OpenOS tmpfs next to the valid disk; the installer must ignore it.
  ARGS, OPTIONS = { "/home/TerraCorp-OS" }, {}
  answers = { "y" }
  order = { "root-0000", "tmpfs-03", "hdd-02" }
  volume("tmpfs-03", { label = "tmpfs", size = 102400 })
  volume("hdd-02", { label = "nuevo", size = 4194304 })
elseif scenario == "list" then
  ARGS, OPTIONS = { "/home/TerraCorp-OS" }, { list = true }
  order = { "root-0000", "floppy-01" }
  volume("floppy-01", { label = "TC" })
else
  error("unknown scenario: " .. tostring(scenario))
end

local chunk = assert(loadfile(repo .. "/tools/install.lua"))
local chunkOk, chunkErr = pcall(chunk)
if not chunkOk then
  error("installer failed: " .. tostring(chunkErr), 0)
end

-- ---------------------------------------------------------------------------
-- Comprobaciones
-- ---------------------------------------------------------------------------
local text = table.concat(out)
local errorText = table.concat(err)
local function has(haystack, needle) return haystack:find(needle, 1, true) ~= nil end

local function copiedInto(address)
  local v = volumes[address]
  return v and v.files["init.lua"] ~= nil and v.files["boot/kernel.lua"] ~= nil
end

if scenario == "floppy" then
  assert(has(text, "Detected: floppy-0"), "did not detect floppy:\n" .. text .. errorText)
  assert(copiedInto("floppy-01"), "did not copy to floppy")
  assert(bootAddress == "floppy-01", "boot address = " .. tostring(bootAddress))
  assert(volumes["floppy-01"].dirs["etc"], "did not create /etc")
  assert(volumes["floppy-01"].dirs["var/log"], "did not create /var/log")
elseif scenario == "multiple" then
  assert(has(text, "1) floppy"), "did not list candidates:\n" .. text)
  assert(copiedInto("hdd-02"), "did not copy to selected volume (2)")
  assert(bootAddress == "hdd-02", "boot address = " .. tostring(bootAddress))
elseif scenario == "multiple_yes" then
  assert(has(errorText, "Multiple candidates"), "did not warn about multiple candidates:\n" .. errorText)
  assert(bootAddress == nil, "should not have changed the boot address")
elseif scenario == "data_disk" then
  assert(has(errorText, "No eligible install volume"), "did not reject volumes with data:\n" .. errorText)
  assert(bootAddress == nil, "should not have installed")
elseif scenario == "explicit" then
  assert(copiedInto("hdd-02"), "did not copy to the explicit address")
  assert(bootAddress == "hdd-02", "boot address = " .. tostring(bootAddress))
elseif scenario == "list" then
  assert(has(text, "floppy-0"), "did not list volumes:\n" .. text)
  assert(volumes["floppy-01"].files["init.lua"] == nil, "should not copy with --list")
elseif scenario == "small_disk" then
  assert(not has(text, "tmpfs-03") and not has(text, "tmpfs"), "selected tmpfs:\n" .. text .. errorText)
  assert(copiedInto("hdd-02"), "did not copy to the valid disk")
  assert(bootAddress == "hdd-02", "boot address = " .. tostring(bootAddress))
end

rawPrint("OK " .. scenario)
