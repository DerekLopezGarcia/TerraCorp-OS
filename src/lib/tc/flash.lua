-- Floppy flasher for line node installers.
--
-- The master already holds the runtime, so it can write the installer medium
-- itself: the tree, the `/installer.lua` marker that makes `/init.lua` run the
-- installer, and a node configuration that already names the master. The floppy
-- is then only read, so it commissions one computer after another.
--
-- Only `/init.lua`, `/boot`, `/lib`, `/apps` are written. `/var` and the master's
-- own `/etc` never travel: the medium gets a fresh configuration.

local vfsModule = require("tc.vfs")
local installer = require("tc.installer")
local payload = require("tc.payload")

local flash = {}
flash.__index = flash
flash.MARKER = "/installer.lua"
flash.MARGIN = 8 * 1024
flash.MARKER_TEXT = table.concat({
  "-- TerraCorp line node installer medium.",
  "-- `/init.lua` runs `/boot/install.lua` when this file is present, so a floppy",
  "-- carrying it installs the runtime onto the computer's disk instead of booting",
  "-- from the floppy. The installer never writes to this medium.",
  "",
}, "\n")

local function cleanName(name)
  return tostring(name):gsub("/+$", "")
end

function flash.new(options)
  options = options or {}
  local self = setmetatable({}, flash)
  self.kernel = options.kernel
  self.vfs = options.vfs
  self.log = options.log
  self.config = options.config
  self.version = options.version or {}
  self.computer = options.computer or computer
  self.component = options.component or component
  self.last = nil
  return self
end

--- Writable filesystems that are not the boot volume. A floppy in a disk drive
-- is one; so is a spare disk, which is why the smallest is preferred and the
-- app shows which medium it will use.
function flash:mediums()
  local found = {}
  if not self.component or type(self.component.list) ~= "function" then
    return found
  end
  local boot = self.kernel and self.kernel.volumeAddress
  for address in self.component.list("filesystem") do
    if address ~= boot then
      local ok, readOnly = pcall(self.component.invoke, address, "isReadOnly")
      local proxy = self.component.proxy(address)
      if (not ok or readOnly ~= true) and proxy then
        local used, total = 0, 0
        if proxy.spaceUsed then
          used = tonumber(proxy.spaceUsed()) or 0
        end
        if proxy.spaceTotal then
          total = tonumber(proxy.spaceTotal()) or 0
        end
        found[#found + 1] = {
          address = address,
          proxy = proxy,
          used = used,
          total = total,
          label = proxy.getLabel and (proxy.getLabel() or "") or "",
          ours = proxy.exists and proxy.exists(flash.MARKER) == true,
        }
      end
    end
  end
  table.sort(found, function(a, b)
    if a.total == b.total then
      return a.address < b.address
    end
    -- A floppy is the smallest writable filesystem on the bus.
    return a.total < b.total
  end)
  return found
end

local function listRoot(volume)
  local names, reason = volume.list("/")
  if not names then
    return nil, reason or "could not list the medium"
  end
  return names
end

--- A medium may be reused only when it is empty or holds an installer this
-- module wrote. Anything else is somebody's disk and is refused.
function flash:checkMedium(medium)
  local volume = vfsModule.new(medium.proxy)
  if not volume then
    return nil, "the medium is not readable"
  end
  if volume.exists(flash.MARKER) then
    return true, "ours", volume
  end
  local names, reason = listRoot(volume)
  if not names then
    return nil, reason
  end
  for _, raw in ipairs(names) do
    local name = cleanName(raw)
    if name ~= "" then
      return nil, "the medium already contains data (" .. name .. ")"
    end
  end
  return true, "empty", volume
end

--- The node payload, read from the master's own volume.
--
-- The list comes from `tc.payload`: an explicit set, not a directory walk, so
-- what the flasher writes is exactly what `npm run size` measures.
function flash:collect()
  local entries, total = {}, 0

  for _, path in ipairs(payload.files) do
    if not self.vfs.exists(path) then
      return nil, "the payload is incomplete: " .. path .. " is missing"
    end
    local data, reason = self.vfs.read(path)
    if not data then
      return nil, reason or ("could not read " .. path)
    end
    entries[#entries + 1] = { path = path, data = data, size = #data }
    total = total + #data
  end

  table.sort(entries, function(a, b)
    return a.path < b.path
  end)
  return entries, total
end

local function writeFile(volume, path, data)
  local directory = path:match("^(.*)/[^/]+$")
  if directory and directory ~= "" then
    local ok, reason = volume.ensureDir(directory)
    if not ok then
      return nil, reason
    end
  end
  local written, reason = volume.write(path, data)
  if not written then
    return nil, reason or ("could not write " .. path)
  end
  if volume.read(path) ~= data then
    return nil, "verification failed for " .. path
  end
  return true
end

--- Write the installer to a medium. Returns a summary or nil and a reason.
function flash:write(medium, opts)
  opts = opts or {}
  local allowed, state, volume = self:checkMedium(medium)
  if not allowed then
    return nil, state
  end

  local entries, total = self:collect()
  if not entries then
    return nil, total
  end

  if medium.total > 0 and medium.total - medium.used < total + flash.MARGIN then
    return nil, string.format(
      "the medium needs %d KB free but only %d KB are available",
      math.floor((total + flash.MARGIN) / 1024 + 0.5),
      math.floor((medium.total - medium.used) / 1024)
    )
  end

  for _, entry in ipairs(entries) do
    local ok, reason = writeFile(volume, entry.path, entry.data)
    if not ok then
      return nil, reason
    end
  end

  local markerOk, markerReason = writeFile(volume, flash.MARKER, flash.MARKER_TEXT)
  if not markerOk then
    return nil, markerReason
  end

  local configText = opts.configText or installer.configText({
    name = opts.name or "",
    master = opts.master or (self.computer and self.computer.address() or ""),
  })
  local configOk, configReason = writeFile(volume, installer.configPath, configText)
  if not configOk then
    return nil, configReason
  end

  local summary = {
    address = medium.address,
    files = #entries + 2,
    bytes = total + #flash.MARKER_TEXT + #configText,
    state = state,
    version = tostring(self.version.version or ""),
  }
  self.last = summary
  if self.log and self.log.info then
    self.log:info(string.format("flash: wrote %d files (%d KB) to %s",
      summary.files, math.floor(summary.bytes / 1024), tostring(medium.address):sub(1, 8)))
  end
  return summary
end

--- Flash the first eligible medium. The app asks first; the kernel does not.
function flash:auto(opts)
  local mediums = self:mediums()
  if #mediums == 0 then
    return nil, "no_medium"
  end
  return self:write(mediums[1], opts)
end

function flash:status()
  local mediums = self:mediums()
  return {
    mediums = mediums,
    last = self.last,
  }
end

return flash
