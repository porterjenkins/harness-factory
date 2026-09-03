#!/usr/bin/env bash
# Install the Granola export LaunchAgent.
#
#   ./.system/connectors/granola-export/install.sh [--interval SECONDS] [--label LABEL] [--dry-run]
#
# Mirrors .system/wiki/launchagent/install.sh: the vault path is derived from this
# script's own location and substituted into the plist template at install time,
# so nothing in the repo carries an absolute path.
#
# Must run on the Mac that owns the vault, as the logged-in user. Not sudo: a
# LaunchAgent belongs to the user session.
set -euo pipefail

# Neutral reverse-DNS default; override with --label. Must not embed a project
# or company name -- the vault ships to other people.
LABEL="com.knowledgebase.granola-export"
INTERVAL=1800         # 30 minutes
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --label)    LABEL="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ "$(id -u)" == "0" ]]; then
  echo "error: do not run this with sudo. A LaunchAgent must be installed as the" >&2
  echo "       logged-in user." >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# .system/connectors/granola-export -> ../../.. = vault root
VAULT="$(cd "$HERE/../../.." && pwd)"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/$LABEL.plist"

# The key lives in the shared secrets file, not the connector's own .env (which
# now holds options only). Check for the key itself rather than the file: an
# existing .env missing the key is the more likely failure after the split.
SHARED_ENV="$(cd "$HERE/../../.." && pwd)/.system/.env"
if [[ ! -f "$SHARED_ENV" ]]; then
  echo "WARNING: $SHARED_ENV not found -- the job needs GRANOLA_API_KEY."
  echo "         cp .system/.env.example .system/.env  and add your grn_ key."
elif ! grep -qE '^[[:space:]]*(export[[:space:]]+)?GRANOLA_API_KEY=.+' "$SHARED_ENV"; then
  echo "WARNING: no GRANOLA_API_KEY in $SHARED_ENV -- the job will fail."
fi

mkdir -p "$VAULT/.system/log/run-logs" "$PLIST_DIR"

RENDERED="$(sed \
  -e "s|__LABEL__|$LABEL|g" \
  -e "s|__VAULT__|$VAULT|g" \
  -e "s|__INTERVAL__|$INTERVAL|g" \
  "$HERE/granola-export.plist.template")"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "--- would write $PLIST ---"
  echo "$RENDERED"
  exit 0
fi

echo "$RENDERED" > "$PLIST"
plutil -lint "$PLIST" >/dev/null

# bootout first so re-running this script is idempotent.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/$LABEL"

echo
echo "installed $LABEL"
echo "  plist:    $PLIST"
echo "  interval: ${INTERVAL}s"
echo "  logs:     $VAULT/.system/log/run-logs/granola-export.log"
