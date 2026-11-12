#!/usr/bin/env node
"use strict";

// Operator client for the External Link bridge.
//
// The bridge speaks TC1 frames over HTTP; typing them by hand is easy to get
// wrong, so this wraps queueing a command and reading its result.
//
// Settings, in order of precedence: command-line flag, environment variable,
// then a file under .link/ (git-ignored):
//
//   .link/token   shared secret, also used by bridge.js --token
//   .link/bridge  base URL, default http://127.0.0.1:8787
//   .link/node    the node address learned with `use` or `nodes`
//
// Examples:
//   node tools/bridge/linkctl.js nodes
//   node tools/bridge/linkctl.js use 1a2b3c4d-...
//   node tools/bridge/linkctl.js queue status
//   node tools/bridge/linkctl.js queue log n=20 --wait
//   node tools/bridge/linkctl.js queue fs.list path=/etc --wait
//   node tools/bridge/linkctl.js results

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..");
const STATE_DIR = path.join(ROOT, ".link");
const DEFAULT_BRIDGE = "http://127.0.0.1:8787";
const DEFAULT_TIMEOUT = 45;

const ESCAPES = {
  "%": "%25",
  " ": "%20",
  "\t": "%09",
  "\r": "%0D",
  "\n": "%0A",
  "=": "%3D",
};

const USAGE = [
  "Usage: node tools/bridge/linkctl.js <command> [options]",
  "",
  "Commands:",
  "  state                 Counters and known node addresses",
  "  nodes                 Just the node addresses that have polled",
  "  use <address>         Remember the node address in .link/node",
  "  queue <cmd> [k=v...]  Queue one LINK frame for the node",
  "  results [id]          Show stored results, or one body by id",
  "  wait <id>             Poll until that result has a state",
  "",
  "Options:",
  "  --wait                After queue, wait for the result (queue only)",
  "  --timeout <seconds>   How long wait polls. Default " + DEFAULT_TIMEOUT + ".",
  "  --bridge <url>        Bridge base URL. Default " + DEFAULT_BRIDGE + ".",
  "  --token <value>       Shared secret. Default from .link/token.",
  "  --node <address>      Node address. Default from .link/node.",
  "  -h, --help            This text.",
].join("\n");

function readText(file) {
  try {
    return fs.readFileSync(file, "utf8").trim();
  } catch {
    return "";
  }
}

function writeText(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, value + "\n");
}

function escapeValue(value) {
  return String(value).replace(/[% \t\r\n=]/g, (char) => ESCAPES[char]);
}

function parseArgs(argv) {
  const options = {
    bridge: DEFAULT_BRIDGE,
    token: "",
    node: "",
    wait: false,
    timeout: DEFAULT_TIMEOUT,
    help: false,
  };
  const positional = [];

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "-h" || arg === "--help") {
      options.help = true;
    } else if (arg === "--wait") {
      options.wait = true;
    } else if (arg === "--bridge" || arg === "--token" || arg === "--node" || arg === "--timeout") {
      const value = argv[index + 1];
      index += 1;
      if (value === undefined) throw new Error(arg + " needs a value");
      if (arg === "--bridge") options.bridge = value;
      else if (arg === "--token") options.token = value;
      else if (arg === "--node") options.node = value;
      else {
        const seconds = Number(value);
        if (!Number.isFinite(seconds) || seconds <= 0) {
          throw new Error("invalid --timeout: " + value);
        }
        options.timeout = seconds;
      }
    } else if (arg.startsWith("--")) {
      throw new Error("unknown option: " + arg);
    } else {
      positional.push(arg);
    }
  }

  if (!options.token) options.token = process.env.LINK_TOKEN || readText(path.join(STATE_DIR, "token"));
  if (!options.bridge || options.bridge === DEFAULT_BRIDGE) {
    options.bridge = process.env.LINK_BRIDGE || readText(path.join(STATE_DIR, "bridge")) || DEFAULT_BRIDGE;
  }
  if (!options.node) options.node = process.env.LINK_NODE || readText(path.join(STATE_DIR, "node"));
  options.bridge = options.bridge.replace(/\/+$/, "");

  return { options, command: positional[0] || "", rest: positional.slice(1) };
}

function requireToken(options) {
  if (!options.token) {
    throw new Error("no token: pass --token, set LINK_TOKEN, or write .link/token");
  }
}

function requireNode(options) {
  if (!options.node) {
    throw new Error("no node: run `nodes` then `use <address>`, or pass --node");
  }
}

async function call(options, method, route, body) {
  requireToken(options);
  const headers = { "X-Link-Token": options.token };
  if (body !== undefined) headers["Content-Type"] = "text/plain; charset=utf-8";

  const response = await fetch(options.bridge + route, { method, headers, body });
  const text = await response.text();
  if (!response.ok) {
    throw new Error("HTTP " + response.status + ": " + text.trim());
  }
  return text;
}

// Mirrors the block format of /link/results:
//   # id=<id> state=<state> size=<n>
//   <body>
//   # end
function parseResults(text) {
  const blocks = [];
  let current = null;

  for (const line of text.split("\n")) {
    const head = /^# id=(.*) state=(\S+) size=(\d+)$/.exec(line);
    if (head) {
      current = { id: head[1], state: head[2], size: Number(head[3]), lines: [] };
      blocks.push(current);
      continue;
    }
    if (line === "# end") {
      current = null;
      continue;
    }
    if (current) current.lines.push(line);
  }

  for (const block of blocks) {
    block.body = block.lines.join("\n");
    delete block.lines;
  }
  return blocks;
}

function printBlock(block) {
  const header = "# " + block.id + " state=" + block.state + " size=" + block.size;
  process.stdout.write(header + "\n");
  if (block.body !== "") process.stdout.write(block.body + "\n");
  process.stdout.write("# end\n");
}

function newId() {
  return Date.now().toString(36) + Math.floor(Math.random() * 0x10000).toString(16).padStart(4, "0");
}

function buildFrame(options, cmd, fields) {
  const frame = {
    id: newId(),
    token: options.token,
    cmd,
  };

  for (const pair of fields) {
    const equals = pair.indexOf("=");
    if (equals < 1) throw new Error("expected key=value, got " + pair);
    const key = pair.slice(0, equals);
    if (Object.hasOwn(frame, key)) throw new Error("cannot override " + key);
    frame[key] = pair.slice(equals + 1);
  }

  const parts = Object.entries(frame).map(([key, value]) => key + "=" + escapeValue(value));
  return { id: frame.id, line: "TC1 LINK " + parts.join(" ") };
}

async function waitFor(options, id) {
  const deadline = Date.now() + options.timeout * 1000;
  let last = null;

  while (Date.now() < deadline) {
    const blocks = parseResults(await call(options, "GET", "/link/results?node=" + encodeURIComponent(options.node)));
    const block = blocks.find((entry) => entry.id === id);
    if (block && block.state !== "unknown") return block;
    last = block || last;
    await new Promise((resolve) => setTimeout(resolve, 750));
  }

  throw new Error(
    "no result for " + id + " after " + options.timeout + "s" +
    (last ? " (state=" + last.state + ")" : "") +
    "; the OS posts results on its next exchange",
  );
}

async function main() {
  const { options, command, rest } = parseArgs(process.argv.slice(2));

  if (options.help || command === "" || command === "help") {
    console.log(USAGE);
    return;
  }

  if (command === "state" || command === "nodes") {
    const state = JSON.parse(await call(options, "GET", "/link/state"));
    if (command === "state") {
      console.log(JSON.stringify(state, null, 2));
      return;
    }
    const addresses = state.addresses || [];
    if (addresses.length === 0) {
      console.log("no node has polled yet: check linkSink, linkToken and the Internet Card");
      return;
    }
    for (const entry of addresses) {
      console.log(entry.node + "  queued=" + entry.queued + " results=" + entry.results);
    }
    return;
  }

  if (command === "use") {
    const address = rest[0];
    if (!address) throw new Error("usage: use <address>");
    writeText(path.join(STATE_DIR, "node"), address);
    console.log("node set to " + address);
    return;
  }

  if (command === "queue") {
    requireNode(options);
    const cmd = rest[0];
    if (!cmd) throw new Error("usage: queue <cmd> [key=value...]");
    const frame = buildFrame(options, cmd, rest.slice(1));
    const reply = await call(options, "POST", "/link/queue?node=" + encodeURIComponent(options.node), frame.line + "\n");
    console.log(reply.trim() + " id=" + frame.id);
    if (options.wait) printBlock(await waitFor(options, frame.id));
    return;
  }

  if (command === "results") {
    requireNode(options);
    const text = await call(options, "GET", "/link/results?node=" + encodeURIComponent(options.node));
    const blocks = parseResults(text);
    const wanted = rest[0];
    if (wanted) {
      const block = blocks.find((entry) => entry.id === wanted);
      if (!block) throw new Error("no result with id " + wanted);
      printBlock(block);
      return;
    }
    if (blocks.length === 0) {
      console.log("no results for " + options.node);
      return;
    }
    for (const block of blocks) printBlock(block);
    return;
  }

  if (command === "wait") {
    requireNode(options);
    const id = rest[0];
    if (!id) throw new Error("usage: wait <id>");
    printBlock(await waitFor(options, id));
    return;
  }

  throw new Error("unknown command: " + command);
}

main().catch((error) => {
  console.error("linkctl: " + error.message);
  process.exit(1);
});
