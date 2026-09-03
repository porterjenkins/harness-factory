---
name: log-manager
description: Read from or append to the knowledge base action log at .system/log/log-YYYY-MM.csv. Use this skill whenever you need to record an action you took in the vault (ingesting, tagging, editing, creating notes, running a workflow), or when you need to find out what happened in the vault recently — "what did you do yesterday", "what changed this week", "when was this note last touched", "show me recent activity". Also use before reading any log file, since reading it wrong will flood the context window.
tags:
  - skill
  - knowledge-base
  - automation
  - reference
tagged: 2026-08-27
tagged_hash: b2cd50aac9996f86
type: concept
---

# Log Manager

The action log is the audit trail for everything an agent does in this vault.

**File:** `.system/log/log-YYYY-MM.csv`, rotated monthly.
**Fields:** `timestamp|action|path|summary` — pipe-delimited, no header row.

## Appending

One line per **action**, not per run. A run that tags 12 notes writes 12 lines.

```bash
echo "$(date -Iseconds)|tag|Projects/<project>/<note>.md|added tags <project>/<subproject>, mongodb" \
  >> .system/log/log-$(date +%Y-%m).csv
```

Rules, all of which break the file if ignored:

- **`summary` must be a single line.** Strip newlines.
- **Strip `|` from every field** — it is the delimiter. Replace with `/`.
- Never rewrite or reorder existing lines. Append only.
- Use ISO-8601 for the timestamp.

The pipeline does this for you via `.system/wiki/logcsv.py`, which sanitises
automatically. Prefer that over hand-rolled `echo` when you're already in Python.

Conventional `action` values: `tag`, `move`, `delete`, `edit`, `create`,
`rebuild`, `prune`, `run`, `search`, `tag-failed`, `conflict-fork`,
`spec-revision`.

`search` is logged once per retrieval task (see `doc-retrieval`), not once per
`obsidian` call — a fuzzy question's 3–5 expansion queries collapse to a single
log line.

## Reading — never `cat` the whole file

The log grows unbounded within a month and reading it whole will blow your
context for no benefit. Always narrow first.

```bash
tail -20 .system/log/log-$(date +%Y-%m).csv                      # recent activity
grep "|Projects/<project>/" .system/log/log-2026-08.csv | tail -5    # one folder
grep "^2026-08-07" .system/log/log-2026-08.csv                   # one day
grep "|tag|" .system/log/log-2026-08.csv | wc -l                 # how much tagging
cut -d'|' -f1,4 .system/log/log-2026-08.csv | tail -30           # readable timeline
awk -F'|' '$2=="tag-failed"' .system/log/log-2026-08.csv          # failures only
```

For a date range spanning months, select the month files first:

```bash
cat .system/log/log-2026-0[67].csv | grep "|tag|" | cut -d'|' -f1,3
```

That `cat` is fine because it is immediately narrowed. A bare
`cat .system/log/log-2026-08.csv` is not.

## Rotation

The filename carries the month, so rotation is automatic — a new month means a
new file the first time anything appends. Nothing to schedule. Do not
consolidate old months into one file; the whole point is that `tail` stays cheap.

## Pipeline run logs

`launchd` stdout/stderr for the ingestion job land in `.system/log/run-logs/`.
Those are debugging output, not the audit trail — transient, safe to delete, and
not the same thing as `log-YYYY-MM.csv`.
