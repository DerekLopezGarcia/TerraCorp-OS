// Verify that the OS recovers when the GPU rejects writes.
//
//   node tools/harness/test-faults.js
//
// The real GPU may return nil, "not enough energy". The OS must retry rejected
// spans so the final screen matches a run without injected faults.

const path = require("path");
const { spawnSync } = require("child_process");

const simulate = path.join(__dirname, "simulate.js");
const scenarios = ["dashboard", "console", "files", "settings"];

function run(scenario, extra) {
  const args = [simulate, scenario, "--strict"].concat(extra);
  const result = spawnSync(process.execPath, args, { encoding: "utf8" });
  const output = (result.stdout || "") + (result.stderr || "");

  const start = output.indexOf("=== FINAL SCREEN ===");
  const end = output.indexOf("=== PERSISTED LOG ===");
  const raw = start >= 0 && end > start ? output.slice(start, end) : null;
  // Mask the clock so separate runs do not differ only by time.
  const screen = raw === null ? null : raw.replace(/\d{2}:\d{2}:\d{2}/g, "HH:MM:SS").trimEnd();

  return { code: result.status, screen, output };
}

let problems = 0;
for (const scenario of scenarios) {
  const base = run(scenario, []);
  const fault = run(scenario, ["--fault=200"]);

  if (base.code !== 0) {
    problems += 1;
    console.log("FAIL " + scenario + ": baseline scenario failed");
    continue;
  }
  if (fault.code !== 0) {
    problems += 1;
    console.log("FAIL " + scenario + ": did not recover from GPU power failures");
    continue;
  }
  if (!base.screen || !fault.screen) {
    problems += 1;
    console.log("FAIL " + scenario + ": could not read final screen");
    continue;
  }
  if (base.screen !== fault.screen) {
    problems += 1;
    const baseLines = base.screen.split("\n");
    const faultLines = fault.screen.split("\n");
    let first = -1;
    for (let i = 0; i < Math.max(baseLines.length, faultLines.length); i += 1) {
      if (baseLines[i] !== faultLines[i]) {
        first = i;
        break;
      }
    }
    console.log("FAIL " + scenario + ": screen differs after injected fault (line " + (first + 1) + ")");
    console.log("  baseline: " + (baseLines[first] || "(empty)"));
    console.log("  faulted : " + (faultLines[first] || "(empty)"));
    continue;
  }
  console.log("ok " + scenario + ": same screen with and without GPU faults");
}

console.log("");
console.log(problems === 0 ? "no failures" : problems + " problem(s)");
process.exit(problems === 0 ? 0 : 1);
