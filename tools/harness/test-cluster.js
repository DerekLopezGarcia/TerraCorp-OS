// Test the 0.3.0 cluster foundation: tc.net frames/transport and the
// /var/nodes.tsv registry. Pure Lua modules are loaded with Fengari.
//
//   node tools/harness/test-cluster.js

const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const repoRoot = path.resolve(__dirname, "../..");
const lib = path.join(repoRoot, "src", "lib").replace(/\\/g, "/");
const src = path.join(repoRoot, "src").replace(/\\/g, "/");
const packagePath = lib + "/?.lua;" + src + "/?.lua";

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const prelude =
  "package.path = " + JSON.stringify(packagePath) +
  "; REPO_ROOT = " + JSON.stringify(repoRoot.replace(/\\/g, "/"));
if (lauxlib.luaL_dostring(L, to_luastring(prelude)) !== lua.LUA_OK) {
  console.error("FAIL could not configure package.path: " + to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(1);
}

// Fengari has no io.open, so hand the tests the real source files as strings.
// They are copied into the fake volumes used by the provision/netboot tests.
const sources = {};
for (const relative of [
  "src/boot/netboot.lua",
  "src/lib/tc/vfs.lua",
  "src/lib/tc/provision.lua",
  "src/lib/tc/net.lua",
]) {
  sources[relative] = fs.readFileSync(path.join(repoRoot, relative), "utf8");
}
lua.lua_newtable(L);
for (const [name, data] of Object.entries(sources)) {
  lua.lua_pushstring(L, to_luastring(data));
  lua.lua_setfield(L, -2, to_luastring(name));
}
lua.lua_setglobal(L, to_luastring("SOURCES"));

const testPath = path.join(__dirname, "cluster-test.lua");
if (lauxlib.luaL_loadfile(L, to_luastring(testPath)) !== lua.LUA_OK) {
  console.error("FAIL could not load cluster-test.lua: " + to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(1);
}

if (lua.lua_pcall(L, 0, 1, 0) !== lua.LUA_OK) {
  console.error("FAIL cluster tests crashed: " + to_jsstring(lua.lua_tostring(L, -1) || ""));
  process.exit(1);
}

const failures = to_jsstring(lua.lua_tostring(L, -1) || "");
lua.lua_settop(L, 0);

if (failures !== "") {
  for (const line of failures.split("\n")) {
    console.error("FAIL " + line);
  }
  const count = failures.split("\n").filter(Boolean).length;
  console.log("cluster: " + count + " failure(s)");
  process.exit(1);
}

console.log("cluster: framing, transport, and registry tests passed");
