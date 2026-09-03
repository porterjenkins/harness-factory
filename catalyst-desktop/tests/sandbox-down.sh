#!/usr/bin/env bash
# Tear down a sandbox vault.
#
#   ./sandbox-down.sh --vault ~/.catalyst-sandboxes/maya-work
#   ./sandbox-down.sh --all --yes
#   ./sandbox-down.sh --list
#
# Will only delete a directory containing `.sandbox-manifest.json`. That marker is
# the entire safety mechanism: this script does `rm -rf` on a path that in normal
# use sits one typo away from someone's real Obsidian vault, and there is no
# undo. No flag overrides the check.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TESTS_DIR/../lib" && pwd)"
. "$LIB_DIR/common.sh"

ROOT="${CATALYST_SANDBOX_HOME:-$HOME/catalyst-sandboxes}"
VAULT=""; ALL=0; YES=0; LIST=0; CACHE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --vault) VAULT="$2"; shift 2 ;;
    --root)  ROOT="$2"; shift 2 ;;
    --all)   ALL=1; shift ;;
    --list)  LIST=1; shift ;;
    --cache) CACHE=1; shift ;;
    -y|--yes) YES=1; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) VAULT="$1"; shift ;;
  esac
done

find_sandboxes() {
  [ -d "$ROOT" ] || return 0
  find "$ROOT" -maxdepth 3 -name '.sandbox-manifest.json' 2>/dev/null \
    | while IFS= read -r _m; do dirname "$_m"; done | sort
}

if [ "$LIST" = "1" ]; then
  "$TESTS_DIR/sandbox-ls.sh" --root "$ROOT"
  exit 0
fi

if [ "$CACHE" = "1" ]; then
  _c="${LLM_CACHE_DIR:-$HOME/.cache/catalyst-sandbox}"
  if [ -d "$_c" ]; then
    _n="$(find "$_c" -type f | wc -l | tr -d ' ')"
    rm -rf "$_c"
    ok "cleared generation cache ($_n entries) at $_c"
  else
    info "no generation cache at $_c"
  fi
  [ -n "$VAULT" ] || [ "$ALL" = "1" ] || exit 0
fi

TARGETS=""
if [ "$ALL" = "1" ]; then
  TARGETS="$(find_sandboxes)"
  [ -n "$TARGETS" ] || { info "no sandboxes under $ROOT"; exit 0; }
elif [ -n "$VAULT" ]; then
  TARGETS="${VAULT%/}"
else
  die "pass --vault <path>, or --all. Use --list to see what exists."
fi

# Validate everything before deleting anything: a half-completed --all that
# aborted on the third of five is worse than one that refuses up front.
printf '%s\n' "$TARGETS" | while IFS= read -r _t; do
  [ -n "$_t" ] || continue
  [ -d "$_t" ] || die "not a directory: $_t"
  [ -f "$_t/.sandbox-manifest.json" ] \
    || die "$_t has no .sandbox-manifest.json -- refusing to delete a directory this script did not create"
done

rule "Tear down"
printf '%s\n' "$TARGETS" | while IFS= read -r _t; do
  [ -n "$_t" ] || continue
  info "$_t  ($(find "$_t" -name '*.md' | wc -l | tr -d ' ') md files, $(du -sh "$_t" 2>/dev/null | awk '{print $1}'))"
done

if [ "$YES" != "1" ]; then
  printf '   delete the above? [y/N] ' >&2
  read -r _ans
  case "$_ans" in y|Y|yes|YES) ;; *) info "aborted"; exit 0 ;; esac
fi

printf '%s\n' "$TARGETS" | while IFS= read -r _t; do
  [ -n "$_t" ] || continue
  rm -rf "$_t"
  ok "removed $_t"
done

# Prune the root only if the harness owns it and nothing is left.
if [ -d "$ROOT" ] && [ -z "$(ls -A "$ROOT" 2>/dev/null)" ]; then
  rmdir "$ROOT" 2>/dev/null && info "removed empty $ROOT" || true
fi
