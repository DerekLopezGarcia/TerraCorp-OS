// Parser for the plant bodies defined in docs/external-link.md.
//
// The bridge uses it to keep a parsed mirror; the MCP server uses it to read
// the result of a queued verb. Both sides must agree, so the parser lives in
// one place.

"use strict";

const PLANT_FORMAT = /^format=plant\.([a-z]+)\.v1$/;

const PLANT_RECORD_TYPES = new Set([
  "stock", "entry", "alarm", "error", "sample", "path",
  "step", "shortfall", "warning", "recipe", "io",
]);

const PLANT_BUCKETS = {
  stock: "stocks",
  entry: "entries",
  alarm: "alarms",
  error: "errors",
};

function decodePlantValue(value) {
  return value.replace(/%([0-9A-Fa-f]{2})/g, (_, hex) =>
    String.fromCharCode(parseInt(hex, 16)));
}

function parsePlantLine(line) {
  const tokens = line.split(" ");
  const record = { type: tokens[0] };
  for (const token of tokens.slice(1)) {
    const equals = token.indexOf("=");
    if (equals > 0) {
      record[token.slice(0, equals)] = decodePlantValue(token.slice(equals + 1));
    }
  }
  return record;
}

function parsePlantBody(body) {
  const lines = body.split("\n").filter((line) => line !== "");
  if (lines.length === 0) return null;
  const head = PLANT_FORMAT.exec(lines[0]);
  if (head === null) return null;

  const parsed = {
    kind: head[1],
    fields: {},
    records: [],
    stocks: [],
    entries: [],
    alarms: [],
    errors: [],
  };

  for (const line of lines.slice(1)) {
    if (line === "snapshot_begin") continue;
    const type = line.slice(0, line.indexOf(" "));
    if (PLANT_RECORD_TYPES.has(type)) {
      const record = parsePlantLine(line);
      const bucket = PLANT_BUCKETS[record.type] || record.type;
      if (parsed[bucket] === undefined) parsed[bucket] = [];
      parsed[bucket].push(record);
      parsed.records.push(record);
      continue;
    }
    const equals = line.indexOf("=");
    if (equals > 0) {
      parsed.fields[line.slice(0, equals)] = decodePlantValue(line.slice(equals + 1));
    }
  }
  return parsed;
}

function isPlantBody(body) {
  return parsePlantBody(body) !== null;
}

module.exports = {
  PLANT_FORMAT,
  PLANT_RECORD_TYPES,
  decodePlantValue,
  parsePlantLine,
  parsePlantBody,
  isPlantBody,
};
