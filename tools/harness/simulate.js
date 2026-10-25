// Run TerraCorp OS outside Minecraft and print the resulting screen.
//
//   node tools/harness/simulate.js [dashboard|console|files|settings|nodes|all] [--strict] [--fault=N] [--screen=WxH]
//
// Bundle src/ in memory, expose it as a boot volume to API-faithful fake
// components, and replay events. This smoke test does not replace in-game
// testing. `--fault=N` rejects the first N GPU writes; `--screen=WxH` simulates
// another display size.

const { runScenario } = require("./runner");

const args = process.argv.slice(2);
const strict = args.includes("--strict");
const faultArg = args.find((arg) => arg.startsWith("--fault="));
const faultSet = faultArg ? parseInt(faultArg.split("=")[1], 10) || 0 : 0;
const screenArg = args.find((arg) => arg.startsWith("--screen="));
let screen = null;
if (screenArg) {
  const [width, height] = screenArg.split("=")[1].split("x").map((part) => parseInt(part, 10));
  if (width > 0 && height > 0) screen = { width, height };
}
const scenario = args.find((arg) => !arg.startsWith("--")) || "all";

try {
  process.exit(runScenario(scenario, strict, faultSet, screen) > 0 ? 1 : 0);
} catch (error) {
  console.error(error.message);
  process.exit(2);
}
