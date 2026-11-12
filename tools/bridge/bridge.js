"use strict";

// External Link bridge for TerraCorp OS.
//
// The OS is always the client: it polls this bridge over outbound HTTP from the
// OpenComputers `internet` component. The bridge never opens a connection to a
// computer, so it cannot push anything; it queues work and the OS collects it.
//
// The wire format is the TC1 line frame from src/lib/tc/net.lua, one frame per
// line:
//
//   TC1 <VERB> key=value key=value ...
//
// Values percent-escape %, space, tab, CR, LF and =. See docs/external-link.md
// for the verbs and the command set.
//
// The bridge keeps two things per node, in memory only:
//   - a queue of LINK frames waiting to be taken by that node
//   - the result frames (LREP/LDATA/LEND) the node posted back
//
// Frames and request bodies are carried as latin1 strings so a byte on the wire
// never changes on the way through. Replies are written back the same way,
// which keeps the round trip byte exact.

const crypto = require("crypto");
const http = require("http");

const PROTOCOL = "TC1";
const MAX_FRAME = 1024;
const MAX_BODY = 64 * 1024;
const DEFAULT_PORT = 8787;
const DEFAULT_HOST = "127.0.0.1";
const TOKEN_HEADER = "x-link-token";
const MAX_NODE_LENGTH = 128;

// Required fields per verb, mirroring the closed verb table of the OS.
const REQUIRED = {
  LINK: ["id", "token", "cmd"],
  LREP: ["id", "token", "state"],
  LDATA: ["id", "off"],
  LEND: ["id", "size"],
};

const RESULT_VERBS = ["LREP", "LDATA", "LEND"];

const VERB_NAME = /^[A-Z][A-Z0-9_]*$/;
const FIELD_NAME = /^[a-z][a-zA-Z0-9_]*$/;
const UNSIGNED = /^[0-9]+$/;
const SLUG = /^[a-z0-9][a-z0-9._-]*$/;

const USAGE = [
  "Usage: node tools/bridge/bridge.js [options] [token]",
  "",
  "The token is taken from --token, then LINK_TOKEN, then the positional",
  "argument. Without a token the bridge does not start.",
  "",
  "Options:",
  "  --token <value>  Shared secret every request must present.",
  "  --port <n>       Listen port. Default " + DEFAULT_PORT + ".",
  "  --host <addr>    Listen address. Default " + DEFAULT_HOST + ".",
  "  -h, --help       Print this text.",
].join("\n");

const HELP = [
  "TerraCorp OS External Link bridge.",
  "",
  "Every request must carry the header X-Link-Token with the shared secret.",
  "",
  "Endpoints:",
  "  POST /link/next?node=<addr>",
  "      Body: result frames from the previous command (LREP, LDATA, LEND),",
  "      one per line, or empty. Reply: the node's queued LINK frames, one per",
  "      line. Delivered frames are consumed and never handed out twice.",
  "  POST /link/queue?node=<addr>",
  "      Body: one or more LINK frames, one per line. Reply: queued=<n>.",
  "  GET  /link/results?node=<addr>",
  "      Assembled bodies for that node: header, body and '# end' lines.",
  "  GET  /link/state",
  "      Counters as JSON: nodes, queued, delivered, results.",
  "  GET  /",
  "      This text.",
  "",
  "Frames use the TC1 format, one per line:",
  "  TC1 <VERB> key=value key=value ...",
  "A value escapes % as %25, space as %20, tab as %09, CR as %0D, LF as %0A and",
  "= as %3D.",
  "",
  "Limits: frame " + MAX_FRAME + " bytes, request body " + MAX_BODY + " bytes.",
  "State is kept in memory and is lost when the bridge restarts.",
].join("\n") + "\n";

// ---------------------------------------------------------------- arguments

function parseArgs(argv) {
  const options = { port: DEFAULT_PORT, host: DEFAULT_HOST, token: "", help: false };
  const positional = [];

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "-h" || arg === "--help") {
      options.help = true;
      continue;
    }

    const equals = arg.indexOf("=");
    const name = arg.startsWith("--") && equals > 0 ? arg.slice(0, equals) : arg;
    if (name === "--port" || name === "--host" || name === "--token") {
      let value;
      if (name !== arg) {
        value = arg.slice(equals + 1);
      } else {
        index += 1;
        value = argv[index];
        if (value !== undefined && value.startsWith("--")) value = undefined;
      }
      if (value === undefined || value === "") {
        throw new Error(name + " needs a value");
      }
      if (name === "--port") {
        const port = Number(value);
        if (!Number.isInteger(port) || port < 1 || port > 65535) {
          throw new Error("invalid --port: " + value);
        }
        options.port = port;
      } else if (name === "--host") {
        options.host = value;
      } else {
        options.token = value;
      }
      continue;
    }

    if (arg.startsWith("--")) throw new Error("unknown option: " + arg);
    positional.push(arg);
  }

  if (!options.token) options.token = process.env.LINK_TOKEN || "";
  if (!options.token && positional.length > 0) options.token = positional[0];
  if (positional.length > 1) throw new Error("unexpected argument: " + positional[1]);
  return options;
}

// ------------------------------------------------------------------- frames

function unescapeValue(value) {
  // A % not followed by two hex digits is a literal %.
  return value.replace(/%([0-9A-Fa-f]{2})/g, (whole, hex) =>
    String.fromCharCode(parseInt(hex, 16)));
}

function isUnsignedInteger(value) {
  return UNSIGNED.test(value) && Number.isSafeInteger(Number(value));
}

// Parse one frame. Returns { verb, fields } or { error }.
function parseFrame(line) {
  if (line.length === 0) return { error: "empty frame" };
  if (line.length > MAX_FRAME) {
    return { error: "frame is larger than " + MAX_FRAME + " bytes" };
  }
  if (/[\r\n\0]/.test(line)) return { error: "frame must be one line" };

  const head = /^(\S+)\s+(\S+)\s*(.*)$/.exec(line);
  if (!head) return { error: "frame is not 'TC1 <VERB> key=value ...'" };
  if (head[1] !== PROTOCOL) return { error: "unsupported protocol: " + head[1] };

  const verb = head[2];
  if (!VERB_NAME.test(verb)) return { error: "invalid verb: " + verb };
  if (!Object.hasOwn(REQUIRED, verb)) return { error: "unknown verb: " + verb };

  const fields = Object.create(null);
  for (const token of head[3].split(/\s+/)) {
    if (token === "") continue;
    const equals = token.indexOf("=");
    if (equals < 1) return { error: "malformed field: " + token };
    const key = token.slice(0, equals);
    if (!FIELD_NAME.test(key)) return { error: "invalid field name: " + key };
    if (Object.hasOwn(fields, key)) return { error: "duplicate field: " + key };
    fields[key] = unescapeValue(token.slice(equals + 1));
  }

  for (const key of REQUIRED[verb]) {
    if (!Object.hasOwn(fields, key) || fields[key] === "") {
      return { error: "missing field: " + key };
    }
  }

  if (verb === "LREP") {
    if (fields.state !== "ok" && fields.state !== "error") {
      return { error: "state must be ok or error" };
    }
    if (Object.hasOwn(fields, "reason") && !SLUG.test(fields.reason)) {
      return { error: "reason must be a slug" };
    }
    if (Object.hasOwn(fields, "size") && !isUnsignedInteger(fields.size)) {
      return { error: "size must be a non-negative integer" };
    }
  } else if (verb === "LDATA") {
    if (!isUnsignedInteger(fields.off)) {
      return { error: "off must be a non-negative integer" };
    }
    if (!Object.hasOwn(fields, "data")) return { error: "missing field: data" };
  } else if (verb === "LEND") {
    if (!isUnsignedInteger(fields.size)) {
      return { error: "size must be a non-negative integer" };
    }
  } else if (verb === "LINK") {
    if (Object.hasOwn(fields, "n") && !isUnsignedInteger(fields.n)) {
      return { error: "n must be a non-negative integer" };
    }
  }

  return { verb, fields };
}

// Parse every non-empty line of a body and keep the frames whose verb is
// allowed here. Returns { frames } or { error } naming the offending line.
function parseFrames(body, allowedVerbs) {
  const lines = body.toString("latin1").split("\n");
  const frames = [];

  for (let index = 0; index < lines.length; index += 1) {
    let line = lines[index];
    if (line.endsWith("\r")) line = line.slice(0, -1);
    if (line === "") continue;

    const parsed = parseFrame(line);
    if (parsed.error) {
      return { error: "line " + (index + 1) + ": " + parsed.error };
    }
    if (!allowedVerbs.includes(parsed.verb)) {
      return {
        error: "line " + (index + 1) + ": verb " + parsed.verb + " is not accepted here",
      };
    }
    frames.push({ line, verb: parsed.verb, fields: parsed.fields });
  }

  return { frames };
}

// -------------------------------------------------------------------- state

// A node is created on first mention. Results are grouped by frame id; a record
// created by LDATA before its LREP reports state=unknown.
function nodeOf(state, name) {
  let node = state.nodes.get(name);
  if (node === undefined) {
    node = { queue: [], results: new Map() };
    state.nodes.set(name, node);
  }
  return node;
}

function applyResultFrame(node, frame) {
  const id = frame.fields.id;
  let record = node.results.get(id);
  if (record === undefined) {
    record = { id, state: "unknown", replySize: null, endSize: null, chunks: [] };
    node.results.set(id, record);
  }

  if (frame.verb === "LREP") {
    record.state = frame.fields.state;
    if (Object.hasOwn(frame.fields, "size")) record.replySize = Number(frame.fields.size);
  } else if (frame.verb === "LDATA") {
    record.chunks.push({ off: Number(frame.fields.off), data: frame.fields.data });
  } else if (frame.verb === "LEND") {
    record.endSize = Number(frame.fields.size);
  }
}

function recordBody(record) {
  const ordered = record.chunks.slice().sort((left, right) => left.off - right.off);
  return ordered.map((chunk) => chunk.data).join("");
}

// Replace control characters so an id or a state cannot break the line format.
function printable(value) {
  return String(value).replace(/[\x00-\x1F\x7F]/g, "?");
}

function renderResults(node) {
  const blocks = [];
  for (const record of node.results.values()) {
    const body = recordBody(record);
    const size = record.endSize !== null
      ? record.endSize
      : record.replySize !== null
        ? record.replySize
        : Buffer.byteLength(body, "latin1");
    const terminated = body === "" || body.endsWith("\n") ? body : body + "\n";
    blocks.push(
      "# id=" + printable(record.id) +
      " state=" + printable(record.state) +
      " size=" + size + "\n" +
      terminated +
      "# end\n",
    );
  }
  return blocks.join("");
}

function countQueued(state) {
  let total = 0;
  for (const node of state.nodes.values()) total += node.queue.length;
  return total;
}

function countResults(state) {
  let total = 0;
  for (const node of state.nodes.values()) total += node.results.size;
  return total;
}

// ---------------------------------------------------------------- transport

function httpError(status, message) {
  const error = new Error(message);
  error.status = status;
  return error;
}

function sendText(res, status, body, contentType) {
  const payload = Buffer.from(body, "latin1");
  res.writeHead(status, {
    "Content-Type": contentType || "text/plain; charset=utf-8",
    "Content-Length": payload.length,
    "Cache-Control": "no-store",
  });
  res.end(payload);
}

function sendJson(res, status, value) {
  sendText(res, status, JSON.stringify(value), "application/json; charset=utf-8");
}

// Collect the request body up to MAX_BODY bytes. The request keeps draining
// after an overflow so the client can still read the 413.
function readBody(req) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let total = 0;
    const chunks = [];

    const fail = (error) => {
      if (settled) return;
      settled = true;
      reject(error);
    };

    const declared = Number(req.headers["content-length"]);
    if (Number.isFinite(declared) && declared > MAX_BODY) {
      fail(httpError(413, "request body is larger than " + MAX_BODY + " bytes"));
      return;
    }

    req.on("data", (chunk) => {
      if (settled) return;
      total += chunk.length;
      if (total > MAX_BODY) {
        chunks.length = 0;
        fail(httpError(413, "request body is larger than " + MAX_BODY + " bytes"));
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      if (settled) return;
      settled = true;
      resolve(Buffer.concat(chunks));
    });
    req.on("error", (error) => fail(error));
  });
}

// ----------------------------------------------------------------- handlers

function nodeFromQuery(query, res) {
  const value = query.get("node");
  if (value === null || value === "") {
    sendText(res, 400, "missing required query parameter: node");
    return null;
  }
  if (value.length > MAX_NODE_LENGTH || /[\x00-\x20\x7F]/.test(value)) {
    sendText(res, 400, "invalid node address");
    return null;
  }
  return value;
}

function handleNext(res, state, query, body) {
  const name = nodeFromQuery(query, res);
  if (name === null) return;

  const parsed = parseFrames(body, RESULT_VERBS);
  if (parsed.error) {
    sendText(res, 400, parsed.error);
    return;
  }

  // Every frame in the request is valid, so it is now safe to store them.
  const node = nodeOf(state, name);
  for (const frame of parsed.frames) applyResultFrame(node, frame);

  const delivered = node.queue;
  node.queue = [];
  state.delivered += delivered.length;
  sendText(res, 200, delivered.join("\n"));
}

function handleQueue(res, state, query, body) {
  const name = nodeFromQuery(query, res);
  if (name === null) return;

  const parsed = parseFrames(body, ["LINK"]);
  if (parsed.error) {
    sendText(res, 400, parsed.error);
    return;
  }
  if (parsed.frames.length === 0) {
    sendText(res, 400, "request body contains no frames");
    return;
  }

  const node = nodeOf(state, name);
  for (const frame of parsed.frames) node.queue.push(frame.line);
  sendText(res, 200, "queued=" + parsed.frames.length);
}

function handleResults(res, state, query) {
  const name = nodeFromQuery(query, res);
  if (name === null) return;
  // A read never creates a node: polling an unknown address must not grow the
  // node table.
  const node = state.nodes.get(name);
  sendText(res, 200, node === undefined ? "" : renderResults(node));
}

function handleState(res, state) {
  sendJson(res, 200, {
    nodes: state.nodes.size,
    queued: countQueued(state),
    delivered: state.delivered,
    results: countResults(state),
  });
}

// ------------------------------------------------------------------- server

function tokenMatches(header, expectedDigest) {
  if (typeof header !== "string" || header === "") return false;
  const digest = crypto.createHash("sha256").update(header, "utf8").digest();
  return crypto.timingSafeEqual(digest, expectedDigest);
}

async function handleRequest(req, res, expectedDigest, state) {
  let body = null;
  let bodyError = null;
  try {
    body = await readBody(req);
  } catch (error) {
    bodyError = error;
  }

  // The token gate comes before any parsing or storage. The body is already
  // drained above so the client can read this reply.
  if (!tokenMatches(req.headers[TOKEN_HEADER], expectedDigest)) {
    sendText(res, 401, "missing or invalid X-Link-Token header");
    return;
  }

  if (bodyError) {
    if (bodyError.status) {
      sendText(res, bodyError.status, bodyError.message);
      return;
    }
    throw bodyError;
  }

  let routed;
  try {
    routed = new URL(req.url, "http://bridge.invalid");
  } catch {
    sendText(res, 400, "malformed request URL");
    return;
  }
  const path = routed.pathname;

  if (path === "/") {
    if (req.method !== "GET") {
      sendText(res, 405, "only GET is allowed on /");
      return;
    }
    sendText(res, 200, HELP);
    return;
  }

  if (path === "/link/next") {
    if (req.method !== "POST") {
      sendText(res, 405, "only POST is allowed on /link/next");
      return;
    }
    handleNext(res, state, routed.searchParams, body);
    return;
  }

  if (path === "/link/queue") {
    if (req.method !== "POST") {
      sendText(res, 405, "only POST is allowed on /link/queue");
      return;
    }
    handleQueue(res, state, routed.searchParams, body);
    return;
  }

  if (path === "/link/results") {
    if (req.method !== "GET") {
      sendText(res, 405, "only GET is allowed on /link/results");
      return;
    }
    handleResults(res, state, routed.searchParams);
    return;
  }

  if (path === "/link/state") {
    if (req.method !== "GET") {
      sendText(res, 405, "only GET is allowed on /link/state");
      return;
    }
    handleState(res, state);
    return;
  }

  sendText(res, 404, "unknown endpoint: " + path);
}

function createServer(token) {
  const expectedDigest = crypto.createHash("sha256").update(token, "utf8").digest();
  const state = { nodes: new Map(), delivered: 0 };

  return http.createServer((req, res) => {
    handleRequest(req, res, expectedDigest, state).catch((error) => {
      console.error("bridge: " + String(error && error.stack ? error.stack : error));
      if (!res.headersSent) {
        sendText(res, 500, "internal error");
        return;
      }
      res.end();
    });
  });
}

function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error("bridge: " + error.message);
    console.error("");
    console.error(USAGE);
    process.exit(1);
  }

  if (options.help) {
    console.log(USAGE);
    return;
  }

  if (!options.token) {
    console.error("bridge: no shared token configured");
    console.error("bridge: refusing to start without a secret; every request is gated on it");
    console.error("bridge: pass --token <value>, set LINK_TOKEN, or give it as an argument");
    console.error("");
    console.error(USAGE);
    process.exit(1);
  }

  const server = createServer(options.token);
  server.on("error", (error) => {
    console.error("bridge: " + error.message);
    process.exit(1);
  });
  server.listen(options.port, options.host, () => {
    console.log("bridge: listening on http://" + options.host + ":" + options.port);
    console.log("bridge: state is in memory; a restart drops the queues and results");
  });
}

main();
