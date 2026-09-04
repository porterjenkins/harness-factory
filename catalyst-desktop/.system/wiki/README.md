# Wiki ingestion pipeline

Implements [[wiki-ingestion-spec]]. All executable code lives here; `Skills/`
holds agent instructions. Deterministic logic belongs in this directory — the LLM
is invoked for tagging and nothing else.

## Commands

```bash
.system/wiki/cli.sh doctor           # verify the environment first
.system/wiki/cli.sh init             # create .system/wiki/manifest.sqlite
.system/wiki/cli.sh rebuild          # seed manifest from frontmatter (no LLM)
.system/wiki/cli.sh run --dry-run    # classify, change nothing
.system/wiki/cli.sh run              # one real pass (what launchd runs)
.system/wiki/cli.sh run --max-tag -1 # no tagging ceiling; use deliberately
.system/wiki/cli.sh status           # manifest counts and timestamps
.system/wiki/cli.sh vocab            # tag vocabulary with counts
.system/wiki/cli.sh tag-lint         # drift report
.system/wiki/cli.sh prune            # hard-delete expired tombstones
.system/wiki/cli.sh retry-failed     # requeue files that gave up after N failures
```

`cli.sh` is `uv run --project .system python .system/wiki/cli.py`. Bare `python3`
does not see ruamel.yaml, which is required whenever Obsidian is not the write
path.

## First run

```bash
./.system/wiki/bootstrap.sh
```

Staged and interactive: doctor -> rebuild -> tag a sample of 10 -> pause for
review -> tag everything -> install the LaunchAgent. `--yes` skips the prompts,
`--sample N` changes the review batch size.

The pause after the sample is deliberate. The tagger prefers existing high-count
tags, so the first tags it writes shape every tag that follows. Bad early tags
propagate and `tag-lint` then has to clean up after them.

Doing it by hand instead:

```bash
.system/wiki/cli.sh doctor
.system/wiki/cli.sh rebuild        # marks already-tagged files as tagged
.system/wiki/cli.sh run --dry-run  # confirm the classification looks sane
.system/wiki/cli.sh run            # tag up to MAX_TAG_PER_RUN files
.system/wiki/cli.sh run --max-tag -1   # or tag everything at once
./.system/wiki/launchagent/install.sh
```

`rebuild` before the first `run`. Otherwise every file is case 1 and the tagger
re-tags the whole vault.

## The scheduled job

`launchagent/install.sh` writes `~/Library/LaunchAgents/com.knowledgebase.wiki-ingest.plist`
and bootstraps it into the GUI session. `StartInterval` is 900s, so `cli.py run`
executes **every 15 minutes**. One job covers all three cadences: the runner
checks internally whether the weekly full-rehash sweep and the monthly prune are
due.

```bash
./.system/wiki/launchagent/status.sh                       # installed? loaded? failing?
launchctl kickstart -p gui/$(id -u)/com.knowledgebase.wiki-ingest   # run once now
./.system/wiki/launchagent/uninstall.sh                    # remove it
./.system/wiki/launchagent/install.sh --interval 300       # change the cadence
```

It must be a LaunchAgent, never a LaunchDaemon: only an Agent runs inside the
user's Aqua session, which is required to reach a GUI app. launchd also starts
with a near-empty PATH, so `install.sh` resolves `obsidian` and `claude` at
install time and bakes their directories into the plist.

## Running on Windows

The Python ports as written -- `pathlib` throughout, `as_posix()` manifest keys,
and no shell-outs beyond `claude` and `obsidian`. What does not port is
`bootstrap.sh` and the LaunchAgent. Use the manual sequence plus Task Scheduler.

### Setup

```powershell
cd <path-to-vault>
python .system\wiki\cli.py doctor
python .system\wiki\cli.py rebuild        # before the first run, always
python .system\wiki\cli.py run --dry-run
python .system\wiki\cli.py run
```

`bootstrap.sh` is only a staged wrapper around these, so nothing is lost but the
prompts -- keep its one discipline: tag a small sample first
(`run --max-tag 10`), look at what it wrote, and only then let it loose. Early
tags shape every tag that follows.

`config.py` derives the vault from its own location, so `WIKI_VAULT_PATH` and
`WIKI_VAULT_NAME` need no setting as long as the tree stays at
`<vault>\.system\wiki\`.

### `claude` and `obsidian` need absolute paths

This is the one thing that will bite. Both are `.cmd` shims on Windows, and
`tagger.py`/`obsidian.py` invoke them through `subprocess` without a shell --
which reaches CreateProcess, which searches `PATH` but does **not** apply
`PATHEXT`. A bare `claude` therefore dies with `FileNotFoundError` even though
the same word works in your shell. Point the config at the full path:

```powershell
where.exe claude          # confirm the location first; it depends on the installer
setx WIKI_CLAUDE_BIN "$env:APPDATA\npm\claude.cmd"
```

Only `claude` needs this. There is no `WIKI_OBSIDIAN_BIN` -- `obsidian.py` talks to
the app over a unix socket rather than spawning the CLI binary, so there is no
path for it to resolve. An earlier version of this file told you to `setx` one;
that variable is read by nothing.

`setx` writes a user-level variable, which Task Scheduler inherits. Open a new
shell before testing it.

**`doctor` does not catch this.** It probes with `shutil.which`, which *does*
apply `PATHEXT`, so it reports PASS on a bare `claude` that `subprocess` cannot
launch. Prove the real path with `uv run --project .system python .system\wiki\cli.py run --max-tag 1` and
check that a tag actually landed on disk.

If the Obsidian CLI is unavailable here, nothing is broken -- that is the
documented no-app mode. `.system/wiki/cli.sh` (uv run --project .system) provides
ruamel.yaml and `writer.py` falls back; you lose retrieval and the
`processFrontMatter` write path, not ingestion.

### The scheduled job

Task Scheduler replaces launchd. The plist's constraints map over nearly
one-to-one:

```powershell
$vault = "<path-to-vault>"
$py    = (Get-Command python).Source
$logs  = "$vault\.system\log\run-logs"
New-Item -ItemType Directory -Force -Path $logs | Out-Null

$action = New-ScheduledTaskAction -Execute "cmd.exe" -WorkingDirectory $vault `
  -Argument "/c `"$py`" `"$vault\.system\wiki\cli.py`" run >> `"$logs\ingest.out.log`" 2>> `"$logs\ingest.err.log`""

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration ([TimeSpan]::MaxValue)

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Priority 7

Register-ScheduledTask -TaskName "wiki-ingest" -Action $action -Trigger $trigger `
  -Settings $settings -Description "Wiki ingestion pass (.system/wiki/cli.py run)"
```

- **It must run in your logged-on session** -- the same reason the Mac job is a
  LaunchAgent and not a LaunchDaemon. The Obsidian CLI is a client to a running
  GUI app. `Register-ScheduledTask` with no `-User`/`-Password` defaults to *run
  only when the user is logged on*, which is what you want. Do not switch it to
  *run whether the user is logged on or not*: that lands in session 0 with no
  desktop and every Obsidian call fails.
- **`-StartWhenAvailable` covers sleep.** A repetition missed while the machine
  was asleep fires once after resume instead of being dropped, so Windows needs
  no wake hook.
- **No PATH baking.** `install.sh` resolves `obsidian` and `claude` at install
  time because launchd starts with a near-empty PATH. Task Scheduler hands the
  task the user's environment from the registry, so `PATH` and anything you
  `setx` is already there.
- `-Priority 7` is the analogue of `ProcessType Background` + `Nice 5`.
- Redirection lives in the `cmd.exe` action because a task action has no
  `StandardOutPath` equivalent. Those logs are appended and never rotated --
  trim them yourself if they grow.

Managing it, in place of `status.sh` / `launchctl`:

```powershell
Get-ScheduledTask -TaskName "wiki-ingest" | Get-ScheduledTaskInfo   # last run + LastTaskResult
Start-ScheduledTask -TaskName "wiki-ingest"                         # run once now
Unregister-ScheduledTask -TaskName "wiki-ingest" -Confirm:$false    # remove
```

`LastTaskResult` 0 means the process exited clean. Everything else `status.sh`
reports comes from the vault rather than launchd, so it survives the port:

```powershell
Get-Content "$vault\.system\run-logs\ingest.err.log" -Tail 5
Select-String -Path "$vault\.system\log-$(Get-Date -Format yyyy-MM).csv" -Pattern '\|run\|' | Select-Object -Last 5
```

### Two gaps specific to Windows

- **OneDrive conflict forks go undetected.** `classify.py` knows the Dropbox and
  Syncthing markers (`conflicted copy`, `.sync-conflict`); OneDrive instead
  appends the machine name -- `note-DESKTOP-A1B2C3.md` -- which matches nothing
  and would be ingested as a legitimate new note and tagged. Add the pattern to
  `_CONFLICT_MARKERS` before putting the vault on OneDrive.
- **The action log picks up CRLF.** `logcsv.py` appends in text mode, so rows
  written here end `\r\n` while the Mac's end `\n`. `Select-String` does not
  care, but a trailing `\r` rides along on the last field when the Mac side
  parses the file with `cut`. Passing `newline="\n"` to that `open()` call fixes
  it if the mixed endings bother you.

The manifest rules matter more here, not less: `.system\manifest.sqlite` stays
out of OneDrive's sync scope (a dot-prefix hides nothing on Windows and OneDrive
syncs it happily), each machine keeps its own, and `tagged_hash` is what keeps
two machines consistent without sharing one. WAL is also unavailable on a
OneDrive-backed path -- `connect()` already falls back through TRUNCATE to
DELETE, so that is handled, not something to fix.

Line endings do not cause re-tag churn across machines. Bodies are read with
`read_text()`, whose universal-newline translation normalises `\r\n` to `\n`
before hashing, so a file's `body_hash` is identical on Windows and macOS.

## Module map

| File | Role |
| --- | --- |
| `config.py` | Every tunable and path. Env vars override. |
| `hashing.py` | Body-only hash (frontmatter stripped) + size/line counts. |
| `classify.py` | Vault walk, mtime+size pre-filter, the six cases. Pure logic. |
| `manifest.py` | SQLite schema and transactional ops. Change-detection state only. |
| `obsidian.py` | Obsidian CLI wrapper: preflight, readiness poll, eval, tag counts. |
| `writer.py` | Frontmatter writes — processFrontMatter, ruamel fallback. |
| `tagger.py` | `claude -p` invocation, prompt construction, output parsing. |
| `logcsv.py` | Append-only action log. Deliberately has no read function. |
| `pipeline.py` | Run orchestration, rebuild, prune, cadence checks. |
| `taglint.py` | Tag drift detection. Finds candidates; humans approve merges. |
| `cli.py` | Entrypoint. |

## Design points worth not undoing

**The pre-filter checks mtime AND size.** mtime alone loses data two ways: it does
not advance monotonically once sync is involved (a file can arrive carrying
another device's older timestamp, which a `>` comparison would never re-hash), and
its resolution is filesystem-dependent (a same-second rewrite on a coarse
filesystem leaves it untouched). Compared by inequality, never `>`. An edit that
changes neither mtime nor length is caught only by the weekly full-rehash sweep,
which is why that sweep exists.

**`tagged_hash` is not decoration.** A `tagged` date proves a file was tagged but
not what it looked like. Without the hash, a manifest rebuild silently absorbs any
edit made while the database was missing. It also makes multi-machine tagging safe
without sharing the manifest: the authority for what has been tagged is the vault,
not the database.

**Case 2 requires an *unobserved* match.** `body_hash` is not unique — two empty
notes collide. Repointing a row whose old path still exists makes two files
ping-pong one manifest row forever, and one of them never gets tagged.

**Tagging happens outside the write transaction.** Changes are buffered and applied
in one atomic commit at the end, so the SQLite write lock is not held across
minutes of LLM calls.

**Writes are verified on disk, not trusted.** The Obsidian CLI decorates `eval`
output -- a returned value comes back prefixed, e.g. `=> CLAUDE.md`. Parsing
stdout for paths produced strings matching no file and no manifest row. After
writing, the pipeline re-reads each file's frontmatter and confirms `tagged_hash`
matches what it meant to write. A path only counts as tagged if the disk agrees.

**Tagging failures are capped.** A file that fails `MAX_TAG_ATTEMPTS` times is
marked `failed` and stops being retried. Without the cap an unattended job retries
a permanently-broken file every run forever. `retry-failed` requeues them once the
cause is fixed. Conversely, files deferred by the per-run ceiling stay `pending`
and *are* carried into the next run -- the ceiling must defer, never drop.

**Journal mode falls back.** WAL is preferred but fails on FUSE-style mounts,
including the Google Drive virtual mount. `connect()` tries WAL → TRUNCATE →
DELETE and proves the mode works before returning.

## Tests

```bash
uv run python -m unittest discover -s .system/wiki/tests -t .system
```

Covers every branch that can silently lose data: the pre-filter (both guards, and
the NULL case), all six cases, duplicate-hash move ambiguity, transaction
rollback, rebuild honesty, and log sanitisation. The tagger is stubbed — tests
never shell out to `claude`.

Not covered, because it needs a running Obsidian GUI: `obsidian.py` and the
`processFrontMatter` write path. `cli.py doctor` exercises those interactively.

## Cloud tagger

Ingestion is portable; only retrieval needs the app. To run this on a box without
Obsidian:

```bash
export WIKI_VAULT_PATH=/path/to/vault
.system/wiki/cli.sh run     # uv run --project .system; pulls in ruamel.yaml
```

`writer.py` falls back automatically. Vocabulary falls back to a frontmatter scan
since `obsidian tags` is unavailable. Do not sync the manifest between machines —
each keeps its own, and `tagged_hash` keeps them consistent.
