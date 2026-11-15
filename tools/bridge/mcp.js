#!/usr/bin/env node
// Read-only MCP server for TerraCorp OS.
//
// It runs next to the External Link bridge and answers over stdio. Every tool
// reads: the cached mirror when it is fresh, or one queued `plant.*` verb when
// the data is missing. Nothing here moves an item, opens a gate or rewrites a
// file; a tool that cannot read says so instead of returning a zero.
//
// Usage:
//   node tools/bridge/mcp.js [--bridge URL] [--token T] [--node ADDR]
// Settings fall back to .link/token, .link/node and .link/bridge.

"use strict";

const readline = require("readline");
const {
  loadOptions,
  queueAndWait,
  getMirror,
} = require("./linkclient");
const { parsePlantBody } = require("./plant");

const VERSION = "0.4.8";
const PROTOCOL = "2024-11-05";

const options = loadOptions(process.argv.slice(2));

const TOOLS = [
  {
    name: "plant_situation",
    description: "One-paragraph situation: version, hall, stocks with levels and rates, alarm count.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "stock_query",
    description: "Read one stock by name, or every stock, with its entries. Never returns a guessed level.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Exact stock name or a * glob, for example casing/*." },
        kind: { type: "string", enum: ["item", "fluid"] },
      },
      additionalProperties: false,
    },
  },
  {
    name: "alarm_list",
    description: "Active local level, power, stall and trend alarms, with severity and first/last seen.",
    inputSchema: {
      type: "object",
      properties: {
        since: { type: "number", description: "Only alarms whose last-seen ring time is at or after this." },
      },
      additionalProperties: false,
    },
  },
  {
    name: "history",
    description: "The bounded per-stock ring: rate, trend and the most recent samples.",
    inputSchema: {
      type: "object",
      properties: {
        stock: { type: "string", description: "One stock name; omit for every stock." },
        limit: { type: "number", description: "Samples per stock, 1-360. Default 60." },
      },
      additionalProperties: false,
    },
  },
  {
    name: "plan",
    description: "Plan a target from the operated book: steps, bottleneck, shortfall and warnings.",
    inputSchema: {
      type: "object",
      properties: {
        target: { type: "string", description: "item <key>@<damage> or fluid <name>, for example item gregtech:machine_casing@4." },
        qty: { type: "number", description: "Whole target quantity. Default 1." },
      },
      required: ["target"],
      additionalProperties: false,
    },
  },
  {
    name: "path_list",
    description: "Local semantic paths with cardinality and bound state. Addresses stay on the node.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "path_query",
    description: "One semantic path by exact name or * glob.",
    inputSchema: {
      type: "object",
      properties: { path: { type: "string" } },
      required: ["path"],
      additionalProperties: false,
    },
  },
  {
    name: "recipe_query",
    description: "The operated book, filtered by recipe id or output key.",
    inputSchema: {
      type: "object",
      properties: {
        recipe: { type: "string", description: "Exact recipe id." },
        output: { type: "string", description: "Output key, optionally key@damage." },
      },
      additionalProperties: false,
    },
  },
  {
    name: "audit_tail",
    description: "The tail of /var/log/tc.log from the node.",
    inputSchema: {
      type: "object",
      properties: { n: { type: "number", description: "Lines, 1-200. Default 40." } },
      additionalProperties: false,
    },
  },
];

function globMatch(pattern, name) {
  if (!pattern.includes("*")) return pattern === name;
  const escaped = pattern
    .split("*")
    .map((piece) => piece.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
    .join(".*");
  return new RegExp("^" + escaped + "$").test(name);
}

function formatNumber(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return String(value);
  return Number.isInteger(number) ? String(number) : number.toFixed(1);
}

// Rates must not round to 0.0: 0.020408 targets/s is a real bottleneck.
function formatRate(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return String(value);
  return number.toFixed(4).replace(/0+$/, "").replace(/\.$/, "");
}

function stockLine(stock) {
  const unit = stock.kind === "fluid" ? "mB" : "items";
  const rate = stock.rate === undefined ? "" : " · rate " + formatRate(stock.rate) + "/min";
  return stock.name + ": " + stock.state + " " + formatNumber(stock.total) + " " + unit + rate;
}

async function ensurePlant(kind, cmd, fields, maxAgeSeconds) {
  if (!options.node || !options.token) {
    throw new Error("the link is not configured: pass --node and --token, or write .link/");
  }
  const age = (maxAgeSeconds === undefined ? 15 : maxAgeSeconds) * 1000;
  try {
    const mirror = await getMirror(options);
    const entry = mirror[kind];
    if (entry) {
      const received = Date.parse(entry.received);
      if (!Number.isFinite(received) || Date.now() - received <= age) {
        return { parsed: entry.parsed, received: entry.received };
      }
    }
  } catch {
    // A mirror read is an optimisation; the queued verb below is authoritative.
  }

  const block = await queueAndWait(options, cmd, fields, 20);
  if (block.state !== "ok") {
    throw new Error(cmd + " failed: " + (block.reason || block.state));
  }
  const parsed = parsePlantBody(block.body);
  if (!parsed) {
    throw new Error(cmd + " returned a body this server does not understand");
  }
  return { parsed, received: new Date().toISOString() };
}

async function toolPlantSituation() {
  const status = await ensurePlant("status", "plant.status");
  const snapshot = await ensurePlant("snapshot", "plant.snapshot");
  const alarms = await ensurePlant("alarms", "plant.alarms");
  const fields = status.parsed.fields;
  const lines = [
    "TerraCorp " + (fields.version || "?") + " at " + (fields.hall || "?"),
    snapshot.parsed.stocks.length + " stocks, " + alarms.parsed.alarms.length + " alarms, cache " +
      (fields.cache_age === undefined ? "?" : formatNumber(fields.cache_age)) + " s",
  ];
  for (const stock of snapshot.parsed.stocks) {
    lines.push("- " + stockLine(stock));
  }
  lines.push("source: plant.status + plant.snapshot + plant.alarms over the External Link");
  return lines.join("\n");
}

async function toolStockQuery(args) {
  const snapshot = await ensurePlant("snapshot", "plant.snapshot");
  const wanted = args.name;
  const kind = args.kind;
  let stocks = snapshot.parsed.stocks;
  if (wanted) {
    stocks = stocks.filter((stock) => globMatch(wanted, stock.name));
  }
  if (kind) {
    stocks = stocks.filter((stock) => stock.kind === kind);
  }
  if (wanted && stocks.length === 0) {
    const known = snapshot.parsed.stocks.map((stock) => stock.name).join(", ");
    return "No stock matches " + wanted + ". Known stocks: " + (known || "none") + ".";
  }

  const lines = [];
  for (const stock of stocks) {
    lines.push(stockLine(stock));
    const entries = snapshot.parsed.entries
      .filter((entry) => entry.stock === stock.name)
      .sort((left, right) => Number(right.count || right.amount || 0) - Number(left.count || left.amount || 0));
    for (const entry of entries) {
      const amount = entry.kind === "fluid"
        ? formatNumber(entry.amount) + " mB"
        : "x" + formatNumber(entry.count);
      const damage = entry.damage && entry.damage !== "0" ? " (damage " + entry.damage + ")" : "";
      lines.push("  - " + (entry.label || entry.key) + " " + amount + damage);
    }
    if (entries.length === 0) lines.push("  - (empty)");
  }
  lines.push("source: plant.snapshot over the External Link, received " + snapshot.received);
  return lines.join("\n");
}

async function toolAlarmList(args) {
  const alarms = await ensurePlant("alarms", "plant.alarms");
  const since = Number(args.since);
  const list = alarms.parsed.alarms.filter((alarm) =>
    !Number.isFinite(since) || Number(alarm.last) >= since);
  if (list.length === 0) {
    return (alarms.parsed.alarms.length === 0
      ? "No active alarms."
      : "No alarms at or after ring time " + formatNumber(since) + ".") +
      "\nsource: plant.alarms over the External Link";
  }
  const lines = list.map((alarm) =>
    alarm.code + " " + alarm.source + " (" + alarm.severity + "): " + alarm.message +
    " [first " + formatNumber(alarm.first) + ", last " + formatNumber(alarm.last) + "]");
  lines.push("source: plant.alarms over the External Link");
  return lines.join("\n");
}

async function toolHistory(args) {
  const fields = [];
  if (args.stock) fields.push("stock=" + args.stock);
  if (args.limit) fields.push("n=" + String(Math.floor(Number(args.limit))));
  const history = await ensurePlant("history", "plant.history", fields, 5);
  const lines = [];
  for (const stock of history.parsed.stocks || []) {
    lines.push(stock.name + ": " + stock.samples + " samples, rate " +
      (stock.rate === undefined ? "?" : formatRate(stock.rate) + "/min") +
      (stock.trend === undefined ? "" : ", trend " + formatRate(stock.trend) + "%"));
    const samples = (history.parsed.sample || []).filter((sample) => sample.stock === stock.name);
    for (const sample of samples) {
      lines.push("  t=" + formatNumber(sample.t) + " total=" + formatNumber(sample.total) +
        " (" + sample.state + ")");
    }
  }
  if (lines.length === 0) {
    lines.push("No history samples for " + (args.stock || "any stock") + ".");
  }
  lines.push("source: plant.history over the External Link; times are ring seconds, not wall clock");
  return lines.join("\n");
}

async function toolPlan(args) {
  const target = String(args.target || "").trim();
  if (!target) throw new Error("plan needs a target, for example item gregtech:machine_casing@4");
  const qty = args.qty === undefined ? 1 : Math.floor(Number(args.qty));
  if (!Number.isFinite(qty) || qty < 1) throw new Error("qty must be a positive whole number");
  const fields = ["target=" + target, "qty=" + String(qty)];

  const block = await queueAndWait(options, "plant.plan", fields, 20);
  if (block.state !== "ok") {
    throw new Error("plant.plan failed: " + (block.reason || block.state));
  }
  const parsed = parsePlantBody(block.body);
  if (!parsed) throw new Error("plant.plan returned a body this server does not understand");
  const values = parsed.fields;
  const lines = [
    "Plan for " + values.qty + " " + values.target,
    "Bottleneck: " + (values.bottleneck || "none") + " (" +
      formatRate(values.rate) + " targets/s), " + formatNumber(values.seconds) + " s",
  ];
  if ((parsed.step || []).length === 0) {
    lines.push("The cached stock already covers this target; no crafts are needed.");
  } else {
    lines.push("Steps:");
    for (const step of parsed.step) {
      lines.push("- " + step.recipe + " (" + step.machine + "): " +
        step.crafts + " crafts, " + formatNumber(step.seconds) + " s, status " + step.status);
    }
  }
  if ((parsed.shortfall || []).length > 0) {
    lines.push("Shortfall:");
    for (const item of parsed.shortfall) {
      const damage = item.damage && item.damage !== "0" ? "@" + item.damage : "";
      lines.push("- " + item.kind + " " + item.key + damage + ": need " +
        formatNumber(item.need) + ", have " + formatNumber(item.have) +
        ", missing " + formatNumber(item.missing));
    }
  } else {
    lines.push("Shortfall: none against the cached stock.");
  }
  lines.push((parsed.warning || []).length === 0
    ? "Warnings: none."
    : "Warnings: " + parsed.warning.map((warning) =>
      warning.code + (warning.recipe ? " " + warning.recipe : "") +
      (warning.ratio ? " (" + warning.ratio + ")" : "")).join(", "));
  lines.push("source: plant.plan over the External Link, read from cached stock; no component call");
  return lines.join("\n");
}

function pathText(parsed, title) {
  const paths = parsed.path || [];
  if (paths.length === 0) {
    return title + ": no paths configured.\nsource: plant.paths over the External Link";
  }
  const lines = paths.map((entry) =>
    entry.name + ": " + entry.cardinality + ", " + entry.members + " member(s), " +
    entry.stocks + " stock(s), " + (entry.bound === "1" ? "bound" : "unbound"));
  lines.push("source: plant.paths over the External Link; addresses stay on the node");
  return title + ":\n" + lines.join("\n");
}

async function toolPathList() {
  const paths = await ensurePlant("paths", "plant.paths", [], 10);
  return pathText(paths.parsed, "Paths");
}

async function toolPathQuery(args) {
  const path = String(args.path || "").trim();
  if (!path) throw new Error("path_query needs a path name or glob");
  const paths = await ensurePlant("paths", "plant.paths", ["path=" + path], 10);
  return pathText(paths.parsed, "Path " + path);
}

async function toolRecipeQuery(args) {
  const fields = [];
  if (args.recipe) fields.push("recipe=" + args.recipe);
  const booked = await ensurePlant("book", "plant.book", fields, 30);
  let recipes = booked.parsed.recipe || [];
  if (args.output) {
    const wanted = String(args.output);
    const [kind, keyText] = wanted.includes(" ")
      ? wanted.split(/\s+/, 2)
      : [null, wanted];
    const key = keyText.replace(/@\d+$/, "");
    const damage = /@(\d+)$/.exec(keyText);
    recipes = recipes.filter((recipe) => (booked.parsed.io || []).some((item) => {
      if (item.recipe !== recipe.id || item.side !== "out") return false;
      if (kind && item.kind !== kind) return false;
      if (item.key !== key) return false;
      return damage === null || item.damage === damage[1];
    }));
  }
  if (recipes.length === 0) {
    return "No recipe matches " + (args.recipe || args.output || "the filter") + ".";
  }

  const lines = [];
  for (const recipe of recipes) {
    lines.push(recipe.id + " (" + recipe.label + "): " + recipe.machine +
      ", " + recipe.ticks + " ticks, status " + recipe.status +
      (recipe.ratio && recipe.ratio !== "1.0000" ? ", ratio " + recipe.ratio : ""));
    for (const item of (booked.parsed.io || []).filter((io) => io.recipe === recipe.id)) {
      const amount = item.qty + " " + item.kind + " " + item.key +
        (item.damage && item.damage !== "0" ? "@" + item.damage : "");
      lines.push("  " + item.side + " " + amount +
        (item.chance && item.chance !== "1.0000" ? " (" + item.chance + ")" : ""));
    }
  }
  lines.push("source: plant.book over the External Link");
  return lines.join("\n");
}

async function toolAuditTail(args) {
  const n = Math.max(1, Math.min(200, Math.floor(Number(args.n) || 40)));
  const block = await queueAndWait(options, "log", ["n=" + String(n)], 20);
  if (block.state !== "ok") throw new Error("log failed: " + (block.reason || block.state));
  const body = block.body.trim();
  return (body === "" ? "The log is empty." : body) +
    "\nsource: log n=" + n + " from the node";
}

const HANDLERS = {
  plant_situation: () => toolPlantSituation(),
  stock_query: (args) => toolStockQuery(args || {}),
  alarm_list: (args) => toolAlarmList(args || {}),
  history: (args) => toolHistory(args || {}),
  plan: (args) => toolPlan(args || {}),
  path_list: () => toolPathList(),
  path_query: (args) => toolPathQuery(args || {}),
  recipe_query: (args) => toolRecipeQuery(args || {}),
  audit_tail: (args) => toolAuditTail(args || {}),
};

function send(message) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

async function handle(request) {
  if (request.id === undefined) {
    return; // notification
  }
  const { id, method, params } = request;
  try {
    if (method === "initialize") {
      send({
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: params && params.protocolVersion ? params.protocolVersion : PROTOCOL,
          capabilities: { tools: {} },
          serverInfo: { name: "terracorp-plant", version: VERSION },
        },
      });
      return;
    }
    if (method === "ping") {
      send({ jsonrpc: "2.0", id, result: {} });
      return;
    }
    if (method === "tools/list") {
      send({ jsonrpc: "2.0", id, result: { tools: TOOLS } });
      return;
    }
    if (method === "tools/call") {
      const name = params && params.name;
      const handler = HANDLERS[name];
      if (!handler) {
        send({
          jsonrpc: "2.0",
          id,
          result: {
            content: [{ type: "text", text: "Unknown tool: " + String(name) }],
            isError: true,
          },
        });
        return;
      }
      try {
        const text = await handler(params.arguments || {});
        send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text }] } });
      } catch (error) {
        send({
          jsonrpc: "2.0",
          id,
          result: {
            content: [{ type: "text", text: "Read failed: " + error.message }],
            isError: true,
          },
        });
      }
      return;
    }
    send({
      jsonrpc: "2.0",
      id,
      error: { code: -32601, message: "Method not found: " + String(method) },
    });
  } catch (error) {
    send({
      jsonrpc: "2.0",
      id,
      error: { code: -32603, message: String(error.message || error) },
    });
  }
}

function main() {
  if (options.help) {
    console.error("Usage: node tools/bridge/mcp.js [--bridge URL] [--token T] [--node ADDR]");
    return;
  }
  if (!options.token || !options.node) {
    console.error("mcp: no token or node configured; pass --token/--node or write .link/");
    process.exit(1);
  }
  const rl = readline.createInterface({ input: process.stdin, terminal: false });
  rl.on("line", (line) => {
    if (!line.trim()) return;
    let request;
    try {
      request = JSON.parse(line);
    } catch {
      return;
    }
    handle(request);
  });
}

main();
