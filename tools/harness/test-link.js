// Test src/lib/tc/link.lua against a fake Internet Card.
//
//   node tools/harness/test-link.js
//
// Each scenario runs in a clean Lua state; link-test.lua drives the state
// machine by hand and returns the number of failed checks.

const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const repoRoot = path.resolve(__dirname, "../..");
const netSource = fs.readFileSync(path.join(repoRoot, "src/lib/tc/net.lua"), "utf8");
const linkSource = fs.readFileSync(path.join(repoRoot, "src/lib/tc/link.lua"), "utf8");
const testPath = path.join(__dirname, "link-test.lua");

const scenarios = [
  "disabled",
  "no_card",
  "status",
  "log",
  "app_open",
  "bad_token",
  "unknown_cmd",
  "garbage",
  "fs_list",
  "check",
  "write_refused",
  "write_ok",
  "boot_guard",
  "boot_full",
  "app_close",
  "reboot",
];

function runScenario(scenario) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);

  lua.lua_pushstring(L, to_luastring(netSource));
  lua.lua_setglobal(L, to_luastring("NET_SOURCE"));
  lua.lua_pushstring(L, to_luastring(linkSource));
  lua.lua_setglobal(L, to_luastring("LINK_SOURCE"));

  if (lauxlib.luaL_loadfile(L, to_luastring(testPath)) !== lua.LUA_OK) {
    throw new Error("Could not load link-test.lua: " + to_jsstring(lua.lua_tostring(L, -1)));
  }

  lua.lua_pushstring(L, to_luastring(scenario));

  if (lua.lua_pcall(L, 1, 0, 0) !== lua.LUA_OK) {
    throw new Error(to_jsstring(lua.lua_tostring(L, -1)));
  }

  lua.lua_getglobal(L, to_luastring("LINK_ERRORS"));
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

console.log(scenarios.length + " link scenarios, " + failed + " failures");
process.exit(failed ? 1 : 0);
