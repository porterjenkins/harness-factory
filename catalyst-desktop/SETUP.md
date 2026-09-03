---
title: SETUP.md — Vault Configuration Runbook
type: architecture
created: 2026-08-18
updated: 2026-09-02
---

# Overview

How to stand up a personal knowledge-base vault: Obsidian for reading and search, markdown files
as the only storage format, and an agent doing the filing, tagging, linking and metadata.

**Most of this used to be a manual runbook and is now automated.** `build/build-vault.sh` does
the install, the directory skeleton, the five root documents, the machinery, the connectors, the
manifest and the first tagging pass. What is left here is what a script cannot do: verify the
environment, get honest answers into the template, judge the first ten tags, and register the
scheduled routines.

Read this whole file before running anything.

---

## 0. Agent contract

Five rules for this run:

1. **Work in order.** The phases below have real dependencies. Tagging in particular is
   destructive-by-accumulation and must not run before content import.
2. **The template carries the answers — do not invent them.** `build/TEMPLATE.md` is the input
   contract. A wrong guess about the user's projects, name or folder taxonomy gets baked into
   `CLAUDE.md` and every tag that follows. But once the template is filled, *writing* the vault
   is the build's job, not the user's.
3. **Never write outside the vault** except where a phase explicitly says so
   (`~/Library/LaunchAgents/`, the agent's scheduled-task store at `~/.claude/scheduled-tasks/`).
4. **Stop, don't improvise, on a hard stop.** Where a phase says *escalate*, tell the user to
   contact their implementation engineer and halt that phase. Do not substitute a different tool
   or a degraded path silently.
5. **Log every phase you complete** to `.system/log/log-YYYY-MM.csv`, pipe-delimited
   `timestamp|action|path|summary`. One line per phase, not per file.

Nothing counts as done until the handoff summary in Phase 5 is written.

---

## 1. Preflight — verify the environment

`build-vault.sh` checks most of this itself and fails loudly. Run it by hand first if you want the
report before committing to a build.

```bash
uname -s                      # Darwin (macOS) or a Windows environment
python3 -V                    # 3.9 or newer
python3 -c 'import ruamel.yaml'   # REQUIRED — see below
node -v                       # 18 or newer (only for the Granola exporter)
which claude                  # required for tagging
which obsidian                # required for search/retrieval
ls -d /Applications/Obsidian.app 2>/dev/null
```

| Requirement | If missing | Hard stop? |
| --- | --- | --- |
| Claude Code or Claude Cowork | escalate | **Yes** |
| `python3` ≥ 3.9 | ask user to install | **Yes** |
| `ruamel.yaml` | `pip3 install ruamel.yaml` | **Yes**, for tagging — see below |
| `claude` on `PATH`, signed in | ask user to install and sign in | **Yes** — no tagging without it |
| Obsidian desktop app | install from obsidian.md | **Yes** — the CLI is only a client |
| `obsidian` CLI on `PATH` | see below | No — degraded mode |
| `node` ≥ 18 | only blocks the Granola exporter | No |

**`ruamel.yaml` is the one that hides.** The tagger writes frontmatter through it whenever
Obsidian is not running — and a vault the build just created is never open in Obsidian, so that
is always the path taken on a fresh build. `cli.py doctor` reports its absence as INFO, not FAIL,
so without an explicit check the build passes every gate and then fails at write time.
`build-vault.sh` checks it in Phase 1 and refuses to continue.

**The Obsidian CLI is not the app.** The binary (usually `/usr/local/bin/obsidian`) is a client
that talks to the running GUI process and does nothing without it. Consequence that shapes the
whole design: *ingestion runs anywhere; retrieval only runs locally, with Obsidian open.*

Without the CLI you are in **no-app mode**: `ruamel.yaml` becomes mandatory, search and retrieval
are unavailable until the CLI is installed, and you must say so. Do not silently fall back to
`grep` in place of Obsidian search — a degraded search is how a confidently wrong "I found
nothing" gets delivered.

**Vault location.** Confirm the absolute path is where the vault will live long-term. Every
LaunchAgent and scheduled task bakes it in; moving the vault afterward breaks all of them. Note
whether it sits inside a cloud-sync folder — a Google Drive virtual mount changes the SQLite
journal mode, and `# Sync` in the template drives the exclusion rules.

---

## 2. Fill in the implementation template

Copy `build/TEMPLATE.md`, fill it in with the user, and keep it — it is the vault's build record.
The comments in the file explain each section. Three rules that are not obvious from reading it:

**Verify every source; do not take the user's word.** A role in `# Sources` may only name a tool
you have confirmed is reachable *from your session* — an MCP server or connector you can actually
enumerate, not a product the user owns a licence for. Anything unverified is `none`, which the
skills handle explicitly by naming what they skipped. A role that names an absent tool is worse
than `none`: the skill treats it as stale and reports a gap the user then has to debug.

**Ask about private channels and DMs for `chat`.** `daily-plan` needs that scope to find messages
awaiting a reply. Record the answer and the date in the notes column — that is what stops it
re-prompting on every scheduled run.

**A misspelled role is fatal, by design.** The build rejects any role outside
`vault meetings calendar chat email issues code second-vault memory web`, because a typo'd role
is indistinguishable at run time from a disconnected one and silently disables its skill.

---

## 3. Build

```bash
./build/build-vault.sh --template <filled.md> --out <vault path>
```

Add `--dry-run` first to see the parsed template and the planned tree without writing anything.
`--offline` builds the full structure with canned prose and no model calls — useful for checking
the shape, useless as a deliverable.

The build runs eleven phases and ends with a blocking verification gate. It is safe to re-run:
generation is cached, and a non-empty target requires `--force` and is backed up first.

**Import existing content before the tagging phase**, not after. For an Evernote export use the
`evernote-to-obsidian` skill; for loose markdown, copy it into the right `Projects/{name}/`
folders and re-run with `--skip-tagging` first, then tag. Tagging an empty vault teaches the
tagger nothing, and the review gate below is only meaningful against real content.

Anything other than Evernote or plain markdown: **escalate**.

---

## 4. The review gate — the one step that needs a human

The build tags a sample of ten notes and **stops**. Put those tags in front of the user.

This pause is the most important step in this file. The tagger prefers existing high-count tags,
so the first tags it writes shape every tag that follows: bad early tags propagate through the
whole vault, and `tag-lint` then has to clean up after them. Ten reviewed tags now is worth an
afternoon of merges later.

```bash
cd <vault> && python3 .system/wiki/cli.py run --max-tag -1   # only after the user approves
```

If the tags are wrong: revert (`git checkout -- .` if the vault is under git), edit the prompt in
`.system/wiki/tagger.py`, and retry the sample. Do not proceed on a bad sample because the user
seems impatient. If editing `tagger.py` does not fix it, **escalate**.

---

## 5. Register the routines, then hand off

The build writes each `Routines/*.md` with its real Task ID and cron, confirms each one with the
user, and records the confirmed list at `.system/routines-confirmed.txt`. It cannot register them.

**Why not.** Three different schedulers are involved, and only two are scriptable:

| What | Mechanism | Scriptable? |
| --- | --- | --- |
| Granola export | `~/Library/LaunchAgents/<prefix>.granola-export.plist`, 30 min | **Yes** — `--install-agents` |
| Wiki ingestion | `~/Library/LaunchAgents/<prefix>.wiki-ingest.plist`, 15 min | **Yes** — `--install-agents` |
| Local scheduled tasks | `create_scheduled_task` — **Claude Desktop agent mode only** | **No** |
| Cloud routines | `RemoteTrigger` → claude.ai, runs in a remote sandbox | Yes, but cannot reach a local vault |

The routine *prompt* is a file on disk and the build writes it. The *schedule* is not, and the CLI
cannot bind it. `create_scheduled_task` — the tool that makes a task which runs **locally**, on
this Mac, against this vault — ships only with Claude Desktop agent mode. `CronCreate` is
available in the CLI but is session-scoped and in-memory, so the job dies with the process.
`RemoteTrigger` is also available and is a trap: it creates a routine that runs in a remote
sandbox, which registers cleanly and then fails every run because it cannot see this vault.

So the last mile is one paste, in **Claude Desktop (agent mode)**:

```
open .system/routines-register.md, paste it into Claude Desktop, confirm what it registered
```

Adjust times to the user's timezone and working hours; the bundled defaults are somebody else's
schedule. Skip any routine whose dependencies the user does not have — a Slack-reading step with
no Slack connected — and say which ones you skipped and why.

**Handoff summary.** Report: the vault path and its `vault=<name>`; which roles are connected and
which are `none`; which skills and routines are installed and which are registered; the tag
sample the user approved; and what is left for them to do.

---

## Appendix A — Escalation triggers

Stop the affected phase and tell the user to contact their implementation engineer:

- The agent is not Claude Code or Claude Cowork.
- The meeting platform is not Granola.
- The import source is not Evernote or plain markdown.
- `claude` cannot be installed or signed in — nothing gets tagged without it.
- Obsidian cannot be installed — the vault still works as markdown, but there is no retrieval.
- The tagging sample is wrong and editing `tagger.py` does not fix it.
- `cli.py doctor` reports a failure you cannot explain from this file.

Escalating is not a failure. Silently substituting a different tool, or a degraded search path,
is.

## Appendix B — Design decisions not to undo

Reasons behind choices that look arbitrary and get "fixed" by the next person:

- **`.system/` is dot-prefixed** to get Obsidian indexing *and* Obsidian Sync exclusion from one
  naming decision. Git and Google Drive do **not** skip dotfolders and need explicit rules.
- **The manifest holds change-detection state only** — no tags, no properties, no content. Those
  live in frontmatter and are queried through Obsidian. That keeps the manifest disposable.
- **`tagged_hash` is not decoration.** A `tagged` date proves a file was tagged, not what it
  looked like. Without the hash, a manifest rebuild silently absorbs any edit made while the
  database was missing — and multi-machine tagging stops being safe.
- **The change pre-filter checks mtime AND size, compared by inequality, never `>`.** mtime does
  not advance monotonically once sync is involved. The weekly full-rehash sweep catches what both
  miss.
- **Tagging happens outside the write transaction**, so the SQLite write lock is not held across
  minutes of LLM calls.
- **Writes are verified on disk, not trusted.** After writing, the pipeline re-reads each file's
  frontmatter and confirms `tagged_hash` matches.
- **Tagging failures are capped** at 3 attempts, then marked `failed`. Files deferred by the
  per-run ceiling stay `pending` and *are* carried forward — the ceiling must defer, never drop.
- **`CLAUDE.md` and `README.md` are excluded from tagging.** Tagging them pollutes the vocabulary
  with the vault's own instructions and rewrites the file agents read every session.
- **`domain` is derived from folder path**, never stored in frontmatter.
- **Structure is written by bash and is exact; prose is generated.** Every planning skill parses
  something — `SOURCES.md`'s two tables, `CLAUDE.md`'s project list, each routine's Task ID and
  cron. The build splices those in after generation rather than trusting a model to reproduce
  them. See `build/README.md`.

## Appendix C — Hardcoded values

Three ways a value stops being hardcoded, best first:

1. **Self-location** — the file resolves its own path at runtime. Nothing to substitute, and it
   survives the user moving the vault later.
2. **Token rendering** — `{{VAULT_PATH}}` and friends. Verifiable: "no `{{` remains" is a
   complete check.
3. **Literal substitution** — rewriting an authoring vault's actual values. Lossy by nature; only
   proves someone thought of every literal.

Self-locating, and needing no substitution at all: `.system/wiki/config.py`
(`Path(__file__).resolve().parents[2]`), `.system/wiki/bootstrap.sh` and
`launchagent/install.sh` (`$HERE/../..`), `.system/connectors/granola-export/run.sh`
(`BASH_SOURCE`), and `export.mjs` (`import.meta.url`). Keep it that way — a vault that
self-locates is one that survives being moved.
