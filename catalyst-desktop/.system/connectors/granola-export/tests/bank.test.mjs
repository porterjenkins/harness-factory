import assert from "node:assert/strict";
import crypto from "node:crypto";
import test from "node:test";

import {
  CATEGORIES,
  MODEL,
  PROMPT_VERSION,
  marker,
  readFrontmatterScalar,
  redactNote,
  splitFrontmatter,
} from "../redact/index.mjs";
import { isNegative, loadBank } from "./helpers.mjs";

const hash = (s) => crypto.createHash("sha256").update(s).digest("hex");

// Never shells out to `claude`. Same policy as the wiki pipeline's tagger tests:
// a suite that needs a signed-in CLI is a suite nobody runs.
const silentInvoker = async () => "[]";
const screenLexical = (fx) =>
  redactNote(fx.text, { sourceHash: hash(fx.text), semantic: false });
const screenBoth = (fx, invoker = silentInvoker) =>
  redactNote(fx.text, { sourceHash: hash(fx.text), invoker });

test("negatives survive the lexical pass untouched", async () => {
  for (const fx of loadBank().filter(isNegative)) {
    const out = await screenLexical(fx);
    assert.equal(out.redactions, 0, `${fx.file} redacted benign text:\n${out.text}`);
    assert.deepEqual(out.categories, [], fx.file);
    assert.equal(
      splitFrontmatter(out.text).body,
      splitFrontmatter(fx.text).body,
      `${fx.file}: body changed despite zero redactions`
    );
  }
});

test("positives are caught with the expected categories", async () => {
  for (const fx of loadBank().filter((f) => !isNegative(f))) {
    const out = await screenLexical(fx);
    assert.ok(
      out.redactions >= fx.expectMinRedactions,
      `${fx.file}: ${out.redactions} redactions, expected >= ${fx.expectMinRedactions}`
    );
    for (const c of fx.expectCategories) {
      assert.ok(out.categories.includes(c), `${fx.file}: missing category ${c}, got ${out.categories}`);
    }
  }
});

test("no sensitive term survives into a screened positive", async () => {
  // Spot-check the literal strings a reviewer would grep for.
  const banned = {
    "abuse-disclosure-positive.md": ["mandatory reporter", "failure to report", "hotline"],
    "criminal-felony-positive.md": ["felony", "docket", "arrested", "plea"],
    "financial-embezzlement-positive.md": ["Embezzlement", "$18,400", "restitution"],
    "pii-positive.md": ["123-45-6789", "4111 1111 1111 1111", "nathan.doe@example.com", "555-0134"],
    "employment-pip-positive.md": ["performance improvement plan", "PIP", "administrative leave"],
  };
  const bank = new Map(loadBank().map((f) => [f.file, f]));
  for (const [file, terms] of Object.entries(banned)) {
    // Body only: a fixture's own `case:` key legitimately names the term it
    // tests, and frontmatter is not screened.
    const body = splitFrontmatter((await screenLexical(bank.get(file))).text).body;
    for (const t of terms) {
      assert.equal(body.includes(t), false, `${file}: "${t}" survived screening`);
    }
  }
});

test("the marker names a category and carries no link", async () => {
  for (const fx of loadBank()) {
    const body = splitFrontmatter((await screenLexical(fx)).text).body;
    for (const m of body.match(/\[REDACTED[^\]]*\]/g) || []) {
      assert.match(m, /^\[REDACTED · (\w+)\]$/, `marker carries more than a category: ${m}`);
      assert.equal(/https?:|granola_id|see /.test(m), false, `marker still links: ${m}`);
    }
  }
  const withUrl = loadBank().find((f) => f.file === "hardship-divorce-positive.md");
  assert.ok((await screenLexical(withUrl)).text.includes(marker("hardship")));
});

test("the pointer to the original lives in frontmatter, once per note", async () => {
  const bank = new Map(loadBank().map((f) => [f.file, f]));

  // A note Granola gave a web url keeps it.
  const withUrl = bank.get("mixed-positive.md");
  const out = await screenLexical(withUrl);
  assert.equal(readFrontmatterScalar(out.text, "granola_url").replace(/^"|"$/g, ""), withUrl.url);
  assert.ok(out.redactions >= 6, "expected several redactions in this note");
  // ...exactly once, however many passages were redacted.
  assert.equal((out.text.match(/granola_url:/g) || []).length, 1);

  // A note without one is still traceable by id.
  const noUrl = bank.get("no-url-positive.md");
  assert.equal(noUrl.url, null);
  const out2 = await screenLexical(noUrl);
  assert.equal(readFrontmatterScalar(out2.text, "granola_url"), null);
  assert.equal(readFrontmatterScalar(out2.text, "granola_id"), noUrl.id);
  assert.ok(out2.redactions > 0, "fixture should redact");
});

test("markers are single-bracketed so Obsidian does not read them as wikilinks", async () => {
  for (const fx of loadBank()) {
    const out = await screenLexical(fx);
    assert.equal(/\[\[REDACTED/.test(out.text), false, fx.file);
  }
});

test("document structure survives screening", async () => {
  const bullets = (s) => (s.match(/^[ \t]*[-*+] /gm) || []).length;
  const headings = (s) => (s.match(/^#{1,6} /gm) || []).length;
  for (const fx of loadBank()) {
    // Body only -- `flag_categories` is itself a YAML sequence and would count
    // as bullets.
    const after = splitFrontmatter((await screenLexical(fx)).text).body;
    const before = splitFrontmatter(fx.text).body;
    assert.equal(bullets(after), bullets(before), `${fx.file}: bullet count changed`);
    assert.equal(headings(after), headings(before), `${fx.file}: heading count changed`);
  }
});

test("frontmatter is stamped and machine-readable", async () => {
  for (const fx of loadBank()) {
    const out = await screenBoth(fx);
    const src = hash(fx.text);
    assert.equal(readFrontmatterScalar(out.text, "screened"), "true", fx.file);
    assert.equal(readFrontmatterScalar(out.text, "screened_mode"), "lexical+semantic", fx.file);
    assert.equal(readFrontmatterScalar(out.text, "screened_version"), `"${PROMPT_VERSION}"`, fx.file);
    assert.equal(readFrontmatterScalar(out.text, "redactions"), String(out.redactions), fx.file);
    assert.equal(readFrontmatterScalar(out.text, "source_hash"), src, fx.file);

    // The original keys are still there, in their original order -- downstream
    // skills parse this shape.
    const fm = splitFrontmatter(out.text).fm.join("\n");
    assert.match(fm, /^title:/m, fx.file);
    assert.match(fm, /^source: granola$/m, fx.file);
    assert.ok(fm.indexOf("title:") < fm.indexOf("screened:"), `${fx.file}: keys reordered`);

    if (out.categories.length) {
      assert.match(fm, /^flag_categories:$/m, fx.file);
      for (const c of out.categories) assert.match(fm, new RegExp(`^ {2}- ${c}$`, "m"), fx.file);
    } else {
      assert.equal(/^flag_categories:$/m.test(fm), false, fx.file);
    }
  }
});

test("flag_categories is emitted in a stable order regardless of discovery order", async () => {
  const fx = loadBank().find((f) => f.file === "mixed-positive.md");
  const out = await screenLexical(fx);
  const listed = [...out.text.matchAll(/^ {2}- (\w+)$/gm)].map((m) => m[1]);
  assert.deepEqual(listed, CATEGORIES.filter((c) => listed.includes(c)));
  assert.ok(listed.length >= 3, `expected 3+ categories, got ${listed}`);
});

test("screening is deterministic: same input, same bytes", async () => {
  for (const fx of loadBank()) {
    const a = await screenLexical(fx);
    const b = await screenLexical(fx);
    assert.equal(a.text, b.text, `${fx.file} is not deterministic`);
  }
});

test("screened_mode records which layers actually ran", async () => {
  const fx = loadBank()[0];
  assert.equal(readFrontmatterScalar((await screenLexical(fx)).text, "screened_mode"), "lexical");
  assert.equal(readFrontmatterScalar((await screenBoth(fx)).text, "screened_mode"), "lexical+semantic");
});

test("a note with no frontmatter is refused rather than screened", async () => {
  await assert.rejects(
    () => redactNote("# Just a body\n", { ref: "x", sourceHash: "y", semantic: false }),
    /no frontmatter/
  );
});

test("trace records what each layer did, per chunk", async () => {
  const fx = loadBank().find((f) => f.file === "abuse-age-relationship-positive.md");
  const trace = [];
  await redactNote(fx.text, {
    sourceHash: hash(fx.text),
    invoker: async (prompt) => {
      // Matched on text that SURVIVES the lexical pass: "14-year-old" is
      // already a marker by the time the model sees this chunk.
      const chunks = [...prompt.matchAll(/### CHUNK (\d+)\n```\n([\s\S]*?)\n```/g)];
      const target = chunks.find((m) => m[2].includes("after-school"));
      return JSON.stringify([
        { i: Number(target[1]), flag: true, category: "abuse", text: marker("abuse") },
      ]);
    },
    trace,
  });

  // One row per screened chunk, in document order, with the structural ones
  // (blank lines, fences) left out.
  assert.ok(trace.length > 0);
  assert.deepEqual(trace.map((t) => t.index), [...trace.map((t) => t.index)].sort((a, b) => a - b));
  for (const row of trace) {
    assert.ok(typeof row.original === "string" && typeof row.lexical === "string", "row shape");
    assert.ok(["heading", "listItem", "paragraph", "transcriptTurn"].includes(row.kind), row.kind);
  }

  const changed = trace.find((t) => t.original.includes("14-year-old"));
  assert.ok(changed, "the sensitive chunk was not traced");
  assert.match(changed.lexical, /REDACTED · abuse/, "lexical step not recorded");
  assert.equal(changed.semantic, marker("abuse"), "semantic step not recorded");

  // Untouched chunks carry no semantic step at all.
  const untouched = trace.find((t) => t.original.includes("Volunteer rotation"));
  assert.equal(untouched.lexical, untouched.original);
  assert.equal(untouched.semantic, undefined);
});

test("omitting trace changes nothing about the result", async () => {
  const fx = loadBank().find((f) => f.file === "mixed-positive.md");
  const opts = { sourceHash: hash(fx.text), semantic: false };
  const withTrace = await redactNote(fx.text, { ...opts, trace: [] });
  const without = await redactNote(fx.text, opts);
  assert.equal(withTrace.text, without.text);
});

test("the screening model is pinned and recorded on the note", async () => {
  const fx = loadBank().find((f) => f.file === "hardship-divorce-positive.md");

  // Recorded when a model ran...
  const both = await redactNote(fx.text, { sourceHash: hash(fx.text), invoker: async () => "[]" });
  assert.equal(readFrontmatterScalar(both.text, "screened_model"), MODEL);
  assert.match(MODEL, /^claude-[a-z0-9-]+$/, "model must be an explicit id, not a CLI default");

  // ...and absent when none did, rather than claiming a model that never saw it.
  const lex = await redactNote(fx.text, { sourceHash: hash(fx.text), semantic: false });
  assert.equal(readFrontmatterScalar(lex.text, "screened_model"), null);
  assert.equal(readFrontmatterScalar(lex.text, "screened_mode"), "lexical");
});
