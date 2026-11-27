// Test M0 DNS1: frames, value codec, transport, HELLO, DESCRIBE, catalog, EXEC.
//
//   node tools/harness/test-dns.js

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

const testPath = path.join(__dirname, "dns-test.lua");
if (lauxlib.luaL_loadfile(L, to_luastring(testPath)) !== lua.LUA_OK) {
  console.error("FAIL could not load dns-test.lua: " + to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(1);
}

if (lua.lua_pcall(L, 0, 1, 0) !== lua.LUA_OK) {
  console.error("FAIL dns tests crashed: " + to_jsstring(lua.lua_tostring(L, -1) || ""));
  process.exit(1);
}

const result = to_jsstring(lua.lua_tostring(L, -1) || "");
lua.lua_settop(L, 0);

if (result !== "" && result.indexOf("dns: ") === 0) {
  console.log("PASS " + result);
  process.exit(0);
}

for (const line of result.split("\n").filter(Boolean)) {
  console.error("FAIL " + line);
}
const count = result.split("\n").filter(Boolean).length;
console.log("dns: " + count + " failure(s)");
process.exit(1);
