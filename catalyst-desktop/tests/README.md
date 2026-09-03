# Sandbox vaults

An on-demand, disposable PARA knowledge vault for testing the Catalyst AI desktop
service. Everything in a generated vault — the person, their employers, projects,
colleagues, meetings and notes — is fiction, simulated with `claude -p`.

```bash
./sandbox-up.sh                                  # default persona, ~48 notes
./sandbox-verify.sh                              # assert the fixture is sound
./sandbox-ls.sh                                  # what exists on this machine
./sandbox-down.sh --vault ~/catalyst-sandboxes/maya-work

./build-into-sandbox.sh --persona default --tag 8   # the end-to-end test
./persona-to-template.sh default > /tmp/t.md        # persona -> build template
```

Sandboxes land in `~/catalyst-sandboxes/<vault-name>` unless you pass `--out`.
Override the root with `--root` or `CATALYST_SANDBOX_HOME`. Nothing is ever
written inside this repo.

The root is deliberately **not** dot-prefixed: a sandbox exists to be opened in
Obsidian, and macOS file pickers hide dot directories by default. It is also
deliberately outside `~/knowledge-base/` — a vault under a synced tree would get
picked up by Obsidian Sync, iCloud or Drive, and by the real vault's own tooling.

## The one design rule

**Structure is written by bash and is exact. Prose is generated and is expected to
vary.**

Anything a skill *parses* — frontmatter keys, `tagged_hash`, plan filenames, the
`timestamp|action|path|summary` log format, the `sources.md` role table, the
`[P1]` priority markers, the Admin/Goals/Notes skeleton — is emitted by shell code
and asserted by `sandbox-verify.sh`. Anything a skill *reads as prose* — `CLAUDE.md`,
`USER.md`, every note body — comes from the model.

That split is the whole point. If the fixture's wording were also authored here,
tests would only ever prove that the skills work against phrasing chosen by
whoever wrote the fixture.

Two consequences worth knowing:

- `tagged_hash` is computed the same way `.system/wiki/hashing.py` computes it
  (sha256 of the body with frontmatter stripped, first 16 hex chars). A fresh
  sandbox therefore reads as *already ingested*, and the tagger won't re-tag all
  forty notes on first run. `sandbox-verify.sh` recomputes every hash, so if the
  pipeline ever changes `HASH_LEN` or what it hashes, the fixture fails loudly
  instead of drifting.
- Plan notes are normalised after generation (`_normalize_daily`,
  `_normalize_weekly` in `lib/docgen.sh`). About one note in forty comes back
  missing a section heading; the skeleton is a template contract, so it is
  enforced rather than left to chance.

## Building into a sandbox

`build-into-sandbox.sh` is the end-to-end test: generate a populated vault, derive
a build template from the same persona, build into it, then require **both**
verifiers to pass on the result — the builder owns the configuration, the sandbox
owns the content, and neither may break the other's contract. Pass `--tag N` to
also run a real tagging sample.

This is the only way the tagging phase means anything. `build-vault.sh` on an
empty directory can seed nothing but stub notes, so it proves the plumbing and
nothing about tag quality; against this corpus the tagger converges on vocabulary
drawn from the persona's own projects (`northbeam`, `tidewater`, `palletgeist`).

The order is forced and cannot be reversed: `sandbox-up.sh` refuses to touch a
directory without its own marker, and it deliberately leaves `Skills/` and
`Routines/` empty for the build to fill. The build needs `--force` because the
directory is non-empty by design; it backs up anything it would overwrite first,
and retires the placeholder READMEs it has just made untrue.

`persona-to-template.sh` is the translation between the two halves — the persona is
the sandbox's identity, the template is the builder's input, and they describe the
same things in different shapes. It is a translation, not a second source of
truth: edit the persona and regenerate.

## What you get

| Location | Contents |
| --- | --- |
| `Projects/<path>/` | Working docs per project: plans, specs, decision logs, scoping notes. Cross-linked with `[[Wikilinks]]`. |
| `Areas/<name>/` | Ongoing-responsibility notes — cadences and standing obligations, no deadlines. |
| `Resources/` | Reference notes consulted across projects. |
| `Resources/Meetings/` | Granola-shaped meeting notes: connector frontmatter, `### Speaker` sections, `### Action Items`. |
| `Resources/Plans/<year>/Weekly/` | `Weekly Planning M-D-YYYY to M-D-YYYY.md`, Sunday–Saturday, with `[P1]`/`[P2]`/`[P3]` markers. |
| `Resources/Plans/<year>/Daily/` | `YYYY-MM-DD.md`, weekdays only, Goals pulled from that week's plan. |
| `Archive/<year-1>/` | Closed-out notes, so historical search has something to find. |
| `Clippings/` | Saved external articles — a different document shape from anything the owner writes. |
| `CLAUDE.md`, `USER.md` | Generated. See below. |
| `.system/` | `sources.md`, a seeded action log, and the machinery directories. |
| `.claude/settings.local.json` | Rendered per sandbox, with the `Resources/Meetings/` write-deny. |
| `.obsidian/` | Daily-notes and template settings pointing at the right folders. |
| `Skills/`, `Routines/` | **Deliberately empty.** The build script compiles these in. |

### `CLAUDE.md` and `USER.md`

Both are generated per persona, not copied from anyone's real vault.

`CLAUDE.md` is generated from a checklist of *invariants* (`_scaffold_claude_facts`
in `lib/scaffold.sh`) rather than from a template: the three access tags, the role
of `.system/`, the log format, the pipeline frontmatter keys, the Obsidian-CLI
search rules, the Meetings write-deny, and the project enumeration. The prose is
the model's; `sandbox-verify.sh` asserts every invariant is actually stated. So a
skill that depends on one of those rules is tested against wording it has never
seen, while a skill that depends on exact phrasing fails — which is the correct
outcome.

## Personas

A persona file is the **only** place a sandbox's identity lives. No name, employer,
project or path is hardcoded anywhere else.

- `personas/default.persona.sh` — seven projects across four groups, three areas,
  ten recurring meetings, fifteen named colleagues. The realistic case.
- `personas/minimal.persona.sh` — two projects, one area. For smoke tests and CI.

To add one, copy either file and edit the records. Everything downstream — the
directory tree, `USER.md`, `CLAUDE.md`'s project section, note titles, meeting
attendees, weekly-plan headings — follows from it.

```bash
./sandbox-up.sh --persona ./personas/mine.persona.sh
```

## Flags

`sandbox-up.sh`:

| Flag | Default | Notes |
| --- | --- | --- |
| `--persona <name\|path>` | `default` | Resolved against `personas/`, or a path. |
| `--size small\|medium\|large` | `medium` | ~18 / ~48 / ~82 notes. The cost dial. |
| `--out <path>` / `--name <basename>` | under the sandbox root | The basename matters: skills pass it as `vault=<vault-name>`. |
| `--today YYYY-MM-DD` | today | Anchors every generated date. Set it for reproducible plan filenames. |
| `--offline` | off | No model calls at all. Deterministic stubs, structurally valid, dull. |
| `--model <alias>` | `sonnet` | Passed to `claude -p`. |
| `--jobs N` | 4 | Concurrent generations. 8 is comfortable. |
| `--no-cache` | cache on | Prompt→body is cached under `~/.cache/catalyst-sandbox`. |
| `--untagged-every N` | 4 | Every Nth note is left with no `tagged`/`tagged_hash`, i.e. pending ingestion. `0` disables. |
| `--force` | off | Replace an existing **sandbox**. Never enough to touch anything else. |
| `--dry-run`, `--no-verify`, `--keep-work` | | |

Cost and time, medium size, `--jobs 8`: about 50 `claude -p` calls, a few minutes.
A second run of the same persona is free — the cache is keyed on the prompt, so
only genuinely new documents call the model. Iterate on the *harness* with
`--offline`; iterate on the *skills* against a cache-hot vault.

## Verification

`sandbox-verify.sh` exits non-zero on any hard failure, so it drops into CI as-is.
It checks the PARA layout, that the root documents exist and state their
invariants, that every note's frontmatter parses, that every `tagged_hash` agrees
with its body, that plan and meeting filenames match what the planning skills
match on, that the daily/weekly section skeletons are intact, that the log is
4-field pipe-delimited, that the Meetings deny-glob points at *this* vault, and
that no host filesystem path leaked into a note.

Dangling wikilinks are a warning, not a failure — real vaults have them, and the
model occasionally invents a link target.

## Tear-down

```bash
./sandbox-down.sh --vault <path>     # one
./sandbox-down.sh --all --yes        # everything under the root
./sandbox-down.sh --cache            # just the generation cache
```

`sandbox-down.sh` will only delete a directory containing
`.sandbox-manifest.json`. That marker is the entire safety mechanism: this script
runs `rm -rf` on a path that in normal use sits one typo away from a real Obsidian
vault, and there is no undo. **No flag overrides the check** — and `sandbox-up.sh`
refuses to overwrite an unmarked directory for the same reason.

## Implementation notes

Targets **bash 3.2**, the shell that actually ships on macOS. No associative
arrays, no `wait -n`, no `mapfile`, no `${var,,}`. Two traps worth remembering if
you extend these scripts, because both fail only on a stock Mac and pass on a
brew-installed bash:

- Under `set -u`, both `"${arr[@]}"` on an *empty* array and `${#arr[@]}` on an
  *unset* one are "unbound variable" errors. `lib/persona.sh` declares every
  optional array before anything reads it, and passes array *names* rather than
  expansions.
- BSD `sed` and `grep` treat `\t` inside a bracket expression as the literal
  characters `\` and `t` — so `s/[ \t]*$//` quietly strips trailing `t`s off real
  words. Use `[[:space:]]`. (`awk` is fine.)

Also: `set -o pipefail` plus a `grep` that legitimately matches nothing will abort
a script mid-run. Wrap those in `|| true`.

Layout:

```
sandbox-up.sh          create
sandbox-verify.sh      assert
sandbox-down.sh        destroy
sandbox-ls.sh          list
lib/common.sh          logging, hashing, frontmatter stamping, date math, job fan-out
lib/llm.sh             the `claude -p` wrapper: no tools, cached, retried, stub fallback
lib/persona.sh         persona loading and the shared prompt brief
lib/scaffold.sh        directories, CLAUDE.md, USER.md, machinery files
lib/docgen.sh          the four generation phases
personas/*.persona.sh  identity — the only place it lives
```

The generator runs with `--restricted`, no MCP, no skills, no session persistence,
a replaced system prompt, and a working directory outside any vault. A generator
that can read the real vault will copy the real user's notes into the sandbox,
which defeats the purpose.
