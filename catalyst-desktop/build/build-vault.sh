#!/usr/bin/env bash
# Build a working PARA knowledge vault from a filled-in implementation template.
#
#   ./build-vault.sh --template ./filled.md --out ~/notes/my-vault
#   ./build-vault.sh --template ./filled.md --out /tmp/v --dry-run
#   ./build-vault.sh --template ./filled.md --out /tmp/v --offline   # no model calls
#   ./build-vault.sh --template ./filled.md --out /tmp/v --tag-all   # no review gate
#
# This automates Projects/Catalyst/SETUP.md phases 3-14. The template is the
# artifact of the Phase 2 implementation interview; see TEMPLATE.md for its shape.
#
# Targets bash 3.2 -- the shell that ships on macOS.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$(cd "$HERE/.." && pwd)"          # catalyst-desktop/: the versioned tooling
LIB_DIR="$PAYLOAD/lib"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/llm.sh"
. "$HERE/lib/template.sh"
. "$HERE/lib/hydrate.sh"
. "$HERE/lib/wire.sh"

TEMPLATE=""; OUT=""; VAULT_NAME=""; LABEL_PREFIX="com.knowledgebase"
TODAY="$(date '+%Y-%m-%d')"
JOBS="${JOBS:-4}"
DRY_RUN=0; FORCE=0; VERIFY=1; KEEP_WORK=0
INSTALL_AGENTS=0; ASSUME_YES=0; DO_ROUTINES=1; DO_TAGGING=1
TAG_ALL=0; TAG_SAMPLE=10
GRANOLA_READY=0

usage() { sed -n '2,12p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --template)       TEMPLATE="$2"; shift 2 ;;
    --out)            OUT="$2"; shift 2 ;;
    --name)           VAULT_NAME="$2"; shift 2 ;;
    --label-prefix)   LABEL_PREFIX="$2"; shift 2 ;;
    --today)          TODAY="$2"; shift 2 ;;
    --model)          LLM_MODEL="$2"; shift 2 ;;
    --jobs)           JOBS="$2"; shift 2 ;;
    --offline)        LLM_OFFLINE=1; shift ;;
    --no-cache)       LLM_USE_CACHE=0; shift ;;
    --install-agents) INSTALL_AGENTS=1; shift ;;
    --skip-tagging)   DO_TAGGING=0; shift ;;
    --tag-all|--skip-tag-review) TAG_ALL=1; shift ;;
    --tag-sample)     TAG_SAMPLE="$2"; shift 2 ;;
    --no-routines)    DO_ROUTINES=0; shift ;;
    --yes|-y)         ASSUME_YES=1; shift ;;
    --force)          FORCE=1; shift ;;
    --no-verify)      VERIFY=0; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --keep-work)      KEEP_WORK=1; shift ;;
    -h|--help)        usage 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# ------------------------------------------------------------ 1/11  preflight

rule "1/11  Preflight"

[ -n "$TEMPLATE" ] || die "--template is required (start from $HERE/TEMPLATE.md)"
[ -n "$OUT" ]      || die "--out is required"
[ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"

need_cmd python3; need_cmd rsync; need_cmd awk; need_cmd sed; need_cmd find
[ "$LLM_OFFLINE" = "1" ] || need_cmd claude
date_fmt "$TODAY" '+%Y-%m-%d' >/dev/null 2>&1 || die "--today must be YYYY-MM-DD, got: $TODAY"

# ruamel.yaml is the trap. It is required for the no-Obsidian frontmatter write
# path, but `cli.py doctor` reports its absence as INFO rather than FAIL -- so a
# build passes every check and then fails at write time. A vault this script just
# created is by definition not open in Obsidian, so this path is the one that runs.
if [ "$DO_TAGGING" = "1" ]; then
  if python3 -c 'import ruamel.yaml' >/dev/null 2>&1; then
    ok "ruamel.yaml present (the no-Obsidian frontmatter write path)"
  else
    die "ruamel.yaml is not installed.

       The tagger writes frontmatter through it whenever Obsidian is not running,
       and a vault this script just created is never open in Obsidian. \`cli.py
       doctor\` reports this as INFO, not FAIL, so without this check the build
       would pass and the first tagging pass would fail at write time.

         pip3 install ruamel.yaml

       Or re-run with --skip-tagging to build the vault and tag it later."
  fi
fi

# ------------------------------------------------------------- 2/11  template

rule "2/11  Template"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/catalyst-build.XXXXXX")"
cleanup() {
  if [ "$KEEP_WORK" = "1" ]; then info "scratch kept at $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

template_load "$TEMPLATE" "$WORK"

case "$OUT" in /*) VAULT="$OUT" ;; *) VAULT="$(pwd)/$OUT" ;; esac
# Collapse repeated slashes and strip any trailing one. This is not cosmetic:
# .claude/settings.local.json embeds the absolute vault path in its deny glob,
# and build-verify.sh canonicalises with `cd && pwd` before comparing. A path
# like `$TMPDIR/vault` -- where TMPDIR already ends in `/` -- produced a glob
# with `//` in it that matched nothing, leaving the Resources/Meetings write
# protection silently inert.
VAULT="$(printf '%s' "$VAULT" | sed -e 's|//*|/|g' -e 's|/$||')"
[ -n "$VAULT_NAME" ] || VAULT_NAME="$(basename "$VAULT")"

info "template   $TEMPLATE"
info "vault      $VAULT"
info "name       $VAULT_NAME   (the obsidian vault=<name> parameter)"
info "owner      $(tmpl_kv "$TMPL_USER" Name)"
info "projects   $(tmpl_project_paths | tr '\n' ' ')"
info "areas      $(tmpl_area_names | tr '\n' ' ')"
info "connected  $(tmpl_roles | awk -F'|' '$2 != "none" && $2 != "" { printf "%s ", $1 }')"
info "skills     $(tmpl_skill_names skills__system | tr '\n' ' ')$(tmpl_skill_names skills__user | tr '\n' ' ')"
wire_resolve_platform

# .system/wiki/config.py derives VAULT_NAME from the folder basename. If --name
# disagrees, the skills say vault=<name> while the pipeline says vault=<basename>
# and every retrieval command silently targets the wrong vault.
if [ "$VAULT_NAME" != "$(basename "$VAULT")" ]; then
  warn "--name '$VAULT_NAME' != folder name '$(basename "$VAULT")'."
  info "  config.py will derive '$(basename "$VAULT")' and disagree with the skills."
  info "  Rename the folder to match, or export WIKI_VAULT_NAME wherever the pipeline runs."
fi

if [ "$DRY_RUN" = "1" ]; then
  rule "Dry run -- nothing written"
  info "would create these directories under $VAULT:"
  tmpl_project_paths | sed 's|^|   Projects/|'
  tmpl_area_names    | sed 's|^|   Areas/|'
  echo
  info "would write: CLAUDE.md USER.md SOURCES.md PRIORITIES.md MEMORY.md"
  info "routines:"
  tmpl_routine_names | while read -r _r; do
    [ -n "$_r" ] && printf '   %-28s %s\n' "$_r" "$(wire_cron_of "$(tmpl_alias_attr routines "$_r" Frequency)")"
  done
  exit 0
fi

# --------------------------------------------------------------- 3/11  safety

rule "3/11  Target safety"

case "$VAULT" in
  "$HOME") die "refusing to build into \$HOME directly -- use a subdirectory" ;;
esac
if [ -e "$VAULT" ] && [ -n "$(ls -A "$VAULT" 2>/dev/null)" ]; then
  [ "$FORCE" = "1" ] || die "$VAULT exists and is not empty.
       Re-run with --force to build into it anyway (existing files are backed up
       first), or point --out at an empty directory."
  BACKUP="$VAULT/.system/build-backup-$(date '+%Y%m%dT%H%M%S')"
  mkdir -p "$BACKUP"
  for _d in CLAUDE.md USER.md SOURCES.md PRIORITIES.md MEMORY.md Skills Routines; do
    [ -e "$VAULT/$_d" ] && cp -R "$VAULT/$_d" "$BACKUP/" 2>/dev/null || true
  done
  warn "existing content backed up to $BACKUP"
else
  info "target is empty"
fi
mkdir -p "$VAULT"
# Now that it exists, resolve it the same way every consumer does -- symlinks and
# `..` included -- so the path baked into the deny glob is the canonical one.
VAULT="$(cd "$VAULT" && pwd)"

jobs_init "$WORK/status"
llm_init "$WORK"

# -------------------------------------------------------------- 4/11  payload

rule "4/11  Install payload"
wire_dirs
wire_payload
wire_render_gate

# ------------------------------------------------------------- 5/11  hydrate

rule "5/11  Hydrate root documents"
hydrate_configs

# --------------------------------------------------------------- 6/11  seeds

rule "6/11  Seed starter notes"
wire_seed_notes

# ----------------------------------------------------------- 7/11  machinery

rule "7/11  Machinery"
wire_settings
wire_obsidian
wire_templates
wire_env
wire_log
wire_tags_md
wire_sync_exclusions

# ---------------------------------------------------------- 8/11  connectors

rule "8/11  Connectors"
wire_connectors
GRANOLA_WANTED=0
[ -n "$(tmpl_records connectors__meetings | cut -d'|' -f1 | grep -v '^none$' || true)" ] && GRANOLA_WANTED=1

if [ "$PLATFORM" = "macos" ]; then
  if [ "$GRANOLA_READY" = "1" ] && [ "$INSTALL_AGENTS" = "1" ]; then
    "$VAULT/.system/connectors/granola-export/install.sh" \
      --label "$LABEL_PREFIX.granola-export" && ok "granola-export LaunchAgent installed (RunAtLoad fires it now)"
  elif [ "$GRANOLA_READY" = "1" ]; then
    info "not installing the LaunchAgent (pass --install-agents). To do it yourself:"
    info "  $VAULT/.system/connectors/granola-export/install.sh --label $LABEL_PREFIX.granola-export"
  fi
elif [ "$GRANOLA_WANTED" = "1" ]; then
  info "windows: run.ps1 is the peer of run.sh; the scheduled task is written in phase 10"
fi

# ------------------------------------------------------------- 9/11  manifest

rule "9/11  Manifest and first tagging pass"

CLI="python3 $VAULT/.system/wiki/cli.py"
if [ "$DO_TAGGING" = "0" ]; then
  warn "--skip-tagging: manifest not built. Later, from $VAULT:"
  info "  python3 .system/wiki/cli.py init && python3 .system/wiki/cli.py rebuild"
else
  # init BEFORE doctor: `doctor` FAILs on a missing manifest, and `init` is what
  # creates it. Running doctor first on a fresh vault fails for the one reason
  # that is guaranteed to be true.
  step "init";    (cd "$VAULT" && $CLI init)
  step "doctor"
  if ! (cd "$VAULT" && $CLI doctor); then
    die "cli.py doctor failed (above). Fix what it reported and re-run -- the vault
       itself is already built, so a re-run only redoes this phase."
  fi
  # rebuild before the first run, always: skip it and every file looks brand new,
  # so the tagger re-tags the whole vault.
  step "rebuild"; (cd "$VAULT" && $CLI rebuild)
  step "status";  (cd "$VAULT" && $CLI status)
  step "run --dry-run"; (cd "$VAULT" && $CLI run --dry-run)

  if [ "$TAG_ALL" = "1" ]; then
    rule "9b/11  Tagging EVERYTHING -- review gate skipped"
    warn "--tag-all: tagging the whole vault in one pass, with no review."
    info "  The tagger prefers existing high-count tags, so the first tags it writes"
    info "  shape every tag that follows. Nobody is looking at them. If the early"
    info "  tags are wrong they will propagate, and \`tag-lint\` has to clean up after."
    info "  Recoverable if the vault is under git: git checkout -- . and re-run."
    (cd "$VAULT" && $CLI run --max-tag -1) || warn "the tagging pass reported an error"
  else
    rule "9b/11  Tagging a sample of $TAG_SAMPLE -- REVIEW GATE"
    (cd "$VAULT" && $CLI run --max-tag "$TAG_SAMPLE") || warn "the sample tagging pass reported an error"
  fi

  _log="$VAULT/.system/log/log-$(date_fmt "$TODAY" '+%Y-%m').csv"
  _tagged="$(grep '|tag|' "$_log" 2>/dev/null | wc -l | tr -d ' ')"
  # Two independent proofs: doctor can PASS on a `claude` that subprocess cannot
  # actually launch, so the log alone is not enough -- check the disk too.
  _ondisk="$(grep -rl '^tagged_hash:' "$VAULT/Projects" "$VAULT/Areas" 2>/dev/null | wc -l | tr -d ' ')"

  if [ "$_tagged" -gt 0 ] && [ "$_ondisk" -gt 0 ]; then
    ok "tagger works: $_tagged log row(s), $_ondisk note(s) carry tagged_hash on disk"
    echo
    grep '|tag|' "$_log" | tail -"$TAG_SAMPLE" | cut -d'|' -f3,4 | sed 's/^/     /'
    echo
    if [ "$TAG_ALL" = "1" ]; then
      _pending="$( (cd "$VAULT" && $CLI status) 2>/dev/null | awk '/^  pending/ { print $2 }')"
      warn "The whole vault was tagged with no review (--tag-all)."
      info "  Read the tags above and run \`cli.py vocab\` to see the vocabulary that"
      info "  now exists. If it drifted, \`tag-lint\` will propose merges."
      [ "${_pending:-0}" != "0" ] && info "  $_pending file(s) still pending -- deferred by the per-run ceiling, not dropped."
    else
      warn "STOP AND REVIEW THE TAGS ABOVE before tagging the rest."
      info "  The tagger prefers existing high-count tags, so these first tags shape"
      info "  every tag that follows. $TAG_SAMPLE reviewed now is worth an afternoon of merges."
      info "  Happy? Then:  cd $VAULT && python3 .system/wiki/cli.py run --max-tag -1"
      info "  Not happy?    edit .system/wiki/tagger.py's prompt and retry the sample."
    fi
  else
    warn "no tags were written ($_tagged log rows, $_ondisk notes with tagged_hash)"
    info "  The manifest exists, but tagging did not produce a result. Check that"
    info "  \`claude\` is logged in: claude -p 'hello'"
  fi
fi

# ------------------------------------------------------------- 10/11  routines

rule "10/11  Routines"

if [ "$DO_ROUTINES" = "0" ]; then
  info "--no-routines: routine docs left as bundled"
else
  wire_routines
  CONFIRMED="$WORK/routines-confirmed.txt"; : > "$CONFIRMED"
  echo
  # These write to the vault on a schedule with no human in the loop, so each is
  # confirmed individually. Blanket approval is not appropriate.
  while IFS='|' read -r _r _cron _freq; do
    [ -n "$_r" ] || continue
    printf '   %s\n' "$_r"
    printf '     when:   %s  (cron %s)\n' "$(_wire_cron_human "$_cron")" "$_cron"
    printf '     writes: unattended, into this vault\n'
    if [ "$ASSUME_YES" = "1" ]; then
      printf '%s|%s\n' "$_r" "$_cron" >> "$CONFIRMED"; printf '     -> confirmed (--yes)\n\n'
    elif [ ! -t 0 ]; then
      printf '     -> skipped: stdin is not a terminal. Re-run with --yes to confirm all.\n\n'
    else
      printf '     register this routine? [y/N] '
      read -r _reply </dev/tty || _reply=n
      case "$_reply" in
        [Yy]*) printf '%s|%s\n' "$_r" "$_cron" >> "$CONFIRMED"; printf '     -> confirmed\n\n' ;;
        *) printf '     -> skipped\n\n' ;;
      esac
    fi
  done < "$ROUTINE_PLAN"
  cp "$CONFIRMED" "$VAULT/.system/routines-confirmed.txt" 2>/dev/null || true
  ok "$(wc -l < "$CONFIRMED" | tr -d ' ') routine(s) confirmed for registration"
  wire_routine_register "$CONFIRMED"
fi

case "$PLATFORM" in
  macos)
    if [ "$INSTALL_AGENTS" = "1" ]; then
      step "installing the ingestion LaunchAgent"
      "$VAULT/.system/wiki/launchagent/install.sh" --label "$LABEL_PREFIX.wiki-ingest" \
        && ok "ingestion LaunchAgent installed (every 15 min)"
      info "status/uninstall need the label:  WIKI_LABEL=$LABEL_PREFIX.wiki-ingest .system/wiki/launchagent/status.sh"
    else
      info "ingestion LaunchAgent not installed (pass --install-agents). To do it yourself:"
      info "  $VAULT/.system/wiki/launchagent/install.sh --label $LABEL_PREFIX.wiki-ingest"
    fi
    ;;
  windows)
    # launchctl does not exist here, so the build emits the Task Scheduler
    # equivalent rather than failing in the middle of an installer.
    wire_windows_agents
    info "run it to register both jobs:"
    info "  powershell -NoProfile -ExecutionPolicy Bypass -File .system\\install-agents.ps1"
    ;;
  *)
    warn "no scheduler integration for '$PLATFORM'."
    info "  Run the ingestion pass yourself, or wire it to cron:"
    info "  cd '$VAULT' && python3 .system/wiki/cli.py run"
    ;;
esac

# --------------------------------------------------------------- 11/11  verify

rule "11/11  Verify"

if [ "$VERIFY" = "1" ]; then
  "$HERE/build-verify.sh" "$VAULT" || die "the built vault failed verification (above)"
else
  info "--no-verify: skipped"
fi

llm_summary

rule "Ready"
echo
info "vault:     $VAULT"
info "open it:   open -a Obsidian '$VAULT'   (then it is reachable as vault=$VAULT_NAME)"
echo
info "Remaining, in order:"
_n=1
if [ "$DO_TAGGING" = "1" ] && [ "$TAG_ALL" = "0" ]; then
  info "  $_n. Review the sample tags above, then: cd '$VAULT' && python3 .system/wiki/cli.py run --max-tag -1"
  _n=$(( _n + 1 ))
elif [ "$DO_TAGGING" = "1" ]; then
  info "  $_n. Tags were written without review. Check the vocabulary:"
  info "     cd '$VAULT' && python3 .system/wiki/cli.py vocab"
  _n=$(( _n + 1 ))
fi
if [ -s "${CONFIRMED:-/dev/null}" ]; then
  # Named here, but the real prompt comes after this list as its own block --
  # it is the one step that needs the user to switch applications, and burying
  # it as item N of a numbered list is how it gets missed.
  info "  $_n. Register the routines in Claude Desktop — see ACTION REQUIRED below."
  _n=$(( _n + 1 ))
fi
if [ "$GRANOLA_READY" = "0" ] && [ -n "$(tmpl_records connectors__meetings | cut -d'|' -f1 | grep -v '^none$' || true)" ]; then
  info "  $_n. Paste the Granola API key into .system/.env, then run"
  info "     .system/connectors/granola-export/install.sh"
  _n=$(( _n + 1 ))
fi
info "  $_n. Symlink Skills/ into .claude/skills/ if this vault is used from Claude Code."
echo

# The registration prompt gets its own block, and lands on the clipboard. It is
# the only remaining step a script cannot do, and it points at a file inside
# `.system/` -- dot-prefixed, so invisible in Obsidian and hidden in Finder. A
# path the user cannot browse to needs to arrive already copied.
if [ -s "${CONFIRMED:-/dev/null}" ]; then
  "$HERE/register-routines.sh" "$VAULT" || true
fi
