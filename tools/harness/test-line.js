// Test src/lib/tc/line.lua against the casing fixture and malformed input.
//
//   node tools/harness/test-line.js

const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const repoRoot = path.resolve(__dirname, "../..");
const lineSource = fs.readFileSync(path.join(repoRoot, "src/lib/tc/line.lua"), "utf8");
const casing = fs.readFileSync(path.join(__dirname, "fixtures/casing.line"), "utf8");
const testPath = path.join(__dirname, "line-test.lua");

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

lua.lua_pushstring(L, to_luastring(lineSource));
lua.lua_setglobal(L, to_luastring("LINE_SOURCE"));
lua.lua_pushstring(L, to_luastring(casing));
lua.lua_setglobal(L, to_luastring("CASING_LINE"));

if (lauxlib.luaL_loadfile(L, to_luastring(testPath)) !== lua.LUA_OK) {
  throw new Error("Could not load line-test.lua: " + to_jsstring(lua.lua_tostring(L, -1)));
}

if (lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
  throw new Error(to_jsstring(lua.lua_tostring(L, -1)));
}

lua.lua_getglobal(L, to_luastring("LINE_ERRORS"));
const errors = lua.lua_isnumber(L, -1) ? lua.lua_tointeger(L, -1) : 1;
lua.lua_settop(L, 0);

if (errors !== 0) {
  console.error("FAIL line parser: " + errors + " problem(s)");
  process.exit(1);
}
console.log("ok line parser");
