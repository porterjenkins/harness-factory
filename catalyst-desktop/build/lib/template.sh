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
TMPL_OPTIONAL="Import|Tag Vocabulary|Sync"

# Roles the SOURCES.md registry understands. A row naming anything else is a typo,
# and a typo'd role is indistinguishable from a disconnected one at run time.
TMPL_KNOWN_ROLES="vault meetings calendar chat email issues code second-vault memory web"

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
  awk -v dir="$TMPL_DIR" '
    function slug(s) {
      s = tolower(s)
      gsub(/[^a-z0-9]+/, "-", s)
      sub(/^-/, "", s); sub(/-$/, "", s)
      return s
    }
    /^# /   { h1 = slug(substr($0, 3)); h3 = ""; next }
    /^### / { if (h1 != "") h3 = h1 "__" slug(substr($0, 5)); next }
    /^## /  { h3 = ""; next }
    {
      if (h1 != "") print $0 >> (dir "/" h1 ".md")
      if (h3 != "") print $0 >> (dir "/" h3 ".md")
    }
  ' "$TMPL_DIR/.clean.md"

  _tmpl_validate
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
  [ -n "$(tmpl_records projects)" ] \
    || die "# Projects is empty. A vault needs at least one project -- it is the
       taxonomy every planning skill reads its section headers from."

  # Validate role names now, while we can still name the line that is wrong.
  _bad=""; rm -f "$TMPL_DIR/.badroles"
  tmpl_roles | while IFS='|' read -r _role _src _notes; do
    [ -n "$_role" ] || continue
    case " $TMPL_KNOWN_ROLES " in
      *" $_role "*) ;;
      *) printf '%s\n' "$_role" >> "$TMPL_DIR/.badroles" ;;
    esac
  done
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
      for (i = 1; i <= n; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", f[i])
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
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^-[[:space:]]/ {
      line = substr($0, 3); split(line, f, "|")
      cur = trim(f[1]); sub(/:$/, "", cur); next
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
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^-[[:space:]]/ { line = substr($0, 3); split(line, f, "|"); cur = trim(f[1]); sub(/:$/, "", cur); next }
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
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
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

# tmpl_roles -> `role|source|notes` from # Sources.
# An unfilled `- role:` with no value reads as `none`, which is the honest default:
# a role nobody recorded an answer for is not connected.
tmpl_roles() {
  _f="$(_tmpl_file sources)"; [ -n "$_f" ] || return 0
  awk '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^-[[:space:]]/ {
      line = substr($0, 3)
      i = index(line, ":")
      if (i == 0) next
      role = trim(substr(line, 1, i - 1))
      rest = substr(line, i + 1)
      n = split(rest, f, "|")
      src = trim(f[1]); notes = (n > 1 ? trim(f[2]) : "")
      for (i = 3; i <= n; i++) notes = notes " | " trim(f[i])
      if (src == "") src = "none"
      printf "%s|%s|%s\n", role, src, notes
    }
  ' "$_f"
}

# tmpl_numbered <slug> -> items of an ordered list, numbering stripped.
tmpl_numbered() {
  _f="$(_tmpl_file "$1")"; [ -n "$_f" ] || return 0
  awk '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
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
