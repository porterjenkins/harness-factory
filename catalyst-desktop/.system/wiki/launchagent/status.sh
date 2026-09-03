#!/usr/bin/env bash
# Is the ingestion job installed, loaded, and actually running?
set -uo pipefail

LABEL="${WIKI_LABEL:-com.knowledgebase.wiki-ingest}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="$(cd "$HERE/../../.." && pwd)"

echo "label:  $LABEL"
if [[ -f "$PLIST" ]]; then
  echo "plist:  $PLIST"
  echo "every:  $(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$PLIST" 2>/dev/null || echo '?')s"
else
  echo "plist:  NOT INSTALLED -- run ./.system/wiki/launchagent/install.sh"
  exit 1
fi

echo
if launchctl print "gui/$(id -u)/$LABEL" >/tmp/.wiki-agent-state 2>/dev/null; then
  echo "loaded: yes"
  grep -E '^\s+(state|last exit code|runs|pid) ' /tmp/.wiki-agent-state | sed 's/^/  /'
else
  echo "loaded: NO -- the plist exists but is not bootstrapped."
  echo "        launchctl bootstrap gui/$(id -u) $PLIST"
  exit 1
fi
rm -f /tmp/.wiki-agent-state

echo
echo "recent stderr:"
if [[ -s "$VAULT/.system/log/run-logs/ingest.err.log" ]]; then
  tail -5 "$VAULT/.system/log/run-logs/ingest.err.log" | sed 's/^/  /'
else
  echo "  (empty -- good)"
fi

echo
echo "recent runs from the action log:"
grep '|run|' "$VAULT/.system/log/log-$(date +%Y-%m).csv" 2>/dev/null | tail -5 \
  | cut -d'|' -f1,4 | sed 's/^/  /' || echo "  (none yet)"

echo
echo "run once now:  launchctl kickstart -p gui/$(id -u)/$LABEL"
