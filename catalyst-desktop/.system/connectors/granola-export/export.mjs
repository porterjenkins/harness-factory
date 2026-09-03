#!/usr/bin/env node
/**
 * Granola -> Markdown exporter (official Personal API).
 *
 * Uses https://public-api.granola.ai/v1 with a `grn_` API key.
 * Writes one markdown file per note into the output dir, idempotently:
 * a file is only rewritten when its content actually changes.
 *
 * Config (env vars):
 *   GRANOLA_API_KEY   required. Your grn_... key. Supplied by run.sh from the
 *                     shared <vault>/.system/.env (see .system/.env.example).
 *   GRANOLA_OUT_DIR   base output dir (default: <vault>/Resources/Meetings, resolved from this
 *                     file's own location — no hardcoded path)
 *   GRANOLA_TRANSCRIPT  "1" to include transcripts (default off; slower, larger)
 */

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const API_BASE = "https://public-api.granola.ai/v1";
const API_KEY = process.env.GRANOLA_API_KEY;
// This file lives at <vault>/.system/connectors/granola-export/export.mjs. Resolve the vault
// from our own location rather than hardcoding it, so the exporter works in any
// vault at any path -- the same discipline as run.sh (BASH_SOURCE) and
// .system/wiki/config.py (__file__). A hardcoded default fails silently here:
// main() mkdirs OUT_DIR before writing, so a wrong path creates itself and the
// notes land somewhere the user never looks.
const HERE = path.dirname(fileURLToPath(import.meta.url));
// .system/connectors/granola-export -> up three to the vault root. Counting
// these levels wrong is silent: the export "succeeds" and writes a whole
// Meetings tree somewhere nobody looks.
const VAULT = path.resolve(HERE, "..", "..", "..");
const OUT_DIR = process.env.GRANOLA_OUT_DIR || path.join(VAULT, "Resources", "Meetings");
const INCLUDE_TRANSCRIPT = process.env.GRANOLA_TRANSCRIPT === "1";
const STATE_DIR = HERE;

// Stay under the API limit (5 req/s sustained). ~250ms between calls is safe.
const REQ_DELAY_MS = 260;

if (!API_KEY) {
  console.error(
    "ERROR: GRANOLA_API_KEY is not set.\n" +
      "Create a key in Granola: Settings -> Connectors -> API keys,\n" +
      `then put it in ${path.join(VAULT, ".system", ".env")}`
  );
  process.exit(1);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(pathAndQuery) {
  const url = `${API_BASE}${pathAndQuery}`;
  for (let attempt = 0; attempt < 5; attempt++) {
    const res = await fetch(url, {
      headers: {
        Authorization: `Bearer ${API_KEY}`,
        "Content-Type": "application/json",
        "User-Agent": "granola-markdown-exporter/1.0",
      },
    });
    if (res.status === 429) {
      const wait = Math.min(2000 * (attempt + 1), 8000);
      console.warn(`Rate limited; backing off ${wait}ms...`);
      await sleep(wait);
      continue;
    }
    if (!res.ok) {
      const body = await res.text().catch(() => "");
      throw new Error(`GET ${pathAndQuery} -> ${res.status} ${res.statusText}\n${body}`);
    }
    return res.json();
  }
  throw new Error(`GET ${pathAndQuery} -> gave up after retries (rate limited)`);
}

// Turn a title into a readable, filesystem-safe filename.
// Keeps case, spaces, and words; only strips characters that are illegal in
// filenames or awkward in Obsidian, and collapses runs of separators.
function safeTitle(s) {
  return (s || "Untitled meeting")
    .replace(/[/\\]+/g, " - ") // slashes -> " - " (Oleo/Young -> Oleo - Young)
    .replace(/[:*?"<>|#^[\]]/g, "") // strip fs- and Obsidian-illegal chars
    .replace(/\s*-\s*-+\s*/g, " - ") // collapse repeated dashes
    .replace(/\s+/g, " ")
    .trim()
    .replace(/[.\s]+$/, "") // no trailing dots/spaces
    .slice(0, 120) || "Untitled meeting";
}

function pick(obj, ...keys) {
  for (const k of keys) {
    if (obj && obj[k] != null && obj[k] !== "") return obj[k];
  }
  return undefined;
}

function yamlEscape(v) {
  const s = String(v);
  return /[:#"'\[\]{}\n]/.test(s) ? JSON.stringify(s) : s;
}

function transcriptToMarkdown(transcript) {
  if (!Array.isArray(transcript) || transcript.length === 0) return "";
  // Each segment: { text, start_time, end_time, speaker: { source, diarization_label } }.
  // Merge consecutive segments from the same speaker into one paragraph so the
  // transcript reads as turns, not thousands of one-line fragments.
  const turns = [];
  for (const seg of transcript) {
    const spk = seg.speaker || {};
    const who = pick(spk, "diarization_label", "source") || "Speaker";
    const text = (pick(seg, "text", "content") || "").trim();
    if (!text) continue;
    const last = turns[turns.length - 1];
    if (last && last.who === who) last.text += " " + text;
    else turns.push({ who, text });
  }
  const lines = turns.map((t) => `**${t.who}:** ${t.text}`);
  return `\n## Transcript\n\n${lines.join("\n\n")}\n`;
}

function noteToMarkdown(note) {
  const title = pick(note, "title") || "Untitled meeting";
  const createdAt = pick(note, "created_at", "createdAt", "created", "date") || "";
  const dateOnly = createdAt ? createdAt.toString().slice(0, 10) : "";
  const owner = note.owner || {};
  const ownerName = pick(owner, "name");
  const ownerEmail = pick(owner, "email");
  // The note body is markdown under `summary_markdown` (fall back to plain text).
  const body = pick(note, "summary_markdown", "summary_text", "summary") || "";

  const attendees = Array.isArray(note.attendees)
    ? note.attendees.map((a) => pick(a, "name", "email")).filter(Boolean)
    : [];
  const folder = Array.isArray(note.folder_membership)
    ? pick(note.folder_membership[0] || {}, "name")
    : undefined;
  const webUrl = pick(note, "web_url");
  const ev = note.calendar_event || {};
  const start = pick(ev, "scheduled_start_time");
  const end = pick(ev, "scheduled_end_time");

  const fm = ["---"];
  fm.push(`title: ${yamlEscape(title)}`);
  if (dateOnly) fm.push(`date: ${yamlEscape(dateOnly)}`);
  if (start) fm.push(`start_time: ${yamlEscape(start)}`);
  if (end) fm.push(`end_time: ${yamlEscape(end)}`);
  if (ownerName) fm.push(`owner: ${yamlEscape(ownerName)}`);
  if (ownerEmail) fm.push(`owner_email: ${yamlEscape(ownerEmail)}`);
  if (folder) fm.push(`folder: ${yamlEscape(folder)}`);
  if (attendees.length) {
    fm.push("attendees:");
    for (const a of attendees) fm.push(`  - ${yamlEscape(a)}`);
  }
  if (webUrl) fm.push(`granola_url: ${yamlEscape(webUrl)}`);
  fm.push(`granola_id: ${yamlEscape(note.id || "")}`);
  fm.push("source: granola");
  fm.push("---");

  let md = `\n# ${dateOnly ? dateOnly + " " : ""}${title}\n`;
  if (body) md += `\n${body}\n`;
  if (INCLUDE_TRANSCRIPT) md += transcriptToMarkdown(note.transcript);

  return fm.join("\n") + "\n" + md;
}

function contentHash(s) {
  return crypto.createHash("sha256").update(s).digest("hex");
}

async function listAllNotes() {
  const notes = [];
  let cursor = null;
  do {
    const q = cursor
      ? `/notes?cursor=${encodeURIComponent(cursor)}`
      : `/notes`;
    const page = await api(q);
    const batch = page.notes || page.data || [];
    notes.push(...batch);
    cursor = page.hasMore ? page.cursor : null;
    await sleep(REQ_DELAY_MS);
  } while (cursor);
  return notes;
}

async function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  fs.mkdirSync(STATE_DIR, { recursive: true });

  const stamp = () =>
    new Date().toLocaleString("sv-SE", { timeZoneName: "short" }); // YYYY-MM-DD HH:MM:SS TZ
  console.log(`\n[${stamp()}] Fetching note list from Granola...`);
  const list = await listAllNotes();
  console.log(`Found ${list.length} note(s).`);

  let written = 0,
    skipped = 0,
    failed = 0;

  for (const stub of list) {
    try {
      const id = stub.id;
      const q = INCLUDE_TRANSCRIPT
        ? `/notes/${encodeURIComponent(id)}?include=transcript`
        : `/notes/${encodeURIComponent(id)}`;
      const note = await api(q);
      await sleep(REQ_DELAY_MS);

      const md = noteToMarkdown(note);

      // Readable filename from the title. A note's id is stored in frontmatter
      // (granola_id), so re-runs find the right file even when titles collide:
      // we reuse whatever existing file already carries this note's id, and
      // only add a short-id suffix when a *different* note wants the same name.
      const shortId = (note.id || "").replace(/^not_/, "").slice(0, 8);
      const created = (pick(note, "created_at", "createdAt", "created", "date") || "")
        .toString()
        .slice(0, 10);
      // Prefix the filename with the meeting date (YYYY-MM-DD) so notes sort
      // chronologically in Obsidian.
      const clean = [created, safeTitle(pick(note, "title"))]
        .filter(Boolean)
        .join(" ");
      // Notes are filed by YEAR, under OUT_DIR/<YYYY>/, matching the vault's
      // Resources/{Plans,Meetings}/{year}/ convention.
      //
      // The year comes from the MEETING's own date, never from the clock. Using
      // the run date would file a December meeting exported on Jan 2nd under the
      // new year -- wrong, and invisible until someone goes looking for it.
      // Notes with no usable date stay at the OUT_DIR root rather than being
      // guessed into a year: a visible stray is recoverable, a mis-filed one is not.
      const year = /^\d{4}/.test(created) ? created.slice(0, 4) : null;
      const destDir = year ? path.join(OUT_DIR, year) : OUT_DIR;
      fs.mkdirSync(destDir, { recursive: true });

      let base = `${clean}.md`;
      let outPath = path.join(destDir, base);

      const idTag = `granola_id: ${yamlEscape(note.id || "")}`;
      const takenByOther =
        fs.existsSync(outPath) &&
        !fs.readFileSync(outPath, "utf8").includes(idTag);
      if (takenByOther) {
        base = `${clean} (${shortId}).md`;
        outPath = path.join(destDir, base);
      }

      if (fs.existsSync(outPath)) {
        const existing = fs.readFileSync(outPath, "utf8");
        if (contentHash(existing) === contentHash(md)) {
          skipped++;
          continue;
        }
      }
      fs.writeFileSync(outPath, md, "utf8");
      written++;
    } catch (e) {
      failed++;
      console.warn(`Skipped ${stub.id}: ${e.message.split("\n")[0]}`);
    }
  }

  console.log(
    `[${stamp()}] Done. ${written} written, ${skipped} unchanged, ${failed} failed. -> ${OUT_DIR}`
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
