// F0 metrics: source size and harness rendering cost.
//
//   node tools/harness/measure.js
//
// This is not a gate: print metrics for `docs/tests.md` and version comparisons.
// Exit with an error only if a scenario fails.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const repoRoot = path.resolve(__dirname, "../..");
const srcRoot = path.join(repoRoot, "src");
const simulate = path.join(__dirname, "simulate.js");

function luaFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...luaFiles(full));
    else if (entry.name.endsWith(".lua")) out.push(full);
  }
  return out.sort();
}

function stats(files) {
  let lines = 0;
  let bytes = 0;
  for (const file of files) {
    const text = fs.readFileSync(file, "utf8");
    lines += text.split("\n").filter((line) => line.trim() !== "").length;
    bytes += Buffer.byteLength(text, "utf8");
  }
  return { lines, bytes };
}

const entry = [path.join(srcRoot, "init.lua")];
const boot = luaFiles(path.join(srcRoot, "boot"));
const lib = luaFiles(path.join(srcRoot, "lib"));
const apps = luaFiles(path.join(srcRoot, "apps"));
const core = [...entry, ...boot, ...lib];

const coreStats = stats(core);
const appStats = stats(apps);
const total = stats([...core, ...apps]);
const kb = (bytes) => (bytes / 1024).toFixed(1) + " KB";

console.log("TerraCorp OS — local metrics (Lua 5.3 harness)");
console.log("-".repeat(70));
console.log(
  "core   : " + coreStats.lines + " lines · " + kb(coreStats.bytes) + " · init " +
  stats(entry).lines + " · boot " + stats(boot).lines + " · lib " + stats(lib).lines
);
console.log("apps   : " + appStats.lines + " lines · " + kb(appStats.bytes) + " (" + apps.length + " apps)");
console.log("total  : " + total.lines + " lines · " + kb(total.bytes) + " across " +
  (core.length + apps.length) + " modules (tier 2 disk: 1 MB)");
console.log("");

const scenarios = ["dashboard", "console", "files", "settings", "all"];
const screens = [
  { width: 160, height: 50 },
  { width: 80, height: 25 },
];

let problems = 0;

console.log(
  "scenario".padEnd(11) + "screen".padEnd(10) + "painted".padEnd(21) +
  "gpu.set".padEnd(9) + "signals"
);

for (const screen of screens) {
  const size = screen.width + "x" + screen.height;
  for (const scenario of scenarios) {
    const result = spawnSync(
      process.execPath,
      [simulate, scenario, "--strict", "--screen=" + size],
      { encoding: "utf8" }
    );
    const output = (result.stdout || "") + (result.stderr || "");

    if (result.status !== 0) {
      problems += 1;
      console.log(scenario.padEnd(11) + size.padEnd(10) + "FAIL: scenario did not complete");
      continue;
    }

    const painted = output.match(
      /painted\s*:\s*(\d+) of (\d+) cells \(([\d.]+) %\).*?(\d+) gpu\.set calls · (\d+) signals/
    );

    console.log(
      scenario.padEnd(11) +
      size.padEnd(10) +
      (painted ? painted[1] + "/" + painted[2] + " (" + painted[3] + " %)" : "(no data)").padEnd(21) +
      (painted ? painted[4] : "(no data)").padEnd(9) +
      (painted ? painted[5] : "(no data)")
    );
  }
}

console.log("");
console.log(
  "Harness startup is synchronous: the first frame draws before any event is read,\n" +
  "so measure real boot time and memory in-game (uptime and computer.freeMemory,\n" +
  "recorded in /var/log/tc.log)."
);

process.exit(problems === 0 ? 0 : 1);
