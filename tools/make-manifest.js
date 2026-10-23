// Genera tools/manifest.txt: la lista de ficheros que tools/fetch.lua copia al
// ordenador de OpenComputers. `npm run check` falla si el manifiesto se queda
// desfasado respecto al árbol real.
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

// src/** y eeprom/**, más los .lua de primer nivel de tools/ (el arnés no
// se copia: necesita Node y no hace falta dentro del juego).
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
  console.log(entries.length + " ficheros en tools/manifest.txt");
}
