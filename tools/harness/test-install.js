// Test tools/install.lua under simulated OpenOS: volume detection, selection,
// and copying. Each scenario runs in a clean Lua state.
//
//   node tools/harness/test-install.js

const path = require("path");
const fs = require("fs");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const repoRoot = path.resolve(__dirname, "../..");
const scenarios = ["floppy", "multiple", "multiple_yes", "data_disk", "explicit", "small_disk", "list"];

const sources = {
  "src/init.lua": fs.readFileSync(path.join(repoRoot, "src/init.lua"), "utf8"),
  "src/boot/kernel.lua": fs.readFileSync(path.join(repoRoot, "src/boot/kernel.lua"), "utf8"),
  "eeprom/init.lua": fs.readFileSync(path.join(repoRoot, "eeprom/init.lua"), "utf8"),
};

function runScenario(scenario) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);

  // FILES = { ["src/init.lua"] = content, ... } (source tree)
  lua.lua_newtable(L);
  for (const rel of Object.keys(sources)) {
    lua.lua_pushstring(L, to_luastring(rel));
    lua.lua_pushstring(L, to_luastring(sources[rel]));
    lua.lua_rawset(L, -3);
  }
  lua.lua_setglobal(L, to_luastring("FILES"));

  const testPath = path.join(__dirname, "install-test.lua");
  if (lauxlib.luaL_loadfile(L, to_luastring(testPath)) !== lua.LUA_OK) {
    throw new Error("Could not load install-test.lua: " + to_jsstring(lua.lua_tostring(L, -1)));
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
    console.error("FAIL " + scenario + ": " + error.message);
  }
}

console.log(scenarios.length + " installer scenarios, " + failed + " failures");
process.exit(failed ? 1 : 0);
