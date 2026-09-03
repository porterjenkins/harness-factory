#!/usr/bin/env bash
# Assert that a sandbox vault is actually usable as a test fixture.
#
#   ./sandbox-verify.sh                      # newest sandbox under the root
#   ./sandbox-verify.sh ~/vaults/maya-work   # a specific vault
#   ./sandbox-verify.sh --quiet <vault>      # only failures
#
# Checks the things a skill will break on, not the things a human would notice:
# frontmatter that does not parse, a `tagged_hash` that disagrees with the body
# (which makes the ingestion pipeline re-tag the whole vault on first run), plan
# filenames the planning skills cannot match, meeting notes missing the connector's
# frontmatter contract, and dangling wikilinks.
#
# Exit 0 = fixture is sound. Exit 1 = at least one hard failure.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TESTS_DIR/../lib" && pwd)"
. "$LIB_DIR/common.sh"

QUIET=0; VAULT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) VAULT="$1"; shift ;;
  esac
done

if [ -z "$VAULT" ]; then
  _root="${CATALYST_SANDBOX_HOME:-$HOME/catalyst-sandboxes}"
  VAULT="$(find "$_root" -maxdepth 2 -name '.sandbox-manifest.json' 2>/dev/null \
           | head -1 | xargs -I{} dirname {} 2>/dev/null || true)"
  [ -n "$VAULT" ] || die "no sandbox found under $_root -- pass a vault path"
fi
VAULT="${VAULT%/}"
[ -d "$VAULT" ] || die "not a directory: $VAULT"

FAILS=0; WARNS=0; CHECKS=0
pass() { CHECKS=$(( CHECKS + 1 )); [ "$QUIET" = "1" ] || ok "$*"; }
bad()  { CHECKS=$(( CHECKS + 1 )); FAILS=$(( FAILS + 1 )); fail "$*"; }
soft() { WARNS=$(( WARNS + 1 )); warn "$*"; }

# Body with any leading frontmatter block stripped -- byte-identical to what
# .system/wiki/hashing.py hashes.
note_body() {
  awk '
    NR==1 && $0 == "---" { st=1; next }
    st==1 && $0 == "---" { st=2; next }
    st==1 { next }
    { print }
  ' "$1"
}

# All markdown that is vault *content*: excludes machinery and the templates,
# whose `{{date}}` placeholders are not meant to parse as real notes.
content_notes() {
  find "$VAULT/Projects" "$VAULT/Areas" "$VAULT/Resources" "$VAULT/Archive" \
       "$VAULT/Clippings" -name '*.md' 2>/dev/null | sort
}

rule "Verify $(basename "$VAULT")"

# ------------------------------------------------------------------ 1. marker

if [ -f "$VAULT/.sandbox-manifest.json" ]; then
  pass "sandbox marker present"
  [ "$QUIET" = "1" ] || sed -n 's/.*"name": "\(.*\)".*/   persona: \1/p' \
    "$VAULT/.sandbox-manifest.json" | head -1 >&2
else
  bad "no .sandbox-manifest.json -- this may not be a generated sandbox"
fi

# ------------------------------------------------------------- 2. PARA layout

_year="$(sed -n 's/.*"anchor_date": "\([0-9]\{4\}\)-.*/\1/p' \
         "$VAULT/.sandbox-manifest.json" 2>/dev/null | head -1)"
_year="${_year:-$(date '+%Y')}"

_missing=""
for _d in Projects Areas Resources Resources/Meetings \
          "Resources/Plans/$_year/Daily" "Resources/Plans/$_year/Weekly" \
          Archive Clippings Skills Routines Templates \
          .system .system/log .claude .obsidian; do
  [ -d "$VAULT/$_d" ] || _missing="$_missing $_d"
done
if [ -z "$_missing" ]; then pass "PARA layout and machinery directories"
else bad "missing directories:$_missing"; fi

# ------------------------------------------------- 3. root instruction documents

_mode="$(sed -n 's/.*"mode": "\([^"]*\)".*/\1/p' "$VAULT/.sandbox-manifest.json" 2>/dev/null | head -1)"
# An offline stub is short by design; only a live generation that comes back this
# small was actually truncated.
if [ "$_mode" = "offline" ]; then _min_root=400; else _min_root=800; fi

for _f in CLAUDE.md USER.md; do
  if [ ! -s "$VAULT/$_f" ]; then
    bad "$_f missing or empty"
  elif [ "$(wc -c < "$VAULT/$_f" | tr -d ' ')" -lt "$_min_root" ]; then
    bad "$_f is suspiciously short ($(wc -c < "$VAULT/$_f" | tr -d ' ') bytes, floor $_min_root) -- generation probably truncated"
  else
    pass "$_f ($(wc -w < "$VAULT/$_f" | tr -d ' ') words)"
  fi
done

# CLAUDE.md is a contract, not decoration: these are the facts the skills rely on
# it stating. Generated prose varies; the presence of each concept must not.
if [ -s "$VAULT/CLAUDE.md" ]; then
  _absent=""
  for _needle in ai-read-only ai-read-frontmatter-only ai-read-write \
                 Projects Areas Resources Archive .system tagged_hash \
                 sources.md; do
    grep -qF "$_needle" "$VAULT/CLAUDE.md" || _absent="$_absent $_needle"
  done
  grep -qiE 'log-[Y0-9]{4}-[M0-9]{2}\.csv|log-YYYY-MM' "$VAULT/CLAUDE.md" \
    || _absent="$_absent log-YYYY-MM.csv"
  grep -qiE 'timestamp\|action\|path\|summary' "$VAULT/CLAUDE.md" \
    || _absent="$_absent log-field-order"
  grep -qiE 'vault=|vault-name|Obsidian CLI' "$VAULT/CLAUDE.md" \
    || _absent="$_absent obsidian-cli-search-rule"

  if [ -z "$_absent" ]; then pass "CLAUDE.md states every required invariant"
  else bad "CLAUDE.md never mentions:$_absent"; fi

  # The vault name must be discoverable but never baked in as an absolute path.
  if grep -qF "$(basename "$VAULT")" "$VAULT/CLAUDE.md"; then
    pass "CLAUDE.md names the vault basename for vault=<vault-name>"
  else
    soft "CLAUDE.md never names the vault basename ($(basename "$VAULT")); doc-retrieval has nothing to substitute"
  fi
fi

# ------------------------------------------------------- 4. frontmatter parses

_bad_fm=""; _n_notes=0
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  _n_notes=$(( _n_notes + 1 ))
  if [ "$(head -1 "$_f")" != "---" ]; then
    _bad_fm="$_bad_fm
      ${_f#"$VAULT/"} (no opening ---)"
  elif [ "$(sed -n '2,60p' "$_f" | grep -c '^---$')" -lt 1 ]; then
    _bad_fm="$_bad_fm
      ${_f#"$VAULT/"} (frontmatter never closes)"
  fi
done <<EOF
$(content_notes)
EOF

if [ "$_n_notes" -eq 0 ]; then
  bad "no content notes found at all"
elif [ -z "$_bad_fm" ]; then
  pass "$_n_notes content notes, all with well-formed frontmatter"
else
  bad "malformed frontmatter:$_bad_fm"
fi

# ------------------------------- 5. tagged_hash agrees with the body (the big one)

_drift=""; _hashed=0; _untagged=0
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  _claimed="$(sed -n '1,40p' "$_f" | sed -n 's/^tagged_hash:[[:space:]]*//p' | head -1 \
              | tr -d '"'"'"' ')"
  if [ -z "$_claimed" ]; then _untagged=$(( _untagged + 1 )); continue; fi
  _actual="$(note_body "$_f" > "$VAULT/.verify.tmp" && body_hash_file "$VAULT/.verify.tmp")"
  _hashed=$(( _hashed + 1 ))
  [ "$_claimed" = "$_actual" ] || _drift="$_drift
      ${_f#"$VAULT/"} (frontmatter $_claimed, body $_actual)"
done <<EOF
$(content_notes)
EOF
rm -f "$VAULT/.verify.tmp"

if [ -z "$_drift" ]; then
  pass "tagged_hash matches recomputed body hash on all $_hashed tagged notes ($_untagged left pending ingestion)"
else
  bad "tagged_hash drift -- the pipeline would re-tag these on first run:$_drift"
fi

if [ "$_untagged" -eq 0 ]; then
  soft "every note is pre-tagged; nothing for the ingestion pipeline to pick up (--untagged-every 0 was set?)"
fi

# ------------------------------------------------------- 6. plans are parseable

_wk_dir="$VAULT/Resources/Plans/$_year/Weekly"
_wk_n="$(ls "$_wk_dir" 2>/dev/null | grep -c '\.md$' || true)"
if [ "${_wk_n:-0}" -eq 0 ]; then
  bad "no weekly plans in Resources/Plans/$_year/Weekly"
else
  _wk_bad=""
  for _f in "$_wk_dir"/*.md; do
    _b="$(basename "$_f")"
    # "Weekly Planning 8-23-2026 to 8-29-2026.md" -- the weekly-planning skill
    # matches on this shape, so a drifted name is a real failure.
    printf '%s' "$_b" \
      | grep -qE '^Weekly Planning [0-9]{1,2}-[0-9]{1,2}-[0-9]{4} to [0-9]{1,2}-[0-9]{1,2}-[0-9]{4}\.md$' \
      || _wk_bad="$_wk_bad
      $_b (filename)"
    grep -q '^# Weekly Goals' "$_f" || _wk_bad="$_wk_bad
      $_b (no '# Weekly Goals' section)"
    grep -qE '^- \[[ x]\]' "$_f" || _wk_bad="$_wk_bad
      $_b (no checkbox items)"
    grep -qE '\[P[123]\]' "$_f" || _wk_bad="$_wk_bad
      $_b (no [P1]/[P2]/[P3] priority markers -- daily-plan filters on these)"
  done
  if [ -z "$_wk_bad" ]; then pass "$_wk_n weekly plan(s): filename, sections and priority markers"
  else bad "weekly plan problems:$_wk_bad"; fi
fi

_dy_dir="$VAULT/Resources/Plans/$_year/Daily"
_dy_n="$(ls "$_dy_dir" 2>/dev/null | grep -c '\.md$' || true)"
if [ "${_dy_n:-0}" -eq 0 ]; then
  bad "no daily notes in Resources/Plans/$_year/Daily"
else
  _dy_bad=""
  for _f in "$_dy_dir"/*.md; do
    _b="$(basename "$_f")"
    printf '%s' "$_b" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.md$' \
      || _dy_bad="$_dy_bad
      $_b (filename must be YYYY-MM-DD.md)"
    for _sec in '# Admin' '# Goals' '# Notes'; do
      grep -qF "$_sec" "$_f" || _dy_bad="$_dy_bad
      $_b (missing '$_sec')"
    done
  done
  if [ -z "$_dy_bad" ]; then pass "$_dy_n daily note(s): filename and Admin/Goals/Notes sections"
  else bad "daily note problems:$_dy_bad"; fi
fi

# ------------------------------------------------------- 7. meeting note shape

_mt_n="$(ls "$VAULT/Resources/Meetings" 2>/dev/null | grep -c '\.md$' || true)"
if [ "${_mt_n:-0}" -eq 0 ]; then
  bad "no meeting notes in Resources/Meetings"
else
  _mt_bad=""
  for _f in "$VAULT"/Resources/Meetings/*.md; do
    _b="$(basename "$_f")"
    printf '%s' "$_b" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} ' \
      || _mt_bad="$_mt_bad
      $_b (filename must start YYYY-MM-DD )"
    for _k in title date attendees source; do
      grep -q "^$_k:" "$_f" || _mt_bad="$_mt_bad
      $_b (frontmatter missing '$_k')"
    done
  done
  if [ -z "$_mt_bad" ]; then pass "$_mt_n meeting note(s): connector frontmatter contract"
  else bad "meeting note problems:$_mt_bad"; fi
fi

# ----------------------------------------------------------- 8. machinery files

_log="$(ls "$VAULT/.system/log/"log-*.csv 2>/dev/null | head -1)"
if [ -n "$_log" ] && [ -s "$_log" ]; then
  if awk -F'|' 'NF != 4 { bad=1 } END { exit bad ? 1 : 0 }' "$_log"; then
    pass "action log is 4-field pipe-delimited ($(wc -l < "$_log" | tr -d ' ') lines)"
  else
    bad "$(basename "$_log") has lines that are not exactly 4 pipe-delimited fields"
  fi
else
  bad "no .system/log/log-*.csv"
fi

if grep -q '^| role | source | notes |' "$VAULT/.system/sources.md" 2>/dev/null; then
  pass "sources.md role table"
else
  bad ".system/sources.md missing or has no role table"
fi

if grep -q "Resources/Meetings" "$VAULT/.claude/settings.local.json" 2>/dev/null; then
  if grep -qF "$VAULT/Resources/Meetings" "$VAULT/.claude/settings.local.json"; then
    pass "settings.local.json denies writes under this vault's Meetings/"
  else
    bad "settings.local.json deny glob points at a different vault -- the protection is inert"
  fi
else
  bad "settings.local.json has no Resources/Meetings deny rule"
fi

# ------------------------------------------------------------- 9. wikilinks

# No `xargs grep` here: note titles contain spaces, so xargs would split them into
# nonexistent paths, and grep exits 1 on no match -- which under `set -o pipefail`
# aborted this script before it printed its summary.
_titles="$(content_notes | sed -e 's|.*/||' -e 's/\.md$//')"
_all_links="$VAULT/.verify-links.tmp"
: > "$_all_links"
_link_n=0
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  # `|| true` inside the pipe: grep -o exits 1 on a note with no links, and under
  # `set -o pipefail` that aborted verification mid-run.
  _link_n=$(( _link_n + $({ grep -o '\[\[' "$_f" 2>/dev/null || true; } | wc -l | tr -d ' ') ))
  sed -n 's/.*\[\[\([^]|]*\)\(|[^]]*\)\{0,1\}\]\].*/\1/p' "$_f" >> "$_all_links" 2>/dev/null || true
done <<EOF
$(content_notes)
EOF

_dangling=""
while IFS= read -r _t; do
  [ -n "$_t" ] || continue
  case "$_t" in CLAUDE.md|USER.md|Welcome) continue ;; esac
  printf '%s\n' "$_titles" | grep -qxF "$_t" || _dangling="$_dangling $_t"
done <<EOF
$(sed 's/#.*//' "$_all_links" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  | grep -v '^$' | sort -u)
EOF
rm -f "$_all_links"

if [ -z "$_dangling" ]; then
  pass "$_link_n wikilink(s), all resolving"
else
  soft "dangling wikilink target(s):$(printf '%s' "$_dangling" | cut -c1-200)"
fi

# ------------------------------------------------- 10. no host-path leakage

_leaked=""
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  grep -qF "$HOME" "$_f" 2>/dev/null && _leaked="$_leaked ${_f#"$VAULT/"}"
done <<EOF
$(content_notes)
EOF

if [ -z "$_leaked" ]; then
  pass "no host filesystem paths in generated notes"
else
  bad "generated notes reference the host home directory:$_leaked"
fi

# ------------------------------------------------------------------- summary

rule "Result"
if [ "$FAILS" -eq 0 ]; then
  ok "$CHECKS checks passed, $WARNS warning(s)"
  exit 0
else
  fail "$FAILS of $CHECKS checks failed, $WARNS warning(s)"
  exit 1
fi
