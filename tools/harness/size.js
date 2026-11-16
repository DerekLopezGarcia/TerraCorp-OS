// Size gate for the line node installer image.
//
// The floppy only installs; the node runs from the HDD. That means the medium
// caps the *installer image* (payload + boot/install.lua) at 512 KB, and this
// gate keeps the image well under it so the budget cannot rot in three releases.
//
//   npm run size
//
// A file marked `planned` is not written yet: its estimate counts towards the
// total and the report says so. When the file lands, the measured size replaces
// the estimate with no change to this list.

const fs = require("fs");
const path = require("path");

const repoRoot = path.resolve(__dirname, "../..");

const MEDIUM_KB = 512; // a floppy holds 512 KB in Supersymmetry
const TARGET_KB = 256; // keep the image at half the medium or less

// Everything a line node needs to boot, read, alarm and publish. Estimated sizes
// come from the 0.4.8 measurements of the same modules plus the design in
// docs/line-node.md.
const FILES = [
  { file: "src/init.lua", estimate: 3.6 },
  { file: "src/boot/kernel.lua", estimate: 24.9 },
  { file: "src/boot/install.lua", estimate: 8.0 },
  { file: "src/lib/tc/config.lua", estimate: 4.2 },
  { file: "src/lib/tc/log.lua", estimate: 2.6 },
  { file: "src/lib/tc/util.lua", estimate: 2.6 },
  { file: "src/lib/tc/vfs.lua", estimate: 5.0 },
  { file: "src/lib/tc/version.lua", estimate: 0.3 },
  { file: "src/lib/tc/text.lua", estimate: 3.4 },
  { file: "src/lib/tc/installer.lua", estimate: 8.0 },
  { file: "src/lib/tc/naming.lua", estimate: 4.0 },
  { file: "src/lib/tc/addr.lua", estimate: 4.8 },
  { file: "src/lib/tc/path.lua", estimate: 6.7 },
  { file: "src/lib/tc/driver.lua", estimate: 6.4 },
  { file: "src/lib/tc/stock.lua", estimate: 16.5 },
  { file: "src/lib/tc/tank.lua", estimate: 1.3 },
  { file: "src/lib/tc/plant.lua", estimate: 10.0 },
  { file: "src/lib/tc/history.lua", estimate: 9.7 },
  { file: "src/lib/tc/halls.lua", estimate: 6.3 },
  { file: "src/lib/tc/net.lua", estimate: 8.1 },
  { file: "src/lib/tc/report.lua", estimate: 9.0 },
];

let totalBytes = 0;
const rows = [];
let missing = 0;

for (const entry of FILES) {
  const full = path.join(repoRoot, entry.file);
  const exists = fs.existsSync(full);
  if (!exists && !entry.planned) {
    console.error("FAIL missing from the node payload: " + entry.file);
    missing++;
    continue;
  }
  const kb = exists ? fs.statSync(full).size / 1024 : entry.estimate;
  totalBytes += exists ? fs.statSync(full).size : entry.estimate * 1024;
  rows.push({ file: entry.file, kb, measured: exists });
}

if (missing > 0) {
  console.log("size: " + missing + " file(s) missing, the payload list is stale");
  process.exit(1);
}

rows.sort((a, b) => b.kb - a.kb);
const totalKB = totalBytes / 1024;
const estimated = rows.filter((row) => !row.measured).length;

console.log("line node installer image");
for (const row of rows) {
  const mark = row.measured ? "" : " (estimate)";
  console.log("  " + row.kb.toFixed(1).padStart(6) + " KB  " + row.file + mark);
}
console.log("");

const summary =
  "  " + totalKB.toFixed(1) + " KB of " + TARGET_KB + " KB target" +
  "  (" + ((totalKB / MEDIUM_KB) * 100).toFixed(0) + "% of the " + MEDIUM_KB + " KB floppy)";
console.log(summary);
if (estimated > 0) {
  console.log("  " + estimated + " file(s) still planned; the total includes their estimates");
}

if (totalKB > TARGET_KB) {
  console.error("FAIL the installer image is over its " + TARGET_KB + " KB budget");
  process.exit(1);
}

console.log("size: the installer image fits with room to spare");
