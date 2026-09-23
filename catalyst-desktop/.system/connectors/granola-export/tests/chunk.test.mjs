import assert from "node:assert/strict";
import test from "node:test";

import { chunk, join, parts, rebuild, REDACTABLE } from "../redact/chunk.mjs";
import { splitFrontmatter } from "../redact/index.mjs";
import { loadBank } from "./helpers.mjs";

// The contract the whole idempotency story rests on. If chunking a document and
// joining it back changes one byte, every note looks changed on every scheduled
// run and the exporter re-screens (and re-pays for) the entire vault forever.
test("chunk/join round-trips every fixture byte for byte", () => {
  for (const fx of loadBank()) {
    const { body } = splitFrontmatter(fx.text);
    assert.equal(join(chunk(body)), body, `round-trip failed for ${fx.file}`);
  }
});

test("chunk/join round-trips awkward whitespace", () => {
  for (const s of ["", "\n", "\n\n\n", "no trailing newline", "a\n\nb\n", "   \n\ttabbed\n"]) {
    assert.equal(join(chunk(s)), s, JSON.stringify(s));
  }
});

test("parts() reassembles every node exactly", () => {
  for (const fx of loadBank()) {
    const { body } = splitFrontmatter(fx.text);
    for (const node of chunk(body)) {
      const { lead, core, trail } = parts(node);
      assert.equal(lead + core + trail, node.text, `${fx.file}: ${node.kind}`);
      assert.equal(rebuild(node, core), node.text);
    }
  }
});

test("fenced blocks are atomic and never screenable", () => {
  const nodes = chunk("intro\n\n```js\nconst a = 1;\n\nconst b = 2;\n```\n\nafter\n");
  const fence = nodes.find((n) => n.kind === "fence");
  assert.ok(fence, "no fence node");
  assert.match(fence.text, /const b = 2;/, "fence split at its interior blank line");
  assert.equal(REDACTABLE.has("fence"), false);
});

test("an unterminated fence runs to end of document", () => {
  const nodes = chunk("```\nopen forever\nstill open\n");
  assert.equal(nodes.length, 1);
  assert.equal(nodes[0].kind, "fence");
});

test("bullets chunk per item, with nested children attached to their parent", () => {
  const nodes = chunk("- first topic\n  - nested detail\n- second topic\n");
  const items = nodes.filter((n) => n.kind === "listItem");
  assert.equal(items.length, 2);
  assert.match(items[0].text, /nested detail/);
  assert.match(items[1].text, /second topic/);
});

test("a lazy continuation line stays with its bullet", () => {
  const items = chunk("- a topic that\nwraps onto a second line\n- next\n").filter(
    (n) => n.kind === "listItem"
  );
  assert.equal(items.length, 2);
  assert.match(items[0].text, /wraps onto a second line/);
});

test("headings keep their prefix and level out of the screenable core", () => {
  const [heading] = chunk("### 2026-01-01 Standup\n");
  assert.equal(heading.kind, "heading");
  assert.equal(parts(heading).lead, "### ");
  assert.equal(parts(heading).core, "2026-01-01 Standup");
});

test("speaker turns chunk one turn at a time", () => {
  const turns = chunk("**Ada:** one thing\nand more\n\n**Grace:** another\n").filter(
    (n) => n.kind === "transcriptTurn"
  );
  assert.equal(turns.length, 2);
  assert.equal(parts(turns[0]).lead, "**Ada:** ");
  assert.match(turns[0].text, /and more/);
});
