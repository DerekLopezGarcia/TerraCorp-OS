// The node payload, read from src/lib/tc/payload.lua.
//
// The flasher, the size gate and the payload check all read the same list, so
// they cannot disagree about what a flashed medium contains — which is exactly
// how the flasher came to write 514 KB onto a 512 KB floppy while `npm run size`
// reported 155 KB.
//
//   npm run check   -- completeness and dependency closure
//   npm run size    -- the byte budget

const fs = require("fs");
const path = require("path");

const repoRoot = path.resolve(__dirname, "..");
const payloadPath = path.join(repoRoot, "src", "lib", "tc", "payload.lua");

// Pull one `name = { "a", "b" }` list out of the Lua source. The file is a plain
// table of strings; anything more clever would deserve a real parser.
function readStrings(source, field) {
  const start = source.indexOf(field);
  if (start < 0) return null;
  const open = source.indexOf("{", start);
  const close = open < 0 ? -1 : source.indexOf("}", open);
  if (open < 0 || close < 0) return null;
  const body = source.slice(open + 1, close);
  return [...body.matchAll(/"([^"]+)"/g)].map((match) => match[1]);
}

function load() {
  const source = fs.readFileSync(payloadPath, "utf8");
  const files = readStrings(source, "payload.files");
  const desktopOnly = readStrings(source, "payload.desktopOnly");
  if (!files || !desktopOnly) {
    throw new Error("src/lib/tc/payload.lua: could not read payload.files / payload.desktopOnly");
  }
  return { files, desktopOnly };
}

// A payload path is a boot-volume path: /lib/tc/x.lua is src/lib/tc/x.lua.
function volumePath(file) {
  return path.join(repoRoot, "src", ...file.split("/").filter(Boolean));
}

function measure() {
  const { files, desktopOnly } = load();
  const rows = [];
  const missing = [];
  let total = 0;
  for (const file of files) {
    const full = volumePath(file);
    if (!fs.existsSync(full)) {
      missing.push(file);
      continue;
    }
    const size = fs.statSync(full).size;
    total += size;
    rows.push({ file, size });
  }
  return { files, desktopOnly, rows, total, missing };
}

// Every `tc.X` a payload file asks for must resolve to a module the medium
// carries, or to one declared desktop-only. A new dependency that nobody added
// to the list breaks a flashed node silently; this makes it loud.
//
// The scan is per line and string-based on purpose: the kernel loads with
// `requireModule("tc.x")`, the plant modules with `require("tc.x")`, and some
// sites with `pcall(requireModule, "tc.x")`. Matching the call shape missed the
// last one, and a gate that misses a pattern is worse than no gate.
function closure() {
  const { files, desktopOnly } = load();
  const carried = new Set(
    files
      .filter((file) => file.startsWith("/lib/tc/"))
      .map((file) => "tc." + file.slice("/lib/tc/".length, -4))
  );
  const declared = new Set(desktopOnly);
  const problems = [];
  for (const file of files) {
    const full = volumePath(file);
    if (!fs.existsSync(full)) continue;
    const source = fs.readFileSync(full, "utf8");
    source.split("\n").forEach((line, index) => {
      // `require` without a trailing boundary: the call is `requireModule(...)`
      // in the kernel and `pcall(requireModule, ...)` elsewhere.
      if (!/\brequire/.test(line)) return;
      for (const match of line.matchAll(/"(tc\.[\w.]+)"/g)) {
        const name = match[1];
        if (carried.has(name) || declared.has(name)) return;
        problems.push({ file, module: name, line: index + 1 });
      }
    });
  }
  return problems;
}

module.exports = { load, measure, closure, volumePath };

if (require.main === module) {
  const report = measure();
  for (const row of report.rows.slice().sort((a, b) => b.size - a.size)) {
    console.log("  " + (row.size / 1024).toFixed(1).padStart(6) + " KB  " + row.file);
  }
  console.log("");
  console.log("  " + report.files.length + " files, " + (report.total / 1024).toFixed(1) + " KB");
  for (const file of report.missing) console.log("  MISSING " + file);
  for (const problem of closure()) {
    console.log("  GAP " + problem.file + " requires " + problem.module);
  }
}
