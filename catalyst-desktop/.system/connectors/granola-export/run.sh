#!/bin/bash
# Wrapper: loads the GRANOLA_ vars from the shared .system/.env, then runs the
# exporter. Used by launchd and by hand.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Every variable this connector owns is namespaced GRANOLA_. The shared config
# file is loaded through this prefix filter, so a bug (or a bad npm dependency)
# in this exporter never sees another connector's credentials -- only its own.
ENV_PREFIX="GRANOLA_"

# Anchor on the vault root rather than counting "../.." hops from here: a
# miscount is silent, and the failure surfaces much later as a confusing
# "GRANOLA_API_KEY is not set". This mirrors export.mjs (VAULT from
# import.meta.url) and .system/wiki/config.py (VAULT from __file__).
VAULT="$(cd "$DIR/../../.." && pwd)"
SYSTEM="$VAULT/.system"

# One config file for every connector, partitioned by prefix rather than by
# file: secrets and options both come from $SYSTEM/.env, and only the
# GRANOLA_-prefixed lines are exported into this exporter's environment.
#
# The file does NOT clobber a variable that is already set, so a one-off
#   GRANOLA_TRANSCRIPT=1 ./run.sh
# wins over the file instead of being silently overridden by it. Under launchd
# the environment is minimal, so in the scheduled case the file always applies.
load_env() {
  local file="$1" prefix="$2" all keep line name
  [ -f "$file" ] || return 0
  all="$(mktemp)"
  keep="$(mktemp)"

  # This connector's namespace only -- the isolation boundary.
  grep -E "^[[:space:]]*(export[[:space:]]+)?${prefix}[A-Za-z0-9_]*=" "$file" > "$all" || true

  # Drop assignments whose variable is already set. `${!name+x}` is an
  # "is set" test, so an intentionally empty override (GRANOLA_TRANSCRIPT=)
  # still beats the file rather than falling back to it.
  while IFS= read -r line; do
    name="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z0-9_]+)=.*/\2/')"
    [ -n "$name" ] || continue
    if [ -z "${!name+x}" ]; then
      printf '%s\n' "$line" >> "$keep"
    fi
  done < "$all"

  # Sourcing the survivors (rather than assigning them here) keeps the original
  # shell semantics for quoting and escapes.
  set -a
  # shellcheck disable=SC1090
  . "$keep"
  set +a
  rm -f "$all" "$keep"
}

load_env "$SYSTEM/.env" "$ENV_PREFIX"

# Cap the log at the last N runs (default 1000). A "run" starts with the
# "Fetching note list" marker line. We keep the most recent (N-1) runs here so
# that once the current run appends, the file holds ~N runs. The rewrite is
# in-place (`cat tmp > log`, which truncates the SAME inode) so launchd's open
# append handle keeps writing this run's output to the end.
LOG="$DIR/export.log"
KEEP_RUNS="${GRANOLA_LOG_KEEP_RUNS:-1000}"
if [ -f "$LOG" ] && [ "$KEEP_RUNS" -gt 1 ]; then
  START=$(grep -n "Fetching note list from Granola" "$LOG" 2>/dev/null \
    | tail -n "$((KEEP_RUNS - 1))" | head -n 1 | cut -d: -f1 || true)
  if [ -n "$START" ] && [ "$START" -gt 1 ]; then
    tail -n "+$START" "$LOG" > "$LOG.tmp" && cat "$LOG.tmp" > "$LOG"
    rm -f "$LOG.tmp"
  fi
fi

# Resolve node even when launchd runs with a minimal PATH.
NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ]; then
  for c in /opt/homebrew/bin/node /usr/local/bin/node "$HOME/.nvm/current/bin/node"; do
    [ -x "$c" ] && NODE_BIN="$c" && break
  done
fi
if [ -z "$NODE_BIN" ]; then echo "node not found" >&2; exit 1; fi

exec "$NODE_BIN" "$DIR/export.mjs"
