// Medidas de F0: tamaño del código y coste de pintado en el arnés.
//
//   node tools/harness/measure.js
//
// No es un gate: imprime cifras para `docs/pruebas.md` y para comparar
// versiones. Sale con error sólo si un escenario no termina bien.

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

console.log("TerraCorp OS — medidas locales (arnés, Lua 5.3)");
console.log("-".repeat(70));
console.log(
  "núcleo : " + coreStats.lines + " líneas · " + kb(coreStats.bytes) + " · init " +
  stats(entry).lines + " · boot " + stats(boot).lines + " · lib " + stats(lib).lines
);
console.log("apps   : " + appStats.lines + " líneas · " + kb(appStats.bytes) + " (" + apps.length + " apps)");
console.log("total  : " + total.lines + " líneas · " + kb(total.bytes) + " en " +
  (core.length + apps.length) + " módulos (disco tier 2: 1 MB)");
console.log("");

const scenarios = ["dashboard", "console", "files", "settings", "all"];
const screens = [
  { width: 160, height: 50 },
  { width: 80, height: 25 },
];

let problems = 0;

console.log(
  "escenario".padEnd(11) + "pantalla".padEnd(10) + "pintado".padEnd(21) +
  "gpu.set".padEnd(9) + "señales"
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
      console.log(scenario.padEnd(11) + size.padEnd(10) + "FALLO: el escenario no termina bien");
      continue;
    }

    const painted = output.match(
      /pintado\s*:\s*(\d+) de (\d+) celdas \(([\d.]+) %\).*?(\d+) llamadas a gpu\.set · (\d+) señales/
    );

    console.log(
      scenario.padEnd(11) +
      size.padEnd(10) +
      (painted ? painted[1] + "/" + painted[2] + " (" + painted[3] + " %)" : "(sin datos)").padEnd(21) +
      (painted ? painted[4] : "(sin datos)").padEnd(9) +
      (painted ? painted[5] : "(sin datos)")
    );
  }
}

console.log("");
console.log(
  "El arnés arranca de forma síncrona: el primer frame se pinta antes de consumir\n" +
  "ninguna señal, así que el tiempo real de arranque y la memoria sólo se miden en\n" +
  "juego (uptime y computer.freeMemory, apuntados en /var/log/tc.log)."
);

process.exit(problems === 0 ? 0 : 1);
