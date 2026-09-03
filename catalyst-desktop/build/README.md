# Vault builder

Builds a working PARA knowledge vault from a filled-in implementation-interview
template. This is the automation of `SETUP.md` phases 3–14 — the manual runbook an
agent otherwise walks a customer through by hand.

```bash
./build-vault.sh --template ./filled.md --out ~/notes/my-vault
./build-vault.sh --template ./filled.md --out /tmp/v --dry-run   # parse + plan only
./build-vault.sh --template ./filled.md --out /tmp/v --offline   # no model calls
./build-verify.sh ~/notes/my-vault                               # the gate, standalone
```

Both `--template` and `--out` are required. Start from `TEMPLATE.md`.

## Flags

| Flag | Default | Notes |
| --- | --- | --- |
| `--template` | *required* | the filled-in interview template |
| `--out` | *required* | target vault directory; absolutised |
| `--name` | folder basename | the `obsidian vault=<name>` parameter; warns if it disagrees |
| `--label-prefix` | `com.knowledgebase` | reverse-DNS prefix for launchd labels |
| `--today` | today | anchors every generated date |
| `--model` | `sonnet` | passed to `claude -p` |
| `--jobs` | 4 | concurrent generations |
| `--offline` | off | deterministic stubs, no model calls. The fast structural loop. |
| `--no-cache` | cache on | prompt→body is cached under `~/.cache/catalyst-sandbox` |
| `--install-agents` | off | actually install the LaunchAgents |
| `--skip-tagging` | off | build the vault, leave the manifest for later |
| `--no-routines` | off | leave routine docs as bundled |
| `--yes` / `-y` | off | confirm every routine without prompting |
| `--force` | off | build into a non-empty directory (existing files backed up first) |
| `--dry-run`, `--no-verify`, `--keep-work` | | |

## The one design rule

**Structure is written by bash and is exact. Prose is generated and is expected to
vary.** Inherited from `tests/README.md`, and it is what makes this safe.

Every planning skill *parses* something here: `SOURCES.md`'s two tables,
`CLAUDE.md`'s project enumeration, `PRIORITIES.md`'s ranked list, each routine's
Task ID and cron. A model that writes a four-column table with three columns
breaks those skills silently and at a distance. So the model writes each document,
and then `_splice` **overwrites** the parsed sections with canonical text built
from the template. Splicing after the fact, rather than asking the model to
reproduce a block verbatim, is what makes the guarantee real instead of hoped-for.

`SOURCES.md` goes further and is assembled entirely in bash. It is a registry, not
an essay — two tables and a list wrapped in rules identical across every vault.
Generating prose around them bought nothing and cost a real hazard: a level-1
splice of `# Connected sources` swallows its own `## Who reads what` child.

## Phases

Numbered to match what they automate in `SETUP.md`.

| # | Phase | SETUP.md |
|---|---|---|
| 1 | Preflight — required args, `ruamel.yaml`, `claude` | §1 |
| 2 | Parse the template, print the plan (`--dry-run` stops here) | §2 |
| 3 | Target safety — refuse `$HOME`, back up a non-empty target | §3 |
| 4 | Install payload: Skills, Routines, `.system/{wiki,connectors}` | §3 |
| 5 | Hydrate `CLAUDE.md` `USER.md` `SOURCES.md` `PRIORITIES.md` `MEMORY.md` | §5–7 |
| 6 | Seed one starter note per project and area | §12a |
| 7 | Machinery: settings, Obsidian config, `.env`, log, templates, exclusions | §7–8, §11 |
| 8 | Connectors | §9 |
| 9 | Manifest: `init` → `doctor` → `rebuild` → `run --dry-run` → `run --max-tag 10` | §12 |
| 10 | Routines — confirmed one at a time | §13 |
| 11 | `build-verify.sh`, then the handoff | §14 |

## Things that bit, and the guards that exist because of them

**A shell variable collision silently disabled generation.** `template_brief` set
`_p` as a plain global; every generator holds its prompt-file path in `_p`. The
brief overwrote the path with a paragraph of prose before `llm_raw` read it, so
`claude` received an empty prompt, all four documents fell back to canned stubs —
and the build reported success, because a stub is structurally perfect. The
function now declares `local`, the generators use `_prompt`/`_body`, and **any
stub fallback on a live build is reported loudly**. A silent fallback is worse
than a crash: it ships a vault whose prose is about nobody.

**`init` must precede `doctor`.** `doctor` FAILs on a missing manifest, and `init`
is what creates it, so running `doctor` first on a fresh vault fails for the one
reason guaranteed to be true.

**`ruamel.yaml` is the trap.** The tagger writes frontmatter through it whenever
Obsidian is not running — and a vault this script just created is never open in
Obsidian. `cli.py doctor` reports its absence as INFO, not FAIL, so without the
Phase 1 check the build passes every gate and then fails at write time.

**`rebuild` before the first `run`, always.** Skip it and every file looks brand
new, so the tagger re-tags the whole vault.

**The tagger is proved twice, on purpose.** `doctor` can PASS on a `claude` that
`subprocess` cannot actually launch, so Phase 9 checks both that a `|tag|` row
reached the log *and* that `tagged_hash` reached a note's frontmatter on disk.

**The review gate is not optional.** The tagger prefers existing high-count tags,
so the first ten tags shape every tag that follows. The build stops there and
prints them. Nothing tags the rest of the vault for you.

**`for f in $(find ...)` splits on spaces.** Note titles contain spaces, so that
turns `Acme Overview.md` into two nonexistent paths and every note reads as
malformed. `build-verify.sh` iterates with `while IFS= read -r`.

**The Granola `.env.example` ships a `grn_paste_your_key_here` placeholder** that
matches any naive `grn_` test. Without an explicit exclusion the build reports a
key it does not have and installs an agent that only logs failures.

**Routines are confirmed one at a time.** They write to the vault on a schedule
with no human in the loop. `--yes` exists for unattended builds; blanket approval
is not the default.

**Why the build cannot finish registering them.** Three schedulers are in play and
only two are scriptable:

| What | Mechanism | Scriptable? |
| --- | --- | --- |
| Granola export | `~/Library/LaunchAgents/<prefix>.granola-export.plist`, 30 min, `RunAtLoad true` | **Yes** — `--install-agents` |
| Wiki ingestion | `~/Library/LaunchAgents/<prefix>.wiki-ingest.plist`, 900 s, `RunAtLoad false` | **Yes** — `--install-agents` |
| Claude Code routines | prompt at `~/.claude/scheduled-tasks/<id>/SKILL.md`; schedule bound server-side | **No** |

The routine *prompt* is a file on disk. The *schedule* is not — it is bound through
in-session tooling (`list_scheduled_tasks` / `update_scheduled_task`) that a
headless `claude -p` does not have. `CronCreate` **is** available headlessly, which
makes this look solvable, but it is session-scoped and in-memory: a job created in
one `claude -p` is gone by the next. Verified by doing exactly that — session A
returned a job ID, session B's `CronList` reported nothing.

So the build stops at the last mile it can reach honestly. It writes
`.system/routines-register.md`, a ready prompt carrying each task's ID, cron and
full body, for an **interactive** session to execute:

```bash
cd <vault> && claude "$(cat .system/routines-register.md)"     # interactive, NOT -p
```

The skill each routine drives is read from that routine's own `## Related` line, so
adding a routine needs no code change.

## Layout

```
build-vault.sh      the 11 phases
build-verify.sh     the gate: exits non-zero on any hard failure, CI-ready
TEMPLATE.md         the input contract, blank
lib/template.sh     markdown -> records, plus template_brief()
lib/hydrate.sh      the five config generators and _splice
lib/wire.sh         skeleton, machinery, connectors, routines, cron parsing
```

`lib/common.sh` and `lib/llm.sh` are one level up, in `catalyst-desktop/lib/`,
shared with `tests/`.

Targets **bash 3.2**, the shell that ships on macOS. No associative arrays, no
`wait -n`, no `mapfile`, no `${var,,}`. Use `[[:space:]]`, never `\t`, in `sed` and
`grep` bracket expressions — BSD treats `\t` as the literal characters.
