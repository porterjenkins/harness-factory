#!/usr/bin/env bash
# List the sandbox vaults on this machine, newest first.
#
#   ./sandbox-ls.sh
#   ./sandbox-ls.sh --root /somewhere/else
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TESTS_DIR/../lib" && pwd)"
. "$LIB_DIR/common.sh"

ROOT="${CATALYST_SANDBOX_HOME:-$HOME/catalyst-sandboxes}"
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) shift ;;
  esac
done

_val() { sed -n "s/.*\"$2\": \"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$1" | head -1; }

if [ ! -d "$ROOT" ]; then
  info "no sandbox root at $ROOT"
  exit 0
fi

_found=0
printf '%-26s %-18s %-9s %-8s %6s  %s\n' VAULT PERSONA MODE SIZE FILES CREATED >&2
find "$ROOT" -maxdepth 3 -name '.sandbox-manifest.json' 2>/dev/null | sort | while IFS= read -r _m; do
  _d="$(dirname "$_m")"
  _found=1
  printf '%-26s %-18s %-9s %-8s %6s  %s\n' \
    "$(basename "$_d")" \
    "$(_val "$_m" name)" \
    "$(_val "$_m" mode)" \
    "$(_val "$_m" size)" \
    "$(find "$_d" -name '*.md' | wc -l | tr -d ' ')" \
    "$(_val "$_m" created_at)" >&2
done

[ "$(find "$ROOT" -maxdepth 3 -name '.sandbox-manifest.json' 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ] \
  || info "(none)"
