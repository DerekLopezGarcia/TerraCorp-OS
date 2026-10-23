// Núcleo del arnés: empaqueta src/ y ejecuta el OS en un estado Lua nuevo.
//
// Los componentes falsos de harness.lua imitan la API real de OpenComputers
// (`list` devuelve tabla, `spaceUsed`/`spaceTotal` en bytes). Con `strict` se
// activan además las comprobaciones de contrato del propio arnés.

const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const repoRoot = path.resolve(__dirname, "../..");
const srcRoot = path.join(repoRoot, "src");
const harnessPath = path.join(__dirname, "harness.lua");

function collect(dir, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) collect(full, out);
    else if (entry.name.endsWith(".lua")) out.push(full);
  }
}

function bundleSource() {
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
  return parts.join("\n");
}

// Ejecuta un escenario y devuelve el número de problemas detectados.
// Lanza si el arnés no se puede cargar o revienta.
function runScenario(scenario, strict) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);

  if (lauxlib.luaL_loadstring(L, to_luastring(bundleSource())) !== lua.LUA_OK) {
    throw new Error("No se pudo empaquetar src/: " + to_jsstring(lua.lua_tostring(L, -1)));
  }
  if (lua.lua_pcall(L, 0, 1, 0) !== lua.LUA_OK) {
    throw new Error("Fallo al construir el paquete: " + to_jsstring(lua.lua_tostring(L, -1)));
  }
  lua.lua_setglobal(L, to_luastring("BUNDLE"));

  lua.lua_pushstring(L, to_luastring(scenario));
  lua.lua_setglobal(L, to_luastring("SCENARIO"));

  lua.lua_pushboolean(L, strict ? 1 : 0);
  lua.lua_setglobal(L, to_luastring("STRICT"));

  if (lauxlib.luaL_loadfile(L, to_luastring(harnessPath)) !== lua.LUA_OK) {
    throw new Error("No se pudo cargar el arnés: " + to_jsstring(lua.lua_tostring(L, -1)));
  }
  if (lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
    throw new Error("Fallo del arnés: " + to_jsstring(lua.lua_tostring(L, -1)));
  }

  lua.lua_getglobal(L, to_luastring("TC_ERRORS"));
  const errors = lua.lua_isnumber(L, -1) ? lua.lua_tointeger(L, -1) : 1;
  lua.lua_settop(L, 0);
  return errors;
}

module.exports = { runScenario };
