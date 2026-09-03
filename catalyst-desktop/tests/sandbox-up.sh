#!/usr/bin/env bash
# Spin up a simulated PARA knowledge vault for testing the Catalyst AI desktop
# service.
#
#   ./sandbox-up.sh                                  # default persona, medium size
#   ./sandbox-up.sh --persona minimal --size small   # fast smoke fixture
#   ./sandbox-up.sh --offline                        # no model calls at all
#   ./sandbox-up.sh --out ~/vaults/demo --force      # explicit location, overwrite
#
# Structure (PARA dirs, frontmatter keys, plan filenames, log format) is written
# by bash and is exact. Prose (CLAUDE.md, USER.md, every note body) is simulated
# with `claude -p`, so tests run against wording nobody on this repo chose.
#
# Skills/ and Routines/ are left empty on purpose -- the build script compiles
# those in.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# common.sh and llm.sh are shared with build/ and live one level up; the three
# libs below are sandbox-only and stay here.
LIB_DIR="$(cd "$TESTS_DIR/../lib" && pwd)"
. "$LIB_DIR/common.sh"
. "$LIB_DIR/llm.sh"
. "$TESTS_DIR/lib/persona.sh"
. "$TESTS_DIR/lib/scaffold.sh"
. "$TESTS_DIR/lib/docgen.sh"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

PERSONA_ARG="default"
SANDBOX_ROOT="${CATALYST_SANDBOX_HOME:-$HOME/catalyst-sandboxes}"
OUT=""; VAULT_NAME=""
SIZE="medium"
TODAY="$(date '+%Y-%m-%d')"
FORCE=0; VERIFY=1; DRY_RUN=0; KEEP_WORK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --persona)        PERSONA_ARG="$2"; shift 2 ;;
    --out)            OUT="$2"; shift 2 ;;
    --name)           VAULT_NAME="$2"; shift 2 ;;
    --root)           SANDBOX_ROOT="$2"; shift 2 ;;
    --size)           SIZE="$2"; shift 2 ;;
    --today)          TODAY="$2"; shift 2 ;;
    --model)          LLM_MODEL="$2"; shift 2 ;;
    --jobs)           JOBS="$2"; shift 2 ;;
    --untagged-every) UNTAGGED_EVERY="$2"; shift 2 ;;
    --offline)        LLM_OFFLINE=1; shift ;;
    --no-cache)       LLM_USE_CACHE=0; shift ;;
    --force)          FORCE=1; shift ;;
    --no-verify)      VERIFY=0; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --keep-work)      KEEP_WORK=1; shift ;;
    -h|--help)        usage 0 ;;
    *) printf 'unknown option: %s\n\n' "$1" >&2; usage 2 ;;
  esac
done

# How much corpus to generate. Cost is roughly linear in the total document count,
# so this is the dial that matters: small is a smoke fixture, large is for
# retrieval and ranking work where a thin corpus proves nothing.
case "$SIZE" in
  small)  DOCS_PER_PROJECT=1; DOCS_PER_AREA=1; RESOURCE_COUNT=2; MEETING_COUNT=4
          DAILY_COUNT=3;  WEEKLY_COUNT=1; ARCHIVE_COUNT=1; CLIPPING_COUNT=1 ;;
  medium) DOCS_PER_PROJECT=2; DOCS_PER_AREA=1; RESOURCE_COUNT=4; MEETING_COUNT=8
          DAILY_COUNT=5;  WEEKLY_COUNT=2; ARCHIVE_COUNT=2; CLIPPING_COUNT=2 ;;
  large)  DOCS_PER_PROJECT=4; DOCS_PER_AREA=2; RESOURCE_COUNT=8; MEETING_COUNT=16
          DAILY_COUNT=10; WEEKLY_COUNT=4; ARCHIVE_COUNT=4; CLIPPING_COUNT=3 ;;
  *) die "unknown --size: $SIZE (expected small, medium or large)" ;;
esac

need_cmd awk; need_cmd sed; need_cmd find
date_fmt "$TODAY" '+%Y-%m-%d' >/dev/null 2>&1 || die "--today must be YYYY-MM-DD, got: $TODAY"

persona_load "$(persona_resolve "$PERSONA_ARG")"
VAULT="${OUT:-$SANDBOX_ROOT/${VAULT_NAME:-$PERSONA_VAULT}}"
case "$VAULT" in /*) ;; *) VAULT="$(pwd)/$VAULT" ;; esac

# ------------------------------------------------------------------- plan out

rule "Catalyst sandbox vault"
info "persona    $PERSONA_NAME  ($(basename "$PERSONA_FILE"))"
info "vault      $VAULT"
info "anchor     $TODAY ($(date_fmt "$TODAY" '+%A'))"
info "size       $SIZE"

_planned=$(( ${#PERSONA_PROJECTS[@]} * DOCS_PER_PROJECT
             + ${#PERSONA_AREAS[@]} * DOCS_PER_AREA
             + RESOURCE_COUNT + MEETING_COUNT + DAILY_COUNT + WEEKLY_COUNT
             + ARCHIVE_COUNT + CLIPPING_COUNT + 3 ))
info "documents  ~$_planned markdown files"

if [ "$DRY_RUN" = "1" ]; then
  rule "Dry run -- nothing written"
  info "projects:  $(persona_project_paths | tr '\n' ' ')"
  info "groups:    $(persona_project_groups | tr '\n' ' ')"
  info "weeks:     $(_n=0; while [ $_n -lt $WEEKLY_COUNT ]; do
                       printf '%s ' "$(week_start "$(date_add "$TODAY" "-$(( _n * 7 ))")")"
                       _n=$(( _n + 1 )); done)"
  exit 0
fi

# --------------------------------------------------------------- target safety

if [ -e "$VAULT" ]; then
  # A missing marker means this directory was not created by this script. It could
  # be someone's real vault, and --force must never be enough to delete one.
  if [ ! -f "$VAULT/.sandbox-manifest.json" ]; then
    die "$VAULT exists and is not a sandbox (no .sandbox-manifest.json). Refusing to touch it. Use --out to pick another path."
  fi
  [ "$FORCE" = "1" ] || die "$VAULT already exists. Re-run with --force to replace it, or --out for a different path."
  warn "replacing existing sandbox at $VAULT"
  rm -rf "$VAULT"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/catalyst-sandbox.XXXXXX")"
cleanup() {
  if [ "$KEEP_WORK" = "1" ]; then
    info "scratch kept at $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

mkdir -p "$VAULT"
jobs_init "$WORK/status"
llm_init "$WORK"

# --------------------------------------------------------------------- build

rule "1/6  Skeleton"
scaffold_dirs
scaffold_templates
scaffold_obsidian
scaffold_settings
scaffold_sources_md

rule "2/6  Root instruction documents"
scaffold_root_docs           # CLAUDE.md + USER.md, in parallel
docgen_titles                # note titles, also parallel; drains both
scaffold_welcome
ok "CLAUDE.md and USER.md written"

rule "3/6  Projects, Areas, Resources, Archive, Meetings"
docgen_corpus

rule "4/6  Weekly plans"
docgen_weeklies

rule "5/6  Daily notes"
docgen_dailies

rule "6/6  Machinery"
scaffold_log
scaffold_manifest
_failed="$(jobs_failed)"
[ "$_failed" = "0" ] || warn "$_failed generation job(s) failed; affected notes fell back to stubs"
llm_summary
ok "$(find "$VAULT" -name '*.md' -not -path '*/.obsidian/*' | wc -l | tr -d ' ') markdown files"

# --------------------------------------------------------------------- verify

if [ "$VERIFY" = "1" ]; then
  "$TESTS_DIR/sandbox-verify.sh" "$VAULT" || die "sandbox failed verification (see above)"
fi

rule "Ready"
cat >&2 <<NEXT
   $VAULT

   Next:
     1. Compile skills and routines into it with the build script.
     2. Open it in Obsidian as a vault -- searches key off the folder basename
        ("$(basename "$VAULT")"), which is what the skills pass as vault=<vault-name>.
     3. Point the desktop service at it, or: cd "$VAULT" && claude

   Inspect:  ./sandbox-verify.sh "$VAULT"
   Remove:   ./sandbox-down.sh --vault "$VAULT"
NEXT
