// Size gate for the line node installer image.
//
// The payload list lives in `src/lib/tc/payload.lua` and the flasher copies
// exactly that list, so this gate measures what a flash actually writes. That is
// the whole point: the flasher used to copy every root (514 KB) while this gate
// measured a hand-written 21-file subset (155 KB) and reported "fits".
//
// The floppy only installs; the node runs from the HDD, so the medium caps the
// installer image.
//
//   npm run size

const payload = require("../payload");

const MEDIUM_KB = 512; // a floppy holds 512 KB in Supersymmetry
const TARGET_KB = 256; // keep the image at half the medium or less
const MARGIN_KB = 8; // flash.MARGIN: the flasher refuses a medium without it
// The flasher also writes /installer.lua and a generated /etc/terracorp.cfg.
const EXTRAS_KB = 0.7;

const report = payload.measure();

if (report.missing.length > 0) {
  console.error("FAIL missing from the node payload: " + report.missing.join(", "));
  process.exit(1);
}

const imageKB = report.total / 1024 + EXTRAS_KB;

console.log("line node installer image (src/lib/tc/payload.lua)");
for (const row of report.rows.slice().sort((a, b) => b.size - a.size)) {
  console.log("  " + (row.size / 1024).toFixed(1).padStart(6) + " KB  " + row.file);
}
console.log("");
console.log(
  "  " + report.files.length + " files, " + imageKB.toFixed(1) + " KB of " + TARGET_KB +
  " KB target  (" + ((imageKB / MEDIUM_KB) * 100).toFixed(0) + "% of the " + MEDIUM_KB + " KB floppy)"
);

if (imageKB > TARGET_KB) {
  console.error("FAIL the installer image is over its " + TARGET_KB + " KB budget");
  process.exit(1);
}
if (imageKB + MARGIN_KB > MEDIUM_KB) {
  console.error(
    "FAIL the installer image (" + imageKB.toFixed(1) + " KB) plus the " + MARGIN_KB +
    " KB margin no longer fits the " + MEDIUM_KB + " KB medium"
  );
  process.exit(1);
}
console.log("size: the installer image fits with room to spare");
