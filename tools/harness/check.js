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

console.log(files.length + " files checked, " + errors + " errors");
console.log("manifest: " + (manifest ? manifest.length : "missing") + " files");
process.exit(errors ? 1 : 0);
