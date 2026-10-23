// Comprueba que todos los ficheros Lua compilan con Lua 5.3 (fengari) y que
// tools/manifest.txt (lo que descarga fetch.lua) coincide con el árbol real.
// No ejecuta el código: solo valida sintaxis, como haría `load` en OpenComputers.

const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");
const { list } = require("../make-manifest");

const repoRoot = path.resolve(__dirname, "../..");
const targets = ["src", "eeprom", "tools"];

const files = [];
function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === "node_modules" || entry.name === ".git") continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (entry.name.endsWith(".lua")) files.push(full);
  }
}

for (const target of targets) {
  const full = path.join(repoRoot, target);
  if (fs.existsSync(full)) walk(full);
}
files.sort();

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

let errors = 0;
// Firmas de UTF-8 leído como CP1252 y vuelto a escribir: duplica los acentos y
// deja el texto ilegible en el juego. Un BOM al principio rompe `load`.
const MOJIBAKE = /Ã[\u0080-\u00BF]|Â[\u0080-\u00BF]/;

for (const file of files) {
  const source = fs.readFileSync(file, "utf8");

  if (source.charCodeAt(0) === 0xfeff) {
    errors++;
    console.error("ERROR " + path.relative(repoRoot, file));
    console.error("      empieza con BOM: `load` lo rechaza en OpenComputers");
  }

  const mojibake = source.match(MOJIBAKE);
  if (mojibake) {
    errors++;
    console.error("ERROR " + path.relative(repoRoot, file));
    console.error("      codificación duplicada cerca de " + JSON.stringify(mojibake[0]));
  }

  const status = lauxlib.luaL_loadstring(L, to_luastring(source));
  if (status !== lua.LUA_OK) {
    errors++;
    console.error("ERROR " + path.relative(repoRoot, file));
    console.error("      " + to_jsstring(lua.lua_tostring(L, -1)));
  }
  lua.lua_settop(L, 0);
}

// El manifiesto es lo que descarga tools/fetch.lua dentro del juego: si no
// coincide con el árbol, la instalación se queda a medias sin avisar.
const manifestPath = path.join(repoRoot, "tools", "manifest.txt");
const expected = list();
let manifest = null;

try {
  manifest = fs.readFileSync(manifestPath, "utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
} catch (error) {
  errors++;
  console.error("FALTA tools/manifest.txt (ejecuta: npm run manifest)");
}

if (manifest) {
  for (const file of expected) {
    if (!manifest.includes(file)) {
      errors++;
      console.error("FUERA DEL MANIFIESTO " + file + " (ejecuta: npm run manifest)");
    }
  }
  for (const file of manifest) {
    if (!expected.includes(file)) {
      errors++;
      console.error("EN EL MANIFIESTO PERO NO EN EL ÁRBOL " + file);
    }
  }
}

console.log(files.length + " ficheros comprobados, " + errors + " errores");
console.log("manifiesto: " + (manifest ? manifest.length : "ausente") + " ficheros");
process.exit(errors ? 1 : 0);
