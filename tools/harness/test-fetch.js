// Test tools/fetch.lua under simulated OpenOS. Each case runs in a clean Lua
// state and checks the in-game failure behavior.
//
//   node tools/harness/test-fetch.js

const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const repoRoot = path.resolve(__dirname, "../..");
// `--file=path` can target another version to ensure this gate catches regressions.
const fileArg = process.argv.find((arg) => arg.startsWith("--file="));
const fetchPath = fileArg
  ? path.resolve(repoRoot, fileArg.slice("--file=".length))
  : path.join(repoRoot, "tools/fetch.lua");
const fetchSource = fs.readFileSync(fetchPath, "utf8");
const testPath = path.join(__dirname, "fetch-test.lua");

const scenarios = ["ok", "404", "missing_file", "short_file", "disk_full", "no_card"];

function runScenario(scenario) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);

  lua.lua_pushstring(L, to_luastring(fetchSource));
  lua.lua_setglobal(L, to_luastring("FETCH_SRC"));

  if (lauxlib.luaL_loadfile(L, to_luastring(testPath)) !== lua.LUA_OK) {
    throw new Error("Could not load fetch-test.lua: " + to_jsstring(lua.lua_tostring(L, -1)));
  }

  lua.lua_pushstring(L, to_luastring(scenario));

  if (lua.lua_pcall(L, 1, 0, 0) !== lua.LUA_OK) {
    throw new Error(to_jsstring(lua.lua_tostring(L, -1)));
  }

  lua.lua_getglobal(L, to_luastring("FETCH_ERRORS"));
  const errors = lua.lua_isnumber(L, -1) ? lua.lua_tointeger(L, -1) : 1;
  lua.lua_settop(L, 0);
  return errors;
}

let failed = 0;
for (const scenario of scenarios) {
  try {
    const errors = runScenario(scenario);
    if (errors !== 0) {
      failed++;
      console.error("FAIL " + scenario + ": " + errors + " problem(s)");
    } else {
      console.log("ok " + scenario);
    }
  } catch (error) {
    failed++;
    console.error("FAIL " + scenario + ": " + error.message);
  }
}

console.log(scenarios.length + " downloader scenarios, " + failed + " failures");
process.exit(failed ? 1 : 0);
