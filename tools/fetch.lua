-- TerraCorp OS repository downloader for OpenComputers (run under OpenOS).
--
--   wget https://raw.githubusercontent.com/DerekLopezGarcia/TerraCorp-OS/main/tools/fetch.lua /tmp/fetch.lua
--   lua /tmp/fetch.lua [destination] [base-url]
--
-- Copies the public repository without Git or manual file copying. Requires an
-- Internet Card and HTTP(S) access enabled in the mod configuration.
--
-- Keep output ASCII and short because OpenComputers terminals may render long
-- lines poorly. The final RESULT line is authoritative; intermediate lines are
-- informational only.

local component = require("component")
local filesystem = require("filesystem")
local internet = require("internet")
local shell = require("shell")

local args = shell.parse(...)
local target = shell.resolve(args[1] or "/home/TerraCorp-OS")
local base = (args[2] or "https://raw.githubusercontent.com/DerekLopezGarcia/TerraCorp-OS/main"):gsub("/+$", "")

if not component.isAvailable("internet") then
  io.stderr:write("RESULT: ERROR - no Internet Card\n")
  return
end

-- Return body, error, and HTTP status. A 404 means the URL/repository path is
-- wrong, not that the network is unavailable. GitHub raw URLs are case-sensitive.
local function request(url)
  local ok, handle, reason = pcall(internet.request, url)
  if not ok then
    return nil, "excepcion: " .. tostring(handle)
  end
  if not handle then
    return nil, reason or "no response"
  end

  local status
  if type(handle.response) == "function" then
    local codeOk, code = pcall(handle.response, handle)
    if codeOk and type(code) == "number" then
      status = code
    end
  end

  local chunks = {}
  local readOk, readError = pcall(function()
    for chunk in handle do
      chunks[#chunks + 1] = chunk
    end
  end)
  pcall(handle.close, handle)

  if not readOk then
    return nil, "read: " .. tostring(readError), status
  end
  if status and status ~= 200 then
    return nil, "HTTP " .. status, status
  end

  local body = table.concat(chunks)
  if body == "" then
    return nil, "empty response", status
  end
  return body, nil, status
end

-- Retry once; the first request after boot can fail transiently in OpenComputers.
local function fetch(url)
  local body, reason, status = request(url)
  if body then
    return body
  end
  body, reason, status = request(url)
  return body, reason, status
end

local copied, failed = 0, 0
local bytes = 0

print("TERRACORP OS - descarga")
print("target: " .. target)
print("source: " .. base)

local manifest, reason, status = fetch(base .. "/tools/manifest.txt")
if not manifest then
  io.stderr:write("RESULT: ERROR - manifest read failed (" .. tostring(reason) .. ")\n")
  if status == 404 then
    io.stderr:write("path not found; check repository visibility\n")
    io.stderr:write("and owner capitalization: DerekLopezGarcia\n")
  else
    io.stderr:write("check network: component.isAvailable(\"internet\")\n")
  end
  return
end

local paths = {}
for line in manifest:gmatch("[^\r\n]+") do
  line = line:gsub("^%s+", ""):gsub("%s+$", "")
  if line ~= "" and line:sub(1, 1) ~= "#" then
    paths[#paths + 1] = line
  end
end

if #paths == 0 then
  io.stderr:write("RESULT: ERROR - empty manifest\n")
  return
end

print("files: " .. #paths)

for index, relative in ipairs(paths) do
  local destination = filesystem.concat(target, relative)
  local directory = destination:match("^(.*)/[^/]+$")
  if directory and directory ~= "" then
    pcall(filesystem.makeDirectory, directory)
  end

  local content, why = fetch(base .. "/" .. relative)
  local writeReason

  if content then
    local handle, openError = filesystem.open(destination, "wb")
    if handle then
      local writeOk = pcall(function()
        handle:write(content)
        handle:close()
      end)
      if not writeOk then
        writeReason = "interrupted write"
      else
        -- Verify bytes on disk rather than trusting the display or write call;
        -- a full volume can leave a truncated file.
        local okSize, size = pcall(filesystem.size, destination)
        if okSize and size ~= #content then
          writeReason = string.format("wrote %s of %d B", tostring(size), #content)
        end
      end
    else
        writeReason = openError or "could not open"
    end
  end

  if content and not writeReason then
    copied = copied + 1
    bytes = bytes + #content
    print(string.format("[%2d/%2d] %s", index, #paths, relative))
  else
    failed = failed + 1
    print(string.format("[%2d/%2d] FAILED %s (%s)", index, #paths, relative,
      tostring(writeReason or why)))
  end
end

if failed > 0 then
  print(string.format("RESULT: INCOMPLETE - %d/%d files (%d failures)",
    copied, #paths, failed))
  return
end

print(string.format("RESULT: OK - %d/%d files, %d bytes", copied, #paths, bytes))
print("")
print("next step:")
print("  cd " .. filesystem.concat(target, "tools"))
print("  ./install.lua " .. target)
