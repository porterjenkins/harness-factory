# harness-factory

Build a personal knowledge vault that an AI agent can actually work in.

`catalyst-desktop/` is the product: an Obsidian vault layout, a set of agent
skills, a SQLite-backed ingestion and auto-tagging pipeline, inbound connectors,
and a build script that stands the whole thing up on a new machine from a single
filled-in template.

Markdown files are the only storage format. Obsidian is the reader and the search
index. Everything an agent does — filing, tagging, linking, planning — happens
against plain files you can read, diff, and take with you.

## Quick start

```bash
git clone <this repo> && cd harness-factory/catalyst-desktop

cp build/TEMPLATE.md my-vault.md
$EDITOR my-vault.md                              # the implementation interview

./build/build-vault.sh --template my-vault.md --out ~/notes/my-vault --dry-run
./build/build-vault.sh --template my-vault.md --out ~/notes/my-vault
```

The build runs eleven phases and ends on a blocking verification gate. It is safe
to re-run: model output is cached, and a non-empty target requires `--force` and
gets backed up first.

Iterating on the harness rather than a real vault? `--offline` builds the whole
structure with canned prose and no model calls.

## What you get

| Path | What lives there |
| --- | --- |
| `Projects/` | Active work with an outcome and an end — one folder per project |
| `Areas/` | Ongoing responsibilities with no finish line |
| `Resources/` | Reference material: `Plans/`, `Meetings/`, `Agendas/`, all by year |
| `Archive/` | Inactive and compacted notes, still indexed and searchable |
| `Skills/` | Agent instructions — 10 of them, from `daily-plan` to `tag-lint` |
| `Routines/` | Scheduled automations, each documenting its own cron and task ID |
| `.system/` | All executable code: the pipeline, connectors, logs, the manifest |

Plus five root documents the agent reads every session — `CLAUDE.md`, `USER.md`,
`SOURCES.md`, `PRIORITIES.md`, `MEMORY.md` — generated from your template rather
than copied from anyone else's vault.

The split that matters: **`Skills/` holds instructions for an agent to follow;
`.system/` holds programs that run unattended with no agent in the loop.**
Deterministic logic belongs in code, not in a prompt.

## Layout

```
catalyst-desktop/
  SETUP.md              the operator runbook — read this before building for someone else
  build/                the builder, the gate, and the input contract
    TEMPLATE.md           fill this in; it drives everything
    build-vault.sh        11 phases: install → hydrate → seed → wire → tag → verify
    build-verify.sh       24 assertions; exits non-zero, drops into CI as-is
    register-routines.sh  surfaces the one step that cannot be automated
  lib/                  common.sh and llm.sh, shared by build/ and tests/
  Skills/               10 agent skills
  Routines/             4 scheduled automations
  .system/
    wiki/                 ingestion + auto-tagging pipeline (9 CLI commands, 81 tests)
    connectors/           inbound feeds — currently Granola meeting notes
    .env.example          the single config file for every connector
  tests/                sandbox vaults: disposable fixtures generated with `claude -p`
```

Every README in that tree is worth reading before changing the thing it describes:
`build/README.md` (design rules and the traps behind them), `.system/wiki/README.md`
(pipeline internals, Windows), `.system/connectors/granola-export/README.md`, and
`tests/README.md`.

## Requirements

| | |
| --- | --- |
| macOS or Windows | Linux runs the pipeline but has no scheduler integration |
| `python3` ≥ 3.9 | plus `ruamel.yaml` — see below |
| `claude` CLI, signed in | required for tagging and for generating the root documents |
| Obsidian desktop + CLI | required for search and retrieval, not for ingestion |
| `node` ≥ 18 | only for the Granola connector |

**`ruamel.yaml` is the one that hides.** The tagger writes frontmatter through it
whenever Obsidian is not running — which is always true of a vault the build just
created. `cli.py doctor` reports its absence as INFO, not FAIL, so without an
explicit check a build passes every gate and then fails at write time. Phase 1
checks it and refuses to continue.

## Design rules

Four decisions the rest of the code depends on. Each exists because of a specific
failure, and each is documented where it lives.

**Structure is written by bash and is exact; prose is generated.** Every planning
skill *parses* something — `SOURCES.md`'s two tables, `CLAUDE.md`'s project
enumeration, each routine's cron. A model that writes a four-column table with
three columns breaks those skills silently and at a distance. So the model writes
each document and the build then *splices* the parsed sections in from the
template. Splicing after the fact, rather than trusting a model to reproduce a
block verbatim, is what makes it a guarantee.

**Nothing hardcodes an absolute path.** `wiki/config.py` resolves the vault from
`__file__`, `run.sh` from `BASH_SOURCE`, `export.mjs` from `import.meta.url`.
launchd plists are rendered from `.template` files at install time. A vault that
self-locates survives being moved.

**The manifest holds change-detection state only** — body hashes, sizes, mtimes,
tagging status. No tags, no content: those live in frontmatter and are queried
through Obsidian. That keeps `manifest.sqlite` disposable and rebuildable, which
is why it is excluded from sync and from git. A synced manifest with two writers
corrupts silently.

**The first ten tags get a human.** The tagger prefers existing high-count tags,
so early tags shape every tag that follows. The build tags a sample and stops.
Nothing tags the rest of your vault for you.

## Development

```bash
cd catalyst-desktop/.system && python3 -m unittest discover -s wiki/tests -t .   # 81 tests
cd catalyst-desktop && ./build/build-vault.sh --template … --out /tmp/v --offline
cd catalyst-desktop && ./tests/sandbox-up.sh --offline --dry-run
```

`--offline` is the fast structural loop — no model calls, deterministic stubs, a
vault that still passes verification. Use it to iterate on the harness; use a
cache-hot live build to iterate on prose.

`tests/` generates disposable fictional vaults for exercising the skills against
content nobody on this project wrote. See `tests/README.md`.

Targets **bash 3.2**, the shell that ships on macOS: no associative arrays, no
`wait -n`, no `mapfile`, no `${var,,}`. In `sed` and `grep` bracket expressions use
`[[:space:]]`, never `\t` — BSD treats `\t` as the literal characters, and
`s/[ \t]*$//` quietly strips trailing `t`s off real words.

## What is not automated

Two things, both on purpose:

- **Reviewing the first tag sample.** See above.
- **Registering the Claude Code routines.** The tool that creates a task running
  locally against your vault ships only with Claude Desktop agent mode. The build
  writes a ready prompt and puts it on your clipboard; you paste it once. The CLI
  can *look* like it works — `RemoteTrigger` creates a routine that registers
  cleanly and then fails every run, because it executes in a remote sandbox that
  cannot see your vault.

## Secrets

`.system/.env` is the single config file for every connector, namespaced by
prefix (`GRANOLA_API_KEY`, …) so a bug in one connector never sees another's
credentials. It is per-machine, never synced, and git-ignored along with the
manifest and every log. `.env.example` is the committed template.
