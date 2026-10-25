// Harness core: bundle src/ and run the OS in a fresh Lua state.
//
// Fake components in harness.lua model the OpenComputers API. Strict mode also
// enables the harness contract checks.

const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const repoRoot = path.resolve(__dirname, "../..");
const srcRoot = path.join(repoRoot, "src");
const harnessPath = path.join(__dirname, "harness.lua");

function collect(dir, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) collect(full, out);
    else if (entry.name.endsWith(".lua")) out.push(full);
  }
}

function bundleSource() {
  const files = [];
  collect(srcRoot, files);
  files.sort();

  const parts = ["return {"];
  for (const file of files) {
    const virtual = "/" + path.relative(srcRoot, file).replace(/\\/g, "/");
    const content = fs.readFileSync(file, "utf8");
    let level = 3;
    while (content.includes("]" + "=".repeat(level) + "]")) level++;
    const open = "[" + "=".repeat(level) + "[";
    const close = "]" + "=".repeat(level) + "]";
    parts.push(`  [${JSON.stringify(virtual)}] = ${open}${content}${close},`);
  }
  parts.push("}");
  return parts.join("\n");
}

// Run a scenario and return the number of detected issues. Throw if the
// harness cannot load or crashes. `faultSet` rejects the first N GPU writes;
// `screen` sets the simulated screen's maximum resolution.
function runScenario(scenario, strict, faultSet, screen) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);

  if (lauxlib.luaL_loadstring(L, to_luastring(bundleSource())) !== lua.LUA_OK) {
    throw new Error("Could not bundle src/: " + to_jsstring(lua.lua_tostring(L, -1)));
  }
  if (lua.lua_pcall(L, 0, 1, 0) !== lua.LUA_OK) {
    throw new Error("Failed to build bundle: " + to_jsstring(lua.lua_tostring(L, -1)));
  }
  lua.lua_setglobal(L, to_luastring("BUNDLE"));

  lua.lua_pushstring(L, to_luastring(scenario));
  lua.lua_setglobal(L, to_luastring("SCENARIO"));

  lua.lua_pushboolean(L, strict ? 1 : 0);
  lua.lua_setglobal(L, to_luastring("STRICT"));

  if (faultSet > 0) {
    lua.lua_newtable(L);
    lua.lua_pushinteger(L, faultSet);
    lua.lua_setfield(L, -2, to_luastring("set"));
    lua.lua_setglobal(L, to_luastring("FAULT"));
  }

  if (screen && screen.width > 0 && screen.height > 0) {
    lua.lua_pushinteger(L, screen.width);
    lua.lua_setglobal(L, to_luastring("MAX_WIDTH"));
    lua.lua_pushinteger(L, screen.height);
    lua.lua_setglobal(L, to_luastring("MAX_HEIGHT"));
  }

  if (lauxlib.luaL_loadfile(L, to_luastring(harnessPath)) !== lua.LUA_OK) {
    throw new Error("Could not load harness: " + to_jsstring(lua.lua_tostring(L, -1)));
  }
  if (lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
    throw new Error("Harness failed: " + to_jsstring(lua.lua_tostring(L, -1)));
  }

  lua.lua_getglobal(L, to_luastring("TC_ERRORS"));
  const errors = lua.lua_isnumber(L, -1) ? lua.lua_tointeger(L, -1) : 1;
  lua.lua_settop(L, 0);
  return errors;
}

module.exports = { runScenario };
