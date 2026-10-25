-- TerraCorp OS installer. Run under OpenOS, not under TerraCorp OS.
--
--   install <raizDelRepo> [direccionFilesystem] [--eeprom] [--yes] [--list]
--
-- Copies src/ to the selected filesystem, creates /etc and /var/log, and sets
-- the boot volume. EEPROM flashing is optional and normally unnecessary.
-- Without an address, select a writable non-OpenOS volume that is empty or
-- already contains TerraCorp. Never choose a disk with unrelated data.

local component = require("component")
local computer = require("computer")
local filesystem = require("filesystem")
local shell = require("shell")
local term = require("term")

local args, options = shell.parse(...)

local repoRoot = args[1]
local address = args[2]

if not repoRoot then
  print("Usage: install <repo-root> [filesystem-address] [--eeprom] [--yes] [--list]")
  print("Example: install /home/TerraCorp-OS")
  print("         install /home/TerraCorp-OS 1a2b3c4d-...")
  return
end

repoRoot = shell.resolve(repoRoot)
local sourceRoot = filesystem.concat(repoRoot, "src")
local eepromSource = filesystem.concat(repoRoot, "eeprom/init.lua")

if not filesystem.isDirectory(sourceRoot) then
  io.stderr:write("Source tree not found: " .. sourceRoot .. "\n")
  return
end

--------------------------------------------------------------------------------
-- Select the destination volume
--------------------------------------------------------------------------------

-- The OS needs at least 1 MB. This excludes the small writable OpenOS tmpfs.
local MIN_BYTES = 1048576

-- Filesystem component handles expect an integer read size, not io's "*a".
local function readAll(handle)
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

local function rootAddress()
  local ok, proxy = pcall(filesystem.get, "/")
  if ok and proxy and proxy.address then
    return proxy.address
  end
  return nil
end

local function countEntries(proxy)
  local ok, names = pcall(proxy.list, "")
  if not ok or type(names) ~= "table" then
    return 0
  end
  local total = 0
  for _ in pairs(names) do
    total = total + 1
  end
  return total
end

local function stateOf(proxy)
  local ok, exists = pcall(proxy.exists, "/boot/kernel.lua")
  if ok and exists then
    return "existing installation"
  end
  if countEntries(proxy) == 0 then
    return "empty"
  end
  return "has data"
end

local function isWritable(proxy)
  local ok, readOnly = pcall(proxy.isReadOnly)
  return ok and readOnly == false
end

local function describe(item)
  local size = "unlimited"
  if item.size ~= math.huge then
    size = string.format("%.1f MB", item.size / 1048576)
  end
  return string.format("%s  %-20s %-16s %10s", item.address:sub(1, 8), item.state, item.label, size)
end

local function candidates()
  local root = rootAddress()
  local found = {}

  for candidate in component.list("filesystem") do
    if candidate ~= root then
      local proxy = component.proxy(candidate)
      if proxy and proxy.type == "filesystem" and isWritable(proxy) then
        local total = proxy.spaceTotal() or 0
        local state = stateOf(proxy)
        if state ~= "has data" and total >= MIN_BYTES then
          found[#found + 1] = {
            address = candidate,
            proxy = proxy,
            state = state,
            label = (proxy.getLabel and proxy.getLabel()) or "no label",
            size = total,
          }
        end
      end
    end
  end

  table.sort(found, function(a, b)
    return a.address < b.address
  end)

  return found
end

local function pick(found)
  if #found == 1 then
    print("Detected: " .. describe(found[1]))
    return found[1]
  end

  print("Available install volumes:")
  for index, item in ipairs(found) do
    print(string.format("  %d) %s", index, describe(item)))
  end

  if options.yes then
    io.stderr:write("Multiple candidates; specify a filesystem address.\n")
    return nil
  end

  io.write("Select a volume [1]: ")
  local answer = io.read("*l") or ""
  local index = tonumber(answer) or 1
  if not found[index] then
    io.stderr:write("Invalid selection.\n")
    return nil
  end

  return found[index]
end

local proxy

if options.list then
  local found = candidates()
  if #found == 0 then
    print("No eligible install volumes found.")
  end
  for _, item in ipairs(found) do
    print(describe(item))
  end
  return
end

if address then
  proxy = component.proxy(address)
  if not proxy or proxy.type ~= "filesystem" then
    io.stderr:write("Not a valid filesystem address: " .. tostring(address) .. "\n")
    return
  end
else
  local found = candidates()
  if #found == 0 then
    io.stderr:write("No eligible install volume found.\n")
    io.stderr:write("Disks with data and disks under 1 MB are ignored.\n")
    io.stderr:write("Connect an empty disk or pass its address: install <root> <address>\n")
    return
  end

  local chosen = pick(found)
  if not chosen then
    return
  end

  proxy, address = chosen.proxy, chosen.address
end

print(string.format("Source      : %s", sourceRoot))
print(string.format("Destination: %s (%s)", address, proxy.getLabel and (proxy.getLabel() or "no label") or "no label"))

local used = proxy.spaceUsed()
local total = proxy.spaceTotal()
if used and total then
  print(string.format("Disk   : %.1f / %.1f MB used · %s", used / 1048576, total / 1048576, stateOf(proxy)))
end

if not options.yes then
  io.write("Files with matching names will be overwritten. Continue? (y/N) ")
  local answer = io.read("*l") or ""
  if answer:lower() ~= "y" and answer:lower() ~= "yes" then
    print("Cancelled.")
    return
  end
end

local mountPoint = "/mnt/terracorp-install"
if filesystem.exists(mountPoint) then
  pcall(filesystem.umount, mountPoint)
else
  filesystem.makeDirectory(mountPoint)
end

if not filesystem.mount(proxy, mountPoint) then
  io.stderr:write("Could not mount destination at " .. mountPoint .. "\n")
  return
end

local copied, failed = 0, 0

local function copyTree(from, to)
  filesystem.makeDirectory(to)

  for name in filesystem.list(from) do
    local source = filesystem.concat(from, name)
    local target = filesystem.concat(to, name)

    if filesystem.isDirectory(source) then
      copyTree(source, target)
    else
      local input = filesystem.open(source, "rb")
      if not input then
        failed = failed + 1
        io.stderr:write("Could not read " .. source .. "\n")
      else
        local data = readAll(input)
        input:close()

        local output = filesystem.open(target, "wb")
        if not output then
          failed = failed + 1
          io.stderr:write("Could not write " .. target .. "\n")
        else
          output:write(data)
          output:close()
          copied = copied + 1
        end
      end
    end
  end
end

local ok, reason = pcall(copyTree, sourceRoot, mountPoint)

filesystem.makeDirectory(filesystem.concat(mountPoint, "etc"))
filesystem.makeDirectory(filesystem.concat(mountPoint, "var/log"))

pcall(filesystem.umount, mountPoint)

if not ok then
  io.stderr:write("Installation failed: " .. tostring(reason) .. "\n")
  return
end

print(string.format("Copied %d files (%d failures).", copied, failed))

-- pcall catches Lua errors only. component.invoke may return nil, reason when
-- a component rejects the call, so inspect the return value too.
local function succeeded(ok, value, reason)
  if not ok or value == false then
    return false, tostring(reason or value)
  end
  if value == nil and reason ~= nil then
    return false, tostring(reason)
  end
  return true
end

local bootOk, bootReason = succeeded(pcall(computer.setBootAddress, address))
if bootOk then
  print("Boot volume selected: " .. address)
else
  io.stderr:write("Could not select boot volume: " .. tostring(bootReason) .. "\n")
end

if options.eeprom then
  local eepromAddress = component.list("eeprom")()
  if not eepromAddress then
    io.stderr:write("No EEPROM is present.\n")
    return
  end

  print("")
  print("Warning: flashing the EEPROM replaces the computer BIOS.")
  print("         If the manager fails, replace the EEPROM with a Lua BIOS.")
  print("         This is normally unnecessary; selecting the boot volume is enough.")

  local input = filesystem.open(eepromSource, "rb")
  if not input then
    io.stderr:write("Not found: " .. eepromSource .. "\n")
    return
  end

  local code = readAll(input)
  input:close()

  local function flash(value)
    local ok, reason = succeeded(pcall(component.invoke, eepromAddress, "set", value))
    if ok then
      return true
    end
    return false, reason
  end

  local flashed, flashReason = flash(code)
  if not flashed then
    local bytes = {}
    for index = 1, #code do
      bytes[index] = code:byte(index)
    end
    local secondOk, secondReason = flash(bytes)
    if secondOk then
      flashed = true
    else
      flashReason = secondReason or flashReason
    end
  end

  if flashed then
    print("TerraCorp OS boot manager written to EEPROM.")
  else
    io.stderr:write("Could not write EEPROM (" .. tostring(flashReason) .. "). Copy eeprom/init.lua manually.\n")
  end
end

print("")
print("Installation complete. Reboot to start TerraCorp OS.")
term.write("")
