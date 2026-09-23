/**
 * Semantic screening: one `claude -p` call per changed note.
 *
 * The lexical layer only catches what someone wrote down in so many words. A
 * transcript that circles a firing for two paragraphs without ever using a
 * listed term reads exactly like the material the review found, and no keyword
 * bank will ever cover it. This layer classifies each chunk and rewrites the
 * flagged ones.
 *
 * It is ONE call carrying every chunk, not one call per chunk. The export loop
 * is serial with a 260ms pace under the API's 5 req/s budget, so per-chunk calls
 * would multiply a run by the chunk count -- for a note with a transcript, by a
 * few hundred. The classifier is still per chunk; the round trip is not.
 *
 * Invocation follows lib/llm.sh and wiki/tagger.py: no tools, no skills, no
 * session state, replaced system prompt. A screener that can read the vault will
 * happily wander off into it.
 */

import { spawn } from "node:child_process";
import { CATEGORIES } from "./lexical.mjs";

// Stamped into frontmatter as `screened_version`. When the prompt changes, the
// notes screened under the old one are identifiable instead of indistinguishable.
export const PROMPT_VERSION = "2";

const CLAUDE_BIN = process.env.GRANOLA_CLAUDE_BIN || "claude";

// Pinned, not left to the CLI default. Unpinned, screening ran on whatever each
// machine happened to have configured, so the same note could be screened
// differently on the laptop and the desktop -- and a missed redaction is the one
// failure this feature exists to prevent.
//
// Opus over the smaller models on measured recall, not on reputation. Against
// the one bank fixture whose sensitive material is entirely implied -- nothing a
// keyword can reach -- opus caught both passages in 10 of 10 runs, haiku in 13
// of 15, sonnet in 6 of 10. All three were clean on every negative, so this is
// the only axis that separates them. Re-measure with tests/notes/ before
// changing it. Override per-machine with GRANOLA_REDACTION_MODEL.
export const MODEL = process.env.GRANOLA_REDACTION_MODEL || "claude-opus-5";
const TIMEOUT_MS = Number(process.env.GRANOLA_REDACTION_TIMEOUT || 300) * 1000;

// The prompt travels through argv, which is capped (ARG_MAX, ~1MB on macOS). A
// note with a long transcript blows past that, and the failure is an opaque
// E2BIG from spawn rather than anything that names the cause. Splitting into
// sequential batches is the only case that produces more than one call per note.
const MAX_PROMPT_BYTES = 300_000;

const SYSTEM = `You screen meeting notes for sensitive material before they are filed
in a personal knowledge vault. You are a text transformer, not an agent.

You will be given numbered chunks of one meeting note. For EACH chunk decide
whether it contains material in any of these categories:

- abuse: allegations of abuse, assault, grooming, or misconduct involving a
  minor; disclosures; reporting failures; contact with child protective services
  or law enforcement about such a matter.
- discipline: ecclesiastical discipline -- councils, restriction of membership or
  callings, formal church action.
- criminal: arrests, charges, indictments, convictions, pleas, sentencing,
  warrants, probation or parole in the legal sense.
- financial: embezzlement, misappropriation, misuse of funds, unauthorized
  transactions, audit findings of wrongdoing, restitution, fraud -- including the
  amounts and accounts involved.
- hardship: divorce or marital separation, bankruptcy, terminal illness, hospice,
  suicide, overdose, addiction or relapse, miscarriage, the death of a child.
- employment: performance improvement plans, terminations, administrative leave,
  requested resignations, demotions, separation agreements, non-disclosure terms.
- pii: government identifiers, payment card numbers, personal email addresses or
  phone numbers belonging to someone other than the meeting's own participants.
  Reference numbers are NOT pii, however long: order numbers, invoice and ticket
  references, shipment and account ids. A local pass has already run over this
  text and has already removed every government id, every email address, every
  phone number, and every payment card -- cards are checked arithmetically, not
  by shape. So a bare run of digits still visible here has already been examined
  and is not a card and not an identifier. Leave it alone.

Flag a chunk ONLY when it is about an identifiable person's situation. Ordinary
business and engineering language is not sensitive: API abuse, terminating a
process or an instance, investigating a bug, a SOC 2 audit finding, budget
figures, a discrepancy in a metric, separation of concerns, reassigning a ticket,
an order or ticket number.
When in doubt about whether something is business-as-usual, do not flag it.

For each flagged chunk, return the chunk rewritten with every sensitive passage
replaced by the marker given in the prompt. Replace as much as the sensitive
meaning spans -- a phrase, a sentence, or the entire chunk -- and leave the
surrounding non-sensitive text exactly as it was, character for character. Do not
summarise, reword, correct, or reformat anything you are not redacting. Keep any
existing marker already present in the text.

Return ONLY a JSON array, one object per chunk you were given:

[{"i": 0, "flag": false}, {"i": 1, "flag": true, "category": "abuse", "text": "..."}]

Output nothing but the JSON array.`;

export function buildPrompt(items, marker) {
  const parts = [
    `Marker to use: ${marker}`,
    "Substitute the correct category name into the marker where it says CATEGORY.",
    "",
    "## Chunks",
  ];
  for (const it of items) {
    parts.push("", `### CHUNK ${it.i}`, "```", it.core, "```");
  }
  return parts.join("\n");
}

/**
 * Tolerate a fenced block and surrounding chatter around the JSON.
 * Ported from wiki/tagger.py:_extract_json -- same failure, same fix.
 */
export function extractJson(text) {
  let t = String(text).trim();
  const fence = t.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fence) t = fence[1].trim();
  try {
    return JSON.parse(t);
  } catch {
    /* fall through to bracket scanning */
  }
  for (const [open, close] of [["[", "]"], ["{", "}"]]) {
    let start = -1;
    let depth = 0;
    for (let i = 0; i < t.length; i++) {
      if (t[i] === open) {
        if (depth === 0) start = i;
        depth++;
      } else if (t[i] === close) {
        depth--;
        if (depth === 0 && start >= 0) {
          try {
            return JSON.parse(t.slice(start, i + 1));
          } catch {
            start = -1;
          }
        }
      }
    }
  }
  throw new Error(`no JSON found in screener output: ${t.slice(0, 300)}`);
}

/** Default invoker: shell out to `claude -p`. Tests replace this wholesale. */
export function invoke(prompt) {
  return new Promise((resolve, reject) => {
    const env = { ...process.env };
    // Inherited from an interactive Claude Code session, this makes the child
    // try to attach to the parent's transport instead of running standalone.
    delete env.CLAUDE_CODE_SSE_PORT;

    const child = spawn(
      CLAUDE_BIN,
      [
        "-p", prompt,
        "--model", MODEL,
        "--output-format", "text",
        "--system-prompt", SYSTEM,
        "--disallowed-tools", "Read Write Edit Glob Grep WebSearch WebFetch Task Agent",
        "--disable-slash-commands",
        "--strict-mcp-config",
        "--no-session-persistence",
      ],
      // stdin MUST be closed, not inherited. `claude -p` waits ~3s for piped
      // stdin and then errors; under launchd there is no stdin at all, so
      // without this every scheduled run fails.
      { env, stdio: ["ignore", "pipe", "pipe"] }
    );

    let out = "";
    let err = "";
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
    }, TIMEOUT_MS);

    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("error", (e) => {
      clearTimeout(timer);
      reject(new Error(`claude could not be started: ${e.message}`));
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (timedOut) return reject(new Error(`claude -p timed out after ${TIMEOUT_MS / 1000}s`));
      if (code !== 0) return reject(new Error(`claude -p failed (${code}): ${(err || out).trim().slice(0, 400)}`));
      resolve(out);
    });
  });
}

function batches(items, marker) {
  const out = [];
  let current = [];
  for (const it of items) {
    const next = current.concat(it);
    if (current.length && Buffer.byteLength(buildPrompt(next, marker)) > MAX_PROMPT_BYTES) {
      out.push(current);
      current = [it];
    } else {
      current = next;
    }
  }
  if (current.length) out.push(current);
  return out;
}

/**
 * Classify and rewrite. `items` is [{ i, core }]; returns a Map i -> { category, text }
 * for flagged chunks only.
 *
 * Throws on any failure. The caller fails closed on that: a note is never
 * written half-screened, because a note that looks screened and is not is worse
 * than one that was obviously never processed.
 */
export async function screen(items, marker, invoker = invoke) {
  const flagged = new Map();
  if (items.length === 0) return flagged;

  const byIndex = new Map(items.map((it) => [it.i, it]));

  for (const batch of batches(items, marker)) {
    const raw = await invoker(buildPrompt(batch, marker));
    const data = extractJson(raw);
    if (!Array.isArray(data)) throw new Error("screener did not return a JSON array");

    for (const row of data) {
      if (!row || typeof row !== "object") continue;
      const i = Number(row.i);
      if (!byIndex.has(i)) continue;
      if (row.flag !== true) continue;
      const category = String(row.category || "").trim().toLowerCase();
      const text = typeof row.text === "string" ? row.text : null;
      // A flag with no replacement text is not actionable, and a category
      // outside the closed set would produce a marker nobody can review by
      // category. Dropping both is safe: the lexical pass already ran.
      if (!text || !CATEGORIES.includes(category)) continue;
      flagged.set(i, { category, text });
    }
  }
  return flagged;
}

export { SYSTEM };
