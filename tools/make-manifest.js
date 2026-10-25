// Generate tools/manifest.txt, the file list copied by tools/fetch.lua to the
// OpenComputers computer. `npm run check` fails if it differs from the source tree.
//
//   npm run manifest

const fs = require("fs");
const path = require("path");

const repoRoot = path.resolve(__dirname, "..");

function walk(dir, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, out);
    else if (entry.name.endsWith(".lua")) out.push(full);
  }
}

// Include src/**, eeprom/**, and top-level tools/*.lua. The harness is not copied:
// it requires Node.js and is not needed in-game.
function list() {
  const files = [];
  walk(path.join(repoRoot, "src"), files);
  walk(path.join(repoRoot, "eeprom"), files);

  const toolsDir = path.join(repoRoot, "tools");
  for (const entry of fs.readdirSync(toolsDir, { withFileTypes: true })) {
    if (entry.isFile() && entry.name.endsWith(".lua")) {
      files.push(path.join(toolsDir, entry.name));
    }
  }

  return files
    .map((full) => path.relative(repoRoot, full).split(path.sep).join("/"))
    .sort();
}

module.exports = { list };

if (require.main === module) {
  const target = path.join(repoRoot, "tools", "manifest.txt");
  const entries = list();
  fs.writeFileSync(target, entries.join("\n") + "\n");
  console.log(entries.length + " files in tools/manifest.txt");
}
