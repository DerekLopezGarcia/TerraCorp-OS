// Minimal External Link client shared by the MCP server and its tests.
//
// It queues one LINK frame, waits for its LREP/LDATA/LEND result, and returns
// the assembled body. Settings come from flags, the environment or .link/, in
// that order, exactly like linkctl.

"use strict";

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..");
const STATE_DIR = path.join(ROOT, ".link");
const DEFAULT_BRIDGE = "http://127.0.0.1:8787";

const ESCAPES = {
  "%": "%25",
  " ": "%20",
  "\t": "%09",
  "\r": "%0D",
  "\n": "%0A",
  "=": "%3D",
};

function readText(file) {
  try {
    return fs.readFileSync(file, "utf8").trim();
  } catch {
    return "";
  }
}

function escapeValue(value) {
  return String(value).replace(/[% \t\r\n=]/g, (character) => ESCAPES[character]);
}

function loadOptions(argv) {
  const options = {
    bridge: "",
    token: "",
    node: "",
    timeout: 30,
    help: false,
  };
  const rest = [];

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const equals = arg.indexOf("=");
    const name = arg.startsWith("--") && equals > 0 ? arg.slice(0, equals) : arg;
    if (name === "-h" || name === "--help") {
      options.help = true;
    } else if (name === "--bridge" || name === "--token" || name === "--node" || name === "--timeout") {
      let value;
      if (name !== arg) {
        value = arg.slice(equals + 1);
      } else {
        index += 1;
        value = argv[index];
      }
      if (value === undefined) throw new Error(name + " needs a value");
      if (name === "--bridge") options.bridge = value;
      else if (name === "--token") options.token = value;
      else if (name === "--node") options.node = value;
      else {
        const timeout = Number(value);
        if (!Number.isFinite(timeout) || timeout <= 0) throw new Error("invalid --timeout");
        options.timeout = timeout;
      }
    } else {
      rest.push(arg);
    }
  }

  if (!options.token) options.token = process.env.LINK_TOKEN || readText(path.join(STATE_DIR, "token"));
  if (!options.node) options.node = process.env.LINK_NODE || readText(path.join(STATE_DIR, "node"));
  if (!options.bridge) {
    options.bridge = process.env.LINK_BRIDGE || readText(path.join(STATE_DIR, "bridge")) || DEFAULT_BRIDGE;
  }
  options.bridge = options.bridge.replace(/\/+$/, "");
  options.rest = rest;
  return options;
}

function requireToken(options) {
  if (!options.token) {
    throw new Error("no token: pass --token, set LINK_TOKEN, or write .link/token");
  }
}

function requireNode(options) {
  if (!options.node) {
    throw new Error("no node: pass --node or write .link/node");
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

function newId() {
  return Date.now().toString(36) + Math.floor(Math.random() * 0x10000).toString(16).padStart(4, "0");
}

function buildFrame(options, cmd, fields) {
  const frame = {
    id: newId(),
    token: options.token,
    cmd,
  };
  for (const pair of fields || []) {
    const equals = pair.indexOf("=");
    if (equals < 1) throw new Error("expected key=value, got " + pair);
    const key = pair.slice(0, equals);
    if (Object.hasOwn(frame, key)) throw new Error("cannot override " + key);
    frame[key] = pair.slice(equals + 1);
  }
  const line = "TC1 LINK " + Object.entries(frame)
    .map(([key, value]) => key + "=" + escapeValue(value))
    .join(" ");
  return { id: frame.id, line };
}

function parseResults(text) {
  const blocks = [];
  let current = null;
  for (const line of text.split("\n")) {
    const head = /^# id=(.*) state=(\S+)(?: reason=(\S+))? size=(\d+)$/.exec(line);
    if (head) {
      current = {
        id: head[1],
        state: head[2],
        reason: head[3] || null,
        size: Number(head[4]),
        lines: [],
      };
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

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function queueAndWait(options, cmd, fields, timeoutSeconds) {
  requireNode(options);
  const frame = buildFrame(options, cmd, fields);
  const reply = await call(
    options,
    "POST",
    "/link/queue?node=" + encodeURIComponent(options.node),
    frame.line + "\n",
  );
  if (!reply.includes("queued=1")) {
    throw new Error("unexpected queue reply: " + reply.trim());
  }

  const deadline = Date.now() + (timeoutSeconds || options.timeout) * 1000;
  let last = null;
  while (Date.now() < deadline) {
    const blocks = parseResults(
      await call(options, "GET", "/link/results?node=" + encodeURIComponent(options.node)),
    );
    const block = blocks.find((entry) => entry.id === frame.id);
    if (block && block.state !== "unknown") return block;
    last = block || last;
    await sleep(250);
  }
  throw new Error(
    "no result for " + frame.id + " after " + (timeoutSeconds || options.timeout) + "s" +
    (last ? " (state=" + last.state + ")" : "") +
    "; the node posts results on its next exchange",
  );
}

async function getMirror(options) {
  requireNode(options);
  return JSON.parse(
    await call(options, "GET", "/link/mirror?node=" + encodeURIComponent(options.node)),
  );
}

async function getState(options) {
  return JSON.parse(await call(options, "GET", "/link/state"));
}

module.exports = {
  DEFAULT_BRIDGE,
  STATE_DIR,
  readText,
  escapeValue,
  loadOptions,
  call,
  buildFrame,
  parseResults,
  queueAndWait,
  getMirror,
  getState,
};
