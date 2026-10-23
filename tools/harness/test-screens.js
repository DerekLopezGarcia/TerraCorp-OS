// Comprueba que el OS usa la resolución real de la pantalla y se recoloca.
//
//   node tools/harness/test-screens.js
//
// El escritorio no impone una medida fija: en cada tamaño simulado debe
// adoptar exactamente la resolución disponible y terminar sin errores, con
// algo pintado. Es el gate de "la pantalla que exista".

const path = require("path");
const { spawnSync } = require("child_process");

const simulate = path.join(__dirname, "simulate.js");
const scenarios = ["dashboard", "console", "files", "settings"];
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

    const reported = output.match(/resolución:\s*(\d+)x(\d+)/);
    const actual = reported ? reported[1] + "x" + reported[2] : "(sin datos)";

    if (result.status !== 0) {
      problems += 1;
      console.log("FALLO " + size + " " + scenario + ": el escenario termina con errores");
      continue;
    }
    if (actual !== size) {
      problems += 1;
      console.log("FALLO " + size + " " + scenario + ": usa " + actual + " en vez de la de la pantalla");
      continue;
    }

    const start = output.indexOf("=== PANTALLA FINAL ===");
    const end = output.indexOf("=== REGISTRO PERSISTIDO ===");
    const block = start >= 0 && end > start ? output.slice(start, end) : "";
    const painted = (block.match(/[^\s|]/g) || []).length;
    if (painted < 10) {
      problems += 1;
      console.log("FALLO " + size + " " + scenario + ": pantalla prácticamente vacía");
      continue;
    }

    console.log("ok " + size + " " + scenario + " (" + painted + " celdas con contenido)");
  }
}

console.log("");
console.log(problems === 0 ? "sin errores" : problems + " problema(s)");
process.exit(problems === 0 ? 0 : 1);
