import assert from "node:assert/strict";
import crypto from "node:crypto";
import { execFile } from "node:child_process";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import { readFrontmatterScalar, redactNote } from "../redact/index.mjs";
import { loadBank } from "./helpers.mjs";

const run = promisify(execFile);
const EXPORT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "export.mjs");
const hash = (s) => crypto.createHash("sha256").update(s).digest("hex");

// Runs export.mjs far enough to exercise argv and the redaction preflight. It
// never reaches the network: the preflight is deliberately before the fetch.
async function runExport(args, env) {
  try {
    const { stdout, stderr } = await run(process.execPath, [EXPORT, ...args], {
      env: { ...process.env, ...env },
    });
    return { code: 0, stdout, stderr };
  } catch (e) {
    return { code: e.code, stdout: e.stdout || "", stderr: e.stderr || "" };
  }
}

test("an unknown argument is rejected instead of silently ignored", async () => {
  const r = await runExport(["--redact"], { GRANOLA_API_KEY: "grn_test" });
  assert.equal(r.code, 2);
  assert.match(r.stderr, /unknown argument: --redact/);
  assert.match(r.stderr, /--redacted \| --no-redacted/);
});

test("GRANOLA_REDACTION=true turns screening on for a plain run", async () => {
  const r = await runExport([], {
    GRANOLA_API_KEY: "grn_test",
    GRANOLA_REDACTION: "true",
    GRANOLA_CLAUDE_BIN: "/nonexistent/claude",
    GRANOLA_OUT_DIR: path.join(process.env.TMPDIR || "/tmp", "granola-redaction-test-out"),
  });
  assert.equal(r.code, 1);
  assert.match(r.stderr, /not on PATH/);
});

test("--redacted overrides GRANOLA_REDACTION being off", async () => {
  const r = await runExport(["--redacted"], {
    GRANOLA_API_KEY: "grn_test",
    GRANOLA_REDACTION: "false",
    GRANOLA_CLAUDE_BIN: "/nonexistent/claude",
    GRANOLA_OUT_DIR: path.join(process.env.TMPDIR || "/tmp", "granola-redaction-test-out"),
  });
  assert.equal(r.code, 1);
  assert.match(r.stderr, /not on PATH/);
});

test("the missing-key guard still fires before anything else", async () => {
  const r = await runExport([], { GRANOLA_API_KEY: "" });
  assert.equal(r.code, 1);
  assert.match(r.stderr, /GRANOLA_API_KEY is not set/);
});

// The expensive regression. export.mjs decides whether to re-screen by comparing
// contentHash(unredacted render) against the `source_hash` it stamped last time.
// If that round trip ever breaks, every note looks changed on every 30-minute
// run and the whole vault is re-screened, and re-paid for, forever.
test("source_hash round-trips, so an unchanged note is never re-screened", async () => {
  for (const fx of loadBank()) {
    const srcHash = hash(fx.text);
    const out = await redactNote(fx.text, {
      sourceHash: srcHash,
      semantic: false,
    });
    // What main() reads back off disk on the next run.
    assert.equal(readFrontmatterScalar(out.text, "source_hash"), srcHash, fx.file);
    // And it must NOT equal the hash of what was written, or the comparison
    // would be against non-deterministic output.
    assert.notEqual(hash(out.text), srcHash, fx.file);
  }
});

test("a note exported before screening existed has no source_hash and re-screens once", () => {
  const legacy = "---\ntitle: Old\nsource: granola\n---\n\n# Old\n";
  assert.equal(readFrontmatterScalar(legacy, "source_hash"), null);
});
