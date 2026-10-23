// Ejecuta TerraCorp OS fuera de Minecraft y vuelca la pantalla resultante.
//
//   node tools/harness/simulate.js [dashboard|console|files|settings|all] [--strict]
//
// Empaqueta src/ en memoria, la sirve como volumen de arranque a componentes
// falsos fieles a la API real de OpenComputers y reproduce un guion de
// eventos. Es una prueba de humo: detecta errores de ejecución, no sustituye
// a probarlo en el juego.

const { runScenario } = require("./runner");

const args = process.argv.slice(2);
const strict = args.includes("--strict");
const scenario = args.find((arg) => !arg.startsWith("--")) || "all";

try {
  process.exit(runScenario(scenario, strict) > 0 ? 1 : 0);
} catch (error) {
  console.error(error.message);
  process.exit(2);
}
