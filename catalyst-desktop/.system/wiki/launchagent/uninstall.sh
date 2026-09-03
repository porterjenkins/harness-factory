#!/usr/bin/env bash
# Remove the wiki ingestion LaunchAgent. Leaves the manifest and logs alone.
set -euo pipefail
LABEL="${WIKI_LABEL:-com.knowledgebase.wiki-ingest}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "booted out $LABEL" \
  || echo "$LABEL was not loaded"
if [[ -f "$PLIST" ]]; then
  rm "$PLIST"; echo "removed $PLIST"
fi
echo "manifest and logs left untouched in .system/"
