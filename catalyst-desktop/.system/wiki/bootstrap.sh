#!/usr/bin/env bash
# First-run bootstrap: verify, seed, tag the vault, then automate.
#
#   ./.system/wiki/bootstrap.sh              # staged, pauses for review
#   ./.system/wiki/bootstrap.sh --yes        # no prompts
#   ./.system/wiki/bootstrap.sh --sample 20  # size of the review batch
#
# Run on the Mac that owns the vault, with Obsidian running and `claude` logged in.
set -euo pipefail

SAMPLE=10
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)  ASSUME_YES=1; shift ;;
    --sample)  SAMPLE="$2"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="$(cd "$HERE/../.." && pwd)"
CLI="python3 $HERE/cli.py"
cd "$VAULT"

confirm() {
  [[ "$ASSUME_YES" == "1" ]] && return 0
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

rule() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

# ---------------------------------------------------------------- 1. verify
rule "1/5  Environment"
if ! $CLI doctor; then
  echo
  echo "doctor reported failures. Fix them before tagging -- a bad environment"
  echo "here means 98 files tagged wrong, or none at all."
  confirm "Continue anyway?" || exit 1
fi

# ------------------------------------------------------------------ 2. seed
rule "2/5  Seed the manifest"
echo "Reads existing 'tagged'/'tagged_hash' frontmatter so already-tagged notes"
echo "are not re-tagged. No LLM calls."
$CLI rebuild
$CLI status

# ---------------------------------------------------------------- 3. sample
rule "3/5  Tag a sample of $SAMPLE"
echo "Stopping after this so you can judge tag quality before committing the"
echo "whole vault. The tagger reuses existing high-count tags, so early tags"
echo "shape everything that follows -- bad ones propagate."
echo
$CLI run --max-tag "$SAMPLE"

echo
echo "Review what it did:"
echo "  grep '|tag|' .system/log/log-\$(date +%Y-%m).csv | tail -$SAMPLE | cut -d'|' -f3,4"
echo
grep '|tag|' ".system/log/log-$(date +%Y-%m).csv" 2>/dev/null | tail -"$SAMPLE" \
  | cut -d'|' -f3,4 || echo "  (nothing tagged -- check the log for failures)"
echo
echo "If these look wrong, stop now. Undo is:"
echo "  git checkout -- .   (if the vault is under git)"
echo "  and edit the prompt in .system/wiki/tagger.py before retrying."

# ------------------------------------------------------------------- 4. all
rule "4/5  Tag the rest of the vault"
REMAINING="$($CLI status | awk '/^  pending/ {print $2}')"
echo "${REMAINING:-0} file(s) still pending."
if confirm "Tag all remaining files now?"; then
  $CLI run --max-tag -1
  $CLI status
else
  echo "Skipped. The LaunchAgent will work through them at "
  echo "WIKI_MAX_TAG_PER_RUN files per run."
fi

# ----------------------------------------------------------------- 5. agent
rule "5/5  Automate"
if confirm "Install the LaunchAgent (runs every 15 minutes)?"; then
  "$HERE/launchagent/install.sh"
  echo
  "$HERE/launchagent/status.sh" || true
else
  echo "Skipped. Install later with:"
  echo "  ./.system/wiki/launchagent/install.sh"
fi

rule "Done"
echo "Ongoing:"
echo "  ./.system/wiki/launchagent/status.sh     # is the job healthy"
echo "  python3 .system/wiki/cli.py status       # manifest state"
echo "  python3 .system/wiki/cli.py tag-lint     # tag drift, run monthly"
