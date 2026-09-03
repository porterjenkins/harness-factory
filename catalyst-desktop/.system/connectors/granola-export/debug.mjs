#!/usr/bin/env node
/**
 * Debug helper: fetches ONE note from the Granola API and dumps its raw shape
 * so we can see which field holds the note body. Writes nothing to your vault.
 *
 * Run:  node debug.mjs        (loads GRANOLA_API_KEY from ../../.env)
 * It prints top-level keys + types, and saves the full JSON to debug-note.json.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DIR = path.dirname(fileURLToPath(import.meta.url));

// Minimal .env loader. Mirrors run.sh: the one shared config file at
// <vault>/.system/.env, filtered to this connector's GRANOLA_ prefix. An
// already-set real environment variable wins over the file.
const VAULT = path.resolve(DIR, "..", "..", "..");
const ENV_PREFIX = "GRANOLA_";

function loadEnv(file, prefix) {
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    return;
  }
  for (const line of text.split("\n")) {
    const m = line.match(/^\s*(?:export\s+)?([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (!m) continue;
    if (!m[1].startsWith(prefix)) continue;
    if (process.env[m[1]]) continue;
    process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
}

loadEnv(path.join(VAULT, ".system", ".env"), ENV_PREFIX);

const API_BASE = "https://public-api.granola.ai/v1";
const KEY = process.env.GRANOLA_API_KEY;
if (!KEY) {
  console.error("No GRANOLA_API_KEY found. Expected it in <vault>/.system/.env");
  process.exit(1);
}

const H = {
  Authorization: `Bearer ${KEY}`,
  "Content-Type": "application/json",
  "User-Agent": "granola-markdown-exporter-debug/1.0",
};

function describe(obj, depth = 0, prefix = "") {
  if (depth > 2) return;
  for (const [k, v] of Object.entries(obj || {})) {
    const t = Array.isArray(v) ? `array[${v.length}]` : typeof v;
    let preview = "";
    if (typeof v === "string") preview = ` = ${JSON.stringify(v.slice(0, 80))}${v.length > 80 ? "…" : ""}`;
    console.log(`${prefix}${k}: ${t}${preview}`);
    if (v && typeof v === "object" && !Array.isArray(v)) describe(v, depth + 1, prefix + "  ");
    if (Array.isArray(v) && v.length && typeof v[0] === "object")
      describe(v[0], depth + 1, prefix + "  [0] ");
  }
}

const listRes = await fetch(`${API_BASE}/notes`, { headers: H });
if (!listRes.ok) {
  console.error(`GET /notes -> ${listRes.status}: ${await listRes.text()}`);
  process.exit(1);
}
const list = await listRes.json();
const first = (list.notes || list.data || [])[0];
if (!first) {
  console.error("No notes returned.");
  process.exit(1);
}
console.log(`\n=== /notes list item, top-level keys ===`);
describe(first);

const detailRes = await fetch(
  `${API_BASE}/notes/${encodeURIComponent(first.id)}?include=transcript`,
  { headers: H }
);
const detail = await detailRes.json();
console.log(`\n=== /notes/${first.id}?include=transcript, top-level keys ===`);
describe(detail);

fs.writeFileSync(path.join(DIR, "debug-note.json"), JSON.stringify(detail, null, 2));
console.log(`\nFull JSON saved to debug-note.json`);
