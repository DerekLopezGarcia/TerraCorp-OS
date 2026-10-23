// Ejecuta TerraCorp OS fuera de Minecraft y vuelca la pantalla resultante.
//
//   node tools/harness/simulate.js [dashboard|console|files|settings|all] [--strict] [--fault=N]
//
// Empaqueta src/ en memoria, la sirve como volumen de arranque a componentes
// falsos fieles a la API real de OpenComputers y reproduce un guion de
// eventos. Es una prueba de humo: detecta errores de ejecución, no sustituye
// a probarlo en el juego. Con --fault=N las primeras N escrituras de la GPU
// fallan como si no hubiera energía.

const { runScenario } = require("./runner");

const args = process.argv.slice(2);
const strict = args.includes("--strict");
const faultArg = args.find((arg) => arg.startsWith("--fault="));
const faultSet = faultArg ? parseInt(faultArg.split("=")[1], 10) || 0 : 0;
const scenario = args.find((arg) => !arg.startsWith("--")) || "all";

try {
  process.exit(runScenario(scenario, strict, faultSet) > 0 ? 1 : 0);
} catch (error) {
  console.error(error.message);
  process.exit(2);
}
