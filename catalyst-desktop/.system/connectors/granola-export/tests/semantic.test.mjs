import assert from "node:assert/strict";
import test from "node:test";

import { MARKER_TEMPLATE, marker, redactNote, splitFrontmatter } from "../redact/index.mjs";
import { buildPrompt, extractJson, screen } from "../redact/semantic.mjs";

// A note whose sensitive material is entirely implied -- no term in the bank
// appears in it, so the lexical layer cannot touch it. This is the case the
// semantic layer exists for.
const IMPLIED = `---
title: One-on-one
granola_url: https://notes.granola.example/d/abc
granola_id: not_abc
source: granola
---

# 2026-06-02 One-on-one

- He has been coming in late and the team has noticed; we agreed on a written plan with a date on it, and if the date passes we both know what happens next.
- Roadmap review moved to Thursday.
`;

const REF = "https://notes.granola.example/d/abc";
const opts = (invoker) => ({ sourceHash: "h", invoker });

// Parse a prompt back into the chunks it carries, so a stub can answer about
// the chunk it means rather than guessing at an index.
function chunksIn(prompt) {
  return [...prompt.matchAll(/### CHUNK (\d+)\n```\n([\s\S]*?)\n```/g)].map((m) => ({
    i: Number(m[1]),
    core: m[2],
  }));
}

test("extractJson survives fences and surrounding chatter", () => {
  assert.deepEqual(extractJson('[{"i":0,"flag":false}]'), [{ i: 0, flag: false }]);
  assert.deepEqual(extractJson('```json\n[{"i":1,"flag":false}]\n```'), [{ i: 1, flag: false }]);
  assert.deepEqual(
    extractJson('Here you go:\n[{"i":2,"flag":false}]\nHope that helps.'),
    [{ i: 2, flag: false }]
  );
  assert.throws(() => extractJson("no json at all"), /no JSON found/);
});

test("the prompt carries every chunk, indexed, with the marker template", () => {
  const prompt = buildPrompt([{ i: 0, core: "alpha" }, { i: 3, core: "beta" }], MARKER_TEMPLATE);
  assert.match(prompt, /### CHUNK 0/);
  assert.match(prompt, /### CHUNK 3/);
  assert.match(prompt, /alpha/);
  assert.match(prompt, /beta/);
  assert.match(prompt, /CATEGORY/);
  // The marker template the model is told to emit carries no link.
  assert.equal(prompt.includes(REF), false, "the note url leaked into the prompt");
});

test("one call covers the whole note, not one per chunk", async () => {
  let calls = 0;
  await redactNote(IMPLIED, opts(async () => { calls++; return "[]"; }));
  assert.equal(calls, 1);
});

test("a flagged chunk is replaced and its category recorded", async () => {
  const invoker = async (prompt) => {
    const target = chunksIn(prompt).find((c) => c.core.includes("coming in late"));
    return JSON.stringify([
      { i: target.i, flag: true, category: "employment", text: marker("employment") },
    ]);
  };
  const out = await redactNote(IMPLIED, opts(invoker));
  const body = splitFrontmatter(out.text).body;
  assert.equal(body.includes("coming in late"), false, "implied material survived");
  assert.match(body, /Roadmap review moved to Thursday/, "benign chunk was altered");
  assert.deepEqual(out.categories, ["employment"]);
  assert.equal(out.redactions, 1);
  assert.match(body, /^- \[REDACTED · employment/m, "bullet marker was lost");
});

test("the model never sees a chunk the lexical layer already blanked", async () => {
  const note = IMPLIED.replace("Roadmap review moved to Thursday.", "He was arrested Thursday.");
  let sent = "";
  await redactNote(note, opts(async (p) => { sent = p; return "[]"; }));
  assert.equal(sent.includes("arrested"), false, "unredacted term reached the model");
  assert.match(sent, /REDACTED/, "lexical output should be what the model reviews");
});

test("a chunk that is nothing but a marker is not sent at all", async () => {
  const note = IMPLIED.replace(
    "- He has been coming in late and the team has noticed; we agreed on a written plan with a date on it, and if the date passes we both know what happens next.",
    "- embezzlement"
  );
  let sent = "";
  await redactNote(note, opts(async (p) => { sent = p; return "[]"; }));
  const cores = chunksIn(sent).map((c) => c.core);
  // The heading and the benign bullet are still worth judging; the bullet that
  // lexical reduced to a bare marker has nothing left to judge.
  assert.equal(cores.length, 2, `sent: ${JSON.stringify(cores)}`);
  assert.equal(cores.some((c) => c.trim().startsWith("[REDACTED")), false);
});

test("verdicts outside the closed category set are dropped", async () => {
  const invoker = async () =>
    JSON.stringify([{ i: 0, flag: true, category: "gossip", text: marker("gossip") }]);
  const out = await redactNote(IMPLIED, opts(invoker));
  assert.deepEqual(out.categories, []);
  assert.equal(out.redactions, 0);
});

test("a flag with no replacement text, or one that adds no marker, is ignored", async () => {
  for (const row of [
    { i: 0, flag: true, category: "employment" },
    { i: 0, flag: true, category: "employment", text: "rewritten but nothing redacted" },
  ]) {
    const out = await redactNote(IMPLIED, opts(async () => JSON.stringify([row])));
    assert.equal(out.redactions, 0, JSON.stringify(row));
    assert.match(splitFrontmatter(out.text).body, /coming in late/, "text replaced without a marker");
  }
});

test("a verdict for a chunk that was never sent is ignored", async () => {
  const invoker = async () =>
    JSON.stringify([{ i: 999, flag: true, category: "abuse", text: marker("abuse") }]);
  const out = await redactNote(IMPLIED, opts(invoker));
  assert.equal(out.redactions, 0);
});

// Fail-closed. Every one of these must reach export.mjs as a throw, because
// export.mjs writes nothing when redactNote throws -- a note that looks screened
// and is not is worse than one that was obviously never processed.
test("every model failure propagates rather than degrading to a partial screen", async () => {
  const failures = [
    ["non-zero exit", async () => { throw new Error("claude -p failed (1): boom"); }],
    ["timeout", async () => { throw new Error("claude -p timed out after 300s"); }],
    ["unparseable output", async () => "I'm not going to do that"],
    ["not an array", async () => '{"i": 0, "flag": false}'],
  ];
  for (const [label, invoker] of failures) {
    await assert.rejects(() => redactNote(IMPLIED, opts(invoker)), undefined, label);
  }
});

test("screen() returns nothing for an empty chunk list and makes no call", async () => {
  let calls = 0;
  const out = await screen([], MARKER_TEMPLATE, async () => { calls++; return "[]"; });
  assert.equal(out.size, 0);
  assert.equal(calls, 0);
});

test("a rewrite that consolidates an already-marked chunk is accepted", async () => {
  // Lexical marks one span; the model returns a single marker covering the whole
  // bullet. Marker count does not rise, but far more text is gone -- that is a
  // better redaction, not a no-op, and must not be discarded.
  const note = IMPLIED.replace("Roadmap review moved to Thursday.", "He was arrested Thursday at the office.");
  const invoker = async (prompt) => {
    const target = chunksIn(prompt).find((c) => c.core.includes("at the office"));
    return JSON.stringify([
      { i: target.i, flag: true, category: "criminal", text: marker("criminal") },
    ]);
  };
  const out = await redactNote(note, opts(invoker));
  const body = splitFrontmatter(out.text).body;
  assert.equal(body.includes("at the office"), false, "consolidating rewrite was discarded");
  assert.match(body, /^- \[REDACTED · criminal[^\]]*\]$/m);
});

test("a rewrite that grows the text is discarded", async () => {
  // The model writing prose of its own, rather than redacting.
  const invoker = async (prompt) => {
    const target = chunksIn(prompt).find((c) => c.core.includes("coming in late"));
    return JSON.stringify([{
      i: target.i, flag: true, category: "employment",
      text: `${target.core} ${marker("employment")} plus some invented commentary.`,
    }]);
  };
  const out = await redactNote(IMPLIED, opts(invoker));
  assert.equal(out.redactions, 0);
  assert.match(splitFrontmatter(out.text).body, /coming in late/);
  assert.equal(splitFrontmatter(out.text).body.includes("invented commentary"), false);
});

test("marker casing is canonical whatever the model emits", async () => {
  // Sonnet substitutes the template literally and returns `[REDACTED · EMPLOYMENT]`;
  // haiku returns lowercase. Marker format must not depend on which model ran.
  const invoker = async (prompt) => {
    const target = chunksIn(prompt).find((c) => c.core.includes("coming in late"));
    return JSON.stringify([{
      i: target.i, flag: true, category: "employment",
      text: "[REDACTED · EMPLOYMENT]",
    }]);
  };
  const body = splitFrontmatter((await redactNote(IMPLIED, opts(invoker))).text).body;
  assert.match(body, /\[REDACTED · employment\]/);
  assert.equal(body.includes("EMPLOYMENT"), false, "uppercase marker reached the note");
});

test("a lexical marker keeps its own category when the model rewrites around it", async () => {
  // The chunk carries a `criminal` marker from layer one; the model flags the
  // chunk as `abuse`. Normalising must not relabel layer one's verdict.
  const note = IMPLIED.replace(
    "Roadmap review moved to Thursday.",
    "He was arrested Thursday, and a minor disclosed it to a teacher."
  );
  const invoker = async (prompt) => {
    const target = chunksIn(prompt).find((c) => c.core.includes("teacher"));
    return JSON.stringify([{
      i: target.i, flag: true, category: "abuse",
      text: `${target.core.replace(/ and a .*$/, "")} [REDACTED · ABUSE]`,
    }]);
  };
  const body = splitFrontmatter((await redactNote(note, opts(invoker))).text).body;
  assert.match(body, /\[REDACTED · criminal\]/, "lexical category was overwritten");
  assert.match(body, /\[REDACTED · abuse\]/, "model category lost");
});
