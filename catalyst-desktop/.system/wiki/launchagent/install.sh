#!/usr/bin/env bash
# Install the wiki ingestion LaunchAgent.
#
#   ./.system/wiki/launchagent/install.sh [--interval SECONDS] [--label LABEL] [--dry-run]
#
# Must run on the Mac that owns the vault, as the logged-in user. Not sudo:
# a LaunchAgent belongs to the user session, and installing it as root would put
# it outside the Aqua session where GUI access is impossible.
set -euo pipefail

# Neutral reverse-DNS default; override with --label.
LABEL="com.knowledgebase.wiki-ingest"
INTERVAL=900          # 15 minutes
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --label)    LABEL="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ "$(id -u)" == "0" ]]; then
  echo "error: do not run this with sudo. A LaunchAgent must be installed as the" >&2
  echo "       logged-in user, or it cannot reach the GUI session." >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="$(cd "$HERE/../../.." && pwd)"
VAULT_NAME="$(basename "$VAULT")"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/$LABEL.plist"

PYTHON="$(command -v python3 || true)"
if [[ -z "$PYTHON" ]]; then
  echo "error: python3 not found on PATH" >&2; exit 1
fi

# Resolve the tools the job needs NOW, while we have a normal shell, and bake the
# directories into the plist. launchd will not inherit this PATH.
EXTRA_PATHS=""
for bin in obsidian claude; do
  resolved="$(command -v "$bin" || true)"
  if [[ -n "$resolved" ]]; then
    EXTRA_PATHS="$EXTRA_PATHS:$(dirname "$resolved")"
    echo "found $bin at $resolved"
  else
    echo "WARNING: '$bin' not on your PATH."
    if [[ "$bin" == "claude" ]]; then
      echo "         Tagging will fail until it is installed."
    else
      echo "         processFrontMatter and retrieval will be unavailable;"
      echo "         the pipeline falls back to ruamel.yaml for writes."
    fi
  fi
done

JOB_PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin$EXTRA_PATHS"

mkdir -p "$VAULT/.system/log/run-logs" "$PLIST_DIR"

RENDERED="$(sed \
  -e "s|__LABEL__|$LABEL|g" \
  -e "s|__PYTHON__|$PYTHON|g" \
  -e "s|__VAULT__|$VAULT|g" \
  -e "s|__VAULT_NAME__|$VAULT_NAME|g" \
  -e "s|__HOME__|$HOME|g" \
  -e "s|__PATH__|$JOB_PATH|g" \
  -e "s|__INTERVAL__|$INTERVAL|g" \
  "$HERE/com.wiki-ingest.plist.template")"

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
echo "  logs:     $VAULT/.system/log/run-logs/"
echo
echo "Next:"
echo "  python3 $VAULT/.system/wiki/cli.py doctor      # verify the environment"
echo "  launchctl kickstart -p gui/$(id -u)/$LABEL   # run once now"
echo "  launchctl print gui/$(id -u)/$LABEL          # inspect state"
