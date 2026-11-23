// Documentation gate.
//
// Every count a document quotes has to equal what the command behind it prints.
// The requirement that produced docs/canonical.md found 75 contradictions; most
// were quoted numbers, and the reason they drifted is that nothing failed when
// they did. This gate is that failure.
//
// It measures the numbers by running the real gates, then reads every Markdown
// file in docs/ plus README.md and AGENTS.md and compares each claim it finds.
// A claim is a narrow pattern, so a document that says nothing about a number is
// not a failure — a document that says the wrong thing is.
//
//   npm run test:docs

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const root = path.join(__dirname, "..", "..");

function run(script) {
  return execFileSync(process.execPath, [path.join(root, "tools", "harness", script)], {
    cwd: root,
    encoding: "utf8",
  });
}

function pick(text, re, what) {
  const m = text.match(re);
  if (!m) {
    console.error("FAIL the " + what + " gate printed no number to compare against");
    process.exit(1);
  }
  return Number(m[1]);
}

const checkOut = run("check.js");
const sizeOut = run("size.js");
const linkOut = run("test-link.js");

const manifest = pick(checkOut, /manifest:\s*(\d+) files/, "check (manifest)");
const checked = pick(checkOut, /(\d+) files checked/, "check");
const payload = (sizeOut.match(/(\d+) files, ([\d.]+) KB of/) || []);
if (!payload[1]) {
  console.error("FAIL the size gate printed no \"N files, X KB\" line to compare against");
  process.exit(1);
}
const payloadFiles = Number(payload[1]);
const payloadKB = Number(payload[2]);
const scenarios = pick(linkOut, /(\d+) link scenarios/, "test:link");

// The app list is source, not documentation: kernel.lua is what the desktop shows.
const kernel = fs.readFileSync(path.join(root, "src", "boot", "kernel.lua"), "utf8");
const appIds = (kernel.match(/^local APP_IDS = \{([^}]*)\}/m) || [])[1];
if (!appIds) {
  console.error("FAIL kernel.lua no longer declares APP_IDS; update this gate, not the docs");
  process.exit(1);
}
const apps = (appIds.match(/"[^"]+"/g) || []).map((s) => s.replace(/"/g, ""));

// A claim: a document pattern whose captured number must equal `want`. `float`
// compares to a tenth of a kilobyte instead of exactly.
const claims = [
  { re: /manifest:?\s*(\d+)\s*files/gi, want: manifest, what: "manifest file count" },
  { re: /\bmanifest (?:is|of|has) (\d+) files/gi, want: manifest, what: "manifest file count" },
  { re: /(\d+)[- ]file manifest/gi, want: manifest, what: "manifest file count" },
  { re: /(\d+) files checked/gi, want: checked, what: "check file count" },
  { re: /check`?[^\n]{0,40}?\((\d+) files/gi, want: checked, what: "check file count" },
  { re: /(\d+) link scenarios/gi, want: scenarios, what: "link scenario count" },
  { re: /test:link`? \(?(\d+) (?:link )?scenarios/gi, want: scenarios, what: "link scenario count" },
  { re: /installer image (?:is|at) ([\d.]+) KB/gi, want: payloadKB, what: "installer size", float: true },
];

// "22 files, 163.3 KB" is two numbers in one sentence; check them together.
const sizeClaim = /(\d+) files?, ([\d.]+) KB/g;

// Retired vocabulary. Present is fine when the line says so — a banner is how
// this project retires a feature — but present as live documentation is a fail.
const retired = [
  { word: "halls.tsv", why: "decision 26 removed the hall registry" },
  { word: "test:cluster", why: "the rack cluster was removed; the script never existed" },
  { word: "netboot.lua", why: "netboot was removed with the rack cluster" },
  { word: "linkTransport", why: "config.lua has never had that key" },
  { word: "others=", why: "the status frame overflow key is more=<n>" },
  { word: "MAX_STOCKS = 10", why: "report.lua caps at 8 (s1..s8)" },
];
const retirement = /removed|dropped|retired|historical|no longer|never|deleted|banner|not built|absent|gone|superseded|planned|no such|does not exist|used to|is no\b|\(\d{4}-\d{2}-\d{2}|\bdid\b/i;

// The roadmap, the finding ledger and the deferred designs exist to discuss
// removed, deferred and planned things — that is their job. The documents that
// state what the system *is* are held to the rule, because there a retired name
// reads as a current feature.
const ledger = new Set([
  "docs/canonical.md",
  "docs/roadmap.md",
  "docs/plant-service.md",
  "docs/bus.md",
  "docs/sidecar.md",
]);

// Only documents are checked; source comments quote history on purpose.
const docs = ["README.md", "AGENTS.md"].concat(
  fs.readdirSync(path.join(root, "docs")).filter((f) => f.endsWith(".md")).map((f) => "docs/" + f)
);

const failures = [];

for (const rel of docs) {
  const text = fs.readFileSync(path.join(root, rel), "utf8");
  const lines = text.split(/\r?\n/);

  for (const claim of claims) {
    for (const m of text.matchAll(claim.re)) {
      const got = Number(m[1]);
      const ok = claim.float ? Math.abs(got - claim.want) < 0.05 : got === claim.want;
      if (!ok) {
        const prints = claim.float ? claim.want.toFixed(1) : claim.want;
        failures.push(rel + ": says " + m[0].trim() + " — the command prints " + prints);
      }
    }
  }

  for (const m of text.matchAll(sizeClaim)) {
    if (Number(m[1]) !== payloadFiles || Number(m[2]) !== payloadKB) {
      failures.push(
        rel + ": says " + m[0].trim() + " — the size gate prints " + payloadFiles +
        " files, " + payloadKB.toFixed(1) + " KB"
      );
    }
  }

  if (!ledger.has(rel)) {
    for (const item of retired) {
      lines.forEach((line, i) => {
        const at = line.indexOf(item.word);
        if (at < 0) return;
        if (retirement.test(line)) return;
        // "no `off=` continuation", "no separate halls.tsv": a negation states absence.
        if (/\bno\b/i.test(line.slice(Math.max(0, at - 30), at))) return;
        // A release-history row ("| 0.4.3 | … |") records what that version did.
        if (/^\|\s*0\.\d/.test(line)) return;
        failures.push(rel + ":" + (i + 1) + ": mentions " + item.word + " as if it were current (" + item.why + ")");
      });
    }
  }

  // Every document that lists app ids must list the ones the kernel ships.
  const listed = /vault|\blines\b/.test(text);
  if (listed) {
    if (/\bvault\b/i.test(text) && !retirement.test(text)) {
      failures.push(rel + ": names the Vault as current; it was removed in 0.4.9");
    }
    const says = text.match(/\b(eleven|ten|11|10)\s+apps\b/i);
    if (says) {
      const n = /eleven|^11$/i.test(says[1]) ? 11 : 10;
      if (n !== apps.length) {
        failures.push(rel + ": says " + says[0] + " — kernel.lua lists " + apps.length);
      }
    }
  }
}

if (failures.length > 0) {
  console.error("docs: " + failures.length + " claim(s) disagree with the tree\n");
  for (const f of failures) console.error("  " + f);
  process.exit(1);
}

console.log(
  "docs: " + docs.length + " documents agree with the tree (manifest " + manifest +
  ", check " + checked + ", payload " + payloadKB.toFixed(1) + " KB, link " +
  scenarios + " scenarios, " + apps.length + " apps)"
);
