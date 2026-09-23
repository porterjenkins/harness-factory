#!/usr/bin/env node
/**
 * Screen one markdown note and show what happened.
 *
 * This is the inspection tool for the redaction engine: it runs the exact same
 * code path export.mjs runs, on a file you choose, and prints what each layer
 * did rather than only the result. Use it on a fixture from tests/notes/ to see
 * a category behave, or on a real exported note to check a rule before turning
 * screening on for the whole vault.
 *
 *   node redact/screen.mjs <note.md> [options]
 *
 *   --lexical      local pass only -- no model call, instant
 *   --trace        show each changed chunk, layer by layer
 *   --body         print only the body, not the frontmatter
 *   --json         machine-readable {redactions, categories, text}
 *
 * Nothing is written. The note on disk is never modified.
 */

import fs from "node:fs";
import crypto from "node:crypto";

import { redactNote, splitFrontmatter } from "./index.mjs";

const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const file = argv.find((a) => !a.startsWith("--"));

if (!file) {
  console.error("usage: node redact/screen.mjs <note.md> [--lexical] [--trace] [--body] [--json]");
  process.exit(2);
}

const text = fs.readFileSync(file, "utf8");

// Exactly what export.mjs computes per note before deciding whether to screen.
const sourceHash = crypto.createHash("sha256").update(text).digest("hex");

const trace = [];
const out = await redactNote(text, {
  sourceHash,
  semantic: !has("--lexical"),
  trace,
});

if (has("--json")) {
  console.log(JSON.stringify({ redactions: out.redactions, categories: out.categories, text: out.text }, null, 2));
  process.exit(0);
}

if (has("--trace")) {
  const changed = trace.filter((t) => t.lexical !== t.original || t.semantic);
  console.log(`\x1b[1m── trace ── ${changed.length} of ${trace.length} chunk(s) changed\x1b[0m`);
  for (const t of changed) {
    console.log(`\n\x1b[2mchunk ${t.index} (${t.kind})\x1b[0m`);
    console.log(`  \x1b[31moriginal \x1b[0m ${t.original}`);
    if (t.lexical !== t.original) console.log(`  \x1b[33mlexical  \x1b[0m ${t.lexical}`);
    if (t.semantic) console.log(`  \x1b[32msemantic \x1b[0m ${t.semantic}`);
  }
  console.log("");
}

console.log(has("--body") ? splitFrontmatter(out.text).body.trimEnd() : out.text.trimEnd());

console.error(
  `\n${out.redactions} redaction(s)` +
    (out.categories.length ? ` in ${out.categories.join(", ")}` : "") +
    ` · ${has("--lexical") ? "lexical" : "lexical+semantic"} · nothing written`
);
