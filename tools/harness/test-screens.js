// Verify that the OS adopts the actual screen resolution and reflows.
//
//   node tools/harness/test-screens.js
//
// The desktop must adapt to each simulated resolution, finish without errors,
// and paint visible content.

const path = require("path");
const { spawnSync } = require("child_process");

const simulate = path.join(__dirname, "simulate.js");
const scenarios = ["dashboard", "console", "files", "settings", "updater"];
const screens = [
  { width: 160, height: 50 },
  { width: 120, height: 40 },
  { width: 80, height: 25 },
  { width: 60, height: 20 },
  { width: 40, height: 16 },
];

let problems = 0;

for (const screen of screens) {
  const size = screen.width + "x" + screen.height;
  for (const scenario of scenarios) {
    const args = [simulate, scenario, "--strict", "--screen=" + size];
    const result = spawnSync(process.execPath, args, { encoding: "utf8" });
    const output = (result.stdout || "") + (result.stderr || "");

    const reported = output.match(/resolution\s*:\s*(\d+)x(\d+)/);
    const actual = reported ? reported[1] + "x" + reported[2] : "(no data)";

    if (result.status !== 0) {
      problems += 1;
      console.log("FAIL " + size + " " + scenario + ": scenario ended with errors");
      continue;
    }
    if (actual !== size) {
      problems += 1;
      console.log("FAIL " + size + " " + scenario + ": reported the wrong screen resolution");
      continue;
    }

    const start = output.indexOf("=== FINAL SCREEN ===");
    const end = output.indexOf("=== PERSISTED LOG ===");
    const block = start >= 0 && end > start ? output.slice(start, end) : "";
    const painted = (block.match(/[^\s|]/g) || []).length;
    if (painted < 10) {
      problems += 1;
      console.log("FAIL " + size + " " + scenario + ": screen is nearly empty");
      continue;
    }

      console.log("ok " + size + " " + scenario + " (" + painted + " nonblank cells)");
  }
}

console.log("");
console.log(problems === 0 ? "no failures" : problems + " problem(s)");
process.exit(problems === 0 ? 0 : 1);
