# Granola → Markdown auto-export

Exports your Granola notes to `Resources/Meetings/{year}/` in this vault as one markdown
file per meeting, on a schedule. The year comes from the meeting's own date, not the
run date, so a December meeting exported in January still files under the old year. Uses Granola's **official Personal API** — no
reverse-engineering of local cache files, so it won't break when Granola
changes its storage format (which is what killed the old `granola-to-markdown`
npm tool).

## One-time setup

### 1. Create an API key (requires Business or Enterprise plan)
In the Granola desktop app: **Settings → Connectors → API keys → Create key**.
Give it the **Personal notes** scope. Copy the `grn_...` value.

### 2. Save the key
Everything this connector reads — the key and every option — lives in the one
shared config file at **`.system/.env`**. There is no `.env` in this folder.
From the vault root:
```sh
cp .system/.env.example .system/.env
chmod 600 .system/.env
# edit .system/.env and paste your key after GRANOLA_API_KEY=
```

`run.sh` exports **only** the variables matching this connector's `GRANOLA_`
prefix, so a bug or a bad npm dependency in this exporter cannot see another
connector's credentials. Isolation comes from the prefix, not from separate
files — which is why the prefix convention is mandatory: an unprefixed variable
in `.system/.env` is invisible to every connector, and two connectors sharing a
prefix share their secrets.

**Precedence: the environment wins over the file.** A variable already set when
`run.sh` starts is left alone, so a one-off run can override any setting without
editing `.system/.env`:

```sh
GRANOLA_TRANSCRIPT=1 ./run.sh          # transcripts just this once
GRANOLA_OUT_DIR=/tmp/test ./run.sh     # dry-run somewhere harmless
```

An intentionally empty value (`GRANOLA_TRANSCRIPT= ./run.sh`) also wins rather
than falling back to the file. Under launchd the environment is minimal, so
scheduled runs always take their settings from `.system/.env`.

### 3. Test it once
```sh
./run.sh
```
You should see notes written into the vault's `Resources/Meetings/{year}/`.

### 4. Turn on the schedule (runs every 30 minutes)
```sh
./install.sh                      # default: every 30 minutes
./install.sh --interval 900       # or pick a cadence
./install.sh --dry-run            # show the rendered plist, write nothing
```
`install.sh` derives the vault path from its own location and substitutes it into
`co.<prefix>.granola-export.plist.template`. Nothing in the repo carries an absolute path;
launchd needs one, so it is rendered at install time. Re-running is idempotent.

## Managing the schedule
```sh
LABEL=com.knowledgebase.granola-export       # or whatever --label you installed with
# stop
launchctl bootout "gui/$(id -u)/$LABEL"
# run right now
launchctl kickstart -p "gui/$(id -u)/$LABEL"
# watch the log (path relative to the vault root)
tail -f .system/log/run-logs/granola-export.log
```

Change how often it runs by re-running `./install.sh --interval <seconds>`; it boots the old
job out first, so there is no need to edit the plist by hand.

### Wake-based sync (for laptop sleep)

`StartInterval` timers do **not** fire while the Mac is asleep — so on a laptop
that's often closed, the 30-min schedule stalls. To cover that, `sleepwatcher`
runs the exporter on every wake:

```sh
brew install sleepwatcher
brew services start sleepwatcher
# if `pgrep sleepwatcher` shows nothing after starting, force it once:
launchctl kickstart -k "gui/$(id -u)/homebrew.mxcl.sleepwatcher"
```

- The wake hook is `~/.wakeup` (runs `run.sh`, logs to `export.log`).
- It has a 15-min debounce so a wake right after a scheduled run doesn't
  double-fire, and rapid maintenance wakes don't pile up.
- Net behavior: **every 30 min while awake + one sync on each wake.** True
  every-30-min-through-sleep isn't possible without forcing wakes (`pmset`).
- Check it's alive: `pgrep -lf sbin/sleepwatcher`.

## Running on Windows

`export.mjs` is already portable -- `node:path`, `os.homedir()`, and a filename
sanitiser that strips the characters Windows rejects along with trailing dots and
spaces. What does not port is `run.sh` and the launchd plist. Use `run.ps1`
(the PowerShell peer of `run.sh`, same directory) and Task Scheduler.

### One-time setup

Steps 1 and 2 are unchanged -- create the key in the Granola desktop app with
the **Personal notes** scope, then:

```powershell
cd <path-to-vault>
Copy-Item .system\.env.example .system\.env
notepad .system\.env      # paste the grn_... key after GRANOLA_API_KEY=
```

Test it once:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\run.ps1
```

`run.ps1` does what `run.sh` does: loads `.system\.env` filtered to the
`GRANOLA_` prefix (same `KEY=VALUE` format, quotes and `#` comments handled),
trims the log, resolves `node`, runs the exporter. Windows paths need no escaping --
`GRANOLA_OUT_DIR=C:\path\to\vault\Resources\Meetings` is read literally. If the
vault sits at `<path-to-vault>` the default output path already resolves
correctly and you can leave it unset.

### Turn on the schedule (every 30 minutes)

```powershell
$tool = "<path-to-vault>\.system\connectors\granola-export"

$action = New-ScheduledTaskAction -Execute "powershell.exe" -WorkingDirectory $tool `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$tool\run.ps1`" -Log"

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration ([TimeSpan]::MaxValue)

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName "granola-export" -Action $action -Trigger $trigger `
  -Settings $settings -Description "Export Granola notes to the vault"
```

The `-Log` switch is what sends output to `export.log`; without it the exporter
prints to the terminal. That preserves the Mac split where only scheduled runs
are logged.

### Managing the schedule

```powershell
Get-ScheduledTask -TaskName "granola-export" | Get-ScheduledTaskInfo   # last run + LastTaskResult
Start-ScheduledTask -TaskName "granola-export"                         # run right now
Unregister-ScheduledTask -TaskName "granola-export" -Confirm:$false    # stop and remove
Disable-ScheduledTask -TaskName "granola-export"                       # stop, keep it installed
Get-Content .\export.log -Tail 20 -Wait                                # the tail -f equivalent
```

Change the cadence by re-running `Register-ScheduledTask` with a different
`-RepetitionInterval`; it overwrites the existing task.

### Sleep is handled for you -- no wake hook needed

The `sleepwatcher` setup on the Mac exists because `StartInterval` timers do not
fire while the machine is asleep and launchd simply drops the missed run. Task
Scheduler has that case built in: **`-StartWhenAvailable`** runs a missed
repetition once after resume. So the net behavior on Windows is *every 30 min
while awake + one catch-up sync after each resume* -- the same outcome as
launchd + sleepwatcher + the 15-minute debounce, with nothing extra to install.

Two knobs if you want more than that:

- `-WakeToRun` on the settings object forces a wake to run on schedule (the
  `pmset` equivalent). Costs battery; usually not worth it.
- Add a resume trigger if you want a sync on *every* wake rather than only after
  a missed one. `New-ScheduledTaskTrigger` cannot express it, so it needs a raw
  event trigger on Kernel-Power event ID 107 via the `Register-ScheduledTask
  -Xml` form. `run.ps1` has no debounce of its own, so pair this with
  `-MultipleInstances IgnoreNew` (already set above) to avoid pile-ups.

Idempotency and rate limiting are in `export.mjs`, so re-runs from any trigger
stay safe: a file is only rewritten when its content changes.

## Options (in `.system/.env`)
All optional; the connector runs on its defaults without them. They go in the
same `.system/.env` as the key, in the `granola-export` block.
- `GRANOLA_TRANSCRIPT=1` — include full transcripts (larger files, slower).
- `GRANOLA_OUT_DIR=...` — write somewhere other than `Resources/Meetings`. Year subfolders
  are created beneath whatever base you give it.
- `GRANOLA_LOG_KEEP_RUNS=<n>` — cap `export.log` at the last n runs (default 1000).
- `GRANOLA_REDACTION=true` — screen every note for sensitive material before
  writing it (default off). See [Redaction](#redaction).
- `GRANOLA_REDACTION_TIMEOUT=<seconds>` — cap on one screening call (default 300).
- `GRANOLA_CLAUDE_BIN=<path>` — use a specific `claude` binary.
- `GRANOLA_REDACTION_MODEL=<id>` — screen with a different model
  (default `claude-opus-5`).

## Redaction

Granola records whatever was said in the room. A review of exported notes found
material about identifiable people — abuse allegations and reporting failures,
church and employment discipline, criminal charges, financial misconduct with
figures attached, personal hardship. Left alone, all of it lands in the vault
every thirty minutes, gets indexed by Obsidian, and is read by every agent that
touches the vault.

Turn screening on in `.system/.env`:

```sh
GRANOLA_REDACTION=true
```

Or for a single run, either way:

```sh
./run.sh --redacted       # screen this run whatever the file says
./run.sh --no-redacted    # skip screening this run
```

Precedence is flag, then `GRANOLA_REDACTION`, then off.

### What it does

The note is split into chunks — one bullet, one paragraph, one heading, one
speaker turn — and each chunk goes through two layers.

**Lexical** is keyword and regex, local, no network, no model. It catches SSNs,
payment cards (Luhn-checked, so order numbers survive), emails and phone numbers,
plus the vocabulary of each category. Ambiguous terms only fire alongside a
qualifier, which is what keeps ordinary notes intact: "API abuse", "terminate the
instance", "investigate the regression", "SOC 2 audit finding", "$40,000 of
budget" and "separation of concerns" are all left alone, while "abuse" next to a
minor, "probation" next to a court, and a shortfall next to an audit finding are
not. This layer is authoritative — the second layer can add a redaction but never
removes one.

**Semantic** is one `claude -p` call per changed note, pinned to
`claude-opus-5`. It sees the
lexically-screened text, classifies each chunk, and rewrites the flagged ones. It
exists for the material that is implied rather than stated: two paragraphs
circling someone's firing without ever using a listed word. Because it rewrites a
whole chunk, it can also widen a redaction the lexical layer could only pin to a
single phrase.

Redacted passages become:

```
[REDACTED · discipline]
```

The marker names the category and nothing else. Where to find the unredacted
original is a property of the note, not of each passage, and it is already in the
frontmatter as `granola_url` — or, for a note Granola gave no web url, as
`granola_id`. Putting the link in every marker repeated the same url up to a
dozen times in one note and buried the one thing the marker is there to say.

### Reading the result

Frontmatter records what happened, so a screened note is obviously screened and
can be reviewed by category:

```yaml
screened: true
screened_mode: lexical+semantic
screened_version: "2"
screened_model: claude-opus-5
redactions: 3
flag_categories:
  - abuse
  - discipline
source_hash: 6f1c…
```

Find everything that was touched, or everything in one category:

```sh
grep -rl "^screened: true" Resources/Meetings | xargs grep -l "  - abuse"
```

### Four things to know

**The model is pinned, and recorded.** Screening runs on `claude-opus-5`, not on
whatever each machine has set as its CLI default — unpinned, the same note
screened differently on the laptop and the desktop. The choice is measured, not
assumed: against the bank fixture whose sensitive material is entirely implied,
opus caught it 10 of 10 runs, haiku 13 of 15, sonnet 6 of 10, with all three
clean on every negative. Override with `GRANOLA_REDACTION_MODEL`. Each note records both halves
of what judged it: `screened_version` for the prompt, `screened_model` for the
model, so notes screened by something you later stop trusting can be found and
re-screened:

```sh
grep -rl "screened_model: claude-opus-5" Resources/Meetings
```

**It needs `claude` on PATH and signed in.** The exporter checks once at startup
and refuses to run rather than failing note by note through an unattended run.

**It fails closed.** If the model call errors or times out, that note is not
written at all and whatever was already on disk is left alone. A note that looks
screened and is not is worse than one that was obviously never processed.

**Re-runs are still cheap.** `source_hash` in the frontmatter is the hash of the
*unredacted* render. A note whose source has not changed is skipped without a
model call, so a scheduled run costs one call per genuinely changed note. Hashing
the screened file instead would compare non-deterministic output against itself
and re-screen the whole vault on every run.

**Turning it off un-redacts.** With screening off the exporter writes the
unredacted render, and since that content differs from the screened file on disk,
previously screened notes get rewritten in the clear on the next run.

### What is not screened

Frontmatter and filenames. `title`, `attendees` and `owner_email` are left as
Granola supplied them — the attendee list is what makes a meeting note usable,
and the filename is built from the title, so redacting the title in frontmatter
would not remove it from disk anyway. A meeting whose *title* is sensitive still
needs renaming by hand.

### Inspecting one note

`redact/screen.mjs` runs the same code path the exporter runs, on a file you
choose, and prints what each layer did. It writes nothing — the note on disk is
never modified. Point it at a fixture to watch a category behave, or at a real
exported note before turning screening on for the whole vault.

```sh
node redact/screen.mjs tests/notes/abuse-age-relationship-positive.md --trace --body
```

```
── trace ── 1 of 5 chunk(s) changed

chunk 3 (listItem)
  original   A 14-year-old in the after-school program and an adult volunteer; the relationship was flagged to us by a parent.
  lexical    A [REDACTED · abuse] in the after-school program and an adult volunteer; the relationship was flagged to us by a parent.
  semantic   A [REDACTED · abuse] [REDACTED · abuse]

# 2026-03-11 Program Review

- A [REDACTED · abuse] [REDACTED · abuse]
- Volunteer rotation needs a second adult in the room at all times.

2 redaction(s) in abuse · lexical+semantic · nothing written
```

| Option | |
| --- | --- |
| `--lexical` | local pass only, no model call, instant |
| `--trace` | show each changed chunk, layer by layer |
| `--body` | print only the body, not the frontmatter |
| `--json` | machine-readable `{redactions, categories, text}` |

The summary line goes to stderr, so `--json` and `--body` pipe cleanly.

### Tests

```sh
node --test tests/
```

Fifty-eight tests, fully offline — the model is stubbed, nothing shells out to
`claude`. `tests/notes/` is the bank of example notes: positive cases for every
category and negative cases for the benign phrasings that a naive keyword list
eats. Each fixture declares its own expectation in frontmatter, so covering a new
case means adding one file.

## Notes
- Re-runs are idempotent: a file is only rewritten when its content changes.
- Only notes that have a generated AI summary are returned by the API.
- Rate limit is handled automatically (stays under 5 req/s, backs off on 429).
- With redaction on, a note that fails screening is counted as failed and not
  written; the run continues with the rest.

## Log
- Each launchd run appends a timestamped entry to `export.log`.
- Check the last run: `tail -4 export.log`.
- The log is capped at the **last 1000 runs** — `run.sh` trims it in place at the
  start of each run. Override with `GRANOLA_LOG_KEEP_RUNS=<n>` in `.system/.env`.
- Only launchd-triggered runs are logged; running `./run.sh` by hand prints to
  the terminal instead.
