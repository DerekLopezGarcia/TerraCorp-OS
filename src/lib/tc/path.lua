-- Local semantic paths. A path is a human-facing name for one or more physical
-- addresses; the stock reader resolves it and the app displays it. The first
-- version is authoritative on this computer: no gateway, no DNS protocol.
--
-- A path resolves to a set. `single` means exactly one member; `pool` means
-- several members are replicas and reads sum across them.

local path = {}

path.PATHS_PATH = "/etc/paths.tsv"
path.MAX_PATH = 160
path.MAX_MEMBERS = 64

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split(value)
  local parts = {}
  for segment in tostring(value):gmatch("[^/]+") do
    parts[#parts + 1] = segment
  end
  return parts
end

local function validLiteral(segment)
  return segment:match("^[A-Za-z0-9_%-]+$") ~= nil
end

--- A stored path: lowercase-ish segments, no wildcards, no empty segment.
function path.valid(value)
  if type(value) ~= "string" or value == "" or #value > path.MAX_PATH then
    return false
  end
  if value:sub(1, 1) == "/" or value:sub(-1) == "/" or value:find("//", 1, true) then
    return false
  end
  for _, segment in ipairs(split(value)) do
    if not validLiteral(segment) then
      return false
    end
  end
  return true
end

local function matchSegments(patternSegments, nameSegments, patternIndex, nameIndex)
  if patternIndex > #patternSegments then
    return nameIndex > #nameSegments
  end
  local token = patternSegments[patternIndex]
  if token == "**" then
    for index = nameIndex, #nameSegments do
      if matchSegments(patternSegments, nameSegments, patternIndex + 1, index) then
        return true
      end
    end
    return false
  end
  if nameIndex > #nameSegments then
    return false
  end
  if token ~= "*" and token ~= nameSegments[nameIndex] then
    return false
  end
  return matchSegments(patternSegments, nameSegments, patternIndex + 1, nameIndex + 1)
end

--- Match a wildcard query against a stored path. `*` is one segment, `**` is
-- zero or more. Literal segments must be valid.
function path.matches(pattern, name)
  if type(pattern) ~= "string" or type(name) ~= "string" then
    return false
  end
  local patternSegments = split(pattern)
  local nameSegments = split(name)
  if #patternSegments == 0 or #nameSegments == 0 then
    return false
  end
  for _, segment in ipairs(patternSegments) do
    if segment ~= "*" and segment ~= "**" and not validLiteral(segment) then
      return false
    end
  end
  return matchSegments(patternSegments, nameSegments, 1, 1)
end

function path.new()
  return { paths = {} }
end

--- Add a member to a path. The cardinality is declared intent: `single` or
-- `pool`. Adding a second member to a `single` path is legal storage but the
-- resolver reports `cardinality_mismatch`; the app can show the mistake.
function path.assign(registry, name, address, cardinality)
  if not registry or type(registry.paths) ~= "table" then
    return nil, "invalid registry"
  end
  if not path.valid(name) then
    return nil, "invalid path"
  end
  if type(address) ~= "string" or address == "" then
    return nil, "invalid address"
  end
  cardinality = cardinality or "single"
  if cardinality ~= "single" and cardinality ~= "pool" then
    return nil, "cardinality must be single or pool"
  end

  local entry = registry.paths[name]
  if not entry then
    entry = { name = name, cardinality = cardinality, members = {} }
    registry.paths[name] = entry
  else
    entry.cardinality = cardinality
  end
  for _, member in ipairs(entry.members) do
    if member == address then
      return entry
    end
  end
  if #entry.members >= path.MAX_MEMBERS then
    return nil, "too many members"
  end
  entry.members[#entry.members + 1] = address
  return entry
end

function path.remove(registry, name, address)
  local entry = registry and registry.paths and registry.paths[name]
  if not entry then
    return nil, "unknown path"
  end
  if not address then
    registry.paths[name] = nil
    return true
  end
  for index = #entry.members, 1, -1 do
    if entry.members[index] == address then
      table.remove(entry.members, index)
    end
  end
  return true
end

--- List entries, optionally filtered by a wildcard query. Sorted by name.
function path.list(registry, pattern)
  local result = {}
  if not registry or not registry.paths then
    return result
  end
  for name, entry in pairs(registry.paths) do
    if not pattern or path.matches(pattern, name) then
      result[#result + 1] = entry
    end
  end
  table.sort(result, function(a, b)
    return a.name < b.name
  end)
  return result
end

--- Resolve one path to its entry. A single path with several members, or a
-- path with no members, is an error rather than a silent choice.
function path.resolve(registry, name)
  local entry = registry and registry.paths and registry.paths[name]
  if not entry then
    return nil, "unknown_path"
  end
  if #entry.members == 0 then
    return nil, "unbound_path"
  end
  if entry.cardinality == "single" and #entry.members > 1 then
    return nil, "cardinality_mismatch"
  end
  return entry
end

--- Load /etc/paths.tsv. A missing file is an empty registry, not an error.
function path.load(vfs)
  local registry = path.new()
  local errors = {}
  if not vfs then
    return registry, errors
  end
  local text, reason = vfs.read(path.PATHS_PATH)
  if not text then
    if vfs.exists(path.PATHS_PATH) then
      errors[#errors + 1] = { line = 0, message = "cannot read " .. path.PATHS_PATH .. ": " .. tostring(reason) }
    end
    return registry, errors
  end

  local number = 0
  for line in text:gmatch("[^\r\n]+") do
    number = number + 1
    local value = trim(line:gsub("#.*$", ""))
    if value ~= "" then
      local name, address, cardinality = value:match("^(%S+)%s+(%S+)%s*(%S*)$")
      if not name then
        errors[#errors + 1] = { line = number, message = "expected <path> <address> [single|pool]" }
      else
        local ok, why = path.assign(registry, name, address, cardinality ~= "" and cardinality or "single")
        if not ok then
          errors[#errors + 1] = { line = number, message = tostring(why) }
        end
      end
    end
  end
  return registry, errors
end

--- Write /etc/paths.tsv. Paths with no members are omitted.
function path.save(vfs, registry)
  if not vfs then
    return nil, "invalid vfs"
  end
  vfs.ensureDir("/etc")
  local lines = { "# TerraCorp: semantic paths" }
  local entries = path.list(registry)
  for _, entry in ipairs(entries) do
    for _, member in ipairs(entry.members) do
      lines[#lines + 1] = entry.name .. "\t" .. member .. "\t" .. entry.cardinality
    end
  end
  local ok, reason = vfs.write(path.PATHS_PATH, table.concat(lines, "\n") .. "\n")
  if not ok then
    return nil, reason
  end
  return true
end

return path
