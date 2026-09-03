# shellcheck shell=bash
# Machinery: PARA skeleton, settings, Obsidian config, seed notes, connectors,
# routines. Everything here is deterministic -- no model calls.
#
# Source after common.sh and template.sh.

[ -n "${_CATALYST_WIRE_SH:-}" ] && return 0
_CATALYST_WIRE_SH=1

# ------------------------------------------------------------------ skeleton

wire_dirs() {
  _year="$(date_fmt "$TODAY" '+%Y')"

  mkdir -p \
    "$VAULT/Projects" "$VAULT/Areas" \
    "$VAULT/Resources/Meetings/$_year" \
    "$VAULT/Resources/Agendas/$_year" \
    "$VAULT/Resources/Plans/$_year/Daily" \
    "$VAULT/Resources/Plans/$_year/Weekly" \
    "$VAULT/Archive/$_year" \
    "$VAULT/Clippings" "$VAULT/Skills" "$VAULT/Routines" "$VAULT/Templates" \
    "$VAULT/.claude" "$VAULT/.obsidian" \
    "$VAULT/.system/log/run-logs"

  tmpl_project_paths | while IFS= read -r _p; do
    [ -n "$_p" ] && mkdir -p "$VAULT/Projects/$_p"
  done
  tmpl_area_names | while IFS= read -r _a; do
    [ -n "$_a" ] && mkdir -p "$VAULT/Areas/$_a"
  done

  ok "PARA skeleton ($(find "$VAULT" -type d | wc -l | tr -d ' ') dirs)"
}

# ------------------------------------------------------------------- payload

# Copy the versioned tooling into the vault. The exclusion list is the point:
# `.env` carries a live API key, a manifest is per-machine state that must never
# travel between vaults, and `*.log` leaks activity history.
wire_payload() {
  _ex=(--exclude ".env" --exclude "*.log" --exclude "__pycache__" --exclude "*.pyc"
       --exclude ".DS_Store" --exclude ".git" --exclude "manifest.sqlite*"
       --exclude "node_modules" --exclude "debug-note.json")

  rsync -a "${_ex[@]}" "$PAYLOAD/Skills" "$PAYLOAD/Routines" "$VAULT/"
  rsync -a "${_ex[@]}" "$PAYLOAD/.system/wiki" "$PAYLOAD/.system/connectors" "$VAULT/.system/"
  cp "$PAYLOAD/.system/.env.example" "$VAULT/.system/.env.example"

  # zip round-trips drop the executable bit; rsync -a preserves it, but a payload
  # that arrived as an archive would not.
  find "$VAULT/.system" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

  # Skills the template did not ask for are removed rather than left inert: a
  # SKILL.md on disk is discoverable, and a skill whose sources were never
  # configured will run and produce a confidently empty answer.
  _want="$(tmpl_skill_names skills__system; tmpl_skill_names skills__user)"
  _dropped=""
  for _d in "$VAULT/Skills"/*/; do
    [ -d "$_d" ] || continue
    _n="$(basename "$_d")"
    case "
$_want
" in
      *"
$_n
"*) ;;
      *) rm -rf "$_d"; _dropped="$_dropped $_n" ;;
    esac
  done
  [ -n "$_dropped" ] && info "skills not requested, removed:$_dropped"

  ok "payload installed ($(find "$VAULT/Skills" -name SKILL.md | wc -l | tr -d ' ') skills, $(find "$VAULT/.system" -type f | wc -l | tr -d ' ') machinery files)"
}

# Run the bundle's own leftover-value gate when it is present. The payload is
# clean today, so this is a tripwire for a future rebuild from a dirtier tree
# rather than a step that currently does work.
wire_render_gate() {
  _r="$PAYLOAD/.system/vault-bundle/render.py"
  if [ ! -f "$_r" ]; then
    info "render.py not present in payload -- skipping the leftover-value gate"
    return 0
  fi
  if python3 "$_r" --root "$VAULT" --check-only --vault-path "$VAULT" \
       --vault-name "$VAULT_NAME" --label-prefix "$LABEL_PREFIX" >/dev/null 2>&1; then
    ok "no authoring-vault values remain in the installed payload"
  else
    python3 "$_r" --root "$VAULT" --check-only --vault-path "$VAULT" \
      --vault-name "$VAULT_NAME" --label-prefix "$LABEL_PREFIX" || true
    die "payload still carries authoring-vault values (above). Those reach a plist
       or a skill and fail on this machine. Fix render.py's rules and re-run."
  fi
}

# ------------------------------------------------------------- machinery files

# The deny glob has to be absolute and therefore per-vault, which is exactly why
# it is rendered here rather than committed.
wire_settings() {
  cat > "$VAULT/.claude/settings.local.json" <<JSON
{
  "permissions": {
    "allow": [
      "Edit(**/*.md)",
      "Write(**/*.md)",
      "Bash(python3 .system/wiki/cli.py:*)"
    ],
    "deny": [
      "Edit($VAULT/Resources/Meetings/**)",
      "Write($VAULT/Resources/Meetings/**)"
    ]
  }
}
JSON
  ok "settings.local.json (Resources/Meetings/ is write-denied)"
}

wire_obsidian() {
  _year="$(date_fmt "$TODAY" '+%Y')"
  cat > "$VAULT/.obsidian/daily-notes.json" <<JSON
{
  "folder": "Resources/Plans/$_year/Daily",
  "format": "YYYY-MM-DD",
  "template": "Templates/Daily Note Template.md"
}
JSON
  cat > "$VAULT/.obsidian/templates.json" <<'JSON'
{
  "folder": "Templates"
}
JSON
  ok "Obsidian daily-notes and template folders configured"
  warn "Daily Notes points at Resources/Plans/$_year/Daily -- update it each January"
}

wire_env() {
  _env="$VAULT/.system/.env"
  if [ -f "$_env" ]; then
    info ".system/.env already exists -- left alone"
  else
    cp "$VAULT/.system/.env.example" "$_env"
    chmod 600 "$_env"
    ok ".system/.env created from the template (mode 600)"
  fi
}

wire_log() {
  _log="$VAULT/.system/log/log-$(date_fmt "$TODAY" '+%Y-%m').csv"
  printf '%sT%s|build|.system/|vault built from %s by build-vault.sh\n' \
    "$TODAY" "$(date '+%H:%M:%S')" "$(basename "$TEMPLATE")" > "$_log"
  ok "action log started ($(basename "$_log"))"
}

# These are for a HUMAN making a note by hand in Obsidian, and nothing else. The
# skills write their notes directly and carry their own skeletons -- deliberately,
# because `{{date}} {{time}}` is expanded by Obsidian's Templates plugin at insert
# time only. An agent that copied one of these files would write those braces
# literally, and every date-ranged query filtering on `created` would then skip the
# note. Keep these in sync with the skeletons in Skills/{daily-plan,weekly-planning}.
wire_templates() {
  cat > "$VAULT/Templates/Daily Note Template.md" <<'EOF'
---
created: "{{date}} {{time}}"
tags:
  - daily-planning
---

# Communication


# News


# Notes
EOF
  cat > "$VAULT/Templates/Weekly Planning.md" <<'EOF'
---
created: "{{date}} {{time}}"
tags:
  - weekly-planning
---

# Weekly Goals
EOF
  ok "note templates written (for hand-authoring in Obsidian; skills embed their own)"
}

# The tagger needs real content: tagging an empty vault teaches it nothing, and
# the review gate is only meaningful against something. One stub per project and
# area gives the first pass a vocabulary to establish.
wire_seed_notes() {
  _n=0
  tmpl_records projects | while IFS='|' read -r _p _k _d; do
    [ -n "$_p" ] || continue
    {
      printf '# %s\n\n' "$_p"
      [ -n "$_d" ] && printf '%s\n\n' "$_d"
      printf '## Scope\n\nWhat this project covers, and what it does not.\n\n'
      printf '## Current state\n\nNothing recorded yet — this note was created when the vault was built.\n\n'
      printf '## Open questions\n\n- \n'
    } > "$WORK/seed.md"
    stamp_note "$VAULT/Projects/$_p/$_p Overview.md" "$WORK/seed.md" "project" "" ""
    tmpl_children projects "$_p" | while IFS='|' read -r _c _ck _cd; do
      [ -n "$_c" ] || continue
      {
        printf '# %s\n\n' "$_c"
        [ -n "$_cd" ] && printf '%s\n\n' "$_cd"
        printf 'A subproject of [[%s Overview]].\n\n## Current state\n\nNothing recorded yet.\n' "$_p"
      } > "$WORK/seed.md"
      stamp_note "$VAULT/Projects/$_p/$_c/$_c Overview.md" "$WORK/seed.md" "project" "" ""
    done
  done
  tmpl_records areas | while IFS='|' read -r _a _k _d; do
    [ -n "$_a" ] || continue
    {
      printf '# %s\n\n' "$_a"
      _ad="${_d:-$_k}"
      [ -n "$_ad" ] && printf '%s\n\n' "$_ad"
      printf '## The standard\n\nWhat "maintained" means here.\n\n## Cadence\n\n- \n'
    } > "$WORK/seed.md"
    stamp_note "$VAULT/Areas/$_a/$_a.md" "$WORK/seed.md" "area" "" ""
  done
  _n="$(find "$VAULT/Projects" "$VAULT/Areas" -name '*.md' | wc -l | tr -d ' ')"
  ok "seeded $_n starter note(s) for the first tagging pass"
}

wire_tags_md() {
  _mode="$(tmpl_kv tag-vocabulary Mode)"
  [ "$_mode" = "canon" ] || { info "tag vocabulary: frequency mode (the default)"; return 0; }
  _tags="$(tmpl_records tag-vocabulary | cut -d'|' -f1 | grep -vE '^(Mode|Tags):' || true)"
  if [ -z "$_tags" ]; then
    warn "tag vocabulary set to canon but no tags listed -- staying in frequency mode"
    return 0
  fi
  printf '%s\n' "$_tags" | sed 's/^/- /' > "$VAULT/.system/tags.md"
  warn "canon mode is only safe while this list is maintained; a stale tags.md
        makes tag-lint recommend merges toward tags nobody uses"
  ok ".system/tags.md written (canon mode)"
}

# ------------------------------------------------------------------ exclusions

wire_sync_exclusions() {
  _method="$(tmpl_kv sync Method)"
  case "${_method:-none}" in
    git)
      cat > "$VAULT/.gitignore" <<'EOF'
.system/.env
.system/wiki/manifest.sqlite
.system/wiki/manifest.sqlite-wal
.system/wiki/manifest.sqlite-shm
.system/log/
*.log
__pycache__/
*.pyc
.DS_Store
.obsidian/workspace.json
EOF
      ok ".gitignore written (manifest, .env and logs excluded)"
      ;;
    obsidian)
      info "Obsidian Sync skips hidden folders, so .system/ is excluded already"
      ;;
    drive|onedrive|dropbox)
      warn "$_method does NOT skip dotfolders. Exclude .system/ manually, or the
        manifest syncs between machines and corrupts silently."
      ;;
    none|"") info "no sync configured" ;;
    *) warn "unrecognised sync method '$_method' -- no exclusions written" ;;
  esac
}

# ----------------------------------------------------------------- connectors

wire_connectors() {
  _meet="$(tmpl_records connectors__meetings | cut -d'|' -f1 | grep -v '^none$' || true)"
  if [ -z "$_meet" ]; then
    info "no meeting connector requested -- Resources/Meetings/ is a manual folder"
    return 0
  fi
  case "$_meet" in
    *granola-export*) ;;
    *) warn "unsupported meeting connector '$_meet' -- only granola-export is bundled"
       return 0 ;;
  esac

  # The connector's own installer only WARNS about a missing key and still exits
  # 0, so the build gates on it here instead. A LaunchAgent that fires every 30
  # minutes against no credential is just a log full of failures.
  # The example ships a `grn_paste_your_key_here` placeholder, which matches any
  # naive `grn_` test -- so the placeholder is excluded explicitly. Without this
  # the build reports a key it does not have and installs an agent that only logs
  # failures.
  if grep -qE '^[[:space:]]*(export[[:space:]]+)?GRANOLA_API_KEY=grn_[A-Za-z0-9]' "$VAULT/.system/.env" 2>/dev/null \
     && ! grep -q 'GRANOLA_API_KEY=grn_paste_your_key_here' "$VAULT/.system/.env" 2>/dev/null; then
    ok "GRANOLA_API_KEY present in .system/.env"
    GRANOLA_READY=1
  else
    warn "GRANOLA_API_KEY is not set in .system/.env"
    info "  Granola desktop -> Settings -> Connectors -> API keys (Business/Enterprise)"
    info "  Paste it after GRANOLA_API_KEY= in $VAULT/.system/.env, then run:"
    info "    $VAULT/.system/connectors/granola-export/install.sh"
    GRANOLA_READY=0
  fi
}

# --------------------------------------------------------------------- routines

# Plain English to cron. Anything already looking like five fields is passed
# through untouched, so a user can write the expression directly.
wire_cron_of() {
  _f="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$_f" in
    *' '*' '*' '*' '*) if printf '%s' "$_f" | grep -qE '^[-0-9*/,]+ [-0-9*/,]+ [-0-9*/,]+ [-0-9*/,]+ [-0-9*/,]+$'; then
                         printf '%s' "$_f"; return 0
                       fi ;;
  esac

  _h=6; _m=0
  # A frequency with no clock time ("weekly") legitimately matches nothing.
  _t="$(printf '%s' "$_f" | grep -oE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)' | head -1 || true)"
  if [ -n "$_t" ]; then
    _hh="$(printf '%s' "$_t" | sed -E 's/^([0-9]{1,2}).*/\1/')"
    _mm="$(printf '%s' "$_t" | sed -nE 's/^[0-9]{1,2}:([0-9]{2}).*/\1/p')"
    _ap="$(printf '%s' "$_t" | grep -oE 'am|pm' || true)"
    _h="$_hh"; _m="${_mm:-0}"
    [ "$_ap" = "pm" ] && [ "$_h" -lt 12 ] && _h=$(( _h + 12 ))
    [ "$_ap" = "am" ] && [ "$_h" = "12" ] && _h=0
  fi
  _m="$(printf '%s' "$_m" | sed 's/^0*//')"; _m="${_m:-0}"

  case "$_f" in
    *weekday*|*"mon-fri"*)          printf '%s %s * * 1-5' "$_m" "$_h" ;;
    *sunday*|*sun*)                 printf '%s %s * * 0'   "$_m" "$_h" ;;
    *monday*)                       printf '%s %s * * 1'   "$_m" "$_h" ;;
    *friday*|*fri*)                 printf '%s %s * * 5'   "$_m" "$_h" ;;
    *saturday*)                     printf '%s %s * * 6'   "$_m" "$_h" ;;
    *daily*|*"every day"*|*day*)    printf '%s %s * * *'   "$_m" "$_h" ;;
    *weekly*)                       printf '%s %s * * 0'   "$_m" "$_h" ;;
    *)                              printf '%s %s * * *'   "$_m" "$_h" ;;
  esac
}

_wire_cron_human() {
  awk -v c="$1" 'BEGIN {
    split(c, f, " ")
    dow = f[5]
    if (dow == "1-5") d = "weekdays"
    else if (dow == "0") d = "Sundays"
    else if (dow == "1") d = "Mondays"
    else if (dow == "5") d = "Fridays"
    else if (dow == "6") d = "Saturdays"
    else d = "daily"
    h = f[2] + 0; m = f[1] + 0
    ap = (h < 12) ? "AM" : "PM"
    hh = h % 12; if (hh == 0) hh = 12
    printf "%s at %d:%02d %s", d, hh, m, ap
  }'
}

# Rewrite each routine doc so its Schedule section records the task ID and cron
# this build actually used. A routine doc describing a schedule the harness is not
# running is worse than no doc.
wire_routines() {
  ROUTINE_PLAN="$WORK/routines.txt"; : > "$ROUTINE_PLAN"
  tmpl_routine_names | while read -r _r; do
    [ -n "$_r" ] || continue
    _doc="$VAULT/Routines/$_r.md"
    if [ ! -f "$_doc" ]; then
      warn "no bundled routine doc for '$_r' -- skipping"
      continue
    fi
    _freq="$(tmpl_alias_attr routines "$_r" Frequency)"
    _cron="$(wire_cron_of "${_freq:-daily 6:00am}")"
    printf '%s|%s|%s\n' "$_r" "$_cron" "$_freq" >> "$ROUTINE_PLAN"

    {
      printf '\n'
      printf 'Runs **%s** via a Claude scheduled task.\n\n' "$(_wire_cron_human "$_cron")"
      printf -- '- Task ID: `%s`\n' "$_r"
      printf -- '- Cron: `%s` (local time)\n' "$_cron"
      printf -- '- Managed with `list_scheduled_tasks` / `update_scheduled_task` / `delete_scheduled_task`\n'
      [ -n "$_freq" ] && printf -- '\nRequested as "%s" in the implementation template.\n' "$_freq"
    } > "$WORK/blk-sched.md"
    _splice "$_doc" "## Schedule" "$WORK/blk-sched.md"
  done
  ok "$(wc -l < "$ROUTINE_PLAN" | tr -d ' ') routine doc(s) updated with their real schedule"
}

# Emit the registration prompt for the confirmed routines.
#
# Three schedulers are in play and only two are scriptable. Both LaunchAgents are
# installed by their own install.sh. Claude Code routines are not: the prompt half
# lives on disk at ~/.claude/scheduled-tasks/<id>/SKILL.md, but the SCHEDULE is
# bound through in-session tooling (`list_scheduled_tasks`/`update_scheduled_task`)
# that a headless `claude -p` does not have. `CronCreate` IS available headlessly
# but is session-scoped and in-memory -- a job created in one `claude -p` is gone
# by the next one, verified by doing exactly that.
#
# So the build stops at the last mile it can reach honestly: a ready prompt an
# INTERACTIVE session executes. Nothing is written outside the vault.
wire_routine_register() {
  _confirmed="$1"
  _out="$VAULT/.system/routines-register.md"
  [ -s "$_confirmed" ] || { info "no routines confirmed -- nothing to register"; return 0; }

  {
    printf 'Register the following scheduled routines for this vault.\n\n'
    printf '**Run this in Claude Desktop (agent mode), not the Claude Code CLI.** The\n'
    printf 'tool that creates a LOCAL scheduled task (`create_scheduled_task`) ships\n'
    printf 'with Desktop agent mode. The CLI does not have it; what the CLI has is\n'
    printf '`RemoteTrigger`, which creates a CLOUD routine that runs in a remote\n'
    printf 'sandbox and cannot reach this vault on disk. A cloud routine here would\n'
    printf 'register cleanly and then fail every run.\n\n'
    printf 'For each routine below, create a scheduled task with the given task ID,\n'
    printf 'cron expression and prompt body. If a task with that ID already exists,\n'
    printf 'update it rather than creating a duplicate. Report what you registered.\n\n'
    printf 'Vault: `%s`  (Obsidian vault name `%s`)\n\n---\n\n' "$VAULT" "$VAULT_NAME"

    while IFS='|' read -r _r _cron; do
      [ -n "$_r" ] || continue
      # The skill a routine drives is read from its own `## Related` line rather
      # than mapped here, so adding a routine needs no edit to this function.
      _skill="$(grep -oE 'Skills/[a-z-]+/SKILL\.md' "$VAULT/Routines/$_r.md" 2>/dev/null \
                | head -1 | sed -E 's|Skills/([a-z-]+)/SKILL\.md|\1|')"
      _skill="${_skill:-$_r}"
      _when="$(_wire_cron_human "$_cron")"

      printf '## Task `%s`\n\n' "$_r"
      printf -- '- Cron: `%s`  (%s, local time)\n' "$_cron" "$_when"
      printf -- '- Prompt body:\n\n'
      printf '```\n'
      printf 'Run the `%s` skill for this vault. This is an unattended scheduled\n' "$_skill"
      printf 'run -- do the work, do not ask questions, and do not wait for approval.\n\n'
      printf '**Permission mode: Auto.** Not `default`, not `Plan`. Nobody is at the\n'
      printf 'keyboard, so a run that stops on an approval prompt produces nothing at\n'
      printf 'all. Auto still honours the soft-deny rules in settings, so the vault\n'
      printf 'guardrails are enforced rather than bypassed; do not escalate to\n'
      printf '`bypassPermissions`.\n\n'
      printf '**Working directory:** `%s`. Start by cd-ing there; every path is\n' "$VAULT"
      printf 'relative to it.\n\n'
      printf '**What to run:** invoke the `%s` skill (Skill tool) and follow it end to\n' "$_skill"
      printf 'end. If it is not registered, read `Skills/%s/SKILL.md` in the vault and\n' "$_skill"
      printf 'follow that -- it is the authoritative logic, not this prompt. Read\n'
      printf '`CLAUDE.md`, `USER.md` and `SOURCES.md` at the vault root first, for\n'
      printf 'structure, personalisation and which sources are actually connected.\n\n'
      printf '**Sources:** resolve every role from the `## Who reads what` table in\n'
      printf '`SOURCES.md` at run time. A role set to `none`, or naming a tool absent\n'
      printf 'from this session, is skipped AND NAMED in the output -- never silently\n'
      printf 'omitted, never substituted with a different tool.\n\n'
      printf '**Log it:** append one line to `.system/log/log-YYYY-MM.csv`,\n'
      printf 'pipe-delimited `timestamp|action|path|summary`, summary single-line.\n\n'
      printf 'See `Routines/%s.md` in the vault for the schedule rationale.\n' "$_r"
      printf '```\n\n'
    done < "$_confirmed"

    printf -- '---\n\nAfter registering, confirm each task ID and cron back to the user,\n'
    printf 'and note that the times are local to the machine that registered them.\n'
  } > "$_out"

  ok "registration prompt written to .system/routines-register.md"
}

# ------------------------------------------------------------------- platform

# Resolve the target platform from the template, defaulting to the host.
#
# This is an assertion, not a cross-compile switch: the build installs background
# jobs on the machine it is running on, so a template claiming `windows` while
# running on a Mac cannot be satisfied. Failing loudly beats installing the wrong
# scheduler and discovering it when the job never fires.
wire_resolve_platform() {
  _host="$(uname -s 2>/dev/null || echo unknown)"
  case "$_host" in
    Darwin)                 _detected=macos ;;
    MINGW*|MSYS*|CYGWIN*)   _detected=windows ;;
    Linux)                  _detected=linux ;;
    *)                      _detected=unknown ;;
  esac

  _want="$(tmpl_platform_raw | tr '[:upper:]' '[:lower:]')"
  case "${_want:-auto}" in
    ""|auto)          PLATFORM="$_detected" ;;
    macos|mac|darwin) PLATFORM=macos ;;
    windows|win)      PLATFORM=windows ;;
    linux)            PLATFORM=linux ;;
    *) die "# Platform names an unknown OS: '$_want'
       Use macos, windows, linux, or auto." ;;
  esac

  if [ "${_want:-auto}" != "auto" ] && [ -n "$_want" ] && [ "$PLATFORM" != "$_detected" ]; then
    die "# Platform says '$PLATFORM' but this machine is '$_detected' ($_host).

       The build installs the background jobs locally, so it cannot set up a
       Windows Scheduled Task from macOS or a LaunchAgent from Windows. Run the
       build on the target machine, or set '- OS: auto' in the template."
  fi

  info "platform   $PLATFORM$([ "${_want:-auto}" = "auto" ] && printf ' (detected)' || printf ' (declared)')"
  case "$PLATFORM" in
    macos)   info "           background jobs install as LaunchAgents" ;;
    windows) info "           background jobs install as Scheduled Tasks (PowerShell script written)" ;;
    *)       warn "           no scheduler integration for '$PLATFORM' -- jobs must be wired by hand" ;;
  esac
}

# On Windows the build cannot call launchctl, so it emits the equivalent
# PowerShell instead. Paths follow config.py exactly -- RUN_LOG_DIR is
# `.system/log/run-logs`, and an earlier version of the wiki README dropped the
# `log` segment, which sent every scheduled run's output to a directory nobody
# reads.
wire_windows_agents() {
  _ps="$VAULT/.system/install-agents.ps1"
  # A naive s|/|\| turns the MSYS path /c/Users/rob/vault into \c\Users\rob\vault
  # -- no drive letter, so every path in the generated script is wrong. cygpath
  # ships with Git Bash and MSYS and gets this right; the sed is the fallback.
  if command -v cygpath >/dev/null 2>&1; then
    _win_vault="$(cygpath -w "$VAULT")"
  else
    _win_vault="$(printf '%s' "$VAULT" | sed -e 's|^/\([a-zA-Z]\)/|\1:/|' -e 's|/|\\|g')"
  fi
  case "$_win_vault" in
    [a-zA-Z]:*) ;;
    *) warn "could not derive a Windows path from '$VAULT' (got '$_win_vault')."
       info "  Edit \$vault at the top of .system/install-agents.ps1 before running it." ;;
  esac
  {
    printf '# Register this vault'"'"'s background jobs as Windows Scheduled Tasks.\n'
    printf '#\n'
    printf '#   powershell -NoProfile -ExecutionPolicy Bypass -File .system\\install-agents.ps1\n'
    printf '#\n'
    printf '# Both tasks must run in your logged-on session -- the same reason the macOS\n'
    printf '# jobs are LaunchAgents and not LaunchDaemons. Register-ScheduledTask with no\n'
    printf '# -User/-Password defaults to "run only when the user is logged on", which is\n'
    printf '# what you want. Do NOT switch it to "run whether the user is logged on or\n'
    printf '# not": that lands in session 0 with no desktop, and every Obsidian call fails\n'
    printf '# silently.\n\n'
    printf '$vault = "%s"\n' "$_win_vault"
    printf '$logs  = "$vault\\.system\\log\\run-logs"\n'
    printf 'New-Item -ItemType Directory -Force -Path $logs | Out-Null\n\n'

    printf '# --- Wiki ingestion, every 15 minutes ---------------------------------\n'
    printf '$py = (Get-Command python).Source\n'
    printf '$action = New-ScheduledTaskAction -Execute "cmd.exe" -WorkingDirectory $vault `\n'
    printf '  -Argument "/c `%s$py`%s `%s$vault\\.system\\wiki\\cli.py`%s run >> `%s$logs\\ingest.out.log`%s 2>> `%s$logs\\ingest.err.log`%s"\n' '"' '"' '"' '"' '"' '"' '"' '"'
    printf '$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `\n'
    printf '  -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration ([TimeSpan]::MaxValue)\n'
    printf '$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `\n'
    printf '  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Priority 7\n'
    printf 'Register-ScheduledTask -TaskName "wiki-ingest" -Action $action -Trigger $trigger `\n'
    printf '  -Settings $settings -Force -Description "Wiki ingestion pass (.system/wiki/cli.py run)"\n\n'

    if [ "${GRANOLA_WANTED:-0}" = "1" ]; then
      printf '# --- Granola export, every 30 minutes ---------------------------------\n'
      printf '$tool = "$vault\\.system\\connectors\\granola-export"\n'
      printf '$gAction = New-ScheduledTaskAction -Execute "powershell.exe" -WorkingDirectory $tool `\n'
      printf '  -Argument "-NoProfile -ExecutionPolicy Bypass -File `%s$tool\\run.ps1`%s -Log"\n' '"' '"'
      printf '$gTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `\n'
      printf '  -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration ([TimeSpan]::MaxValue)\n'
      printf '$gSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `\n'
      printf '  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries\n'
      printf 'Register-ScheduledTask -TaskName "granola-export" -Action $gAction -Trigger $gTrigger `\n'
      printf '  -Settings $gSettings -Force -Description "Export Granola notes to the vault"\n\n'
    fi

    printf '# --- The one that will bite you ---------------------------------------\n'
    printf '# `claude` is a .cmd shim. tagger.py invokes it through subprocess without a\n'
    printf '# shell, which reaches CreateProcess -- that searches PATH but does NOT apply\n'
    printf '# PATHEXT, so a bare `claude` dies with FileNotFoundError even though the same\n'
    printf '# word works in your shell. `cli.py doctor` does not catch it: it probes with\n'
    printf '# shutil.which, which DOES apply PATHEXT, so it reports PASS on a claude that\n'
    printf '# subprocess cannot launch. Point the config at the full path, then prove it:\n'
    printf '#\n'
    printf '#   where.exe claude\n'
    printf '#   setx WIKI_CLAUDE_BIN "$env:APPDATA\\npm\\claude.cmd"\n'
    printf '#   python .system\\wiki\\cli.py run --max-tag 1\n'
    printf '#   # then confirm a tagged_hash actually landed in a note on disk\n'
    printf '#\n'
    printf '# There is no WIKI_OBSIDIAN_BIN -- obsidian.py uses a socket, not a binary.\n\n'
    printf 'Write-Host "Registered. Check with: Get-ScheduledTask -TaskName wiki-ingest | Get-ScheduledTaskInfo"\n'
  } > "$_ps"
  ok "Windows scheduled-task script written to .system/install-agents.ps1"
}
