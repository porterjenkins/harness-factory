#!/usr/bin/env python3
"""Command-line entrypoint for the wiki ingestion pipeline.

    python3 .system/wiki/cli.py doctor          # verify the environment
    python3 .system/wiki/cli.py init            # create .system/wiki/manifest.sqlite
    python3 .system/wiki/cli.py run --dry-run   # classify, change nothing
    python3 .system/wiki/cli.py run             # the real thing (LaunchAgent runs this)
    python3 .system/wiki/cli.py rebuild         # reconstruct manifest from frontmatter
    python3 .system/wiki/cli.py prune           # hard-delete expired tombstones
    python3 .system/wiki/cli.py status          # manifest counts
    python3 .system/wiki/cli.py vocab           # tag vocabulary with counts
    python3 .system/wiki/cli.py tag-lint        # drift report
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

if __package__ in (None, ""):  # allow direct execution
    # .system/wiki/cli.py -> parents[1] = .system/. That directory goes on
    # sys.path so `wiki` imports as a top-level package. The vault root can
    # NOT be used here the way Tools/ was: ".system" is not a legal Python
    # identifier, so `from .system.wiki import ...` is a syntax error.
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from wiki import (classify as C, config, logcsv, manifest, obsidian,
                      pipeline, taglint)
else:  # pragma: no cover
    from . import classify as C, config, logcsv, manifest, obsidian, pipeline, taglint


def cmd_doctor(args) -> int:
    ok = True

    def check(label, passed, detail=""):
        nonlocal ok
        ok = ok and passed
        print("%s %s%s" % ("PASS" if passed else "FAIL", label,
                           "  -- %s" % detail if detail else ""))

    print("vault:        %s" % config.VAULT)
    print("vault name:   %s" % config.VAULT_NAME)
    print("manifest:     %s" % config.MANIFEST)
    print()

    check("vault exists", config.VAULT.is_dir())
    check(".system/ exists", config.SYSTEM_DIR.is_dir(),
          "run `init`" if not config.SYSTEM_DIR.is_dir() else "")
    check("manifest exists", config.MANIFEST.exists(),
          "run `init`" if not config.MANIFEST.exists() else "")

    md = C.walk_vault(config.VAULT)
    check("markdown files found", bool(md), "%d file(s)" % len(md))

    forks = C.find_conflict_forks(config.VAULT)
    check("no sync conflict forks", not forks,
          "%d found: %s" % (len(forks), ", ".join(forks[:3])) if forks else "")

    import shutil
    check("claude on PATH", shutil.which(config.CLAUDE_BIN) is not None,
          "tagging will fail without it" if not shutil.which(config.CLAUDE_BIN) else "")

    # Not running / window closed are legitimate operating modes (the pipeline
    # falls back to disk), so they are INFO, not FAIL. Only a vault that SHOULD
    # be reachable -- socket up, window open -- failing to answer is a defect.
    has_sock = obsidian.socket_present()
    window_open = has_sock and obsidian.vault_window_open()
    if not has_sock:
        print("INFO obsidian not running (no CLI socket) -- disk fallbacks in use")
    elif not window_open:
        print("INFO vault window closed in Obsidian -- disk fallbacks in use "
              "(deliberate: sending any CLI command to a closed vault opens its window)")
    has_cli = has_sock and window_open
    if has_cli:
        check("vault window open in Obsidian", True)
        live = obsidian.available()
        check("obsidian app responding", live,
              "socket present but no reply -- stale socket or app hung; "
              "start/restart Obsidian" if not live else "")
        if live:
            ready = obsidian.wait_until_ready(timeout=20)
            check("metadataCache warm", ready, "count still moving after 20s" if not ready else "")
            try:
                check("tag vocabulary readable", bool(obsidian.tag_counts()) or True,
                      "%d tag(s)" % len(obsidian.tag_counts()))
            except Exception as exc:
                check("tag vocabulary readable", False, str(exc)[:120])

    try:
        import ruamel.yaml  # noqa: F401
        print("INFO ruamel.yaml available (cloud write path ready)")
    except ImportError:
        print("INFO ruamel.yaml not installed -- fine while the Obsidian CLI is the write path")

    print("\n%s" % ("all checks passed" if ok else "one or more checks FAILED"))
    return 0 if ok else 1


def cmd_init(args) -> int:
    config.SYSTEM_DIR.mkdir(parents=True, exist_ok=True)
    conn = manifest.connect()
    manifest.init(conn)
    print("initialised %s (schema v%d)" % (config.MANIFEST, manifest.SCHEMA_VERSION))
    existing = conn.execute("SELECT COUNT(*) AS n FROM notes").fetchone()["n"]
    if existing == 0:
        print("manifest is empty -- run `rebuild` to seed it from the vault, "
              "or `run` to ingest incrementally")
    logcsv.append("init", ".system/wiki/manifest.sqlite",
                  "manifest initialised, schema v%d" % manifest.SCHEMA_VERSION)
    return 0


def cmd_run(args) -> int:
    conn = manifest.connect()
    manifest.init(conn)

    full = args.full_rehash
    if not full and not args.dry_run and pipeline.sweep_due(conn):
        full = True
        print("[weekly full-rehash sweep due]")

    report = pipeline.run(conn, dry_run=args.dry_run, max_tag=args.max_tag,
                          full_rehash=full)

    print("run %s%s" % (report.run_start, "  (dry run)" if report.dry_run else ""))
    print("  " + report.summary_line())
    for path in report.tagged:
        print("  tagged   %s" % path)
    for note in report.notes:
        print("  note: %s" % note)
    if report.conflict_forks:
        print("  WARNING sync conflict forks present, excluded from ingest:")
        for path in report.conflict_forks:
            print("    %s" % path)
    if report.skipped_open:
        print("  skipped (open in editor, retry next run): %s"
              % ", ".join(report.skipped_open))

    if not args.dry_run and pipeline.prune_due(conn):
        stats = pipeline.prune(conn)
        print("  pruned %d expired tombstone(s)" % stats["removed"])
    return 0


def cmd_rebuild(args) -> int:
    conn = manifest.connect()
    manifest.init(conn)
    stats = pipeline.rebuild(conn)
    print("rebuilt %d row(s): %d tagged, %d requeued (body changed since tagged_hash), "
          "%d never tagged" % (stats["rows"], stats["tagged"], stats["requeued"],
                               stats["untagged"]))
    return 0


def cmd_prune(args) -> int:
    conn = manifest.connect()
    manifest.init(conn)
    print("hard-deleted %d expired tombstone(s)" % pipeline.prune(conn)["removed"])
    return 0


def cmd_retry_failed(args) -> int:
    conn = manifest.connect()
    manifest.init(conn)
    with manifest.transaction(conn) as tx:
        n = manifest.reset_failed(tx)
    logcsv.append("retry-failed", ".system/wiki/manifest.sqlite",
                  "reset %d file(s) from failed back to pending" % n)
    print("reset %d file(s) from 'failed' back to 'pending'" % n)
    return 0


def cmd_status(args) -> int:
    conn = manifest.connect()
    manifest.init(conn)
    counts = manifest.counts_by_status(conn)
    total = sum(counts.values())
    print("manifest: %s" % config.MANIFEST)
    print("rows:     %d" % total)
    for status, n in sorted(counts.items()):
        print("  %-8s %d" % (status, n))
    if counts.get("failed"):
        print("  -> %d file(s) gave up after %d tagging attempts; "
              "inspect with `grep '|tag-failed|' .system/log/log-*.csv`, "
              "then `retry-failed` to requeue"
              % (counts["failed"], config.MAX_TAG_ATTEMPTS))
    for key in ("last_run_at", "last_sweep_at", "last_prune_at", "last_rebuild_at",
                "prompt_version", "schema_version"):
        value = manifest.get_meta(conn, key)
        if value:
            print("  %-16s %s" % (key, value))
    print("on disk:  %d markdown file(s)" % len(C.walk_vault(config.VAULT)))
    return 0


def cmd_vocab(args) -> int:
    try:
        counts = obsidian.tag_counts() if obsidian.installed() else {}
    except Exception as exc:
        print("obsidian tag read failed (%s); falling back to frontmatter scan" % exc,
              file=sys.stderr)
        counts = {}
    if not counts:
        counts = pipeline.vocabulary_from_disk(config.VAULT)
    if args.json:
        print(json.dumps(counts, indent=2, sort_keys=True))
    else:
        for tag, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
            print("%6d  %s" % (n, tag))
    return 0


def cmd_tag_lint(args) -> int:
    try:
        counts = obsidian.tag_counts() if obsidian.installed() else {}
    except Exception:
        counts = {}
    if not counts:
        counts = pipeline.vocabulary_from_disk(config.VAULT)

    report = taglint.resolve_vocabulary(counts, config.VAULT,
                                        force_frequency=args.frequency)
    findings = report["near_duplicates"]
    singles = report["singletons"]

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    print("%d tag(s) in vocabulary" % len(counts))
    if report["mode"] == "canon":
        cov = report["coverage"]
        print("canon mode -- %d tag(s) declared in %s (covers %d/%d established, %.0f%%)"
              % (report["canon_size"], report["canon_path"],
                 cov["listed"], cov["established"], 100 * cov["coverage"]))
    else:
        print("frequency mode -- %s" % report["fallback_reason"])
    print()

    if findings:
        header = ("Variants of a declared tag (tags.md spelling wins):"
                  if report["mode"] == "canon"
                  else "Probable duplicates (keep the higher count):")
        print(header)
        for f in findings:
            merges = ", ".join("%s (%d)" % (m["tag"], m["count"]) for m in f["merge"])
            print("  %s (%d)  <-  %s   [%s]"
                  % (f["keep"], f["keep_count"], merges, f["reason"]))
    else:
        print("No near-duplicate tags found.")

    if report["mode"] == "canon":
        unlisted = report["unlisted"]
        if unlisted:
            print("\nIn the vault but not in tags.md (%d) -- add to the list or "
                  "merge by hand; nothing is proposed for these:" % len(unlisted))
            for tag, n in unlisted:
                print("  %6d  %s" % (n, tag))
        unused = report["coverage"]["unused_canon"]
        if unused:
            print("\nDeclared but unused (%d): %s" % (len(unused), ", ".join(unused)))
    elif report["coverage"] is not None:
        miss = report["coverage"]["missing"][:10]
        if miss:
            print("\ntags.md was found but not used. Established tags it omits: %s"
                  % ", ".join("%s (%d)" % (m["tag"], m["count"]) for m in miss))

    if singles:
        print("\nSingle-use tags (%d) -- drift suspects, but a new project "
              "legitimately starts here:" % len(singles))
        print("  " + ", ".join(t for t, _ in singles))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="wiki", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("doctor", help="verify the environment").set_defaults(func=cmd_doctor)
    sub.add_parser("init", help="create the manifest").set_defaults(func=cmd_init)

    p_run = sub.add_parser("run", help="one ingestion pass")
    p_run.add_argument("--dry-run", action="store_true",
                       help="classify and report; change nothing")
    p_run.add_argument("--max-tag", type=int, default=None,
                       help="per-run tagging ceiling (-1 for no limit)")
    p_run.add_argument("--full-rehash", action="store_true",
                       help="hash every file, ignoring the mtime pre-filter")
    p_run.set_defaults(func=cmd_run)

    sub.add_parser("rebuild", help="reconstruct manifest from frontmatter").set_defaults(func=cmd_rebuild)
    sub.add_parser("prune", help="hard-delete expired tombstones").set_defaults(func=cmd_prune)
    sub.add_parser("retry-failed",
                   help="requeue files that gave up after repeated tagging failures"
                   ).set_defaults(func=cmd_retry_failed)
    sub.add_parser("status", help="manifest summary").set_defaults(func=cmd_status)

    p_vocab = sub.add_parser("vocab", help="tag vocabulary with counts")
    p_vocab.add_argument("--json", action="store_true")
    p_vocab.set_defaults(func=cmd_vocab)

    p_lint = sub.add_parser("tag-lint", help="tag drift report")
    p_lint.add_argument("--json", action="store_true")
    p_lint.add_argument("--frequency", action="store_true",
                        help="ignore tags.md and lint on frequency alone")
    p_lint.set_defaults(func=cmd_tag_lint)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
