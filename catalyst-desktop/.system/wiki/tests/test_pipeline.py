"""Tests for the deterministic half of the pipeline.

Everything Obsidian-dependent is out of scope here by design: those paths need a
running GUI app. What IS covered is every branch that can silently lose data --
the mtime pre-filter, all six cases, duplicate-hash move ambiguity, and rebuild.
"""
from __future__ import annotations

import datetime as _dt
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from wiki import classify as C
from wiki import config, manifest, pipeline, taglint
from wiki.hashing import body_stat_from_text, read_frontmatter_scalar, split_frontmatter


def write(vault: Path, rel: str, body: str, fm: str = None, mtime_ns: int = None) -> Path:
    p = vault / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    text = ("---\n%s\n---\n" % fm if fm else "") + body
    p.write_text(text, encoding="utf-8")
    if mtime_ns is not None:
        os.utime(p, ns=(mtime_ns, mtime_ns))
    return p


class HashingTests(unittest.TestCase):
    def test_frontmatter_excluded_from_hash(self):
        """The whole reason v2 case 8 no longer exists."""
        a = body_stat_from_text("---\ntags: [x]\n---\nHello body")
        b = body_stat_from_text("---\ntags: [x, y]\ntagged: 2026-08-07\n---\nHello body")
        self.assertEqual(a.hash, b.hash)
        self.assertEqual(a.bytes, b.bytes)

    def test_body_change_changes_hash(self):
        a = body_stat_from_text("---\nt: 1\n---\nHello")
        b = body_stat_from_text("---\nt: 1\n---\nGoodbye")
        self.assertNotEqual(a.hash, b.hash)

    def test_no_frontmatter(self):
        fm, body = split_frontmatter("just a body")
        self.assertIsNone(fm)
        self.assertEqual(body, "just a body")

    def test_malformed_frontmatter_does_not_raise(self):
        fm, body = split_frontmatter("---\nnot closed\nstill going")
        self.assertIsNone(fm)
        self.assertIn("not closed", body)

    def test_read_scalar(self):
        fm, _ = split_frontmatter("---\ntagged: 2026-08-07\ntagged_hash: abc123\n---\nx")
        self.assertEqual(read_frontmatter_scalar(fm, "tagged"), "2026-08-07")
        self.assertEqual(read_frontmatter_scalar(fm, "tagged_hash"), "abc123")
        self.assertIsNone(read_frontmatter_scalar(fm, "missing"))


class WalkTests(unittest.TestCase):
    def test_dot_dirs_and_excluded_dirs_skipped(self):
        with tempfile.TemporaryDirectory() as td:
            v = Path(td)
            write(v, "Projects/a.md", "a")
            write(v, ".system/log-archive.md", "log")
            write(v, ".obsidian/x.md", "cfg")
            write(v, "Templates/t.md", "tpl")
            found = set(C.walk_vault(v))
            self.assertEqual(found, {"Projects/a.md"})

    def test_conflict_forks_excluded_and_reported(self):
        with tempfile.TemporaryDirectory() as td:
            v = Path(td)
            write(v, "Projects/a.md", "a")
            write(v, "Projects/a (user's conflicted copy 2026-08-07).md", "a")
            self.assertEqual(set(C.walk_vault(v)), {"Projects/a.md"})
            self.assertEqual(len(C.find_conflict_forks(v)), 1)


class PreFilterTests(unittest.TestCase):
    """The pre-filter is the one place data can be lost silently."""

    def test_backward_mtime_is_still_hashed(self):
        """A file synced from another device can carry an OLDER mtime than the
        last run. `>` would never hash it again; inequality catches it."""
        with tempfile.TemporaryDirectory() as td:
            v = Path(td)
            write(v, "a.md", "new content", mtime_ns=1_000)
            rows = {"a.md": {"mtime": 9_999_999, "file_bytes": 11, "body_hash": "stale",
                             "body_bytes": 3, "body_lines": 1, "status": "tagged"}}
            plan = C.classify(v, C.walk_vault(v), rows)
            self.assertEqual(plan.hashed, 1)
            self.assertEqual(plan.decisions[0].case, C.REAL_EDIT)

    def test_unchanged_mtime_is_not_hashed(self):
        with tempfile.TemporaryDirectory() as td:
            v = Path(td)
            write(v, "a.md", "body", mtime_ns=5_000)
            disk = C.walk_vault(v)
            rows = {"a.md": {"mtime": disk["a.md"].mtime, "file_bytes": disk["a.md"].size,
                             "body_hash": "whatever", "body_bytes": 4, "body_lines": 1,
                             "status": "tagged"}}
            plan = C.classify(v, disk, rows)
            self.assertEqual(plan.hashed, 0)
            self.assertEqual(plan.decisions[0].case, C.UNCHANGED)

    def test_no_row_is_always_hashed(self):
        """NULL-safe: a new path has no stored mtime to compare against."""
        with tempfile.TemporaryDirectory() as td:
            v = Path(td)
            write(v, "a.md", "body")
            plan = C.classify(v, C.walk_vault(v), {})
            self.assertEqual(plan.hashed, 1)
            self.assertEqual(plan.decisions[0].case, C.NEW)

    def test_size_change_is_hashed_even_if_mtime_identical(self):
        """mtime resolution is filesystem-dependent. On a coarse-granularity
        filesystem a same-second rewrite leaves mtime untouched, so mtime alone
        would silently skip the edit until the weekly sweep."""
        with tempfile.TemporaryDirectory() as td:
            v = Path(td)
            write(v, "a.md", "much longer body than before", mtime_ns=5_000)
            disk = C.walk_vault(v)
            rows = {"a.md": {"mtime": disk["a.md"].mtime, "file_bytes": 4,
                             "body_hash": "stale", "body_bytes": 4, "body_lines": 1,
                             "status": "tagged"}}
            plan = C.classify(v, disk, rows)
            self.assertEqual(plan.hashed, 1)
            self.assertEqual(plan.decisions[0].case, C.REAL_EDIT)

    def test_full_rehash_ignores_prefilter(self):
        with tempfile.TemporaryDirectory() as td:
            v = Path(td)
            write(v, "a.md", "body", mtime_ns=5_000)
            disk = C.walk_vault(v)
            rows = {"a.md": {"mtime": disk["a.md"].mtime, "file_bytes": disk["a.md"].size,
                             "body_hash": "stale", "body_bytes": 4, "body_lines": 1,
                             "status": "tagged"}}
            plan = C.classify(v, disk, rows, full_rehash=True)
            self.assertEqual(plan.hashed, 1)


class CaseTests(unittest.TestCase):
    def _rows_from(self, v, paths):
        disk = C.walk_vault(v)
        rows = {}
        for p in paths:
            st = body_stat_from_text((v / p).read_text())
            rows[p] = {"mtime": disk[p].mtime, "file_bytes": disk[p].size,
                       "body_hash": st.hash, "body_bytes": st.bytes,
                       "body_lines": st.lines, "status": "tagged"}
        return disk, rows

    def test_case1_new(self):
        with tempfile.TemporaryDirectory() as td:
            v = Path(td); write(v, "a.md", "hello")
            plan = C.classify(v, C.walk_vault(v), {})
            self.assertEqual(plan.decisions[0].case, C.NEW)
            self.assertTrue(plan.decisions[0].needs_tagging)

    def test_case2_move(self):
        with tempfile.TemporaryDirectory() as td:
            v = Path(td)
            write(v, "old.md", "identical body here")
            _, rows = self._rows_from(v, ["old.md"])
            (v / "old.md").rename(v / "new.md")
            plan = C.classify(v, C.walk_vault(v), rows)
            d = plan.decisions[0]
            self.assertEqual(d.case, C.MOVED)
            self.assertEqual(d.from_path, "old.md")
            self.assertFalse(d.needs_tagging)

    def test_case3_unchanged_after_touch(self):
        with tempfile.TemporaryDirectory() as td:
            v = Path(td)
            write(v, "a.md", "stable body")
            disk, rows = self._rows_from(v, ["a.md"])
            rows["a.md"]["mtime"] = disk["a.md"].mtime - 1  # sync touched it
            plan = C.classify(v, C.walk_vault(v), rows)
            self.assertEqual(plan.decisions[0].case, C.UNCHANGED)
            self.assertEqual(plan.hashed, 1)

    def test_case4_cheap_edit(self):
        with tempfile.TemporaryDirectory() as td:
            v = Path(td)
            body = "\n".join("line %d with a decent amount of text" % i for i in range(60))
            write(v, "a.md", body)
            _, rows = self._rows_from(v, ["a.md"])
            write(v, "a.md", body.replace("line 3 ", "line 3, "))
            plan = C.classify(v, C.walk_vault(v), rows)
            self.assertEqual(plan.decisions[0].case, C.CHEAP_EDIT)
            self.assertFalse(plan.decisions[0].needs_tagging)

    def test_case5_real_edit(self):
        with tempfile.TemporaryDirectory() as td:
            v = Path(td)
            write(v, "a.md", "short")
            _, rows = self._rows_from(v, ["a.md"])
            write(v, "a.md", "\n".join("brand new paragraph %d" % i for i in range(40)))
            plan = C.classify(v, C.walk_vault(v), rows)
            self.assertEqual(plan.decisions[0].case, C.REAL_EDIT)
            self.assertTrue(plan.decisions[0].needs_tagging)

    def test_missing_size_baseline_favours_retag(self):
        st = body_stat_from_text("x")
        self.assertTrue(C.is_real_edit(None, None, st))

    def test_duplicate_bodies_do_not_ping_pong(self):
        """Two files with identical bodies must not fight over one manifest row.

        `a.md` stays on disk, so `b.md` is a duplicate, not a move -- the naive
        rule would repoint a.md's row to b.md and leave a.md orphaned, then
        repoint it back next run, forever.
        """
        with tempfile.TemporaryDirectory() as td:
            v = Path(td)
            write(v, "a.md", "")           # empty body, trivially duplicated
            _, rows = self._rows_from(v, ["a.md"])
            write(v, "b.md", "")
            plan = C.classify(v, C.walk_vault(v), rows)
            cases = {d.path: d.case for d in plan.decisions}
            self.assertEqual(cases["b.md"], C.NEW)
            self.assertEqual(cases["a.md"], C.UNCHANGED)

    def test_ambiguous_move_falls_through_to_new(self):
        with tempfile.TemporaryDirectory() as td:
            v = Path(td)
            write(v, "x.md", "same"); write(v, "y.md", "same")
            _, rows = self._rows_from(v, ["x.md", "y.md"])
            (v / "x.md").unlink(); (v / "y.md").unlink()
            write(v, "z.md", "same")
            plan = C.classify(v, C.walk_vault(v), rows)
            self.assertEqual(plan.decisions[0].case, C.NEW)
            self.assertIn("ambiguous", plan.decisions[0].reason)

    def test_moved_and_edited_becomes_new(self):
        with tempfile.TemporaryDirectory() as td:
            v = Path(td)
            write(v, "old.md", "original text")
            _, rows = self._rows_from(v, ["old.md"])
            (v / "old.md").unlink()
            write(v, "new.md", "\n".join("totally different %d" % i for i in range(20)))
            plan = C.classify(v, C.walk_vault(v), rows)
            self.assertEqual(plan.decisions[0].case, C.NEW)


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "m.sqlite"
        self.conn = manifest.connect(self.db)
        manifest.init(self.conn)

    def tearDown(self):
        self.conn.close(); self.tmp.cleanup()

    def _row(self, path, h="h1", status="pending", seen="2026-08-07T10:00:00"):
        return {"path": path, "mtime": 1, "file_bytes": 20, "body_hash": h, "body_bytes": 10,
                "body_lines": 1, "status": status, "tagged_hash": None,
                "tagged_at": None, "seen_at": seen}

    def test_migration_adds_missing_columns(self):
        """CREATE TABLE IF NOT EXISTS is a no-op on an existing table, so an
        upgraded install would keep old columns while meta claimed the new
        version -- and the first write to a new column would fail at runtime."""
        import sqlite3
        db = Path(self.tmp.name) / "old.sqlite"
        legacy = sqlite3.connect(str(db))
        legacy.execute("CREATE TABLE notes (path TEXT PRIMARY KEY, mtime INTEGER, "
                       "body_hash TEXT NOT NULL, body_bytes INTEGER, body_lines INTEGER, "
                       "status TEXT, tagged_hash TEXT, tagged_at TEXT, seen_at TEXT)")
        legacy.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
        legacy.execute("INSERT INTO notes (path, mtime, body_hash, status) "
                       "VALUES ('a.md', 123, 'h1', 'tagged')")
        legacy.commit(); legacy.close()

        conn = manifest.connect(db)
        applied = manifest.init(conn)
        self.assertEqual(sorted(applied), ["file_bytes", "tag_attempts"])
        cols = {r[1] for r in conn.execute("PRAGMA table_info(notes)")}
        self.assertIn("file_bytes", cols)
        self.assertIn("tag_attempts", cols)
        # mtime cleared so the pre-filter cannot spuriously match on a row with
        # no file_bytes baseline
        self.assertIsNone(conn.execute("SELECT mtime FROM notes").fetchone()[0])
        self.assertEqual(manifest.get_meta(conn, "schema_version"),
                         str(manifest.SCHEMA_VERSION))
        conn.close()

    def test_init_is_idempotent(self):
        self.assertEqual(manifest.init(self.conn), [])

    def test_upsert_and_load(self):
        manifest.upsert(self.conn, self._row("a.md")); self.conn.commit()
        rows = manifest.load_all(self.conn)
        self.assertEqual(rows["a.md"]["body_hash"], "h1")

    def test_upsert_preserves_tagging_state(self):
        """A later upsert without tagging info must not erase tagged_hash."""
        manifest.upsert(self.conn, self._row("a.md"))
        manifest.mark_tagged(self.conn, "a.md", "h1", "2026-08-07T10:00:00")
        manifest.upsert(self.conn, self._row("a.md", h="h2", status="pending"))
        self.conn.commit()
        row = manifest.load_all(self.conn)["a.md"]
        self.assertEqual(row["tagged_hash"], "h1")
        self.assertEqual(row["body_hash"], "h2")

    def test_case6_sweep(self):
        manifest.upsert(self.conn, self._row("gone.md", seen="2026-08-01T00:00:00"))
        manifest.upsert(self.conn, self._row("here.md", seen="2026-08-07T12:00:00"))
        self.conn.commit()
        deleted = manifest.sweep_deleted(self.conn, "2026-08-07T12:00:00")
        self.assertEqual(deleted, ["gone.md"])
        self.assertEqual(manifest.load_all(self.conn)["gone.md"]["status"], "deleted")

    def test_sweep_is_idempotent(self):
        manifest.upsert(self.conn, self._row("gone.md", seen="2026-08-01T00:00:00"))
        self.conn.commit()
        manifest.sweep_deleted(self.conn, "2026-08-07T12:00:00")
        self.assertEqual(manifest.sweep_deleted(self.conn, "2026-08-07T13:00:00"), [])

    def test_repoint_keeps_tagging_state(self):
        manifest.upsert(self.conn, self._row("old.md"))
        manifest.mark_tagged(self.conn, "old.md", "h1", "2026-08-07T10:00:00")
        manifest.repoint(self.conn, "old.md", "new.md", 42, 20, "2026-08-07T12:00:00")
        self.conn.commit()
        rows = manifest.load_all(self.conn)
        self.assertNotIn("old.md", rows)
        self.assertEqual(rows["new.md"]["tagged_hash"], "h1")
        self.assertEqual(rows["new.md"]["status"], "tagged")

    def test_transaction_rolls_back(self):
        try:
            with manifest.transaction(self.conn) as tx:
                manifest.upsert(tx, self._row("a.md"))
                raise RuntimeError("boom")
        except RuntimeError:
            pass
        self.assertEqual(manifest.load_all(self.conn), {})

    def test_hard_delete_respects_grace(self):
        old = (_dt.datetime.now() - _dt.timedelta(days=60)).isoformat()
        recent = (_dt.datetime.now() - _dt.timedelta(days=2)).isoformat()
        manifest.upsert(self.conn, self._row("old.md", status="deleted", seen=old))
        manifest.upsert(self.conn, self._row("new.md", status="deleted", seen=recent))
        self.conn.commit()
        removed = manifest.hard_delete_expired(self.conn, 30)
        self.assertEqual(removed, ["old.md"])
        self.assertIn("new.md", manifest.load_all(self.conn))


class RunAndRebuildTests(unittest.TestCase):
    """End-to-end with a stubbed tagger -- never shells out to claude."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.vault = Path(self.tmp.name)
        (self.vault / ".system").mkdir()
        # LOG_DIR is patched too, and must be: logcsv writes there, so leaving it
        # pointing at the authoring vault makes the suite append fake rows to the
        # real append-only action log -- silently, since the tests still pass.
        self._orig = (config.VAULT, config.SYSTEM_DIR, config.MANIFEST,
                      config.WIKI_DIR, config.LOG_DIR)
        config.VAULT = self.vault
        config.SYSTEM_DIR = self.vault / ".system"
        config.WIKI_DIR = config.SYSTEM_DIR / "wiki"
        config.LOG_DIR = config.SYSTEM_DIR / "log"
        config.LOG_DIR.mkdir(parents=True, exist_ok=True)
        config.MANIFEST = config.WIKI_DIR / "manifest.sqlite"
        config.WIKI_DIR.mkdir(parents=True, exist_ok=True)
        self.conn = manifest.connect(config.MANIFEST)
        manifest.init(self.conn)

    def tearDown(self):
        self.conn.close()
        (config.VAULT, config.SYSTEM_DIR, config.MANIFEST,
         config.WIKI_DIR, config.LOG_DIR) = self._orig
        self.tmp.cleanup()

    @staticmethod
    def _fake_tagger(paths):
        import json as _json
        def invoke(prompt):
            return _json.dumps({p: {"tags": ["proj/alpha", "mongodb"],
                                    "type": "architecture",
                                    "summary": "stub"} for p in paths})
        return invoke

    def test_dry_run_writes_nothing(self):
        write(self.vault, "Projects/a.md", "content here")
        report = pipeline.run(self.conn, dry_run=True)
        self.assertEqual(report.counts.get("new"), 1)
        self.assertEqual(manifest.load_all(self.conn), {})

    def test_run_tags_and_records(self):
        write(self.vault, "Projects/a.md", "content here")
        report = pipeline.run(self.conn, invoker=self._fake_tagger(["Projects/a.md"]))
        self.assertEqual(report.write_mechanism, "ruamel")
        self.assertEqual(report.tagged, ["Projects/a.md"])
        row = manifest.load_all(self.conn)["Projects/a.md"]
        self.assertEqual(row["status"], "tagged")
        self.assertTrue(row["tagged_hash"])
        text = (self.vault / "Projects/a.md").read_text()
        self.assertIn("tagged_hash", text)
        self.assertIn("proj/alpha", text)

    def test_second_run_is_a_noop(self):
        """The tagger's own frontmatter write must not look like an edit."""
        write(self.vault, "Projects/a.md", "content here")
        pipeline.run(self.conn, invoker=self._fake_tagger(["Projects/a.md"]))
        def boom(prompt):
            raise AssertionError("tagger must not run again")
        report = pipeline.run(self.conn, invoker=boom)
        self.assertEqual(report.counts.get("unchanged"), 1)
        self.assertFalse(report.tag_failures)

    def test_tagging_ceiling_defers(self):
        for i in range(5):
            write(self.vault, "Projects/n%d.md" % i, "body number %d" % i)
        report = pipeline.run(self.conn, max_tag=2,
                              invoker=self._fake_tagger(["Projects/n0.md", "Projects/n1.md"]))
        self.assertTrue(any("deferred" in n for n in report.notes))
        statuses = manifest.counts_by_status(self.conn)
        self.assertEqual(statuses.get("pending"), 3)

    def test_deferred_files_are_retried_on_a_later_run(self):
        """The ceiling must defer, not drop.

        A deferred file has unchanged mtime and size, so the pre-filter would
        classify it `unchanged` forever and it would never be tagged.
        """
        for i in range(4):
            write(self.vault, "Projects/n%d.md" % i, "body number %d" % i)
        pipeline.run(self.conn, max_tag=2,
                     invoker=self._fake_tagger(["Projects/n0.md", "Projects/n1.md"]))
        self.assertEqual(manifest.counts_by_status(self.conn).get("pending"), 2)

        report = pipeline.run(self.conn, max_tag=2,
                              invoker=self._fake_tagger(["Projects/n2.md", "Projects/n3.md"]))
        self.assertEqual(sorted(report.tagged), ["Projects/n2.md", "Projects/n3.md"])
        self.assertEqual(manifest.counts_by_status(self.conn).get("tagged"), 4)
        self.assertIsNone(manifest.counts_by_status(self.conn).get("pending"))

    def test_failed_tagging_is_retried(self):
        write(self.vault, "Projects/a.md", "body a")
        def boom(prompt):
            raise RuntimeError("tagger down")
        report = pipeline.run(self.conn, invoker=boom)
        self.assertEqual(report.tag_failures, ["Projects/a.md"])
        report = pipeline.run(self.conn, invoker=self._fake_tagger(["Projects/a.md"]))
        self.assertEqual(report.tagged, ["Projects/a.md"])

    def test_persistent_failure_stops_retrying(self):
        """An unattended job must not retry a broken file forever -- that is an
        LLM call every 15 minutes, indefinitely, for nothing."""
        write(self.vault, "Projects/a.md", "body a")
        def boom(prompt):
            raise RuntimeError("tagger down")
        for _ in range(config.MAX_TAG_ATTEMPTS):
            pipeline.run(self.conn, invoker=boom)
        self.assertEqual(manifest.counts_by_status(self.conn).get("failed"), 1)

        def must_not_run(prompt):
            raise AssertionError("failed files must not be retried")
        report = pipeline.run(self.conn, invoker=must_not_run)
        self.assertFalse(report.tag_failures)

        with manifest.transaction(self.conn) as tx:
            self.assertEqual(manifest.reset_failed(tx), 1)
        report = pipeline.run(self.conn, invoker=self._fake_tagger(["Projects/a.md"]))
        self.assertEqual(report.tagged, ["Projects/a.md"])

    def test_deletion_sweep_marks_missing(self):
        write(self.vault, "Projects/a.md", "body a")
        pipeline.run(self.conn, invoker=self._fake_tagger(["Projects/a.md"]))
        (self.vault / "Projects/a.md").unlink()
        report = pipeline.run(self.conn, invoker=lambda p: "{}")
        self.assertEqual(report.deleted, ["Projects/a.md"])

    def test_rebuild_trusts_matching_tagged_hash(self):
        write(self.vault, "Projects/a.md", "body a")
        pipeline.run(self.conn, invoker=self._fake_tagger(["Projects/a.md"]))
        stats = pipeline.rebuild(self.conn)
        self.assertEqual(stats["tagged"], 1)
        self.assertEqual(stats["requeued"], 0)

    def test_rebuild_requeues_when_body_moved_since_tagging(self):
        """A `tagged` date alone would silently absorb this edit. tagged_hash
        is what makes rebuild honest."""
        write(self.vault, "Projects/a.md", "body a")
        pipeline.run(self.conn, invoker=self._fake_tagger(["Projects/a.md"]))
        text = (self.vault / "Projects/a.md").read_text()
        fm, _ = split_frontmatter(text)
        (self.vault / "Projects/a.md").write_text("---\n%s\n---\ncompletely different body\n" % fm)
        stats = pipeline.rebuild(self.conn)
        self.assertEqual(stats["requeued"], 1)
        self.assertEqual(stats["tagged"], 0)

    def test_missing_tagger_result_does_not_abort_the_run(self):
        """A KeyError here would kill the run *after* the manifest committed,
        losing the log for work that actually happened."""
        write(self.vault, "Projects/a.md", "body a")
        import json as _json
        def invoke(prompt):
            return _json.dumps({"Projects/a.md": {"tags": ["x"], "type": "concept"}})
        report = pipeline.run(self.conn, invoker=invoke)
        report.tagged = []
        self.assertEqual(manifest.load_all(self.conn)["Projects/a.md"]["status"], "tagged")

    def test_log_is_written_and_sanitized(self):
        write(self.vault, "Projects/a.md", "body a")
        import json as _json
        def invoke(prompt):
            return _json.dumps({"Projects/a.md": {"tags": ["x"], "type": "concept",
                                              "summary": "has | pipe\nand newline"}})
        pipeline.run(self.conn, invoker=invoke)
        from wiki import logcsv
        content = logcsv.log_path().read_text()
        for line in content.splitlines():
            self.assertEqual(len(line.split("|")), 4, line)
        self.assertNotIn("and newline\n", content.split("|")[-1])


class VocabularyScanTests(unittest.TestCase):
    """The fallback scanner is what the cloud tagger uses; garbage in the
    vocabulary skews the frequency signal the tagger depends on."""

    def test_both_yaml_list_styles_are_read(self):
        """Obsidian indents sequence items; ruamel does not. Both are valid YAML
        and both must count, or the tagger loses its frequency signal."""
        with tempfile.TemporaryDirectory() as td:
            v = Path(td)
            write(v, "indented.md", "x", fm="tags:\n  - proj/alpha\n  - mongodb")
            write(v, "flush.md", "y", fm="tags:\n- proj/alpha\n- redshift")
            counts = pipeline.vocabulary_from_disk(v)
            self.assertEqual(counts.get("proj/alpha"), 2)
            self.assertEqual(counts.get("mongodb"), 1)
            self.assertEqual(counts.get("redshift"), 1)

    def test_code_blocks_and_numeric_tags_excluded(self):
        with tempfile.TemporaryDirectory() as td:
            v = Path(td)
            write(v, "a.md",
                  "Real #proj/alpha tag here.\n\n"
                  "```css\nbody { color: #FFFFFF; background: #25B184; }\n```\n\n"
                  "Inline `#7C3AED` too, and issue #19.\n",
                  fm="tags:\n  - mongodb\n")
            counts = pipeline.vocabulary_from_disk(v)
            self.assertIn("proj/alpha", counts)
            self.assertIn("mongodb", counts)
            for junk in ("FFFFFF", "25B184", "7C3AED", "19"):
                self.assertNotIn(junk, counts, "%s leaked into vocabulary" % junk)


class WriteVerificationTests(unittest.TestCase):
    """Writes are confirmed against the filesystem, never against the writer's
    own report of what it did."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.vault = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_verify_requires_matching_tagged_hash(self):
        from wiki import writer
        write(self.vault, "a.md", "body", fm="tagged: 2026-08-07\ntagged_hash: abc123")
        write(self.vault, "b.md", "body", fm="tagged: 2026-08-07\ntagged_hash: WRONG")
        write(self.vault, "c.md", "body")
        updates = {p: {"tagged_hash": "abc123"} for p in ("a.md", "b.md", "c.md")}
        self.assertEqual(writer.verify_written(self.vault, updates), ["a.md"])

    def test_decorated_cli_output_is_discarded(self):
        """The Obsidian CLI prefixes returned values, e.g. `=> CLAUDE.md`.
        Parsing that as a path yields a string matching no file and no manifest
        row, which previously crashed the run after the manifest had committed."""
        from wiki import obsidian, writer
        updates = {"Projects/a.md": {"tagged_hash": "h1"}}
        original = obsidian.eval_js
        obsidian.eval_js = lambda code, timeout=None: "=> Projects/a.md\n=> CLAUDE.md"
        try:
            self.assertEqual(writer.write_via_obsidian(updates), ["Projects/a.md"])
        finally:
            obsidian.eval_js = original


class ExclusionTests(unittest.TestCase):
    def test_claude_md_is_not_ingested(self):
        """CLAUDE.md is agent configuration. Tagging it pollutes the vocabulary
        with the vault's own instructions and rewrites a file read every session."""
        with tempfile.TemporaryDirectory() as td:
            v = Path(td)
            write(v, "CLAUDE.md", "instructions")
            write(v, "Projects/a.md", "a note")
            self.assertEqual(set(C.walk_vault(v)), {"Projects/a.md"})


class TagLintTests(unittest.TestCase):
    def test_reordered_nesting(self):
        f = taglint.find_near_duplicates({"proj/ai": 20, "ai/proj": 1})
        self.assertEqual(f[0]["keep"], "proj/ai")
        self.assertEqual(f[0]["merge"][0]["tag"], "ai/proj")

    def test_case_and_separator_only(self):
        f = taglint.find_near_duplicates({"Proj-AI": 2, "proj_ai": 9})
        self.assertEqual(f[0]["keep"], "proj_ai")

    def test_edit_distance(self):
        f = taglint.find_near_duplicates({"mongodb": 30, "mongodbb": 1})
        self.assertTrue(any(x["tag"] == "mongodbb" for x in f[0]["merge"]))

    def test_short_tags_not_fuzzy_matched(self):
        self.assertEqual(taglint.find_near_duplicates({"ai": 5, "ml": 5}), [])

    def test_singletons(self):
        self.assertEqual(taglint.find_singletons({"a": 1, "b": 9}), [("a", 1)])

    def test_merge_plan_shape(self):
        plan = taglint.merge_plan(taglint.find_near_duplicates({"proj/ai": 20, "ai/proj": 1}))
        self.assertEqual(plan[0]["from"], "ai/proj")
        self.assertEqual(plan[0]["to"], "proj/ai")


class CanonVocabularyTests(unittest.TestCase):
    """tags.md as a declared vocabulary (canon mode) and the guards around it."""

    #: Enough established tags that a canon list can clear the coverage floor.
    COUNTS = {"proj/ai": 40, "team": 50, "team/review": 25, "mongodb": 30, "beta": 12}

    def _vault(self, tags_md=None):
        d = Path(tempfile.mkdtemp())
        if tags_md is not None:
            (d / "tags.md").write_text(tags_md, encoding="utf-8")
        return d

    def test_parse_accepts_the_layouts_a_human_would_write(self):
        text = ("---\ntags: [meta]\n---\n"
                "# Tag Vocabulary\n"
                "Prose about how to use this file.\n"
                "## Projects\n"
                "- `proj/ai`\n"
                "- #mongodb\n"
                "* team\n"
                "1. team/review\n"
                "beta\n"
                "<!-- comment -->\n")
        self.assertEqual(taglint.parse_canon(text),
                         ["proj/ai", "mongodb", "team", "team/review", "beta"])

    def test_parse_skips_code_blocks(self):
        text = "- team\n```\n- notatag\n```\n- beta\n"
        self.assertEqual(taglint.parse_canon(text), ["team", "beta"])

    def test_canon_beats_frequency(self):
        """The whole point of declaring a vocabulary: the list wins on a tie or a loss."""
        counts = dict(self.COUNTS, **{"ai/proj": 99})
        vault = self._vault("- proj/ai\n- team\n- team/review\n- mongodb\n- beta\n")
        canon = taglint.resolve_vocabulary(counts, vault)
        self.assertEqual(canon["mode"], "canon")
        self.assertEqual(canon["near_duplicates"][0]["keep"], "proj/ai")
        # Frequency mode would reach the opposite conclusion on the same counts.
        freq = taglint.resolve_vocabulary(counts, self._vault())
        self.assertEqual(freq["mode"], "frequency")
        self.assertEqual(freq["near_duplicates"][0]["keep"], "ai/proj")

    def test_unlisted_tags_are_reported_not_merged(self):
        counts = dict(self.COUNTS, **{"brandnewthing": 3})
        r = taglint.resolve_vocabulary(
            counts, self._vault("- proj/ai\n- team\n- team/review\n- mongodb\n- beta\n"))
        self.assertIn(("brandnewthing", 3), r["unlisted"])
        self.assertNotIn("brandnewthing",
                         [m["from"] for m in r["merge_plan"]])

    def test_stale_list_falls_back_to_frequency(self):
        """A list that has fallen behind the vault must not mass-merge live tags."""
        r = taglint.resolve_vocabulary(self.COUNTS,
                                       self._vault("- proj/ai\n- longdeadproject\n"))
        self.assertEqual(r["mode"], "frequency")
        self.assertIn("stale", r["fallback_reason"])

    def test_empty_list_falls_back(self):
        r = taglint.resolve_vocabulary(self.COUNTS, self._vault("# Nothing here\n"))
        self.assertEqual(r["mode"], "frequency")
        self.assertIn("zero tags", r["fallback_reason"])

    def test_missing_file_falls_back(self):
        r = taglint.resolve_vocabulary(self.COUNTS, self._vault())
        self.assertEqual(r["mode"], "frequency")
        self.assertIn("no tags.md", r["fallback_reason"])

    def test_force_frequency_ignores_a_good_list(self):
        vault = self._vault("- proj/ai\n- team\n- team/review\n- mongodb\n- beta\n")
        r = taglint.resolve_vocabulary(self.COUNTS, vault, force_frequency=True)
        self.assertEqual(r["mode"], "frequency")

    def test_dot_system_location_is_found(self):
        d = self._vault()
        (d / ".system").mkdir()
        (d / ".system" / "tags.md").write_text(
            "- proj/ai\n- team\n- team/review\n- mongodb\n- beta\n", encoding="utf-8")
        r = taglint.resolve_vocabulary(self.COUNTS, d)
        self.assertEqual(r["mode"], "canon")
        self.assertTrue(r["canon_path"].endswith(".system/tags.md"))

    def test_unused_canon_is_surfaced(self):
        r = taglint.resolve_vocabulary(
            self.COUNTS,
            self._vault("- proj/ai\n- team\n- team/review\n- mongodb\n- beta\n- aspirational\n"))
        self.assertEqual(r["mode"], "canon")
        self.assertIn("aspirational", r["coverage"]["unused_canon"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
