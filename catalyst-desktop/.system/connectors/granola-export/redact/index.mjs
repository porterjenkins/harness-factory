/**
 * Redaction orchestration: frontmatter split -> chunk -> lexical -> semantic ->
 * reassemble, then stamp the frontmatter so the note is visibly machine-screened.
 *
 * The note is never edited in place and never partially written. redactNote()
 * either returns a complete screened document or throws, and export.mjs writes
 * nothing when it throws. A note that looks screened and is not is worse than a
 * note that was obviously never processed.
 */

import { chunk, join, parts, rebuild, REDACTABLE } from "./chunk.mjs";
import { CATEGORIES, redact as lexicalRedact } from "./lexical.mjs";
import { MODEL, PROMPT_VERSION, screen } from "./semantic.mjs";

export { CATEGORIES, MODEL, PROMPT_VERSION };

// Single brackets, not double: `[[...]]` is an Obsidian wikilink, and a marker
// that renders as a broken link to a page named "REDACTED" is noise in every
// backlink pane in the vault.
//
// The marker carries no link. Where to find the unredacted original is a
// property of the note, not of each passage, and it is already in frontmatter
// as `granola_url` (or `granola_id` for a note Granola gave no web url).
// Repeating a 70-character url inside every marker buried the one thing the
// marker is for -- which category was hit -- and a note with six redactions
// carried the same url six times.
export function marker(category) {
  return `[REDACTED · ${category}]`;
}

// What the semantic layer is told to emit; it substitutes the category itself.
export const MARKER_TEMPLATE = marker("CATEGORY");

const MARKER_RE = /\[REDACTED · [^\]]*\]/g;

function countMarkers(s) {
  return (s.match(MARKER_RE) || []).length;
}

// How much real text a chunk still carries, markers not counted. This is what
// decides whether a model rewrite actually redacted anything: counting markers
// alone is wrong in both directions. A chunk the lexical layer already marked
// can be legitimately collapsed to ONE marker covering the whole sentence --
// more redacted, same marker count -- and a rewrite that merely reflows the text
// can carry the marker through while redacting nothing new.
// Canonicalise whatever the model emitted. It is told to substitute a category
// into `[REDACTED · CATEGORY]`, and a model will happily hand back
// `[REDACTED · EMPLOYMENT]` -- sonnet does, haiku does not. Marker casing that
// depends on which model ran breaks `grep` and makes two notes screened by
// different models look like different formats. An unrecognised category inside
// a marker falls back to the one the verdict declared, which is validated.
function normalizeMarkers(text, fallback) {
  return text.replace(MARKER_RE, (m) => {
    const inner = m.slice("[REDACTED · ".length, -1).trim().toLowerCase();
    return marker(CATEGORIES.includes(inner) ? inner : fallback);
  });
}

function visibleLength(s) {
  return s.replace(MARKER_RE, "").replace(/\s+/g, " ").trim().length;
}

/**
 * Split an exported note into its frontmatter lines and its body.
 * Deliberately not a YAML parser: the connector has no dependencies, and the
 * frontmatter it reads is the frontmatter it just wrote.
 */
export function splitFrontmatter(md) {
  const m = md.match(/^---\n([\s\S]*?)\n---\n/);
  if (!m) return { fm: null, body: md };
  return { fm: m[1].split("\n"), body: md.slice(m[0].length) };
}

export function readFrontmatterScalar(md, key) {
  const { fm } = splitFrontmatter(md);
  if (!fm) return null;
  const re = new RegExp(`^${key}:[ \\t]*(.*)$`);
  for (const line of fm) {
    const hit = line.match(re);
    if (hit) return hit[1].trim();
  }
  return null;
}

/**
 * Screen one rendered note.
 *
 * opts: { sourceHash, semantic = true, invoker }
 *   trace      optional array. Each screened chunk is pushed as
 *              { index, kind, original, lexical, semantic }, which is how
 *              screen.mjs shows what each layer did. Collecting it here rather
 *              than reconstructing it afterwards keeps the tool exact: a model
 *              rewrite can change a chunk's line count, so re-chunking the
 *              output and pairing it up by position would silently misalign.
 *   sourceHash contentHash() of this same unredacted markdown. Stored as
 *              `source_hash` so the next run can tell whether the SOURCE
 *              changed. Comparing the rendered file instead would compare
 *              non-deterministic model output against itself and rewrite -- and
 *              re-screen, and re-pay for -- every note on every 30-minute run.
 */
export async function redactNote(md, opts) {
  const { sourceHash, semantic = true, invoker, trace } = opts;
  const { fm, body } = splitFrontmatter(md);
  if (!fm) throw new Error("note has no frontmatter; refusing to screen");

  const nodes = chunk(body);
  const categories = new Set();
  let redactions = 0;

  // Layer one. Authoritative: the semantic layer may add redactions but never
  // reverses one, so lexical results are applied before the model sees anything.
  const cores = new Map();
  for (const node of nodes) {
    if (!REDACTABLE.has(node.kind)) continue;
    const { core } = parts(node);
    const { text, hits } = lexicalRedact(core, marker);
    for (const h of hits) categories.add(h);
    redactions += hits.length;
    cores.set(node.index, text);
    if (trace) trace.push({ index: node.index, kind: node.kind, original: core, lexical: text });
  }

  // Layer two. The model sees the lexically-redacted text, so it is not
  // re-flagging material layer one already handled.
  if (semantic) {
    const items = [];
    for (const node of nodes) {
      if (!cores.has(node.index)) continue;
      const core = cores.get(node.index);
      // Nothing left to judge: the chunk is a bare marker already.
      if (core.replace(MARKER_RE, "").trim() === "") continue;
      items.push({ i: node.index, core });
    }
    const flagged = await screen(items, MARKER_TEMPLATE, invoker);
    for (const [i, result] of flagged) {
      const before = cores.get(i);
      const text = normalizeMarkers(result.text, result.category);
      // Accept only a rewrite that left a marker behind AND removed material.
      // Anything else -- no marker, unchanged text, or text that grew, which
      // means the model wrote prose of its own -- is discarded in favour of
      // layer one's output. Keeping the more-redacted version is the safe
      // direction, and layer one is authoritative.
      if (countMarkers(text) < 1) continue;
      if (visibleLength(text) >= visibleLength(before)) continue;
      const added = countMarkers(text) - countMarkers(before);
      cores.set(i, text);
      categories.add(result.category);
      // A consolidating rewrite redacts more while adding no marker, so it still
      // counts as one redaction rather than zero.
      redactions += Math.max(1, added);
      if (trace) {
        const row = trace.find((t) => t.index === i);
        if (row) row.semantic = text;
      }
    }
  }

  const out = nodes.map((node) =>
    cores.has(node.index) ? rebuild(node, cores.get(node.index)) : node.text
  );

  const stamped = fm.slice();
  stamped.push("screened: true");
  stamped.push(`screened_mode: ${semantic ? "lexical+semantic" : "lexical"}`);
  stamped.push(`screened_version: "${PROMPT_VERSION}"`);
  // Which model made the judgement calls. `screened_version` tracks the prompt;
  // this tracks the other half, so a note screened by a model you later stop
  // trusting can be found and re-screened. Omitted when no model ran.
  if (semantic) stamped.push(`screened_model: ${MODEL}`);
  stamped.push(`redactions: ${redactions}`);
  if (categories.size) {
    stamped.push("flag_categories:");
    // Emitted in CATEGORIES order rather than discovery order so the same note
    // always produces the same frontmatter and the idempotency check holds.
    for (const c of CATEGORIES) if (categories.has(c)) stamped.push(`  - ${c}`);
  }
  stamped.push(`source_hash: ${sourceHash}`);

  return {
    text: `---\n${stamped.join("\n")}\n---\n${out.join("")}`,
    redactions,
    categories: CATEGORIES.filter((c) => categories.has(c)),
  };
}
