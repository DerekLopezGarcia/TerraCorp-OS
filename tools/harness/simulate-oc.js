// Gate estricto: ejecuta los cuatro escenarios con las comprobaciones de
// contrato activadas (list devuelve tabla, spaceUsed en bytes, tarjeta de
// almacenamiento viva). Falla si cualquiera de ellos reporta problemas.
//
//   node tools/harness/simulate-oc.js

const { runScenario } = require("./runner");

const scenarios = ["dashboard", "console", "files", "settings"];
const failed = [];

for (const scenario of scenarios) {
  console.log("");
  console.log("########## " + scenario + " ##########");
  try {
    const errors = runScenario(scenario, true);
    if (errors > 0) failed.push(scenario + " (" + errors + ")");
  } catch (error) {
    console.error("error del arnés en " + scenario + ": " + error.message);
    failed.push(scenario + " (excepción)");
  }
}

console.log("");
console.log("=== RESUMEN ESTRICTO ===");
if (failed.length === 0) {
  console.log("4 escenarios, sin errores");
  process.exit(0);
}
console.log("escenarios con problemas: " + failed.join(", "));
process.exit(1);
