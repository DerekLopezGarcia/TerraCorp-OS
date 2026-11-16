// Test the line node installer: tc.installer and boot/install.lua against
// in-memory filesystem components.
//
//   node tools/harness/test-installer.js

const path = require("path");
const fs = require("fs");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const repoRoot = path.resolve(__dirname, "../..");
const lib = path.join(repoRoot, "src", "lib").replace(/\\/g, "/");
const src = path.join(repoRoot, "src").replace(/\\/g, "/");
const packagePath = lib + "/?.lua;" + src + "/?.lua";

// Fengari has no usable `io`; the modules the entry loads are injected like the
// other harness tests inject their file trees.
function sourceOf(relative) {
  return fs.readFileSync(path.join(repoRoot, relative), "utf8");
}
const entrySource = sourceOf("src/boot/install.lua");

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const prelude =
  "package.path = " + JSON.stringify(packagePath) + ";" +
  "_REPO = " + JSON.stringify(repoRoot.replace(/\\/g, "/")) + ";" +
  "_INSTALL_SOURCE = " + JSON.stringify(entrySource) + ";" +
  "_SRC_VFS = " + JSON.stringify(sourceOf("src/lib/tc/vfs.lua")) + ";" +
  "_SRC_INSTALLER = " + JSON.stringify(sourceOf("src/lib/tc/installer.lua")) + ";" +
  "_SRC_VERSION = " + JSON.stringify(sourceOf("src/lib/tc/version.lua")) + ";";
if (lauxlib.luaL_dostring(L, to_luastring(prelude)) !== lua.LUA_OK) {
  console.error("FAIL could not configure the Lua state: " + to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(1);
}

const testPath = path.join(__dirname, "installer-test.lua");
if (lauxlib.luaL_loadfile(L, to_luastring(testPath)) !== lua.LUA_OK) {
  console.error("FAIL could not load installer-test.lua: " + to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(1);
}

if (lua.lua_pcall(L, 0, 1, 0) !== lua.LUA_OK) {
  console.error("FAIL installer tests crashed: " + to_jsstring(lua.lua_tostring(L, -1) || ""));
  process.exit(1);
}

const failures = to_jsstring(lua.lua_tostring(L, -1) || "");
lua.lua_settop(L, 0);

if (failures !== "") {
  for (const line of failures.split("\n")) {
    console.error("FAIL " + line);
  }
  const count = failures.split("\n").filter(Boolean).length;
  console.log("installer: " + count + " failure(s)");
  process.exit(1);
}

console.log("installer: the image installs, refuses, resumes and never writes the floppy");
