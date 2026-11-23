// Test the External Link bridge mirror and the plant body parser.
//
//   node tools/harness/test-bridge.js
//
// The bridge is a plain Node HTTP server, so the test starts it on a free port
// and speaks the same frames the OS posts back. It proves three things the OS
// side cannot: a paged body is reassembled, a plant body is parsed, and only a
// complete plant-shaped body replaces the mirrored reply.

"use strict";

const assert = require("assert");
const { spawn } = require("child_process");
const net = require("net");
const path = require("path");

const repoRoot = path.resolve(__dirname, "../..");
const bridgePath = path.join(repoRoot, "tools", "bridge", "bridge.js");
const TOKEN = "bridge-test-token";

const ESCAPES = {
  "%": "%25",
  " ": "%20",
  "\t": "%09",
  "\r": "%0D",
  "\n": "%0A",
  "=": "%3D",
};

function escapeValue(value) {
  return String(value).replace(/[% \t\r\n=]/g, (character) => ESCAPES[character]);
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

function startBridge(port) {
  const child = spawn(process.execPath, [bridgePath, "--port", String(port), "--token", TOKEN], {
    cwd: repoRoot,
    stdio: ["ignore", "pipe", "pipe"],
  });

  return new Promise((resolve, reject) => {
    let output = "";
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error("bridge did not start: " + output));
    }, 8000);

    const onData = (chunk) => {
      output += chunk.toString("utf8");
      if (output.includes("listening on")) {
        clearTimeout(timer);
        resolve(child);
      }
    };
    child.stdout.on("data", onData);
    child.stderr.on("data", onData);
    child.on("exit", (code) => {
      clearTimeout(timer);
      reject(new Error("bridge exited with " + code + ": " + output));
    });
  });
}

async function request(base, method, route, body) {
  const headers = { "X-Link-Token": TOKEN };
  if (body !== undefined) headers["Content-Type"] = "text/plain; charset=utf-8";
  const response = await fetch(base + route, { method, headers, body });
  const text = await response.text();
  if (!response.ok) throw new Error(method + " " + route + " -> " + response.status + ": " + text);
  return text;
}

function linkFrame(id, cmd) {
  return "TC1 LINK id=" + id + " token=" + escapeValue(TOKEN) + " cmd=" + cmd;
}

function resultFrames(id, body) {
  const size = Buffer.byteLength(body, "latin1");
  const frames = ["TC1 LREP id=" + id + " token=" + escapeValue(TOKEN) + " state=ok size=" + size];
  for (let offset = 0; offset < size; offset += 180) {
    frames.push(
      "TC1 LDATA id=" + id +
      " off=" + offset +
      " data=" + escapeValue(body.slice(offset, offset + 180)),
    );
  }
  frames.push("TC1 LEND id=" + id + " size=" + size);
  return frames.join("\n");
}

function snapshotBody() {
  const lines = [
    "format=plant.snapshot.v1",
    "at=990.0",
    "generation=40",
    "revision=4",
    "scanning=0",
    "calls=12",
    "configured=1",
    "halls=1",
    "hall=TC-TEST",
    "stocks=10",
  ];
  for (let index = 1; index <= 10; index += 1) {
    const name = "hall/stock-" + String(index).padStart(2, "0");
    lines.push(
      "stock name=" + name + " kind=item state=exact total=" + index +
      " age=1.000 version=1 members=1 cardinality=single path=" + name,
    );
    lines.push(
      "entry stock=" + name + " kind=item key=test:item damage=" + index +
      " label=Test%20Item%20" + index + " count=" + index,
    );
  }
  lines.push(
    "alarm code=STARVED source=hall/stock-01 severity=warn first=900.000 last=1000.000" +
    " ack=0 message=1%20below%20minimum%208",
  );
  lines.push("error line=4 message=unknown%20stock:%20casing/nope");
  return lines.join("\n") + "\n";
}

function statusBody() {
  return [
    "format=plant.status.v1",
    "version=0.4.2",
    "codename=Mirror",
    "hall=TC-TEST",
    "stocks=10",
    "alarms=1",
    "revision=4",
  ].join("\n") + "\n";
}

async function main() {
  const port = await freePort();
  const base = "http://127.0.0.1:" + port;
  const node = "bridge-test-node";
  const child = await startBridge(port);

  try {
    const help = await request(base, "GET", "/");
    assert.ok(help.includes("/link/mirror"), "the help text names the mirror endpoint");

    await request(base, "POST", "/link/queue?node=" + node,
      linkFrame("c1", "plant.snapshot") + "\n" + linkFrame("c2", "plant.status") + "\n");

    const delivered = await request(base, "POST", "/link/next?node=" + node,
      resultFrames("c1", snapshotBody()) + "\n" + resultFrames("c2", statusBody()) + "\n");
    assert.ok(delivered.includes("cmd=plant.snapshot"), "the bridge delivers the queued snapshot verb");
    assert.ok(delivered.includes("cmd=plant.status"), "the bridge delivers the queued status verb");

    const results = await request(base, "GET", "/link/results?node=" + node);
    assert.ok(results.includes("# id=c1 state=ok"), "the snapshot result is stored");

    const mirror = JSON.parse(await request(base, "GET", "/link/mirror?node=" + node));
    assert.ok(mirror.updated !== null, "the mirror reports an update time");
    assert.strictEqual(mirror.snapshot.parsed.kind, "snapshot", "the snapshot kind is parsed");
    assert.strictEqual(mirror.snapshot.parsed.fields.revision, "4", "the revision is parsed");
    assert.strictEqual(mirror.snapshot.parsed.fields.hall, "TC-TEST", "the hall is parsed");
    assert.strictEqual(mirror.snapshot.parsed.stocks.length, 10, "every stock survives the page split");
    assert.strictEqual(mirror.snapshot.parsed.stocks[9].name, "hall/stock-10", "the last stock is intact");
    assert.strictEqual(mirror.snapshot.parsed.entries[0].label, "Test Item 1", "escaped labels are decoded");
    assert.strictEqual(mirror.snapshot.parsed.alarms[0].code, "STARVED", "the alarm is parsed");
    assert.strictEqual(
      mirror.snapshot.parsed.alarms[0].message,
      "1 below minimum 8",
      "the alarm message is decoded",
    );

    assert.strictEqual(mirror.status.parsed.kind, "status", "the status reply is parsed");
    assert.strictEqual(mirror.status.parsed.fields.version, "0.4.2", "the status version is parsed");

    // A non-plant body must not replace the parsed status.
    await request(base, "POST", "/link/queue?node=" + node, linkFrame("c3", "status") + "\n");
    await request(base, "POST", "/link/next?node=" + node,
      resultFrames("c3", "product=TerraCorp OS\nversion=0.4.2\n") + "\n");
    const afterPlain = JSON.parse(await request(base, "GET", "/link/mirror?node=" + node));
    assert.strictEqual(afterPlain.status.parsed.fields.version, "0.4.2", "a plain body leaves the mirror alone");
    assert.strictEqual(afterPlain.status.parsed.fields.product, undefined, "a plain body is not parsed as plant");

    // A truncated plant body must not replace the last good snapshot either.
    const truncated = resultFrames("c4", snapshotBody()).split("\n");
    const headOnly = truncated[0];
    await request(base, "POST", "/link/queue?node=" + node, linkFrame("c4", "plant.snapshot") + "\n");
    await request(base, "POST", "/link/next?node=" + node, headOnly + "\n");
    const afterTruncated = JSON.parse(await request(base, "GET", "/link/mirror?node=" + node));
    assert.strictEqual(
      afterTruncated.snapshot.parsed.stocks.length,
      10,
      "a truncated body does not replace the last good snapshot",
    );

    const state = JSON.parse(await request(base, "GET", "/link/state"));
    assert.strictEqual(state.addresses.length, 1, "one node is known");
    assert.strictEqual(state.addresses[0].mirror, 2, "two mirror kinds are stored");

    // A sub-second `link.interval` must survive the bridge: `n` may be fractional
    // for that one verb (the OS floor is 0.5 s), and must stay an integer
    // everywhere else, or the relaxation would leak into every other command.
    // This runs last so it cannot disturb the node count or the mirror above.
    const floorNode = "bridge-test-floor";
    const queuedFloor = await request(base, "POST", "/link/queue?node=" + floorNode,
      "TC1 LINK id=f1 token=" + escapeValue(TOKEN) + " cmd=link.interval n=0.5\n");
    assert.ok(queuedFloor.includes("queued=1"), "the bridge accepts a fractional link.interval");
    await assert.rejects(
      () => request(base, "POST", "/link/queue?node=" + floorNode,
        "TC1 LINK id=f2 token=" + escapeValue(TOKEN) + " cmd=fs.read path=%2Fvar%2Fx n=0.5\n"),
      /n must be a non-negative integer/,
      "a fractional n is still rejected for verbs other than link.interval",
    );
  } finally {
    child.kill();
  }

  console.log("bridge: mirror parsing, paging and truncation guard passed");
}

main().catch((error) => {
  console.error("FAIL " + error.message);
  process.exit(1);
});
