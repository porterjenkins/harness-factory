/**
 * Markdown -> ordered chunks -> markdown.
 *
 * Screening happens per chunk, so the chunk boundary decides what the lexical
 * proximity rules can see and what one semantic verdict covers. Granola bodies
 * are overwhelmingly bullet lists, and splitting only on blank lines puts a
 * whole list -- six unrelated topics -- into a single chunk. One bullet is one
 * topic, so bullets are chunked per item.
 *
 * The hard contract is `join(chunk(x)) === x` for every input. Every node's
 * `text` carries its own trailing newlines and nothing is normalised on the way
 * through, because the export's idempotency check hashes the rendered file: a
 * chunker that quietly drops one blank line would make every note look changed
 * on every scheduled run, re-screening (and re-paying for) the entire vault
 * every 30 minutes.
 */

// Kinds that get screened. `fence` and `blank` are structural and pass through
// untouched -- a code block containing something that looks like an SSN is a
// code block, and redacting it would corrupt the snippet without protecting a
// real person.
export const REDACTABLE = new Set(["heading", "listItem", "paragraph", "transcriptTurn"]);

const FENCE = /^[ \t]{0,3}(```+|~~~+)/;
const HEADING = /^[ \t]{0,3}#{1,6}[ \t]+/;
const LIST_MARK = /^([ \t]*)(?:[-*+]|\d{1,9}[.)])[ \t]+/;
// `**Name:** text` -- the shape transcriptToMarkdown() emits for a speaker turn.
const SPEAKER = /^\*\*[^*\n]+:\*\*[ \t]*/;
const BLANK = /^[ \t]*$/;

// Split into lines that each keep their own terminator, so concatenating them
// reproduces the input exactly (a plain split("\n") loses whether the file
// ended with a newline).
function toLines(s) {
  return s.match(/[^\n]*\n|[^\n]+/g) || [];
}

function indentOf(line) {
  const m = line.match(/^[ \t]*/);
  return m ? m[0].length : 0;
}

// A line that starts a new block rather than continuing the current one.
function startsBlock(line) {
  return FENCE.test(line) || HEADING.test(line) || SPEAKER.test(line);
}

export function chunk(body) {
  const lines = toLines(body);
  const nodes = [];
  let i = 0;

  const push = (kind, from, to) => {
    nodes.push({ kind, index: nodes.length, text: lines.slice(from, to).join("") });
  };

  while (i < lines.length) {
    const line = lines[i];

    if (FENCE.test(line)) {
      // Consume to the matching closing fence. An unterminated fence runs to
      // the end of the document, which is also how Markdown renders it.
      const marker = line.match(FENCE)[1][0].repeat(3);
      let j = i + 1;
      while (j < lines.length && !new RegExp(`^[ \\t]{0,3}\\${marker[0]}{3,}[ \\t]*$`).test(lines[j])) j++;
      if (j < lines.length) j++; // include the closing fence
      push("fence", i, j);
      i = j;
      continue;
    }

    if (BLANK.test(line)) {
      let j = i;
      while (j < lines.length && BLANK.test(lines[j])) j++;
      push("blank", i, j);
      i = j;
      continue;
    }

    if (HEADING.test(line)) {
      push("heading", i, i + 1);
      i += 1;
      continue;
    }

    if (SPEAKER.test(line)) {
      let j = i + 1;
      while (j < lines.length && !BLANK.test(lines[j]) && !SPEAKER.test(lines[j]) && !FENCE.test(lines[j])) j++;
      push("transcriptTurn", i, j);
      i = j;
      continue;
    }

    if (LIST_MARK.test(line)) {
      // One top-level item plus everything nested under it. A sibling is a list
      // marker at the same or shallower indent; anything deeper, or any
      // unmarked line, is this item's own continuation.
      const base = indentOf(line);
      let j = i + 1;
      while (j < lines.length) {
        const nxt = lines[j];
        if (BLANK.test(nxt)) break;
        if (startsBlock(nxt)) break;
        if (LIST_MARK.test(nxt) && indentOf(nxt) <= base) break;
        j++;
      }
      push("listItem", i, j);
      i = j;
      continue;
    }

    let j = i;
    while (j < lines.length) {
      const nxt = lines[j];
      if (j > i && (BLANK.test(nxt) || startsBlock(nxt) || LIST_MARK.test(nxt))) break;
      j++;
    }
    push("paragraph", i, j);
    i = j;
  }

  return nodes;
}

export function join(nodes) {
  return nodes.map((n) => n.text).join("");
}

/**
 * Split a node into the prefix that carries structure, the screenable core, and
 * the trailing newlines.
 *
 * The prefix is held out of screening on purpose. Span-level lexical matches
 * would never land on a `## ` or `- ` anyway, but the semantic layer rewrites
 * whole chunks, and a model that returns a redacted bullet without its `- `
 * silently collapses the list into a paragraph. Reattaching the prefix here
 * makes that unrepresentable rather than merely unlikely.
 */
export function parts(node) {
  const trail = node.text.match(/\n*$/)[0];
  const rest = node.text.slice(0, node.text.length - trail.length);
  let lead = "";
  if (node.kind === "heading") lead = rest.match(HEADING)[0];
  else if (node.kind === "listItem") lead = rest.match(LIST_MARK)[0];
  else if (node.kind === "transcriptTurn") lead = rest.match(SPEAKER)[0];
  else lead = rest.match(/^[ \t]*/)[0];
  return { lead, core: rest.slice(lead.length), trail };
}

export function rebuild(node, core) {
  const { lead, trail } = parts(node);
  return lead + core + trail;
}
