# Vault builder

Builds a working PARA knowledge vault from a filled-in implementation-interview
template. This is the automation of `SETUP.md` phases 3–14 — the manual runbook an
agent otherwise walks a customer through by hand.

```bash
./build-vault.sh --template ./filled.md --out ~/notes/my-vault
./build-vault.sh --template ./filled.md --out /tmp/v --dry-run   # parse + plan only
./build-vault.sh --template ./filled.md --out /tmp/v --offline   # no model calls
./build-verify.sh ~/notes/my-vault                               # the gate, standalone
./register-routines.sh ~/notes/my-vault                          # re-surface the last manual step
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
| `--install-agents` | off | actually install the background jobs (macOS only; Windows always gets a script) |
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

## Platform

`# Platform` in the template picks how the two background jobs — wiki ingestion
(15 min) and Granola export (30 min) — get installed:

| `- OS:` | Behaviour |
|---|---|
| `auto` (default) | detect from `uname` |
| `macos` | LaunchAgents, installed directly by `--install-agents` |
| `windows` | writes `.system/install-agents.ps1` for Task Scheduler; nothing is registered for you |
| `linux` | warns; no scheduler integration exists |

Declaring an OS is an **assertion, not a cross-compile switch** — the build
installs jobs on the machine it runs on, so a template saying `windows` while
running on a Mac is a hard error rather than a silent no-op.

Two Windows details the generated script carries, because both are silent
failures otherwise:

- **The run-log path is `.system\log\run-logs`.** An earlier version of
  `.system/wiki/README.md` dropped the `log` segment, so scheduled output went to
  a directory nobody reads. `config.py:28` is authoritative.
- **`claude` is a `.cmd` shim.** `subprocess` reaches `CreateProcess`, which
  searches `PATH` but does not apply `PATHEXT`, so a bare `claude` raises
  `FileNotFoundError` even though the word works in a shell. `cli.py doctor`
  probes with `shutil.which`, which *does* apply `PATHEXT` — so it reports PASS on
  a `claude` that cannot actually launch. Set `WIKI_CLAUDE_BIN` to the full path
  and prove it with `run --max-tag 1`. (There is no `WIKI_OBSIDIAN_BIN`;
  `obsidian.py` uses a socket.)

Path conversion uses `cygpath -w` when present, falling back to a sed that maps
`/c/Users/...` to `c:\Users\...`. If neither yields a drive letter the build says
so and tells you which line to edit — a naive `s|/|\|` would produce
`\c\Users\...` and every path in the script would be wrong.

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
| Local scheduled tasks | `create_scheduled_task`, **Claude Desktop agent mode only**; prompt cached at `~/.claude/scheduled-tasks/<id>/SKILL.md` | **No** |
| Cloud routines | `RemoteTrigger` → `claude.ai/v1/code/triggers`; runs in a remote sandbox | Yes, but **wrong tool** — cannot reach a local vault |

The routine *prompt* is a file on disk. The *schedule* is not, and there are three
dead ends worth documenting so nobody re-walks them:

- **`CronCreate` looks like the answer and is not.** It is available headlessly,
  but session-scoped and in-memory. Verified: session A returned job `ecd15f45`;
  session B's `CronList` reported nothing. A `-p` process exits immediately, so the
  job dies before it can ever fire. Its own schema says `durable` "has no effect."
- **`create_scheduled_task` is the right tool and the CLI does not have it.** It
  ships with Claude Desktop agent mode — which is where the `schedule` skill file
  actually lives (`…/local-agent-mode-sessions/…/skills/schedule/SKILL.md`).
- **`RemoteTrigger` is reachable from the CLI and is the wrong tool.** It creates a
  routine at `claude.ai/v1/code/triggers` that runs in a remote sandbox. It would
  register cleanly and then fail every run, because it cannot see the vault on this
  machine, cannot reach Obsidian, and cannot run the local tagger.

So the build stops at the last mile it can reach honestly. It writes
`.system/routines-register.md`, a ready prompt carrying each task's ID, cron and
full body, to be pasted into **Claude Desktop (agent mode)** — one paste instead of
N hand-filled forms.

`register-routines.sh` is what makes that reachable, and it is separate from the
build for two reasons. Registration usually happens later than the build, often on
another day; and the prompt lives in `.system/`, which is dot-prefixed and so
invisible in Obsidian *and* hidden in Finder and macOS file pickers. Telling
someone to open a file they cannot browse to is not instructions. The script puts
the prompt on the clipboard (`pbcopy`, `wl-copy`, `xclip` or `clip.exe`, best
effort and never fatal), prints the three steps and the reason Desktop is
required, lists the task IDs and times, and names the command to re-run it. The
build calls it automatically as its own closing block rather than as one item in a
numbered list — it is the only step that needs the user to switch applications, and
buried in a list is how it gets missed.

`--print` dumps the raw prompt for piping; `--no-copy` leaves the clipboard alone.
**Note that a default run replaces the clipboard contents.**

The skill each routine drives is read from that routine's own `## Related` line, so
adding a routine needs no code change.

## Layout

```
build-vault.sh      the 11 phases
build-verify.sh     the gate: exits non-zero on any hard failure, CI-ready
register-routines.sh  re-surface the registration prompt; copies it to the clipboard
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
