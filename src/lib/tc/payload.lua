-- The files a line node needs, in one place.
--
-- This list is the node payload: what a flashed medium carries, what the
-- installer copies to the node's disk, and what `npm run size` measures. It is
-- deliberately explicit rather than a directory walk, because a walk made the
-- flasher copy the whole runtime (514 KB) onto a 512 KB floppy while the size
-- gate measured a different, smaller set.
--
-- `desktopOnly` is the other half of the contract: modules the kernel, the apps
-- or the desktop path may mention but that a node must not carry. The payload
-- gate fails when a payload file requires a module that is in neither table, so
-- a newly added dependency cannot silently break a flashed node.
--
-- Add a file here when a node needs it; then run `npm run check` and
-- `npm run size`.

local payload = {}

payload.files = {
  "/init.lua",
  "/boot/install.lua",
  "/boot/kernel.lua",
  "/lib/tc/addr.lua",
  "/lib/tc/changelog.lua",
  "/lib/tc/config.lua",
  "/lib/tc/driver.lua",
  "/lib/tc/halls.lua",
  "/lib/tc/history.lua",
  "/lib/tc/installer.lua",
  "/lib/tc/log.lua",
  "/lib/tc/naming.lua",
  "/lib/tc/net.lua",
  "/lib/tc/path.lua",
  "/lib/tc/plant.lua",
  "/lib/tc/report.lua",
  "/lib/tc/stock.lua",
  "/lib/tc/tank.lua",
  "/lib/tc/text.lua",
  "/lib/tc/util.lua",
  "/lib/tc/version.lua",
  "/lib/tc/vfs.lua",
}

payload.desktopOnly = {
  "tc.book",
  "tc.flash",
  "tc.gate",
  "tc.gfx",
  "tc.keys",
  "tc.lab",
  "tc.line",
  "tc.link",
  "tc.master",
  "tc.move",
  "tc.plan",
  "tc.registry",
  "tc.theme",
  "tc.ui",
  "tc.updater",
}

return payload
