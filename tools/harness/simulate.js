// Ejecuta TerraCorp OS fuera de Minecraft y vuelca la pantalla resultante.
//
//   node tools/harness/simulate.js [dashboard|console|files|settings|all]
//
// Empaqueta src/ en memoria, la sirve como volumen de arranque a componentes
// falsos y reproduce un guion de eventos. Es una prueba de humo: detecta
// errores de ejecución, no sustituye a probarlo en el juego.

const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const repoRoot = path.resolve(__dirname, "../..");
const srcRoot = path.join(repoRoot, "src");

function collect(dir, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) collect(full, out);
    else if (entry.name.endsWith(".lua")) out.push(full);
  }
}

const files = [];
collect(srcRoot, files);
files.sort();

const parts = ["return {"];
for (const file of files) {
  const virtual = "/" + path.relative(srcRoot, file).replace(/\\/g, "/");
  const content = fs.readFileSync(file, "utf8");
  let level = 3;
  while (content.includes("]" + "=".repeat(level) + "]")) level++;
  const open = "[" + "=".repeat(level) + "[";
  const close = "]" + "=".repeat(level) + "]";
  parts.push(`  [${JSON.stringify(virtual)}] = ${open}${content}${close},`);
}
parts.push("}");

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

if (lauxlib.luaL_loadstring(L, to_luastring(parts.join("\n"))) !== lua.LUA_OK) {
  console.error("No se pudo empaquetar src/: " + to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(2);
}
if (lua.lua_pcall(L, 0, 1, 0) !== lua.LUA_OK) {
  console.error("Fallo al construir el paquete: " + to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(2);
}
lua.lua_setglobal(L, to_luastring("BUNDLE"));

lua.lua_pushstring(L, to_luastring(process.argv[2] || "all"));
lua.lua_setglobal(L, to_luastring("SCENARIO"));

if (lauxlib.luaL_loadfile(L, to_luastring(path.join(__dirname, "harness.lua"))) !== lua.LUA_OK) {
  console.error("No se pudo cargar el arnés: " + to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(2);
}

if (lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
  console.error("Fallo del arnés: " + to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(2);
}
