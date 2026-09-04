# shellcheck shell=bash
# Parse the implementation-interview template into records the build can act on.
#
# The template is a human-filled markdown document, so this parser is deliberately
# lenient about prose and strict about anything a skill later parses. A missing
# description is fine; a misspelled role name is fatal, because a role the registry
# does not know silently disables whichever skill depends on it and nothing
# downstream would notice.
#
# Sections are split to files at load time -- one per H1, plus one per H3 within an
# H1 -- so every accessor takes a single slug instead of a slug plus an optional
# subsection. `skills__user` is a scope in its own right, not a filter applied to
# `skills`.
#
# Source after common.sh.

[ -n "${_CATALYST_TEMPLATE_SH:-}" ] && return 0
_CATALYST_TEMPLATE_SH=1

# The one H1 whose slug is too long to spell out at every call site.
TMPL_USER="user-profile-and-preferences"

# Every H1 the build knows how to act on. A template missing one of the required
# names is rejected; the optional ones default to off when absent or empty.
TMPL_REQUIRED="User Profile and Preferences|Projects|Areas|Sources|Skills|Routines|Connectors|Priorities"
TMPL_OPTIONAL="Import|Tag Vocabulary|Sync|Platform|Operating System"

# Roles the SOURCES.md registry understands. A row naming anything else is a typo,
# and a typo'd role is indistinguishable from a disconnected one at run time.
TMPL_KNOWN_ROLES="vault meetings calendar chat email issues code second-vault memory web"

# Roles that are not connectors and so are never interviewed about: the vault is
# the vault, `web` is web search, `memory` is a file at the vault root. They are
# injected into the registry when the template omits them, which it usually does.
TMPL_INTRINSIC_ROLES="vault web memory"

TMPL_DIR=""

# --------------------------------------------------------------------- loading

# Strip HTML comments, including multi-line ones. The template leans on them for
# instructions to whoever fills it in, and none of that should reach a prompt.
_tmpl_decomment() {
  awk '
    { line = $0 }
    {
      while (1) {
        if (incomment) {
          i = index(line, "-->")
          if (i == 0) { line = ""; break }
          line = substr(line, i + 3); incomment = 0
          continue
        }
        i = index(line, "<!--")
        if (i == 0) break
        head = substr(line, 1, i - 1)
        rest = substr(line, i + 4)
        j = index(rest, "-->")
        if (j == 0) { line = head; incomment = 1; break }
        line = head substr(rest, j + 3)
      }
      print line
    }
  ' "$1"
}

# template_load <file> <workdir>
template_load() {
  _file="$1"; TMPL_DIR="$2/sections"
  [ -f "$_file" ] || die "template not found: $_file"
  mkdir -p "$TMPL_DIR"

  _tmpl_decomment "$_file" > "$TMPL_DIR/.clean.md"

  # One pass: H1 opens a section file, H3 opens a nested one that also keeps
  # receiving into its parent, so `tmpl_prose skills` still sees everything.
  # H2/H3 lines themselves are kept in the parent -- `_tmpl_normalize_heading_tree`
  # turns a `## Parent` / `### Child` tree into the bullet records tmpl_records
  # already knows how to read. Dropping them here is why a filled-in heading
  # tree used to look like an empty # Projects.
  awk -v dir="$TMPL_DIR" '
    function slug(s) {
      s = tolower(s)
      gsub(/[^a-z0-9]+/, "-", s)
      sub(/^-/, "", s); sub(/-$/, "", s)
      return s
    }
    # Touch the file at heading time. Creating it only when a line is written
    # makes a present-but-empty section indistinguishable from a missing one, and
    # an interview template arrives with most sections blank -- so validation
    # would reject the very document it is meant to accept.
    /^# /   { h1 = slug(substr($0, 3)); h3 = ""; printf "" >> (dir "/" h1 ".md"); next }
    /^### / {
      if (h1 != "") {
        h3 = h1 "__" slug(substr($0, 5))
        printf "" >> (dir "/" h3 ".md")
        print $0 >> (dir "/" h1 ".md")
      }
      next
    }
    /^## /  { h3 = ""; if (h1 != "") print $0 >> (dir "/" h1 ".md"); next }
    {
      if (h1 != "") print $0 >> (dir "/" h1 ".md")
      if (h3 != "") print $0 >> (dir "/" h3 ".md")
    }
  ' "$TMPL_DIR/.clean.md"

  # Bullet records are the canonical grammar. A heading tree is the shape a
  # human actually writes when filling the interview as a document, so rewrite
  # it into bullets before validation -- otherwise tmpl_records sees prose and
  # reports the section empty.
  _tmpl_normalize_heading_tree projects
  _tmpl_normalize_heading_tree areas
  _tmpl_normalize_skill_sources

  _tmpl_validate
}

# If <slug>.md has no top-level `- ` bullets but does have `## ` headings, rewrite
# the heading tree as `- Parent` / `  - Child` records. Following prose (first
# paragraph) becomes the description. Leaves a bullet-shaped file untouched, so
# TEMPLATE.md and the persona-generated templates keep their existing parse.
_tmpl_normalize_heading_tree() {
  _f="$TMPL_DIR/$1.md"
  [ -f "$_f" ] || return 0
  grep -q '^-[[:space:]]' "$_f" && return 0
  grep -q '^##[[:space:]]' "$_f" || return 0

  _norm="$TMPL_DIR/.$1.norm.md"
  awk '
    function trim(s) {
      gsub(/\r/, "", s)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      gsub(/`/, "", s)
      return s
    }
    function emit() {
      if (parent == "") return
      gsub(/\|/, "/", parent); gsub(/\|/, "/", pdesc)
      printf "- %s | | %s\n", parent, pdesc
      for (i = 1; i <= nchild; i++) {
        gsub(/\|/, "/", cname[i]); gsub(/\|/, "/", cdesc[i])
        printf "  - %s | | %s\n", cname[i], cdesc[i]
      }
      nchild = 0
    }
    BEGIN { parent = ""; pdesc = ""; nchild = 0; mode = "" }
    /^## / {
      emit()
      parent = trim(substr($0, 4))
      pdesc = ""; nchild = 0; mode = "pdesc"
      next
    }
    /^### / {
      if (parent == "") next
      nchild++
      cname[nchild] = trim(substr($0, 5))
      cdesc[nchild] = ""
      mode = "cdesc"
      next
    }
    {
      if (parent == "" ) { print; next }          # leading prose, keep as-is
      line = trim($0)
      if (line == "") {
        if (mode == "pdesc" && pdesc != "") mode = "skip"
        if (mode == "cdesc" && nchild > 0 && cdesc[nchild] != "") mode = "skip"
        next
      }
      if (mode == "pdesc") pdesc = (pdesc == "" ? line : pdesc " " line)
      else if (mode == "cdesc") cdesc[nchild] = (cdesc[nchild] == "" ? line : cdesc[nchild] " " line)
    }
    END { emit() }
  ' "$_f" > "$_norm"

  if grep -q '^-[[:space:]]' "$_norm"; then
    mv "$_norm" "$_f"
  else
    rm -f "$_norm"
  fi
}

# Pull canonical role names out of a free-text Sources value. Interview answers
# are "Calendar, Slack, meeting transcripts", not `calendar, chat, meetings`;
# without this, validation treats each comma-chunk as a role and rejects the
# template for names the registry will never know.
_tmpl_roles_from_text() {
  _rt_in="$1"
  _rt_file="$TMPL_DIR/.roles-from-text"
  : > "$_rt_file"
  printf '%s\n' "$_rt_in" | tr ',' '\n' | while IFS= read -r _tok; do
    _tok="$(printf '%s' "$_tok" | sed -e 's/(.*)//g' -e 's/`//g' \
      -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$_tok" ] || continue
    _tmpl_roles_consider "$_tok"
    printf '%s\n' "$_tok" | tr -cs '[:alnum:]-' '\n' | while IFS= read -r _w; do
      [ -n "$_w" ] && _tmpl_roles_consider "$_w"
    done
  done
  _acc=""; _first=1
  while IFS= read -r _r; do
    [ -n "$_r" ] || continue
    if [ "$_first" = 1 ]; then _acc="$_r"; _first=0; else _acc="$_acc, $_r"; fi
  done < "$_rt_file"
  rm -f "$_rt_file"
  printf '%s' "$_acc"
}

_tmpl_roles_consider() {
  _cr="$(_tmpl_role_alias "$1")"
  [ -n "$_cr" ] || return 0
  case " $TMPL_KNOWN_ROLES " in *" $_cr "*) ;; *) return 0 ;; esac
  grep -qx "$_cr" "$TMPL_DIR/.roles-from-text" 2>/dev/null && return 0
  printf '%s\n' "$_cr" >> "$TMPL_DIR/.roles-from-text"
}

# Rewrite indented `- Sources:` lines under # Skills to the canonical role list
# extracted from whatever the interviewer wrote.
_tmpl_normalize_skill_sources() {
  for _scope in skills__system skills__user; do
    _f="$TMPL_DIR/$_scope.md"
    [ -f "$_f" ] || continue
    _out="$TMPL_DIR/.$_scope.norm.md"
    : > "$_out"
    while IFS= read -r _line || [ -n "$_line" ]; do
      case "$_line" in
        *'- Sources:'*|*'- sources:'*)
          if printf '%s' "$_line" | grep -q '^[[:space:]]\{1,\}-[[:space:]]\{1,\}[Ss]ources:'; then
            _val="$(printf '%s' "$_line" | sed 's/^[[:space:]]*-[[:space:]]*[Ss]ources:[[:space:]]*//')"
            _indent="$(printf '%s' "$_line" | sed 's/-[[:space:]]*[Ss]ources:.*//')"
            printf '%s- Sources: %s\n' "$_indent" "$(_tmpl_roles_from_text "$_val")" >> "$_out"
            continue
          fi
          ;;
      esac
      printf '%s\n' "$_line" >> "$_out"
    done < "$_f"
    mv "$_out" "$_f"
  done
}

_tmpl_validate() {
  _missing=""
  _old="$IFS"; IFS='|'
  for _h in $TMPL_REQUIRED; do
    [ -f "$TMPL_DIR/$(slug "$_h").md" ] || _missing="$_missing
  - # $_h"
  done
  IFS="$_old"
  [ -z "$_missing" ] || die "template is missing required section(s):$_missing

       Every required H1 must be present. An empty section means \"none\" and is
       fine; a missing one means the template was not filled from TEMPLATE.md."

  # A vault with no projects has no content taxonomy: no weekly-plan headings, no
  # folders under Projects/, nothing for CLAUDE.md to enumerate.
  if [ -z "$(tmpl_records projects)" ]; then
    if tmpl_has projects; then
      die "# Projects has content but no parseable project records.

       Write at least one of:
         - Name | kind | description
         ## Name                  (### headings become subprojects)

       Nested bullets (or ### headings) become folders under Projects/<name>/.
       Prose alone is not a project list -- the build needs names to create
       those folders and the CLAUDE.md section headers every planning skill reads."
    else
      die "# Projects is empty. A vault needs at least one project -- it is the
       taxonomy every planning skill reads its section headers from."
    fi
  fi

  # Validate role names now, while we can still name the line that is wrong.
  _bad=""; rm -f "$TMPL_DIR/.badroles"
  tmpl_roles | while IFS='|' read -r _role _src _notes; do
    [ -n "$_role" ] || continue
    case " $TMPL_KNOWN_ROLES " in
      *" $_role "*) ;;
      *) printf '%s\n' "$_role" >> "$TMPL_DIR/.badroles" ;;
    esac
  done
  # A skill citing a role the registry never declares resolves to nothing at run
  # time, and the two SOURCES.md tables end up disagreeing about which roles
  # exist. Catch it here, naming the skill, rather than at the verify gate.
  rm -f "$TMPL_DIR/.undeclared"
  _declared="$(tmpl_roles | cut -d'|' -f1)"
  { tmpl_skill_names skills__system; tmpl_skill_names skills__user; } | while read -r _sk; do
    [ -n "$_sk" ] || continue
    # `|| true`: a skill with an empty `Sources:` -- every skill, for a persona
    # with nothing connected -- makes this grep match nothing and exit 1, which
    # under `set -o pipefail` kills the whole build with no message. Second time
    # this exact trap has fired; it is the one documented in tests/README.md.
    { { tmpl_alias_attr skills__user "$_sk" Sources
        tmpl_alias_attr skills__system "$_sk" Sources; } | tr ',' '\n' \
      | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/`//g' \
      | grep -v '^$' || true; } \
      | while read -r _role; do
          case " $TMPL_INTRINSIC_ROLES " in *" $_role "*) continue ;; esac
          printf '%s\n' "$_declared" | grep -qx "$_role" \
            || printf '%s names role "%s"\n' "$_sk" "$_role" >> "$TMPL_DIR/.undeclared"
        done
  done
  if [ -s "$TMPL_DIR/.undeclared" ]; then
    _u="$(sort -u "$TMPL_DIR/.undeclared" | sed 's/^/         /')"
    rm -f "$TMPL_DIR/.undeclared"
    die "a skill names a role that # Sources does not declare:

$_u

       Add a row for it under # Sources (set it to \`none\` if it is not
       connected), or remove it from that skill's Sources list."
  fi

  if [ -s "$TMPL_DIR/.badroles" ]; then
    _bad="$(tr '\n' ' ' < "$TMPL_DIR/.badroles")"
    rm -f "$TMPL_DIR/.badroles"
    die "# Sources names unknown role(s): $_bad
       Known roles: $TMPL_KNOWN_ROLES
       A role the registry does not know disables its skill silently."
  fi
}

_tmpl_file() {
  _f="$TMPL_DIR/$1.md"
  [ -f "$_f" ] && printf '%s' "$_f"
}

# ------------------------------------------------------------------ accessors

# tmpl_records <slug> -> `name|kind|description` per top-level `- ` bullet.
#
# Tolerates all three shapes the template invites: a bare `- Name`, a piped
# `- Name | kind | description`, and `- Name: value` (which the Sources and Import
# sections use). Attribute-shaped lines are excluded -- those belong to whichever
# record they are nested under, not to the section.
tmpl_records() {
  _f="$(_tmpl_file "$1")"; [ -n "$_f" ] || return 0
  awk -F'|' '
    /^-[[:space:]]/ {
      line = substr($0, 3)
      n = split(line, f, "|")
      # Strip backticks: `daily-plan` in the template is the skill daily-plan,
      # and a name kept as "`daily-plan`" matches no directory on disk.
      for (i = 1; i <= n; i++) { gsub(/`/, "", f[i]); gsub(/^[[:space:]]+|[[:space:]]+$/, "", f[i]) }
      if (f[1] == "") next
      printf "%s|%s|%s\n", f[1], (n > 1 ? f[2] : ""), (n > 2 ? f[3] : "")
    }
  ' "$_f"
}

# tmpl_children <slug> <parent> -> nested records under one parent, same shape.
# An indented `- Key: value` is an attribute of the parent, not a child, so it is
# skipped here and read by tmpl_attr instead.
tmpl_children() {
  _f="$(_tmpl_file "$1")"; [ -n "$_f" ] || return 0
  awk -v want="$2" '
    function trim(s) { gsub(/`/, "", s); gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^-[[:space:]]/ {
      line = substr($0, 3); split(line, f, "|")
      cur = trim(f[1]); sub(/:.*$/, "", cur); next
    }
    /^[[:space:]]+-[[:space:]]/ {
      if (cur != want) next
      line = trim($0); line = substr(line, 3)
      if (line ~ /^[A-Za-z][A-Za-z ]*:/) next          # attribute, not a child
      n = split(line, f, "|")
      for (i = 1; i <= n; i++) f[i] = trim(f[i])
      if (f[1] == "") next
      printf "%s|%s|%s\n", f[1], (n > 1 ? f[2] : ""), (n > 2 ? f[3] : "")
    }
  ' "$_f"
}

# tmpl_attr <slug> <parent> <Key> -> value of an indented `- Key: value`.
tmpl_attr() {
  _f="$(_tmpl_file "$1")"; [ -n "$_f" ] || return 0
  awk -v want="$2" -v key="$3" '
    function trim(s) { gsub(/`/, "", s); gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^-[[:space:]]/ { line = substr($0, 3); split(line, f, "|"); cur = trim(f[1]); sub(/:.*$/, "", cur); next }
    /^[[:space:]]+-[[:space:]]/ {
      if (cur != want) next
      line = trim($0); line = substr(line, 3)
      i = index(line, ":")
      if (i == 0) next
      if (tolower(trim(substr(line, 1, i - 1))) != tolower(key)) next
      print trim(substr(line, i + 1))
    }
  ' "$_f"
}

# tmpl_kv <slug> <Key> -> value of a top-level `- Key: value`.
tmpl_kv() {
  _f="$(_tmpl_file "$1")"; [ -n "$_f" ] || return 0
  awk -v key="$2" '
    function trim(s) { gsub(/`/, "", s); gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^-[[:space:]]/ {
      line = substr($0, 3)
      i = index(line, ":")
      if (i == 0) next
      if (tolower(trim(substr(line, 1, i - 1))) != tolower(key)) next
      v = trim(substr(line, i + 1))
      j = index(v, "|")                      # trailing `| notes` is not the value
      if (j > 0) v = trim(substr(v, 1, j - 1))
      print v; exit
    }
  ' "$_f"
}

# Human labels an interviewer actually writes, mapped to the registry's role
# names. Nobody filling in an intake form should have to know that the chat role
# is spelled `chat` and not `Messaging`, and a rejected template is a worse
# outcome than a lenient parser. Parenthetical hints are stripped first, so
# `Project management (linear, notion, monday.com)` resolves to `issues`.
_tmpl_role_alias() {
  _ra="$(printf '%s' "$1" | sed -e 's/(.*)//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | tr '[:upper:]' '[:lower:]')"
  case "$_ra" in
    email|e-mail|mail|inbox)                        printf 'email' ;;
    messaging|chat|slack|teams|telegram|dm|dms)     printf 'chat' ;;
    meetings|meeting|meeting\ notes|transcripts)    printf 'meetings' ;;
    calendar|cal|schedule)                          printf 'calendar' ;;
    project\ management|issues|tickets|pm|issue\ tracker) printf 'issues' ;;
    code|repo|repos|git|source\ control)            printf 'code' ;;
    second\ vault|second-vault|team\ vault|second\ knowledge\ base) printf 'second-vault' ;;
    vault|this\ vault|filesystem|local\ filesystem)  printf 'vault' ;;
    memory)                                         printf 'memory' ;;
    web|news|web\ search)                           printf 'web' ;;
    *)                                              printf '%s' "$_ra" ;;
  esac
}

# tmpl_roles -> `role|source|notes` from # Sources.
# An unfilled `- role:` with no value reads as `none`, which is the honest default:
# a role nobody recorded an answer for is not connected.
tmpl_roles() {
  _f="$(_tmpl_file sources)"; [ -n "$_f" ] || return 0
  awk '
    function trim(s) { gsub(/`/, "", s); gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^-[[:space:]]/ {
      line = substr($0, 3)
      i = index(line, ":")
      # A role written with no colon at all ("- Project management (linear, ...)")
      # is a role nobody filled in, not a line to drop. Dropping it silently
      # removes the role from the registry, and a role with no row is invisible.
      if (i == 0) { role = trim(line); rest = "" }
      else { role = trim(substr(line, 1, i - 1)); rest = substr(line, i + 1) }
      n = split(rest, f, "|")
      src = trim(f[1]); notes = (n > 1 ? trim(f[2]) : "")
      for (i = 3; i <= n; i++) notes = notes " | " trim(f[i])
      if (src == "") src = "none"
      printf "%s|%s|%s\n", role, src, notes
    }
  ' "$_f" | while IFS='|' read -r _r _s _n; do
      [ -n "$_r" ] || continue
      case "$(printf '%s' "$_s" | tr '[:upper:]' '[:lower:]')" in
        none|n/a|na|no|off|false) _s=none ;;
      esac
      printf '%s|%s|%s\n' "$(_tmpl_role_alias "$_r")" "$_s" "$_n"
    done
}

# tmpl_numbered <slug> -> items of an ordered list, numbering stripped.
tmpl_numbered() {
  _f="$(_tmpl_file "$1")"; [ -n "$_f" ] || return 0
  awk '
    function trim(s) { gsub(/`/, "", s); gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^[0-9]+\.[[:space:]]/ { sub(/^[0-9]+\.[[:space:]]*/, ""); if (trim($0) != "") print trim($0) }
  ' "$_f"
}

# tmpl_prose <slug> -> everything that is not a list item, blanks collapsed.
tmpl_prose() {
  _f="$(_tmpl_file "$1")"; [ -n "$_f" ] || return 0
  awk '
    /^[-*][[:space:]]/    { next }
    /^[[:space:]]+[-*][[:space:]]/ { next }
    /^[0-9]+\.[[:space:]]/ { next }
    { print }
  ' "$_f" | awk 'NF { blank = 0; print; next } !blank { blank = 1; print }' \
    | sed -e '/./,$!d' | awk '{ lines[NR] = $0 } END { last = NR; while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--; for (i = 1; i <= last; i++) print lines[i] }'
}

# tmpl_has <slug> -> 0 when the section exists and holds anything at all.
tmpl_has() {
  _f="$(_tmpl_file "$1")"; [ -n "$_f" ] || return 1
  [ -n "$(tr -d '[:space:]' < "$_f")" ]
}

# Shorthand an interviewer will reach for, mapped to what is actually installed.
# `weekly-plan` is the natural way to say it; `weekly-planning` is the directory
# name. Without this the skill silently fails to install and SOURCES.md names a
# skill that is not on disk.
tmpl_skill_names() {
  tmpl_records "$1" | cut -d'|' -f1 | while read -r _sk; do
    [ -n "$_sk" ] || continue
    # `- weekly-plan: prose...` is a name plus a note, not a skill called the
    # whole sentence. Take the token before the first colon.
    _sk="$(printf '%s' "$_sk" | sed 's/[[:space:]]*:.*//')"
    [ -n "$_sk" ] || continue
    case "$_sk" in
      weekly-plan|weekly-planning) printf 'weekly-planning\n' ;;
      daily-plan|daily-planning)   printf 'daily-plan\n' ;;
      meeting-prep|meeting-preparation) printf 'meeting-prep\n' ;;
      *) printf '%s\n' "$_sk" ;;
    esac
  done
}

# Prose after `- \`name\`: ...` in # Skills, used to seed a stub SKILL.md when
# the template names a skill the payload does not ship.
tmpl_skill_blurb() {
  _want="$1"
  # One scope at a time. Combining them into one pipe and `exit`ing awk on a
  # match closed the pipe while the second tmpl_records was still writing,
  # which is SIGPIPE, which under `set -o pipefail` aborted the payload phase
  # with no message after "skills not requested, removed:".
  _tmpl_skill_blurb_in() {
    tmpl_records "$1" | awk -F'|' -v want="$_want" '
      function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
      function canon(n) {
        n = trim(n); sub(/:.*$/, "", n); n = trim(n)
        if (n == "weekly-plan" || n == "weekly-planning") return "weekly-planning"
        if (n == "daily-plan" || n == "daily-planning") return "daily-plan"
        if (n == "meeting-prep" || n == "meeting-preparation") return "meeting-prep"
        return n
      }
      {
        if (canon($1) != want) next
        note = $1
        if (index(note, ":")) {
          sub(/^[^:]*:[[:space:]]*/, "", note)
          print trim(note)
        } else if (trim($3) != "") {
          print trim($3)
        }
      }
    '
  }
  _note="$(_tmpl_skill_blurb_in skills__user)"
  [ -n "$_note" ] || _note="$(_tmpl_skill_blurb_in skills__system)"
  printf '%s' "$_note"
}

# Same, for routine docs. `weekly-plan-update` is what people say; the bundled
# doc is `weekly-plan-daily-update`.
tmpl_routine_names() {
  tmpl_records routines | cut -d'|' -f1 | while read -r _rt; do
    [ -n "$_rt" ] || continue
    _rt="$(printf '%s' "$_rt" | sed 's/[[:space:]]*:.*//')"
    [ -n "$_rt" ] || continue
    case "$_rt" in
      weekly-plan-update|weekly-plan-daily-update) printf 'weekly-plan-daily-update\n' ;;
      weekly-memory|memory)                        printf 'memory\n' ;;
      *) printf '%s\n' "$_rt" ;;
    esac
  done
}

# The template may name this section `# Platform` or `# Operating System`; both
# are natural, and the second is what the intake form actually says.
tmpl_platform_raw() {
  _v="$(tmpl_kv platform OS)"
  [ -n "$_v" ] || _v="$(tmpl_kv operating-system OS)"
  # `# Operating System (windows vs macos)` with a bare value under it, or the
  # heading's own parenthetical left unfilled, both read as unset.
  if [ -z "$_v" ] && tmpl_has operating-system; then
    _v="$(tmpl_prose operating-system | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    case "$_v" in *windowsvsmacos*|"") _v="" ;; esac
  fi
  printf '%s' "$_v"
}

# The alias accessors return canonical names, but the template still holds
# whatever the interviewer wrote -- so a nested `Sources:` or `Frequency:` under
# `weekly-plan` is invisible to a lookup for `weekly-planning`. These resolve the
# attribute by trying every spelling that maps to the canonical name.
_tmpl_variants() {
  case "$1" in
    weekly-planning)          printf 'weekly-planning weekly-plan' ;;
    daily-plan)               printf 'daily-plan daily-planning' ;;
    meeting-prep)             printf 'meeting-prep meeting-preparation' ;;
    weekly-plan-daily-update) printf 'weekly-plan-daily-update weekly-plan-update' ;;
    memory)                   printf 'memory weekly-memory' ;;
    *)                        printf '%s' "$1" ;;
  esac
}

# tmpl_alias_attr <scope> <canonical-name> <Key>
tmpl_alias_attr() {
  for _cand in $(_tmpl_variants "$2"); do
    _av="$(tmpl_attr "$1" "$_cand" "$3")"
    [ -n "$_av" ] && { printf '%s' "$_av"; return 0; }
  done
  return 0
}

# ------------------------------------------------------------ derived readings

# Project paths, parents and children flattened: `Enzy`, `Enzy/Bedrock`.
tmpl_project_paths() {
  tmpl_records projects | while IFS='|' read -r _n _k _d; do
    [ -n "$_n" ] || continue
    printf '%s\n' "$_n"
    tmpl_children projects "$_n" | while IFS='|' read -r _cn _ck _cd; do
      [ -n "$_cn" ] && printf '%s/%s\n' "$_n" "$_cn"
    done
  done
}

tmpl_area_names() { tmpl_records areas | cut -d'|' -f1 | sed '/^$/d'; }

# A role is connected when it names something other than `none`.
tmpl_role_source() {
  tmpl_roles | awk -F'|' -v r="$1" '$1 == r { print $2; exit }'
}

tmpl_role_connected() {
  _s="$(tmpl_role_source "$1")"
  [ -n "$_s" ] && [ "$_s" != "none" ]
}

# ----------------------------------------------------------------- the brief

# The shared prompt preamble, assembled deterministically from the template. Every
# hydration prompt gets the same one, which is what keeps five independently
# generated documents describing the same person and the same projects.
#
# Kept tight on purpose: it is prepended to every call, so padding is paid for
# many times over.
template_brief() {
  # `local` is not decoration here. These were plain globals, and `_p` collided
  # with the prompt-file path every caller holds in `_p` -- so the prompt path was
  # overwritten with a paragraph of prose before llm_raw ever read it, `claude`
  # got an empty prompt, and every document silently fell back to its stub while
  # the build still reported success.
  local _name _pron _mail _loc _tz _p _sh
  _name="$(tmpl_kv "$TMPL_USER" Name)"
  _pron="$(tmpl_kv "$TMPL_USER" Pronouns)"
  _mail="$(tmpl_kv "$TMPL_USER" Email)"
  _loc="$(tmpl_kv "$TMPL_USER" Location)"
  _tz="$(tmpl_kv "$TMPL_USER" Timezone)"

  printf '## The person this vault belongs to\n\n'
  printf 'Name: %s' "${_name:-unspecified}"
  [ -n "$_pron" ] && printf ' (%s)' "$_pron"
  [ -n "$_mail" ] && printf ' · %s' "$_mail"
  [ -n "$_loc" ]  && printf ' · %s' "$_loc"
  [ -n "$_tz" ]   && printf ' · %s' "$_tz"
  printf '\n\n'

  _p="$(tmpl_prose "$TMPL_USER")"
  [ -n "$_p" ] && printf '%s\n\n' "$_p"

  printf '## Active projects (folders under Projects/)\n'
  tmpl_records projects | while IFS='|' read -r _n _k _d; do
    [ -n "$_n" ] || continue
    printf -- '- Projects/%s' "$_n"
    [ -n "$_k" ] && printf ' (%s)' "$_k"
    [ -n "$_d" ] && printf ': %s' "$_d"
    printf '\n'
    tmpl_children projects "$_n" | while IFS='|' read -r _cn _ck _cd; do
      [ -n "$_cn" ] || continue
      printf -- '  - Projects/%s/%s' "$_n" "$_cn"
      [ -n "$_ck" ] && printf ' (%s)' "$_ck"
      [ -n "$_cd" ] && printf ': %s' "$_cd"
      printf '\n'
    done
  done
  printf '\n'

  if [ -n "$(tmpl_area_names)" ]; then
    printf '## Ongoing areas (folders under Areas/) -- maintained at a standard, never finished\n'
    tmpl_records areas | while IFS='|' read -r _n _k _d; do
      [ -n "$_n" ] || continue
      printf -- '- Areas/%s' "$_n"
      _ad="${_d:-$_k}"; [ -n "$_ad" ] && printf ': %s' "$_ad"
      printf '\n'
    done
    printf '\n'
  fi

  _sh="$(tmpl_children "$TMPL_USER" Shorthand)"
  if [ -n "$_sh" ]; then
    printf '## Shorthand this person uses in their own notes\n'
    printf '%s\n' "$_sh" | while IFS='|' read -r _a _b _c; do
      [ -n "$_a" ] && printf -- '- %s\n' "$_a"
    done
    printf '\n'
  fi
  return 0
}
