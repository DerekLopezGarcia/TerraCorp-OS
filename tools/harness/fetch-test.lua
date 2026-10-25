-- Test tools/fetch.lua with fake OpenOS networking, storage, and shell.
--
--   node tools/harness/test-fetch.js
--
-- Verify the in-game failure UX: an unambiguous RESULT line, 404/network
-- distinction, and detection of truncated files by reading them back.
--
-- Require all output to be ASCII and at most 60 characters for poorly rendered
-- OpenComputers terminals.

local scenario = ...

local out = {}
local disk = {}

local function emit(line)
  out[#out + 1] = line
end

local function say(...)
  local parts = {}
  for index = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(index, ...))
  end
  emit(table.concat(parts, " "))
end

component = {
  isAvailable = function(name)
    return scenario ~= "no_card" and name == "internet"
  end,
}

filesystem = {
  concat = function(a, b)
    return (a:gsub("/+$", "")) .. "/" .. b
  end,
  makeDirectory = function()
    return true
  end,
  open = function(path, mode)
    if scenario == "disk_full" then
      return nil, "no space"
    end
    local buffer = {}
    return {
      write = function(_, content)
        buffer[#buffer + 1] = content
      end,
      close = function()
        local content = table.concat(buffer)
        if scenario == "short_file" then
          content = content:sub(1, 2)
        end
        disk[path] = content
      end,
    }
  end,
  size = function(path)
    return disk[path] and #disk[path] or 0
  end,
}

local payloads = {
  ["http://example.test/tools/manifest.txt"] = "src/init.lua\nsrc/boot/kernel.lua\n",
  ["http://example.test/src/init.lua"] = "return 1\n",
  ["http://example.test/src/boot/kernel.lua"] = "return 2\n",
}

internet = {
  request = function(url)
    local status = 200
    local body = payloads[url]
    if scenario == "404" then
      status, body = 404, nil
    elseif scenario == "missing_file" and url:find("kernel.lua", 1, true) then
      status, body = 404, nil
    end

    local chunks = body and { body:sub(1, 5), body:sub(6) } or { "" }
    local handle = { index = 0 }
    handle.response = function()
      return status, status == 200 and "OK" or "Not Found"
    end
    handle.close = function() end
    return setmetatable(handle, {
      __call = function(self)
        self.index = self.index + 1
        return chunks[self.index]
      end,
    })
  end,
}

shell = {
  parse = function()
    return { "/home/TerraCorp-OS", "http://example.test" }
  end,
  resolve = function(path)
    return path
  end,
}

local stubs = { component = component, filesystem = filesystem, internet = internet, shell = shell }
require = function(name)
  return stubs[name]
end

print = say
io = { stderr = { write = function(_, text) emit((text:gsub("\n$", ""))) end } }

local chunk, loadError = load(rawget(_G, "FETCH_SRC"), "=fetch.lua")
if not chunk then
  say("COMPILE ERROR: " .. tostring(loadError))
  FETCH_ERRORS = 1
  return
end

local ok, failure = pcall(chunk)
if not ok then
  say("RUNTIME ERROR: " .. tostring(failure))
  FETCH_ERRORS = 1
  return
end

local problems = 0
local function check(condition, message)
  if not condition then
    problems = problems + 1
    say("  FAIL " .. scenario .. ": " .. message)
  end
end

local text = table.concat(out, "\n")
local function has(fragment)
  return text:find(fragment, 1, true) ~= nil
end

if scenario == "ok" then
  check(has("RESULT: OK"), "success result was not reported")
  check(disk["/home/TerraCorp-OS/src/init.lua"] == "return 1\n", "init.lua was truncated")
  check(disk["/home/TerraCorp-OS/src/boot/kernel.lua"] == "return 2\n", "kernel.lua was truncated")
elseif scenario == "404" then
  check(has("RESULT: ERROR"), "404 was not reported as an error")
  check(has("HTTP 404"), "404 was confused with a network failure")
  check(has("capitalization"), "owner capitalization hint is missing")
  check(next(disk) == nil, "files were written without a manifest")
elseif scenario == "missing_file" then
  check(has("RESULT: INCOMPLETE"), "missing file did not mark download incomplete")
  check(has("FAILED src/boot/kernel.lua"), "failed file was not identified")
  check(disk["/home/TerraCorp-OS/src/init.lua"] == "return 1\n", "valid file was not copied")
elseif scenario == "short_file" then
  check(has("RESULT: INCOMPLETE"), "truncated file was accepted")
  check(has("wrote"), "truncated byte count was not reported")
elseif scenario == "disk_full" then
  check(has("RESULT: INCOMPLETE"), "full disk was accepted")
  check(has("no space"), "filesystem error was not reported")
elseif scenario == "no_card" then
  check(has("RESULT: ERROR"), "missing Internet Card was not reported")
  check(has("Internet Card"), "missing network hardware was not identified")
end

-- Output must remain readable even if the terminal renders text poorly.
for _, line in ipairs(out) do
  if #line > 60 then
    problems = problems + 1
    say("  FAIL " .. scenario .. ": line exceeds 60 characters")
  end
  for index = 1, #line do
    if line:byte(index) > 126 then
      problems = problems + 1
      say("  FAIL " .. scenario .. ": non-ASCII output")
      break
    end
  end
end

FETCH_ERRORS = problems
