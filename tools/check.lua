-- Syntax checker to run under OpenOS or Lua 5.3.
--
--   lua check.lua <raizDelRepo>
--
-- Walk src/ and eeprom/, compile each file with `load`, and report its path.
-- Do not execute the code.

local root = ...
if type(root) ~= "string" then
  root = "."
end

local isOpenOS = type(require) == "function" and pcall(require, "filesystem")

-- Los handles de `filesystem` son los del componente: `read` espera un entero.
local function readHandle(handle)
  local chunks = {}
  while true do
    local chunk = handle:read(4096)
    if not chunk or chunk == "" then
      break
    end
    chunks[#chunks + 1] = chunk
  end
  return table.concat(chunks)
end

local list, readFile, isDir, concat

if isOpenOS then
  local filesystem = require("filesystem")
  list = filesystem.list
  readFile = function(path)
    local handle = filesystem.open(path, "r")
    if not handle then
      return nil
    end
    local data = readHandle(handle)
    handle:close()
    return data
  end
  isDir = filesystem.isDirectory
  concat = filesystem.concat
else
  concat = function(a, b)
    return a:gsub("/$", "") .. "/" .. b
  end
  isDir = function(path)
    local ok = os.execute('test -d "' .. path .. '"')
    return ok == true or ok == 0
  end
  readFile = function(path)
    local handle = io.open(path, "r")
    if not handle then
      return nil
    end
    local data = handle:read("*a")
    handle:close()
    return data
  end
  list = function(path)
    local pipe = io.popen('ls -1 "' .. path .. '"')
    local names = {}
    if pipe then
      for name in pipe:lines() do
        names[#names + 1] = name
      end
      pipe:close()
    end
    return names
  end
end

local checked, errors = 0, 0

local function checkFile(path)
  local source = readFile(path)
  if not source then
    errors = errors + 1
    print("NOT READ  " .. path)
    return
  end

  local chunk, reason = load(source, "@" .. path, "t")
  checked = checked + 1
  if not chunk then
    errors = errors + 1
    print("ERROR     " .. path)
    print("          " .. tostring(reason))
  end
end

local function walk(path)
  local names = list(path)
  if not names then
    return
  end

  for _, name in ipairs(names) do
    local full = concat(path, name)
    if isDir(full) then
      walk(full)
    elseif name:sub(-4) == ".lua" then
      checkFile(full)
    end
  end
end

walk(concat(root, "src"))
walk(concat(root, "eeprom"))
walk(concat(root, "tools"))

print(string.format("%d files checked, %d errors.", checked, errors))

if errors > 0 then
  os.exit(1)
end
