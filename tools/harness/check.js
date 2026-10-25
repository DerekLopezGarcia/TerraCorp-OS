// Check that all Lua files compile with Lua 5.3 (Fengari) and that
// tools/manifest.txt matches the source tree. This checks syntax only.

const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");
const { list } = require("../make-manifest");

const repoRoot = path.resolve(__dirname, "../..");
const targets = ["src", "eeprom", "tools"];

const files = [];
function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === "node_modules" || entry.name === ".git") continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (entry.name.endsWith(".lua")) files.push(full);
  }
}

for (const target of targets) {
  const full = path.join(repoRoot, target);
  if (fs.existsSync(full)) walk(full);
}
files.sort();

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

let errors = 0;
// Detect UTF-8 misread as CP1252 and written back, which corrupts text. A BOM
// at the start of a file also breaks `load`.
const MOJIBAKE = /Ã[\u0080-\u00BF]|Â[\u0080-\u00BF]/;

for (const file of files) {
  const source = fs.readFileSync(file, "utf8");

  if (source.charCodeAt(0) === 0xfeff) {
    errors++;
    console.error("ERROR " + path.relative(repoRoot, file));
    console.error("      starts with a BOM: OpenComputers `load` rejects it");
  }

  const mojibake = source.match(MOJIBAKE);
  if (mojibake) {
    errors++;
    console.error("ERROR " + path.relative(repoRoot, file));
    console.error("      duplicated encoding near " + JSON.stringify(mojibake[0]));
  }

  const status = lauxlib.luaL_loadstring(L, to_luastring(source));
  if (status !== lua.LUA_OK) {
    errors++;
    console.error("ERROR " + path.relative(repoRoot, file));
    console.error("      " + to_jsstring(lua.lua_tostring(L, -1)));
  }
  lua.lua_settop(L, 0);
}

// tools/fetch.lua downloads the manifest in-game. A mismatch can leave an
// incomplete installation.
const manifestPath = path.join(repoRoot, "tools", "manifest.txt");
const expected = list();
let manifest = null;

try {
  manifest = fs.readFileSync(manifestPath, "utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
} catch (error) {
  errors++;
  console.error("MISSING tools/manifest.txt (run: npm run manifest)");
}

if (manifest) {
  for (const file of expected) {
    if (!manifest.includes(file)) {
      errors++;
      console.error("MISSING FROM MANIFEST " + file + " (run: npm run manifest)");
    }
  }
  for (const file of manifest) {
    if (!expected.includes(file)) {
      errors++;
      console.error("IN MANIFEST BUT NOT IN TREE " + file);
    }
  }
}

// Every app must ship a desktop icon: a 3-cell code for compact tiles and a
// 9x5 `iconArt` pictogram. AGENTS.md states this rule; enforce it here so an
// app cannot ship without a visible desktop icon.
const appsDir = path.join(repoRoot, "src", "apps");
const appFiles = fs.existsSync(appsDir)
  ? fs.readdirSync(appsDir)
    .filter((name) => name.endsWith(".lua"))
    .map((name) => name.slice(0, -4))
    .sort()
  : [];
const kernelSource = fs.readFileSync(path.join(repoRoot, "src", "boot", "kernel.lua"), "utf8");
const idsMatch = kernelSource.match(/APP_IDS\s*=\s*\{([\s\S]*?)\}/);
const registered = idsMatch ? [...idsMatch[1].matchAll(/"([^"]+)"/g)].map((match) => match[1]) : [];

if (!idsMatch) {
  errors++;
  console.error("ERROR src/boot/kernel.lua");
  console.error("      APP_IDS table not found");
}
for (const id of registered) {
  if (!appFiles.includes(id)) {
    errors++;
    console.error("ERROR src/apps/" + id + ".lua");
    console.error("      registered in APP_IDS but the app file is missing");
  }
}
for (const id of appFiles) {
  if (!registered.includes(id)) {
    errors++;
    console.error("ERROR src/apps/" + id + ".lua");
    console.error("      app is not registered in APP_IDS (src/boot/kernel.lua)");
  }
}

const appIds = [...new Set([...registered, ...appFiles])];
const libPath = path.join(repoRoot, "src", "lib").replace(/\\/g, "/");
const srcPath = path.join(repoRoot, "src").replace(/\\/g, "/");
const idsLua = appIds.map((id) => JSON.stringify(id)).join(", ");
const modulePath = JSON.stringify(libPath + "/?.lua;" + srcPath + "/?.lua");
const appScript = `
package.path = ${modulePath}
local text = require("tc.text")
local ids = { ${idsLua} }
local failures = {}
local function fail(message) failures[#failures + 1] = message end
for _, id in ipairs(ids) do
  local ok, app = pcall(require, "apps." .. id)
  if not ok or type(app) ~= "table" then
    fail("src/apps/" .. id .. ".lua: could not load (" .. tostring(app) .. ")")
  else
    if app.id ~= id then
      fail("src/apps/" .. id .. ".lua: id is " .. tostring(app.id))
    end
    if type(app.icon) ~= "string" or text.width(app.icon) ~= 3 then
      fail("src/apps/" .. id .. ".lua: icon must be a 3-cell code")
    end
    if type(app.short) ~= "string" or app.short == "" then
      fail("src/apps/" .. id .. ".lua: short label is required")
    end
    if app.iconStyle ~= nil and app.iconStyle ~= "accent" then
      fail("src/apps/" .. id .. ".lua: unknown iconStyle " .. tostring(app.iconStyle))
    end
    if type(app.iconArt) ~= "table" or #app.iconArt ~= 5 then
      fail("src/apps/" .. id .. ".lua: iconArt must contain 5 rows")
    else
      for row = 1, 5 do
        if type(app.iconArt[row]) ~= "string" or text.width(app.iconArt[row]) ~= 9 then
          fail("src/apps/" .. id .. ".lua: iconArt row " .. row .. " must be 9 cells")
        end
      end
    end
  end
end
return table.concat(failures, "\\n")
`;
const appStatus = lauxlib.luaL_dostring(L, to_luastring(appScript));
if (appStatus !== lua.LUA_OK) {
  errors++;
  console.error("ERROR app icon check failed to run: " + to_jsstring(lua.lua_tostring(L, -1) || ""));
} else {
  const appFailures = to_jsstring(lua.lua_tostring(L, -1) || "");
  if (appFailures !== "") {
    for (const line of appFailures.split("\n")) {
      errors++;
      console.error("ERROR " + line);
    }
  }
}
lua.lua_settop(L, 0);

console.log(files.length + " files checked, " + errors + " errors");
console.log("manifest: " + (manifest ? manifest.length : "missing") + " files");
process.exit(errors ? 1 : 0);
