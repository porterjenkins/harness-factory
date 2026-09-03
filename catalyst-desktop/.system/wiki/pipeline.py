"""Run orchestration: the update flow of spec sec.4.

  1. run_start; enumerate path + mtime
  2. hash where no row, or disk mtime != stored mtime (everything, on a sweep)
  3. classify; stamp seen_at on everything observed
  4. batch cases 1 and 5 to headless `claude -p`
  5. write frontmatter incl. `tagged` / `tagged_hash`
  6. mark case 6 deletions
  7. commit -- steps 3-6 are one transaction
  8. append one line per action to the log

Changes are buffered and applied in a single transaction at the end, so the write
lock is not held across the LLM calls in step 4.
"""
from __future__ import annotations

import datetime as _dt
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

from . import classify as C
from . import config, logcsv, manifest, obsidian, tagger, writer
from .hashing import body_stat, read_frontmatter_scalar, split_frontmatter


def _now() -> str:
    """Full microsecond precision.

    run_start is compared with `<` by the deletion sweep, so second-level
    truncation would make two runs inside the same second indistinguishable and
    the sweep would silently find nothing. The log truncates separately.
    """
    return _dt.datetime.now().isoformat()


@dataclass
class RunReport:
    run_start: str = ""
    dry_run: bool = False
    full_rehash: bool = False
    observed: int = 0
    hashed: int = 0
    counts: Dict[str, int] = field(default_factory=dict)
    tagged: List[str] = field(default_factory=list)
    tag_failures: List[str] = field(default_factory=list)
    deleted: List[str] = field(default_factory=list)
    skipped_open: List[str] = field(default_factory=list)
    conflict_forks: List[str] = field(default_factory=list)
    write_mechanism: str = ""
    notes: List[str] = field(default_factory=list)

    def summary_line(self) -> str:
        bits = ["observed=%d" % self.observed, "hashed=%d" % self.hashed]
        bits += ["%s=%d" % (k, v) for k, v in sorted(self.counts.items()) if v]
        if self.tagged:
            bits.append("tagged=%d" % len(self.tagged))
        if self.tag_failures:
            bits.append("tag_failed=%d" % len(self.tag_failures))
        if self.deleted:
            bits.append("deleted=%d" % len(self.deleted))
        if self.skipped_open:
            bits.append("skipped_open=%d" % len(self.skipped_open))
        if self.conflict_forks:
            bits.append("CONFLICT_FORKS=%d" % len(self.conflict_forks))
        return " ".join(bits)


def _vocabulary() -> Dict[str, int]:
    """Tag vocabulary with counts. Falls back to parsing frontmatter when the CLI
    is unavailable (the cloud tagger cannot call `obsidian tags`) -- spec sec.5."""
    try:
        if obsidian.installed():
            return obsidian.tag_counts()
    except Exception:
        pass
    return vocabulary_from_disk(config.VAULT)


_FENCE_RE = None
_INLINE_CODE_RE = None
_TAG_RE = None
_TAGS_BLOCK_RE = None


def _tag_patterns():
    """Compiled once, lazily, so importing this module stays cheap."""
    global _FENCE_RE, _INLINE_CODE_RE, _TAG_RE, _TAGS_BLOCK_RE
    if _TAG_RE is None:
        import re
        _FENCE_RE = re.compile(r"^```.*?^```", re.DOTALL | re.MULTILINE)
        _INLINE_CODE_RE = re.compile(r"`[^`\n]*`")
        _TAG_RE = re.compile(r"(?<![\w&/#])#([A-Za-z0-9_][A-Za-z0-9_/-]*)")
        # A YAML sequence is valid indented or flush-left. Obsidian writes
        # "  - tag"; ruamel writes "- tag". Requiring indentation silently
        # returned an empty vocabulary, which would have starved the tagger of
        # the frequency signal it depends on.
        _TAGS_BLOCK_RE = re.compile(r"^tags[ \t]*:[ \t]*(.*(?:\n[ \t]*-[ \t].*)*)",
                                    re.MULTILINE)
    return _FENCE_RE, _INLINE_CODE_RE, _TAG_RE, _TAGS_BLOCK_RE


def _is_plausible_tag(tag: str) -> bool:
    """Obsidian rejects purely numeric tags. Hex colour literals and heading
    anchors otherwise pollute the vocabulary badly enough to skew the frequency
    signal the tagger depends on."""
    if not tag or tag.replace("/", "").replace("-", "").replace("_", "").isdigit():
        return False
    return True


def vocabulary_from_disk(vault: Path) -> Dict[str, int]:
    """Tag vocabulary parsed straight from the vault.

    Used by the cloud tagger, which cannot call `obsidian tags` (spec sec.5).
    Code blocks are stripped first because Obsidian ignores tags inside them --
    without that, every `#FFFFFF` in a CSS snippet becomes a tag.
    """
    import collections
    import re
    fence_re, code_re, tag_re, tags_block_re = _tag_patterns()
    counts: collections.Counter = collections.Counter()

    for rel in C.walk_vault(vault):
        try:
            text = (vault / rel).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        fm_text, body = split_frontmatter(text)

        if fm_text:
            block = tags_block_re.search(fm_text)
            if block:
                for tag in re.findall(r"[A-Za-z0-9_][A-Za-z0-9_/-]*", block.group(1)):
                    if _is_plausible_tag(tag):
                        counts[tag] += 1

        body = fence_re.sub("", body)
        body = code_re.sub("", body)
        for tag in tag_re.findall(body):
            if _is_plausible_tag(tag):
                counts[tag] += 1
    return dict(counts)


def run(conn, vault: Optional[Path] = None, dry_run: bool = False,
        max_tag: Optional[int] = None, full_rehash: bool = False,
        invoker=None) -> RunReport:
    vault = Path(vault or config.VAULT)
    run_start = _now()
    report = RunReport(run_start=run_start, dry_run=dry_run, full_rehash=full_rehash)

    # step 1
    disk = C.walk_vault(vault)
    report.observed = len(disk)
    report.conflict_forks = C.find_conflict_forks(vault)

    rows = {p: dict(r) for p, r in manifest.load_all(conn).items()}

    # steps 2-3
    plan = C.classify(vault, disk, rows, full_rehash=full_rehash)
    report.hashed = plan.hashed
    by_case = plan.by_case()
    report.counts = {C.CASE_NAMES[c]: len(v) for c, v in by_case.items()}

    if dry_run:
        report.notes.append("dry run: no writes, no tagging")
        return report

    # step 4 -- tagging happens before the transaction opens so no write lock is
    # held across LLM calls.
    #
    # The queue is newly-classified work (cases 1 and 5) PLUS anything still
    # marked `pending` from an earlier run -- deferred by the ceiling, or failed.
    # Without the carry-over the ceiling would drop files rather than defer them.
    to_tag = [
        d for d in plan.decisions
        if d.stat is not None and (
            d.needs_tagging or (rows.get(d.path, {}).get("status") == "pending")
        )
    ]
    ceiling = config.MAX_TAG_PER_RUN if max_tag is None else max_tag
    deferred = []
    if ceiling >= 0 and len(to_tag) > ceiling:
        deferred = to_tag[ceiling:]
        to_tag = to_tag[:ceiling]
        report.notes.append("%d file(s) deferred to a later run by the tagging ceiling"
                            % len(deferred))

    # Never write to a file open in the editor with possibly-unsaved changes.
    open_paths = set(obsidian.open_file_paths()) if obsidian.installed() else set()
    if open_paths:
        keep = []
        for d in to_tag:
            if d.path in open_paths:
                report.skipped_open.append(d.path)
            else:
                keep.append(d)
        to_tag = keep

    tag_results: Dict[str, tagger.TagResult] = {}
    if to_tag:
        vocab = _vocabulary()
        batch_size = max(1, config.TAG_BATCH_SIZE)
        for i in range(0, len(to_tag), batch_size):
            chunk = [d.path for d in to_tag[i:i + batch_size]]
            try:
                tag_results.update(tagger.tag_batch(vault, chunk, vocab, invoker=invoker))
            except Exception as exc:
                report.tag_failures.extend(chunk)
                report.notes.append("tag batch failed: %s" % exc)

    # step 5
    today = _dt.date.today().isoformat()
    updates = {}
    for path, result in tag_results.items():
        props = {"tags": result.tags, "tagged": today}
        stat_for = next((d.stat for d in to_tag if d.path == path), None)
        if stat_for:
            props["tagged_hash"] = stat_for.hash
        if result.type:
            props["type"] = result.type
        updates[path] = props

    written: List[str] = []
    if updates:
        try:
            written, mechanism = writer.write(vault, updates)
            report.write_mechanism = mechanism
        except Exception as exc:
            report.notes.append("frontmatter write failed: %s" % exc)
            report.tag_failures.extend(updates.keys())
            written = []

    # steps 3, 5, 6, 7 -- one transaction
    with manifest.transaction(conn) as tx:
        for d in plan.decisions:
            if d.case == C.MOVED:
                manifest.repoint(tx, d.from_path, d.path, d.mtime, d.file_bytes, run_start)
            elif d.case == C.UNCHANGED:
                if d.path in rows:
                    manifest.touch(tx, d.path, d.mtime, d.file_bytes, run_start)
                elif d.stat:
                    manifest.upsert(tx, _row(d, run_start, "pending"))
            elif d.case == C.CHEAP_EDIT:
                manifest.upsert(tx, _row(d, run_start, rows.get(d.path, {}).get("status")))
            else:  # NEW or REAL_EDIT
                manifest.upsert(tx, _row(d, run_start, "pending"))

        # Applied uniformly rather than per-case: a successfully tagged file may
        # have been classified NEW, REAL_EDIT, or UNCHANGED (a pending retry).
        for path in written:
            stat = next((d.stat for d in to_tag if d.path == path), None)
            manifest.mark_tagged(tx, path, stat.hash if stat else "", run_start)

        # Attempted but not written: count it, and stop retrying after the cap.
        for path in report.tag_failures:
            manifest.record_tag_failure(tx, path, config.MAX_TAG_ATTEMPTS)

        report.deleted = manifest.sweep_deleted(tx, run_start)
        manifest.set_meta(tx, "last_run_at", run_start)
        if full_rehash:
            manifest.set_meta(tx, "last_sweep_at", run_start)
        manifest.set_meta(tx, "prompt_version", tagger.PROMPT_VERSION)

    report.tagged = list(written)

    # step 8 -- one line per action, outside the transaction so rolled-back runs
    # still leave a trace.
    for path in written:
        result = tag_results.get(path)
        if result is None:
            # Should be unreachable now that writes are verified on disk, but a
            # KeyError here would abort the run *after* the manifest committed,
            # losing the log for work that actually happened.
            report.notes.append("wrote %s but have no tagger result for it" % path)
            logcsv.append("tag", path, "frontmatter written; tagger result missing")
            continue
        logcsv.append("tag", path, "tags %s%s%s" % (
            ", ".join(result.tags),
            "; type=%s" % result.type if result.type else "",
            "; %s" % result.summary if result.summary else "",
        ))
    for d in by_case.get(C.MOVED, []):
        logcsv.append("move", d.path, "moved from %s; no re-tag" % d.from_path)
    for path in report.deleted:
        logcsv.append("delete", path, "not observed this run; marked deleted (grace period)")
    for path in report.tag_failures:
        logcsv.append("tag-failed", path,
                      "tagger or write failed; will retry up to %d times"
                      % config.MAX_TAG_ATTEMPTS)
    for path in report.conflict_forks:
        logcsv.append("conflict-fork", path, "sync conflict fork detected; excluded from ingest")
    logcsv.append("run", ".system/wiki/manifest.sqlite", report.summary_line())
    return report


def _row(d, seen_at: str, status: Optional[str]) -> dict:
    return {
        "path": d.path,
        "mtime": d.mtime,
        "file_bytes": d.file_bytes,
        "body_hash": d.stat.hash if d.stat else "",
        "body_bytes": d.stat.bytes if d.stat else None,
        "body_lines": d.stat.lines if d.stat else None,
        "status": status or "pending",
        "tagged_hash": None,
        "tagged_at": None,
        "seen_at": seen_at,
    }


# --- rebuild ---------------------------------------------------------------

def rebuild(conn, vault: Optional[Path] = None) -> dict:
    """Reconstruct the manifest from the vault (spec sec.4).

    Nearly free: zero LLM calls except for files whose body has moved since
    `tagged_hash` was written. That is the whole point of the breadcrumb -- a
    `tagged` date alone would silently absorb edits made while the DB was gone.
    """
    vault = Path(vault or config.VAULT)
    run_start = _now()
    disk = C.walk_vault(vault)
    stats = {"rows": 0, "tagged": 0, "requeued": 0, "untagged": 0}

    with manifest.transaction(conn) as tx:
        tx.execute("DELETE FROM notes")
        for rel, entry in disk.items():
            text = (vault / rel).read_text(encoding="utf-8", errors="replace")
            fm_text, _ = split_frontmatter(text)
            stat = body_stat(vault / rel)
            tagged = read_frontmatter_scalar(fm_text, "tagged")
            tagged_hash = read_frontmatter_scalar(fm_text, "tagged_hash")

            if tagged and tagged_hash == stat.hash:
                status = "tagged"
                stats["tagged"] += 1
            elif tagged:
                # Tagged once, but the body has changed since -- or predates
                # tagged_hash. Re-queue rather than assume current.
                status = "pending"
                stats["requeued"] += 1
            else:
                status = "pending"
                stats["untagged"] += 1

            manifest.upsert(tx, {
                "path": rel, "mtime": entry.mtime, "file_bytes": entry.size,
                "body_hash": stat.hash,
                "body_bytes": stat.bytes, "body_lines": stat.lines,
                "status": status, "tagged_hash": tagged_hash,
                "tagged_at": tagged, "seen_at": run_start,
            })
            stats["rows"] += 1
        manifest.set_meta(tx, "last_rebuild_at", run_start)

    logcsv.append("rebuild", ".system/wiki/manifest.sqlite",
                  "rebuilt %d rows from frontmatter breadcrumbs: %d tagged, %d requeued, %d never tagged"
                  % (stats["rows"], stats["tagged"], stats["requeued"], stats["untagged"]))
    return stats


def prune(conn) -> dict:
    """Hard-delete tombstones past the grace period, then VACUUM (spec sec.4)."""
    with manifest.transaction(conn) as tx:
        removed = manifest.hard_delete_expired(tx, config.DELETE_GRACE_DAYS)
        manifest.set_meta(tx, "last_prune_at", _now())
    conn.execute("VACUUM")
    logcsv.append("prune", ".system/wiki/manifest.sqlite",
                  "hard-deleted %d tombstone(s) older than %d days; vacuumed"
                  % (len(removed), config.DELETE_GRACE_DAYS))
    return {"removed": len(removed)}


def sweep_due(conn) -> bool:
    age = manifest.days_since_meta(conn, "last_sweep_at")
    return age is None or age >= config.SWEEP_INTERVAL_DAYS


def prune_due(conn) -> bool:
    age = manifest.days_since_meta(conn, "last_prune_at")
    return age is None or age >= config.PRUNE_INTERVAL_DAYS
