// Test eeprom/init.lua in the OpenComputers 1.7.x and 1.8+ sandboxes.
//
//   node tools/harness/test-boot.js

const path = require("path");
const fs = require("fs");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const repoRoot = path.resolve(__dirname, "../..");
const source = fs.readFileSync(path.join(repoRoot, "eeprom/init.lua"), "utf8");
const scenarios = ["175", "18"];

function runScenario(scenario) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);

  lua.lua_pushstring(L, to_luastring(source));
  lua.lua_setglobal(L, to_luastring("EEPROM_SOURCE"));

  if (lauxlib.luaL_loadfile(L, to_luastring(path.join(__dirname, "eeprom-test.lua"))) !== lua.LUA_OK) {
    throw new Error("Could not load eeprom-test.lua: " + to_jsstring(lua.lua_tostring(L, -1)));
  }

  lua.lua_pushstring(L, to_luastring(scenario));

  if (lua.lua_pcall(L, 1, 0, 0) !== lua.LUA_OK) {
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

console.log(scenarios.length + " boot scenarios, " + failed + " failures");
process.exit(failed ? 1 : 0);
