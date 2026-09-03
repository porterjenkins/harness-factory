#!/usr/bin/env bash
# Assert a built vault is sound. Exits non-zero on any hard failure, so it drops
# into CI as-is and is safe to use as build-vault.sh's blocking gate.
#
#   ./build-verify.sh <vault>
#
# What this checks is deliberately narrow: the CONTRACTS. Generated prose varies
# and is none of this script's business; a four-column table that came back with
# three columns very much is.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"
. "$LIB_DIR/common.sh"

VAULT="${1:-}"
[ -n "$VAULT" ] || die "usage: build-verify.sh <vault>"
[ -d "$VAULT" ] || die "not a directory: $VAULT"
VAULT="$(cd "$VAULT" && pwd)"
NAME="$(basename "$VAULT")"

CHECKS=0; FAILS=0; WARNS=0
pass() { CHECKS=$(( CHECKS + 1 )); ok "$*"; }
bad()  { CHECKS=$(( CHECKS + 1 )); FAILS=$(( FAILS + 1 )); fail "$*"; }
soft() { WARNS=$(( WARNS + 1 )); warn "$*"; }

rule "Verify $NAME"

# ------------------------------------------------------------- 1. PARA layout

_missing=""
for _d in Projects Areas Resources/Meetings Resources/Agendas Archive Clippings \
          Skills Routines Templates .claude .obsidian .system/wiki \
          .system/connectors .system/log; do
  [ -d "$VAULT/$_d" ] || _missing="$_missing $_d"
done
[ -z "$_missing" ] && pass "PARA layout and machinery directories" \
                   || bad "missing directories:$_missing"

_year="$(date '+%Y')"
[ -d "$VAULT/Resources/Plans/$_year/Daily" ] && [ -d "$VAULT/Resources/Plans/$_year/Weekly" ] \
  && pass "Resources/Plans/$_year/{Daily,Weekly}" \
  || bad "Resources/Plans/$_year is missing Daily or Weekly"

# --------------------------------------------------------- 2. root documents

for _f in CLAUDE.md USER.md SOURCES.md PRIORITIES.md MEMORY.md; do
  if [ ! -s "$VAULT/$_f" ]; then
    bad "$_f missing or empty"
  elif [ "$(wc -c < "$VAULT/$_f" | tr -d ' ')" -lt 300 ]; then
    bad "$_f is suspiciously short ($(wc -c < "$VAULT/$_f" | tr -d ' ') bytes) -- generation probably truncated"
  else
    pass "$_f ($(wc -w < "$VAULT/$_f" | tr -d ' ') words)"
  fi
done

# CLAUDE.md is a contract, not decoration. Generated prose varies; the presence of
# each concept must not.
if [ -s "$VAULT/CLAUDE.md" ]; then
  _absent=""
  for _c in "Projects/" "Areas/" "Resources/" "Archive/" ".system" \
            "tagged_hash" "settings" "vault=" "log-" ; do
    grep -qF "$_c" "$VAULT/CLAUDE.md" || _absent="$_absent $_c"
  done
  [ -z "$_absent" ] && pass "CLAUDE.md states every required invariant" \
                    || bad "CLAUDE.md never mentions:$_absent"

  grep -qE '^\s*-\s*`' "$VAULT/CLAUDE.md" && pass "CLAUDE.md enumerates projects" \
    || bad "CLAUDE.md has no project enumeration -- the splice did not land"

  # Exactly one section per name. Two Projects sections that disagree is worse
  # than none: weekly-planning reads its H1 headers from here.
  _dupes=""
  for _h in Projects Areas; do
    _c="$(grep -cE "^#+ $_h *$" "$VAULT/CLAUDE.md" || true)"
    [ "${_c:-0}" -eq 1 ] || _dupes="$_dupes $_h(x$_c)"
  done
  [ -z "$_dupes" ] && pass "CLAUDE.md has exactly one Projects and one Areas section" \
                   || bad "CLAUDE.md has duplicate or missing sections:$_dupes"

  # CLAUDE.md is excluded from tagging (WIKI_EXCLUDED_FILES) and carries no
  # frontmatter; a stray `tagged:` here means something stamped it by mistake.
  head -1 "$VAULT/CLAUDE.md" | grep -q '^---$' \
    && bad "CLAUDE.md has YAML frontmatter -- it should have none" \
    || pass "CLAUDE.md carries no frontmatter"
fi

# ------------------------------------------------------- 3. SOURCES.md tables

if [ -s "$VAULT/SOURCES.md" ]; then
  # NF==5 is what separates the 3-column role registry from the 4-column
  # Who-reads-what table, whose header row would otherwise read as a role named
  # "skill". Splitting on `|` yields one empty field at each end.
  _roles="$(awk -F'|' 'NF == 5 { gsub(/ /,"",$2); if ($2 != "---" && $2 != "role") print $2 }' "$VAULT/SOURCES.md" | sort -u)"
  if [ -z "$_roles" ]; then
    bad "SOURCES.md has no parseable role registry table"
  else
    _known="vault meetings calendar chat email issues code second-vault memory web"
    _badrole=""
    for _r in $_roles; do
      case " $_known " in *" $_r "*) ;; *) _badrole="$_badrole $_r" ;; esac
    done
    [ -z "$_badrole" ] && pass "role registry parses ($(printf '%s' "$_roles" | wc -w | tr -d ' ') roles)" \
                       || bad "role registry names unknown role(s):$_badrole"
  fi

  # The four-column skill table, and the arrow that carries its instruction.
  _wr="$(grep -c '^| `[a-z-]*` | `[a-z-]*` |' "$VAULT/SOURCES.md" 2>/dev/null || true)"
  if [ "${_wr:-0}" -gt 0 ]; then
    _noarrow="$(grep '^| `[a-z-]*` | `[a-z-]*` |' "$VAULT/SOURCES.md" | grep -vc '→' 2>/dev/null || true)"
    [ "${_noarrow:-0}" -eq 0 ] \
      && pass "Who-reads-what table: $_wr row(s), every contributes cell has an arrow" \
      || bad "$_noarrow Who-reads-what row(s) have no → in contributes -- the cell is the whole instruction"

    # Every skill named in the table must actually be installed.
    _ghost=""
    grep -o '^| `[a-z-]*`' "$VAULT/SOURCES.md" | tr -d '|` ' | sort -u | while read -r _sk; do
      [ -n "$_sk" ] && [ ! -f "$VAULT/Skills/$_sk/SKILL.md" ] && printf '%s ' "$_sk"
    done > /tmp/.bv_ghost.$$ || true
    _ghost="$(cat /tmp/.bv_ghost.$$ 2>/dev/null || true)"; rm -f /tmp/.bv_ghost.$$
    [ -z "$_ghost" ] && pass "every skill in the table is installed" \
                     || bad "table names skills that are not installed: $_ghost"
  else
    bad "SOURCES.md has no Who-reads-what table"
  fi
fi

# ------------------------------------------------------------ 4. MEMORY.md

if [ -s "$VAULT/MEMORY.md" ]; then
  _order="$(grep '^## ' "$VAULT/MEMORY.md" | sed 's/^## //' | tr '\n' '|')"
  case "$_order" in
    *"Current context"*"Working preferences"*"Projects"*"Areas"*"Achievements"*"Changelog"*)
      pass "MEMORY.md sections are in the order the memory routine asserts" ;;
    *) bad "MEMORY.md section order is wrong: $_order" ;;
  esac
  grep -q '^updated:' "$VAULT/MEMORY.md" \
    && pass "MEMORY.md has the machine-parsed \`updated\` key" \
    || bad "MEMORY.md has no \`updated:\` frontmatter -- the memory routine reads its window from it"
fi

# ---------------------------------------------------- 5. frontmatter parses

# No `for f in $(find ...)` here: note titles contain spaces, so word-splitting
# turns "Acme Overview.md" into two nonexistent paths and every note reads as
# malformed. Same trap sandbox-verify.sh documents for xargs.
_bad_fm=""; _n_notes=0
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  _n_notes=$(( _n_notes + 1 ))
  head -1 "$_f" | grep -q '^---$' || { _bad_fm="$_bad_fm $(basename "$_f")"; continue; }
  awk 'NR>1 && /^---$/ { found=1; exit } END { exit !found }' "$_f" \
    || _bad_fm="$_bad_fm $(basename "$_f")"
done <<EOF
$(find "$VAULT/Projects" "$VAULT/Areas" -name '*.md' 2>/dev/null)
EOF
if [ "$_n_notes" -eq 0 ]; then
  bad "no seeded notes found -- the tagger had nothing to work with"
elif [ -z "$_bad_fm" ]; then
  pass "$_n_notes seeded note(s), all with well-formed frontmatter"
else
  bad "malformed frontmatter:$_bad_fm"
fi

# --------------------------------------------------------- 6. the manifest

_mf="$VAULT/.system/wiki/manifest.sqlite"
if [ ! -f "$_mf" ]; then
  soft "no manifest.sqlite (expected if built with --skip-tagging)"
elif command -v sqlite3 >/dev/null 2>&1; then
  _rows="$(sqlite3 "$_mf" 'SELECT COUNT(*) FROM notes;' 2>/dev/null || echo 0)"
  _sv="$(sqlite3 "$_mf" "SELECT value FROM meta WHERE key='schema_version';" 2>/dev/null || echo '')"
  [ "${_rows:-0}" -gt 0 ] && pass "manifest: $_rows note row(s), schema v${_sv:-?}" \
                          || bad "manifest exists but holds no note rows -- rebuild did not run"
else
  soft "sqlite3 not on PATH -- manifest contents unchecked"
fi

# ------------------------------------------------------ 7. tagging actually ran

_log="$(ls "$VAULT/.system/log/"log-*.csv 2>/dev/null | tail -1 || true)"
if [ -z "$_log" ]; then
  bad "no .system/log/log-*.csv"
else
  if awk -F'|' 'NF != 4 { bad = 1 } END { exit bad ? 1 : 0 }' "$_log"; then
    pass "action log is 4-field pipe-delimited ($(wc -l < "$_log" | tr -d ' ') lines)"
  else
    bad "$(basename "$_log") has lines that are not exactly 4 pipe-delimited fields"
  fi
fi

if [ -f "$_mf" ]; then
  _ondisk="$(grep -rl '^tagged_hash:' "$VAULT/Projects" "$VAULT/Areas" 2>/dev/null | wc -l | tr -d ' ')"
  # Checked on disk rather than from the log because `doctor` can PASS on a
  # `claude` that subprocess cannot actually launch.
  [ "${_ondisk:-0}" -gt 0 ] \
    && pass "$_ondisk note(s) carry tagged_hash on disk -- the tagger really wrote" \
    || soft "no note carries tagged_hash yet (sample pass may have been skipped)"
fi

# -------------------------------------------------------------- 8. settings

_st="$VAULT/.claude/settings.local.json"
if [ ! -f "$_st" ]; then
  bad ".claude/settings.local.json missing"
elif grep -q "$VAULT/Resources/Meetings" "$_st"; then
  pass "settings.local.json denies writes under this vault's Resources/Meetings/"
else
  bad "settings.local.json deny glob does not point at this vault -- the protection is inert"
fi

# --------------------------------------------------------------- 9. routines

_rn=0; _rbad=""
for _f in "$VAULT"/Routines/*.md; do
  [ -f "$_f" ] || continue
  _rn=$(( _rn + 1 ))
  _stem="$(basename "$_f" .md)"
  grep -q '^## Schedule' "$_f" || { _rbad="$_rbad $_stem(no-Schedule)"; continue; }
  # A routine doc that names a task ID other than its own filename stem sends
  # whoever debugs the schedule to the wrong task.
  if grep -q 'Task ID:' "$_f"; then
    _tid="$(grep 'Task ID:' "$_f" | head -1 | sed -E 's/.*`([^`]*)`.*/\1/')"
    [ "$_tid" = "$_stem" ] || _rbad="$_rbad $_stem(id=$_tid)"
  fi
  grep -qE 'Cron: `[-0-9*/, ]+`' "$_f" || _rbad="$_rbad $_stem(no-cron)"
done
if [ "$_rn" -eq 0 ]; then
  soft "no routine docs installed"
elif [ -z "$_rbad" ]; then
  pass "$_rn routine doc(s): Schedule, Task ID and cron all agree"
else
  bad "routine doc problems:$_rbad"
fi

# ------------------------------------------------------------ 10. no leakage

# A path from the machine that BUILT the vault must never appear inside it -- that
# is how a vault stops being portable.
_leaked=""
for _f in "$VAULT"/*.md; do
  [ -f "$_f" ] || continue
  grep -lE '/Users/[a-z]|/home/[a-z]' "$_f" >/dev/null 2>&1 && _leaked="$_leaked $(basename "$_f")"
done
[ -z "$_leaked" ] && pass "no host filesystem paths in the root documents" \
                  || bad "root documents reference a host home directory:$_leaked"

if [ -f "$VAULT/.system/.env" ]; then
  _mode="$(stat -f '%Lp' "$VAULT/.system/.env" 2>/dev/null || stat -c '%a' "$VAULT/.system/.env" 2>/dev/null || echo '')"
  [ "$_mode" = "600" ] && pass ".system/.env is mode 600" \
                       || soft ".system/.env is mode ${_mode:-unknown}, expected 600"
fi

# ----------------------------------------------------------------- summary

rule "Result"
if [ "$FAILS" -eq 0 ]; then
  ok "PASS  $CHECKS check(s), $WARNS warning(s)"
  exit 0
else
  fail "FAIL  $FAILS of $CHECKS check(s) failed, $WARNS warning(s)"
  exit 1
fi
