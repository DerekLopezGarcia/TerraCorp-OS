// Test src/apps/gaia.lua without opening it in the harness.
//
//   node tools/harness/test-gaia.js
//
// The app is a window: this drives draw, touch, and key handling with a
// recording view so a broken hit box or a nil field fails here.

const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const repoRoot = path.resolve(__dirname, "../..");
const sources = {
  KEYS_SOURCE: "src/lib/tc/keys.lua",
  TEXT_SOURCE: "src/lib/tc/text.lua",
  GAIA_SOURCE: "src/apps/gaia.lua",
};
const testPath = path.join(__dirname, "gaia-test.lua");

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

for (const [name, file] of Object.entries(sources)) {
  lua.lua_pushstring(L, to_luastring(fs.readFileSync(path.join(repoRoot, file), "utf8")));
  lua.lua_setglobal(L, to_luastring(name));
}

if (lauxlib.luaL_loadfile(L, to_luastring(testPath)) !== lua.LUA_OK) {
  console.error("Could not load gaia-test.lua: " + to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(2);
}
if (lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
  console.error(to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(2);
}

lua.lua_getglobal(L, to_luastring("GAIA_ERRORS"));
const errors = lua.lua_isnumber(L, -1) ? lua.lua_tointeger(L, -1) : 1;

console.log(errors === 0 ? "ok gaia" : "FAIL gaia: " + errors + " problem(s)");
process.exit(errors === 0 ? 0 : 1);
