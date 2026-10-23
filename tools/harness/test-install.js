// Prueba tools/install.lua con OpenOS simulado: detección de volumen, selección
// y copia. Cada escenario corre en un estado Lua limpio.
//
//   node tools/harness/test-install.js

const path = require("path");
const fs = require("fs");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const repoRoot = path.resolve(__dirname, "../..");
const scenarios = ["floppy", "varios", "varios_yes", "datos", "explicito", "pequeno", "list"];

const sources = {
  "src/init.lua": fs.readFileSync(path.join(repoRoot, "src/init.lua"), "utf8"),
  "src/boot/kernel.lua": fs.readFileSync(path.join(repoRoot, "src/boot/kernel.lua"), "utf8"),
  "eeprom/init.lua": fs.readFileSync(path.join(repoRoot, "eeprom/init.lua"), "utf8"),
};

function runScenario(scenario) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);

  // FILES = { ["src/init.lua"] = contenido, ... } (árbol de origen)
  lua.lua_newtable(L);
  for (const rel of Object.keys(sources)) {
    lua.lua_pushstring(L, to_luastring(rel));
    lua.lua_pushstring(L, to_luastring(sources[rel]));
    lua.lua_rawset(L, -3);
  }
  lua.lua_setglobal(L, to_luastring("FILES"));

  const testPath = path.join(__dirname, "install-test.lua");
  if (lauxlib.luaL_loadfile(L, to_luastring(testPath)) !== lua.LUA_OK) {
    throw new Error("no se pudo cargar install-test.lua: " + to_jsstring(lua.lua_tostring(L, -1)));
  }

  lua.lua_pushstring(L, to_luastring(repoRoot));
  lua.lua_pushstring(L, to_luastring(scenario));

  if (lua.lua_pcall(L, 2, 0, 0) !== lua.LUA_OK) {
    throw new Error(to_jsstring(lua.lua_tostring(L, -1)));
  }
}

let failed = 0;
for (const scenario of scenarios) {
  try {
    runScenario(scenario);
  } catch (error) {
    failed++;
    console.error("FALLO " + scenario + ": " + error.message);
  }
}

console.log(scenarios.length + " escenarios del instalador, " + failed + " errores");
process.exit(failed ? 1 : 0);
