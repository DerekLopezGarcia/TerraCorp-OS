-- Filesystem layer over an OpenComputers filesystem component.
--
-- The OS runs without OpenOS, so it cannot use `fs` or `require`. This module
-- wraps the raw component callbacks with the path helpers the kernel, the
-- installer, and the netboot payload share. All paths are absolute.

local vfs = {}

local function packCall(fn, ...)
  local result = table.pack(pcall(fn, ...))
  if not result[1] then
    return nil, tostring(result[2])
  end
  return table.unpack(result, 2, result.n)
end

local function splitPath(path)
  local parts = {}
  for part in tostring(path):gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  return parts
end

--- Wrap a filesystem component proxy. Returns a table, or nil and a reason.
function vfs.new(volume)
  if not volume then
    return nil, "filesystem is not available"
  end

  local self = { volume = volume }

  function self.read(path)
    local handle, reason = packCall(volume.open, path, "r")
    if not handle then
      return nil, reason
    end

    local chunks = {}
    while true do
      local data, why = packCall(volume.read, handle, 4096)
      -- Stop on an empty string as well as nil to avoid a driver-induced loop.
      if type(data) ~= "string" or data == "" then
        packCall(volume.close, handle)
        if why then
          return nil, why
        end
        break
      end
      chunks[#chunks + 1] = data
    end

    packCall(volume.close, handle)
    return table.concat(chunks)
  end

  local function writeMode(path, data, mode)
    local handle, reason = packCall(volume.open, path, mode)
    if not handle then
      return nil, reason
    end
    local ok, why = packCall(volume.write, handle, data)
    packCall(volume.close, handle)
    if not ok then
      return nil, why
    end
    return true
  end

  function self.write(path, data)
    return writeMode(path, data, "w")
  end

  function self.append(path, data)
    return writeMode(path, data, "a")
  end

  function self.exists(path)
    local ok, value = pcall(volume.exists, path)
    return ok and value == true
  end

  function self.isDirectory(path)
    local ok, value = pcall(volume.isDirectory, path)
    return ok and value == true
  end

  function self.size(path)
    local value = packCall(volume.size, path)
    return tonumber(value)
  end

  -- The component returns a 1..n table of names (see docs/opencomputers.md).
  -- Accept iterators as well for compatibility with older drivers.
  function self.list(path)
    local result, reason = packCall(volume.list, path)

    if type(result) == "function" then
      local names = {}
      local ok = pcall(function()
        for name in result do
          names[#names + 1] = tostring(name)
        end
      end)
      if not ok then
        return nil, "could not list " .. tostring(path)
      end
      table.sort(names)
      return names
    end

    if type(result) ~= "table" then
      return nil, reason or ("could not list " .. tostring(path))
    end

    local names = {}
    for _, name in ipairs(result) do
      names[#names + 1] = tostring(name)
    end

    -- Also support a table whose keys are not sequential.
    if #names == 0 and next(result) ~= nil then
      for _, name in pairs(result) do
        names[#names + 1] = tostring(name)
      end
    end

    table.sort(names)
    return names
  end

  function self.ensureDir(path)
    local current = ""
    for _, part in ipairs(splitPath(path)) do
      current = current .. "/" .. part
      if not self.exists(current) then
        local ok, reason = packCall(volume.makeDirectory, current)
        if not ok and not self.exists(current) then
          return nil, reason
        end
      end
    end
    return true
  end

  function self.remove(path)
    return packCall(volume.remove, path)
  end

  function self.rename(from, to)
    return packCall(volume.rename, from, to)
  end

  -- OpenComputers reports spaceUsed/spaceTotal in bytes; the OS uses KB.
  function self.space()
    local used = packCall(volume.spaceUsed)
    local total = packCall(volume.spaceTotal)
    if type(used) ~= "number" or type(total) ~= "number" then
      return nil
    end
    return used / 1024, total / 1024
  end

  return self
end

return vfs
