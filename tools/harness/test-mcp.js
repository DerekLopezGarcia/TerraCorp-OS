// Test the read-only MCP server over the real bridge.
//
//   node tools/harness/test-mcp.js
//
// A fake node answers the queued verbs, so the test covers the whole path:
// MCP -> link client -> bridge -> node result -> parser -> text. Three of the
// calls are the questions the slice must answer without inventing numbers.

"use strict";

const assert = require("assert");
const { spawn } = require("child_process");
const net = require("net");
const path = require("path");
const readline = require("readline");

const repoRoot = path.resolve(__dirname, "../..");
const bridgePath = path.join(repoRoot, "tools", "bridge", "bridge.js");
const mcpPath = path.join(repoRoot, "tools", "bridge", "mcp.js");
const TOKEN = "mcp-test-token";
const NODE = "mcp-test-node";

const ESCAPES = { "%": "%25", " ": "%20", "\t": "%09", "\r": "%0D", "\n": "%0A", "=": "%3D" };
const escapeValue = (value) => String(value).replace(/[% \t\r\n=]/g, (ch) => ESCAPES[ch]);

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

function waitForLine(child, predicate) {
  return new Promise((resolve, reject) => {
    let output = "";
    const timer = setTimeout(() => reject(new Error("no start line: " + output)), 8000);
    const onData = (chunk) => {
      output += chunk.toString("utf8");
      if (predicate(output)) {
        clearTimeout(timer);
        resolve();
      }
    };
    child.stdout.on("data", onData);
    child.stderr.on("data", onData);
    child.on("exit", (code) => {
      clearTimeout(timer);
      reject(new Error("process exited with " + code + ": " + output));
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

function resultFrames(id, body) {
  const size = Buffer.byteLength(body, "latin1");
  const frames = ["TC1 LREP id=" + id + " token=" + escapeValue(TOKEN) + " state=ok size=" + size];
  for (let offset = 0; offset < size; offset += 180) {
    frames.push("TC1 LDATA id=" + id + " off=" + offset + " data=" + escapeValue(body.slice(offset, offset + 180)));
  }
  frames.push("TC1 LEND id=" + id + " size=" + size);
  return frames.join("\n");
}

async function seed(base, id, body) {
  await request(base, "POST", "/link/next?node=" + NODE, resultFrames(id, body) + "\n");
}

function snapshotBody() {
  return [
    "format=plant.snapshot.v1",
    "at=1000.0",
    "generation=40",
    "revision=7",
    "scanning=0",
    "calls=12",
    "configured=1",
    "halls=1",
    "hall=TC-2907",
    "stocks=2",
    "stock name=casing/ingots kind=item state=exact total=744 age=1.250 version=4 members=1 cardinality=single path=casing/ingots rate=0.000 rate_span=120",
    "entry stock=casing/ingots kind=item key=gregtech:meta_ingot damage=113 label=Titanium%20Ingot count=192",
    "entry stock=casing/ingots kind=item key=gregtech:meta_ingot damage=324 label=Steel%20Ingot count=552",
    "stock name=casing/casings kind=item state=exact total=5 age=1.250 version=4 members=1 cardinality=single path=casing/casings rate=0.000 rate_span=120",
    "entry stock=casing/casings kind=item key=gregtech:machine_casing damage=4 label=EV%20Machine%20Casing count=2",
  ].join("\n") + "\n";
}

function statusBody() {
  return [
    "format=plant.status.v1",
    "version=0.4.5",
    "codename=Atlas",
    "hall=TC-2907",
    "stocks=2",
    "cache_age=1.200",
    "alarms=0",
    "revision=7",
  ].join("\n") + "\n";
}

function alarmsBody() {
  return [
    "format=plant.alarms.v1",
    "at=1000.0",
    "since=-1",
    "count=0",
  ].join("\n") + "\n";
}

const PLAN_BODY = [
  "format=plant.plan.v1",
  "target=item%20gregtech:machine_casing@4",
  "qty=100",
  "steps=1",
  "seconds=4900.000",
  "rate=0.020408",
  "bottleneck=casing_ev",
  "step recipe=casing_ev label=EV%20casing machine=assembler source=book status=declared ratio=1.0000 crafts=98 seconds=4900.000 rate=0.020000",
  "shortfall kind=item key=gregtech:meta_ingot damage=113 need=784 have=192 missing=592",
].join("\n") + "\n";

const BOOK_BODY = [
  "format=plant.book.v1",
  "recipes=1",
  "errors=0",
  "configured=1",
  "recipe id=casing_ev label=EV%20casing machine=assembler ticks=50 priority=10 machines=1 source=book status=declared ratio=1.0000",
  "io recipe=casing_ev side=in kind=item key=gregtech:meta_ingot damage=113 qty=8 chance=1.0000",
  "io recipe=casing_ev side=out kind=item key=gregtech:machine_casing damage=4 qty=1 chance=1.0000",
].join("\n") + "\n";

const HISTORY_BODY = [
  "format=plant.history.v1",
  "at=1000.0",
  "limit=60",
  "stocks=1",
  "stock name=casing/ingots samples=2 rate=2.500 rate_span=100 trend=-12.0 first=900.0 last=1000.0",
  "sample stock=casing/ingots t=900.0 total=700 state=exact",
  "sample stock=casing/ingots t=1000.0 total=744 state=exact",
].join("\n") + "\n";

const PATHS_BODY = [
  "format=plant.paths.v1",
  "paths=2",
  "path name=casing/ingots cardinality=single members=1 stocks=1 bound=1",
  "path name=casing/casings cardinality=single members=1 stocks=1 bound=1",
].join("\n") + "\n";

function bodyFor(cmd) {
  if (cmd === "plant.plan") return PLAN_BODY;
  if (cmd === "plant.book") return BOOK_BODY;
  if (cmd === "plant.history") return HISTORY_BODY;
  if (cmd === "plant.paths") return PATHS_BODY;
  if (cmd === "log") return "12:00:00 TRZ boot\n12:00:01 TRZ ready\n";
  return null;
}

function startNodeLoop(base) {
  let stopped = false;
  const loop = (async () => {
    while (!stopped) {
      // Keep the queued frames if there are any; a fake node only has one verb
      // in flight at a time.
      // eslint-disable-next-line no-await-in-loop
      const frames = await request(base, "POST", "/link/next?node=" + NODE, "");
      const lines = frames.split("\n").filter(Boolean);
      const replies = [];
      for (const line of lines) {
        const id = /(?:^| )id=([^ ]+)/.exec(line);
        const cmd = /(?:^| )cmd=([^ ]+)/.exec(line);
        if (!id || !cmd) continue;
        const body = bodyFor(cmd[1]);
        if (body !== null) {
          replies.push(resultFrames(id[1], body));
        }
      }
      if (replies.length > 0) {
        // eslint-disable-next-line no-await-in-loop
        await request(base, "POST", "/link/next?node=" + NODE, replies.join("\n") + "\n");
      }
      // eslint-disable-next-line no-await-in-loop
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  })();
  return async () => {
    stopped = true;
    await loop.catch(() => {});
  };
}

function mcpClient(child) {
  const pending = new Map();
  let nextId = 1;
  const rl = readline.createInterface({ input: child.stdout, terminal: false });
  rl.on("line", (line) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    const waiter = pending.get(message.id);
    if (waiter) {
      pending.delete(message.id);
      waiter.resolve(message);
    }
  });

  return {
    async call(method, params) {
      const id = nextId++;
      const request = { jsonrpc: "2.0", id, method };
      if (params !== undefined) request.params = params;
      const promise = new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error("MCP timeout for " + method));
        }, 40000);
        pending.set(id, {
          resolve: (message) => {
            clearTimeout(timer);
            resolve(message);
          },
        });
      });
      child.stdin.write(JSON.stringify(request) + "\n");
      return promise;
    },
    close() {
      rl.close();
    },
  };
}

async function main() {
  const port = await freePort();
  const base = "http://127.0.0.1:" + port;
  const bridge = spawn(process.execPath, [bridgePath, "--port", String(port), "--token", TOKEN], {
    cwd: repoRoot,
    stdio: ["ignore", "pipe", "pipe"],
  });
  await waitForLine(bridge, (output) => output.includes("listening on"));

  const mcp = spawn(process.execPath, [mcpPath, "--bridge", base, "--token", TOKEN, "--node", NODE], {
    cwd: repoRoot,
    stdio: ["pipe", "pipe", "pipe"],
  });
  await new Promise((resolve) => setTimeout(resolve, 400));
  const client = mcpClient(mcp);
  const stopLoop = startNodeLoop(base);

  try {
    await seed(base, "seed-status", statusBody());
    await seed(base, "seed-snapshot", snapshotBody());
    await seed(base, "seed-alarms", alarmsBody());

    const initialized = await client.call("initialize", { protocolVersion: "2024-11-05" });
    assert.strictEqual(initialized.result.serverInfo.name, "terracorp-plant", "the MCP identity is set");

    const listed = await client.call("tools/list");
    assert.strictEqual(listed.result.tools.length, 9, "nine read-only tools are listed");

    // Question 1: how is the plant?
    const situation = await client.call("tools/call", { name: "plant_situation", arguments: {} });
    const situationText = situation.result.content[0].text;
    assert.ok(situationText.includes("casing/ingots"), "the situation names the input stock");
    assert.ok(situationText.includes("744"), "the situation cites the real level");
    assert.ok(situationText.includes("0 alarms"), "the situation cites the alarm count");
    assert.ok(situationText.includes("source: plant.status"), "the situation cites its source");

    // Question 2: how many titanium ingots?
    const stock = await client.call("tools/call", {
      name: "stock_query",
      arguments: { name: "casing/ingots" },
    });
    const stockText = stock.result.content[0].text;
    assert.ok(stockText.includes("Titanium Ingot x192"), "the stock query returns the real count");
    assert.ok(stockText.includes("Steel Ingot x552"), "the stock query lists every entry");

    const unknown = await client.call("tools/call", {
      name: "stock_query",
      arguments: { name: "casing/nope" },
    });
    assert.ok(unknown.result.content[0].text.includes("No stock matches casing/nope"),
      "an unknown stock is named, not invented as zero");

    const alarm = await client.call("tools/call", { name: "alarm_list", arguments: {} });
    assert.ok(alarm.result.content[0].text.includes("No active alarms"), "the alarm list is honest about zero");

    // Question 3: what does 100 casings need?
    const plan = await client.call("tools/call", {
      name: "plan",
      arguments: { target: "item gregtech:machine_casing@4", qty: 100 },
    });
    const planText = plan.result.content[0].text;
    assert.ok(planText.includes("Bottleneck: casing_ev"), "the plan names the bottleneck");
    assert.ok(planText.includes("missing 592"), "the plan cites the hand-counted shortfall");
    assert.ok(planText.includes("source: plant.plan"), "the plan cites its source");

    const history = await client.call("tools/call", {
      name: "history",
      arguments: { stock: "casing/ingots" },
    });
    const historyText = history.result.content[0].text;
    assert.ok(historyText.includes("rate 2.5/min"),
      "the history returns the rate. Got: " + historyText);
    assert.ok(historyText.includes("t=1000 total=744"),
      "the history returns samples. Got: " + historyText);

    const paths = await client.call("tools/call", { name: "path_list", arguments: {} });
    assert.ok(paths.result.content[0].text.includes("casing/ingots: single, 1 member(s)"),
      "the path list reports names, not addresses");

    const onePath = await client.call("tools/call", {
      name: "path_query",
      arguments: { path: "casing/casings" },
    });
    assert.ok(onePath.result.content[0].text.includes("casing/casings: single"), "the path query filters");

    const recipes = await client.call("tools/call", {
      name: "recipe_query",
      arguments: { recipe: "casing_ev" },
    });
    const recipeText = recipes.result.content[0].text;
    assert.ok(recipeText.includes("casing_ev (EV casing): assembler"), "the recipe query names the machine");
    assert.ok(recipeText.includes("in 8 item gregtech:meta_ingot@113"), "the recipe query lists its inputs");

    const audit = await client.call("tools/call", { name: "audit_tail", arguments: { n: 2 } });
    assert.ok(audit.result.content[0].text.includes("TRZ ready"), "the audit tail returns the log");
  } finally {
    stopLoop();
    client.close();
    mcp.kill();
    bridge.kill();
  }

  console.log("mcp: nine read-only tools, cited answers and no invented numbers");
}

main().catch((error) => {
  console.error("FAIL " + error.message);
  process.exit(1);
});
