#!/usr/bin/env bash
# Surface the routine-registration prompt and put it on the clipboard.
#
#   ./register-routines.sh <vault>              # instructions + copy to clipboard
#   ./register-routines.sh <vault> --print      # dump the prompt to stdout
#   ./register-routines.sh <vault> --no-copy    # instructions only
#
# Separate from build-vault.sh on purpose: registration usually happens later than
# the build, often on a different day, and the prompt lives in `.system/` -- which
# is dot-prefixed and therefore invisible in Obsidian AND hidden in Finder and
# macOS file pickers. Without this script the user has to already know the path to
# a file they cannot see.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$(cd "$HERE/../lib" && pwd)/common.sh"

VAULT="${1:-}"; shift 2>/dev/null || true
DO_COPY=1; DO_PRINT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --print)   DO_PRINT=1; shift ;;
    --no-copy) DO_COPY=0; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$VAULT" ] || die "usage: register-routines.sh <vault> [--print] [--no-copy]"
[ -d "$VAULT" ] || die "not a directory: $VAULT"
VAULT="$(cd "$VAULT" && pwd)"
PROMPT="$VAULT/.system/routines-register.md"

if [ ! -s "$PROMPT" ]; then
  die "no registration prompt at $PROMPT

       Either no routines were confirmed when this vault was built, or it was
       built with --no-routines. Re-run build-vault.sh against the same template
       to regenerate it; the build is safe to re-run."
fi

if [ "$DO_PRINT" = "1" ]; then
  cat "$PROMPT"
  exit 0
fi

# Clipboard, best effort across platforms. Never fatal -- the path is always shown.
COPIED=0
if [ "$DO_COPY" = "1" ]; then
  if command -v pbcopy >/dev/null 2>&1;   then pbcopy   < "$PROMPT" && COPIED=1
  elif command -v wl-copy >/dev/null 2>&1; then wl-copy  < "$PROMPT" && COPIED=1
  elif command -v xclip >/dev/null 2>&1;   then xclip -selection clipboard < "$PROMPT" && COPIED=1
  elif command -v clip.exe >/dev/null 2>&1; then clip.exe < "$PROMPT" && COPIED=1
  fi
fi

_n="$(grep -c '^## Task `' "$PROMPT" 2>/dev/null || echo 0)"

rule "ACTION REQUIRED — register $_n routine(s)"
echo >&2
info "These are the last piece that cannot be automated. Everything else in this"
info "vault is already installed and running."
echo >&2
if [ "$COPIED" = "1" ]; then
  ok "The prompt is on your clipboard."
else
  warn "Could not reach a clipboard tool. Copy the file by hand:"
  info "  $PROMPT"
fi
echo >&2
info "Then:"
info "  1. Open Claude Desktop (agent mode) — NOT the Claude Code CLI."
info "  2. Paste. It will create one scheduled task per routine."
info "  3. Confirm the task IDs and times it reports back."
echo >&2
info "Why Desktop and not the CLI: the tool that creates a task running LOCALLY"
info "against this vault (create_scheduled_task) ships only with Desktop agent"
info "mode. The CLI's RemoteTrigger makes a CLOUD routine that runs in a remote"
info "sandbox — it would register without error and then fail every run, because"
info "it cannot see this vault on disk."
echo >&2
info "Routines to be registered:"
grep -E '^## Task `|^- Cron:' "$PROMPT" \
  | sed -e 's/^## Task `\(.*\)`/     \1/' \
        -e 's/^- Cron: `\([^`]*\)`  (\(.*\), local time)/         \2  —  \1/' >&2
echo >&2
info "Re-run this any time:  $HERE/register-routines.sh '$VAULT'"
info "Or read it directly:   open '$PROMPT'"
echo >&2
