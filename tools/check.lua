-- Comprobador de sintaxis para ejecutar dentro de OpenOS o con un Lua 5.3.
--
--   lua check.lua <raizDelRepo>
--
-- Recorre src/ y eeprom/, compila cada fichero con `load` y reporta errores con
-- su ruta. No ejecuta el código.

local root = ...
if type(root) ~= "string" then
  root = "."
end

local isOpenOS = type(require) == "function" and pcall(require, "filesystem")

local list, readFile, isDir, concat

if isOpenOS then
  local filesystem = require("filesystem")
  list = filesystem.list
  readFile = function(path)
    local handle = filesystem.open(path, "r")
    if not handle then
      return nil
    end
    local data = handle:read("*a")
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
    print("NO LEÍDO  " .. path)
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

print(string.format("%d ficheros comprobados, %d errores.", checked, errors))

if errors > 0 then
  os.exit(1)
end
