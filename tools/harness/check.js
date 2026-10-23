// Comprueba que todos los ficheros Lua compilan con Lua 5.3 (fengari).
// No ejecuta el código: solo valida sintaxis, como haría `load` en OpenComputers.

const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

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
for (const file of files) {
  const source = fs.readFileSync(file, "utf8");
  const status = lauxlib.luaL_loadstring(L, to_luastring(source));
  if (status !== lua.LUA_OK) {
    errors++;
    console.error("ERROR " + path.relative(repoRoot, file));
    console.error("      " + to_jsstring(lua.lua_tostring(L, -1)));
  }
  lua.lua_settop(L, 0);
}

console.log(files.length + " ficheros comprobados, " + errors + " errores");
process.exit(errors ? 1 : 0);
