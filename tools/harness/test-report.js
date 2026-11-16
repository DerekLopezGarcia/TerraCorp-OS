// Test tc.report: the line node's status publisher, its cadence and its page.
//
//   node tools/harness/test-report.js

const path = require("path");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const repoRoot = path.resolve(__dirname, "../..");
const lib = path.join(repoRoot, "src", "lib").replace(/\\/g, "/");
const src = path.join(repoRoot, "src").replace(/\\/g, "/");
const packagePath = lib + "/?.lua;" + src + "/?.lua";

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const prelude = "package.path = " + JSON.stringify(packagePath) + ";";
if (lauxlib.luaL_dostring(L, to_luastring(prelude)) !== lua.LUA_OK) {
  console.error("FAIL could not configure package.path: " + to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(1);
}

const testPath = path.join(__dirname, "report-test.lua");
if (lauxlib.luaL_loadfile(L, to_luastring(testPath)) !== lua.LUA_OK) {
  console.error("FAIL could not load report-test.lua: " + to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(1);
}

if (lua.lua_pcall(L, 0, 1, 0) !== lua.LUA_OK) {
  console.error("FAIL report tests crashed: " + to_jsstring(lua.lua_tostring(L, -1) || ""));
  process.exit(1);
}

const failures = to_jsstring(lua.lua_tostring(L, -1) || "");
lua.lua_settop(L, 0);

if (failures !== "") {
  for (const line of failures.split("\n")) {
    console.error("FAIL " + line);
  }
  const count = failures.split("\n").filter(Boolean).length;
  console.log("report: " + count + " failure(s)");
  process.exit(1);
}

console.log("report: names, status frames, cadence, backoff and the page passed");
