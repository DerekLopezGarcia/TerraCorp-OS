// Comprueba que el OS se recupera cuando la GPU rechaza escrituras.
//
//   node tools/harness/test-faults.js
//
// La GPU real devuelve nil, "not enough energy" si no tiene energía. El OS
// debe reintentar esos tramos: la pantalla final con fallos inyectados tiene
// que ser IDÉNTICA a la del mismo escenario sin fallos. Si el volcado por
// diferencias da por pintadas las celdas que la GPU rechazó, quedan huecos
// que ya no se reintentan nunca.

const path = require("path");
const { spawnSync } = require("child_process");

const simulate = path.join(__dirname, "simulate.js");
const scenarios = ["dashboard", "console", "files", "settings"];

function run(scenario, extra) {
  const args = [simulate, scenario, "--strict"].concat(extra);
  const result = spawnSync(process.execPath, args, { encoding: "utf8" });
  const output = (result.stdout || "") + (result.stderr || "");

  const start = output.indexOf("=== PANTALLA FINAL ===");
  const end = output.indexOf("=== REGISTRO PERSISTIDO ===");
  const raw = start >= 0 && end > start ? output.slice(start, end) : null;
  // El reloj se lee del sistema: se enmascara para que dos ejecuciones
  // separadas por un segundo no cuenten como diferencia de contenido.
  const screen = raw === null ? null : raw.replace(/\d{2}:\d{2}:\d{2}/g, "HH:MM:SS").trimEnd();

  return { code: result.status, screen, output };
}

let problems = 0;
for (const scenario of scenarios) {
  const base = run(scenario, []);
  const fault = run(scenario, ["--fault=200"]);

  if (base.code !== 0) {
    problems += 1;
    console.log("FALLO " + scenario + ": el escenario base ya falla");
    continue;
  }
  if (fault.code !== 0) {
    problems += 1;
    console.log("FALLO " + scenario + ": no se recupera de la GPU sin energía");
    continue;
  }
  if (!base.screen || !fault.screen) {
    problems += 1;
    console.log("FALLO " + scenario + ": no se pudo leer la pantalla final");
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
    console.log("FALLO " + scenario + ": la pantalla difiere tras inyectar fallos (línea " + (first + 1) + ")");
    console.log("  sin fallos: " + (baseLines[first] || "(vacía)"));
    console.log("  con fallos: " + (faultLines[first] || "(vacía)"));
    continue;
  }
  console.log("ok " + scenario + ": misma pantalla con y sin fallos de GPU");
}

console.log("");
console.log(problems === 0 ? "sin errores" : problems + " problema(s)");
process.exit(problems === 0 ? 0 : 1);
