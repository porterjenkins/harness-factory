# shellcheck shell=bash
# Shared helpers for the sandbox vault scripts.
#
# Targets bash 3.2 -- the shell that actually ships on macOS. No associative
# arrays, no `wait -n`, no `mapfile`, no `${var,,}`. Breaking that rule makes the
# scripts fail on a stock Mac while passing on the author's brew-installed bash,
# which is the worst possible place to find out.
#
# Source this, never execute it.

[ -n "${_CATALYST_COMMON_SH:-}" ] && return 0
_CATALYST_COMMON_SH=1

# ------------------------------------------------------------------- output

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  _C_BOLD=$'\033[1m'; _C_DIM=$'\033[2m'; _C_RED=$'\033[31m'
  _C_GRN=$'\033[32m'; _C_YEL=$'\033[33m'; _C_OFF=$'\033[0m'
else
  _C_BOLD=''; _C_DIM=''; _C_RED=''; _C_GRN=''; _C_YEL=''; _C_OFF=''
fi

rule() { printf '\n%s== %s ==%s\n' "$_C_BOLD" "$*" "$_C_OFF" >&2; }
info() { printf '   %s\n' "$*" >&2; }
step() { printf '   %s->%s %s\n' "$_C_DIM" "$_C_OFF" "$*" >&2; }
ok()   { printf '   %sok%s   %s\n' "$_C_GRN" "$_C_OFF" "$*" >&2; }
warn() { printf '   %swarn%s %s\n' "$_C_YEL" "$_C_OFF" "$*" >&2; }
fail() { printf '   %sfail%s %s\n' "$_C_RED" "$_C_OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$_C_RED" "$_C_OFF" "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# ------------------------------------------------------------------- strings

# Lowercase + dash-separated. `tr` rather than ${x,,}: see the bash 3.2 note.
slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//'
}

# Field n of a pipe-delimited persona record, with surrounding space trimmed.
field() {
  printf '%s' "$2" | awk -F'|' -v n="$1" '{gsub(/^[ \t]+|[ \t]+$/,"",$n); print $n}'
}

# JSON string escaping, for the hand-rolled manifest writer.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'
}

# ------------------------------------------------------------------- hashing

_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# The vault's ingestion pipeline stores `tagged_hash` as sha256 of the note body
# with frontmatter stripped, truncated to 16 hex chars (.system/wiki/hashing.py,
# HASH_LEN=16). Reproduced here so a freshly generated sandbox reads as already
# ingested and the tagger does not immediately re-tag every note. If the pipeline
# ever changes HASH_LEN or hashes something other than the body, this must follow
# -- sandbox-verify.sh recomputes it and will flag the drift.
body_hash_file() {
  _sha256 "$1" | cut -c1-16
}

# ------------------------------------------------------------------- notes

# stamp_note <out_path> <body_file> <type> <tags_csv> <tagged_date> [extra_fm_file]
#
# Frontmatter is written here rather than asked of the model: the keys are a
# contract with the ingestion pipeline, and a model that invents `tag:` for
# `tags:` once in twenty notes produces a sandbox that fails for reasons that
# have nothing to do with the code under test.
#
# Pass tagged_date as "" to leave a note untagged, i.e. pending ingestion.
stamp_note() {
  local _out="$1" _body="$2" _type="$3" _tags="$4" _tagged="$5" _extra="${6:-}"
  mkdir -p "$(dirname "$_out")"

  {
    printf -- '---\n'
    [ -n "$_extra" ] && [ -f "$_extra" ] && cat "$_extra"
    if [ -n "$_tags" ]; then
      printf 'tags:\n'
      printf '%s' "$_tags" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | grep -v '^$' | sed 's/^/  - /'
    fi
    if [ -n "$_tagged" ]; then
      printf 'tagged: %s\n' "$_tagged"
      printf 'tagged_hash: %s\n' "$(body_hash_file "$_body")"
    fi
    [ -n "$_type" ] && printf 'type: %s\n' "$_type"
    printf -- '---\n'
    cat "$_body"
  } > "$_out"
}

# ------------------------------------------------------------------- dates
#
# BSD date (macOS) and GNU date (Linux, CI) share no flags for this, so every
# date operation goes through these three functions.

date_add() {  # date_add <YYYY-MM-DD> <+/-days> -> YYYY-MM-DD
  local _d="$1" _off="$2"
  # An unsigned offset must be forced to "+N": BSD `date -v6d` sets the day of the
  # month to the 6th instead of adding six days, which silently produced week-end
  # dates in the past.
  case "$_off" in
    +*|-*) ;;
    *) _off="+$_off" ;;
  esac
  if date -j -f '%Y-%m-%d' "$_d" '+%Y-%m-%d' >/dev/null 2>&1; then
    date -j -v"${_off}d" -f '%Y-%m-%d' "$_d" '+%Y-%m-%d'
  else
    date -d "$_d $_off days" '+%Y-%m-%d'
  fi
}

date_fmt() {  # date_fmt <YYYY-MM-DD> <strftime> -> formatted
  if date -j -f '%Y-%m-%d' "$1" '+%Y-%m-%d' >/dev/null 2>&1; then
    date -j -f '%Y-%m-%d' "$1" "$2"
  else
    date -d "$1" "$2"
  fi
}

date_dow() {  # 0=Sunday .. 6=Saturday
  date_fmt "$1" '+%w'
}

# Sunday that starts the week containing <date>. The vault's weekly plans run
# Sunday-through-Saturday; the weekly-planning skill parses the filename, so this
# has to agree with it exactly.
week_start() {
  _d="$1"; _dow="$(date_dow "$_d")"
  [ "$_dow" -eq 0 ] && { printf '%s' "$_d"; return; }
  date_add "$_d" "-$_dow"
}

# "8-23-2026" -- unpadded month and day, as the existing plans are named.
date_plan_label() {
  printf '%s-%s-%s' \
    "$(date_fmt "$1" '+%m' | sed 's/^0//')" \
    "$(date_fmt "$1" '+%d' | sed 's/^0//')" \
    "$(date_fmt "$1" '+%Y')"
}

is_weekend() {
  _dow="$(date_dow "$1")"
  [ "$_dow" -eq 0 ] || [ "$_dow" -eq 6 ]
}

# ------------------------------------------------------------------- jobs
#
# Bounded-concurrency fan-out. `wait -n` would be the obvious tool and is bash
# 4.3+; this polls `jobs -pr` instead so it runs under 3.2.

JOBS="${JOBS:-4}"
_JOB_STATUS_DIR=""

jobs_init() {
  _JOB_STATUS_DIR="$1"
  mkdir -p "$_JOB_STATUS_DIR"
  rm -f "$_JOB_STATUS_DIR"/* 2>/dev/null || true
  # fd 3 is the real stderr. Job output goes to a per-job log, so a job that wants
  # to report progress writes to fd 3 via note() instead.
  exec 3>&2
}

# Progress from inside a backgrounded job.
note() { printf '   %s->%s %s\n' "$_C_DIM" "$_C_OFF" "$*" >&3 2>/dev/null || true; }

_job_slot() {
  while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$JOBS" ]; do
    sleep 0.2
  done
}

# job_run <label> <cmd...> -- runs in the background, records pass/fail.
#
# The slug is resolved once, up front. Resolving it after the job body has run
# reads a `_label` the body itself clobbered -- these functions do not all use
# locals, and the result was status files named after the wrong job.
job_run() {
  local __label="$1"; shift
  local __base; __base="$_JOB_STATUS_DIR/$(slug "$__label")"
  _job_slot
  (
    if "$@" >"$__base.log" 2>&1; then
      printf 'ok\n' > "$__base.status"
    else
      printf 'fail\n' > "$__base.status"
      printf '   %sfail%s %s -- see %s.log\n' "$_C_RED" "$_C_OFF" "$__label" "$__base" >&3
    fi
  ) &
}

jobs_drain() {
  wait
}

jobs_failed() {
  # `|| true`: grep exits 1 on no match, and under `set -o pipefail` that failed
  # the whole run at the final step, on the success path.
  { grep -l '^fail$' "$_JOB_STATUS_DIR"/*.status 2>/dev/null || true; } \
    | wc -l | tr -d ' '
}
