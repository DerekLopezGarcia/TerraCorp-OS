// Strict gate: run scenarios with API contract checks enabled and fail if any
// scenario reports a problem.
//
//   node tools/harness/simulate-oc.js

const { runScenario } = require("./runner");

const scenarios = ["dashboard", "console", "files", "settings", "updater", "updater_rollback", "refresh_rate"];
const failed = [];

for (const scenario of scenarios) {
  console.log("");
  console.log("########## " + scenario + " ##########");
  try {
    const errors = runScenario(scenario, true);
    if (errors > 0) failed.push(scenario + " (" + errors + ")");
  } catch (error) {
    console.error("Harness error in " + scenario + ": " + error.message);
    failed.push(scenario + " (exception)");
  }
}

console.log("");
console.log("=== STRICT SUMMARY ===");
if (failed.length === 0) {
  console.log(scenarios.length + " scenarios, no failures");
  process.exit(0);
}
console.log("scenarios with failures: " + failed.join(", "));
process.exit(1);
