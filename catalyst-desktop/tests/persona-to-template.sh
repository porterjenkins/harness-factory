#!/usr/bin/env bash
# Derive a build template from a sandbox persona, so the builder can be tested
# against a populated synthetic vault instead of an empty directory.
#
#   ./persona-to-template.sh default  > /tmp/default.md
#   ./persona-to-template.sh ./personas/mine.persona.sh > /tmp/mine.md
#
# The persona is the sandbox's identity; the template is the builder's input. They
# describe the same things in different shapes, so this is a translation, not a
# second source of truth -- edit the persona, never the generated template.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TESTS_DIR/../lib" && pwd)"
. "$LIB_DIR/common.sh"
. "$TESTS_DIR/lib/persona.sh"

[ $# -ge 1 ] || die "usage: persona-to-template.sh <persona-name|path>"
persona_load "$(persona_resolve "$1")"

# Roles the persona actually connected. A sandbox sets most to `none` on purpose
# -- a test run must not be able to reach a live service -- and the skills below
# inherit exactly that, so their Sources lists come out honest rather than
# aspirational.
_connected() {
  _i=0; _out=""
  while [ "$_i" -lt "${#PERSONA_SOURCES[@]}" ]; do
    _r="$(field 1 "${PERSONA_SOURCES[$_i]}")"
    _s="$(field 2 "${PERSONA_SOURCES[$_i]}")"
    case "$_r" in vault|web|memory) ;; esac
    if [ -n "$_s" ] && [ "$_s" != "none" ]; then
      case " $* " in *" $_r "*) _out="$_out${_out:+, }$_r" ;; esac
    fi
    _i=$(( _i + 1 ))
  done
  printf '%s' "$_out"
}

cat <<EOF
<!-- GENERATED from the sandbox persona "$(basename "$PERSONA_FILE")" by
     tests/persona-to-template.sh. Do not edit: edit the persona and regenerate.
     Its purpose is to let build-vault.sh be tested against a vault that already
     has content, which is the only way the tagging phase means anything. -->

# Projects

EOF

# Persona project paths are "Parent/Child"; the template nests children as
# indented bullets under their parent. First segments are de-duplicated in order,
# and a parent that only ever appears as a prefix still gets its own line.
persona_project_groups | while IFS= read -r _g; do
  [ -n "$_g" ] || continue
  _pdesc=""; _pkind=""
  _i=0
  while [ "$_i" -lt "${#PERSONA_PROJECTS[@]}" ]; do
    _p="$(field 1 "${PERSONA_PROJECTS[$_i]}")"
    if [ "$_p" = "$_g" ]; then
      _pkind="$(field 2 "${PERSONA_PROJECTS[$_i]}")"
      _pdesc="$(field 3 "${PERSONA_PROJECTS[$_i]}")"
    fi
    _i=$(( _i + 1 ))
  done
  printf -- '- %s | %s | %s\n' "$_g" "${_pkind:-group}" \
    "${_pdesc:-Top-level grouping for the projects nested beneath it.}"

  _i=0
  while [ "$_i" -lt "${#PERSONA_PROJECTS[@]}" ]; do
    _p="$(field 1 "${PERSONA_PROJECTS[$_i]}")"
    case "$_p" in
      "$_g"/*) printf -- '  - %s | %s | %s\n' "${_p#*/}" \
                 "$(field 2 "${PERSONA_PROJECTS[$_i]}")" \
                 "$(field 3 "${PERSONA_PROJECTS[$_i]}")" ;;
    esac
    _i=$(( _i + 1 ))
  done
done

printf '\n\n# Areas\n\n'
_i=0
while [ "$_i" -lt "${#PERSONA_AREAS[@]}" ]; do
  printf -- '- %s | %s\n' "$(field 1 "${PERSONA_AREAS[$_i]}")" "$(field 2 "${PERSONA_AREAS[$_i]}")"
  _i=$(( _i + 1 ))
done

printf '\n\n# Sources\n\n'
_i=0
while [ "$_i" -lt "${#PERSONA_SOURCES[@]}" ]; do
  _r="$(field 1 "${PERSONA_SOURCES[$_i]}")"
  _s="$(field 2 "${PERSONA_SOURCES[$_i]}")"
  _n="$(field 3 "${PERSONA_SOURCES[$_i]}")"
  printf -- '- %s: %s%s\n' "$_r" "${_s:-none}" "${_n:+ | $_n}"
  _i=$(( _i + 1 ))
done

# A sandbox never points `meetings` at a live connector -- it uses simulated
# exports under Resources/Meetings/ -- so this is `none` for every bundled
# persona. It is derived rather than hardcoded so a persona that does name
# Granola gets the connector wired.
_meeting_connector() {
  _i=0
  while [ "$_i" -lt "${#PERSONA_SOURCES[@]}" ]; do
    if [ "$(field 1 "${PERSONA_SOURCES[$_i]}")" = "meetings" ]; then
      case "$(field 2 "${PERSONA_SOURCES[$_i]}")" in
        [Gg]ranola*) printf -- '- granola-export\n'; return 0 ;;
      esac
    fi
    _i=$(( _i + 1 ))
  done
  printf -- '- none\n'
}

cat <<EOF


# Skills

### System
- doc-retrieval
- tag-lint
- log-manager
### User
- daily-plan
    - Sources: $(_connected chat email web)
- weekly-plan
    - Sources: $(_connected calendar meetings issues)
- meeting-prep
    - Sources: $(_connected calendar issues chat meetings second-vault)

# Routines
- weekly-plan-create
    - Frequency: Sundays 5:30pm
- weekly-plan-update
    - Frequency: daily 4:30pm
- daily-plan-run
    - Frequency: weekdays 7:30am


# Connectors

### Meetings
$(_meeting_connector)

### External notes
- none


# Priorities

EOF

# A persona declares no priority order, so derive one from project order -- it is
# the only signal available, and an empty # Priorities produces a PRIORITIES.md
# the reranker cannot rank against.
_n=1
persona_project_groups | while IFS= read -r _g; do
  [ -n "$_g" ] || continue
  printf '%s. Move %s forward\n' "$_n" "$_g"
  _n=$(( _n + 1 ))
done

cat <<EOF


# User Profile and Preferences

- Name: $PERSONA_NAME
- Pronouns: $PERSONA_PRONOUNS
- Email: $PERSONA_EMAIL
- Location: $PERSONA_LOCATION
- Timezone: $PERSONA_TZ
- Shorthand:
EOF
_i=0
while [ "$_i" -lt "${#PERSONA_SHORTHAND[@]}" ]; do
  printf -- '    - %s = %s\n' "$(field 1 "${PERSONA_SHORTHAND[$_i]}")" \
                              "$(field 2 "${PERSONA_SHORTHAND[$_i]}")"
  _i=$(( _i + 1 ))
done

printf '\n%s\n' "$PERSONA_SEED"

cat <<EOF

# Operating System (windows vs macos)

- OS: auto
EOF
