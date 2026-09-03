# shellcheck shell=bash
# Persona loading and the prompt brief derived from it.
#
# The brief is assembled deterministically from the persona file rather than
# generated. Every document prompt gets the same brief, which is what keeps names,
# project paths and shorthand consistent across forty independently generated
# notes -- the property that makes the corpus feel like one person's vault instead
# of forty unrelated documents.
#
# Source after common.sh.

[ -n "${_CATALYST_PERSONA_SH:-}" ] && return 0
_CATALYST_PERSONA_SH=1

persona_resolve() {  # accepts a name from personas/, or a path to a file
  _p="$1"
  if [ -f "$_p" ]; then printf '%s' "$_p"; return 0; fi
  for _cand in \
    "$TESTS_DIR/personas/$_p.persona.sh" \
    "$TESTS_DIR/personas/$_p.sh" \
    "$TESTS_DIR/personas/$_p"
  do
    [ -f "$_cand" ] && { printf '%s' "$_cand"; return 0; }
  done
  die "persona not found: $_p (looked in $TESTS_DIR/personas/)"
}

persona_load() {
  _file="$1"
  # shellcheck disable=SC1090
  . "$_file"

  for _v in PERSONA_ID PERSONA_NAME PERSONA_EMAIL PERSONA_VAULT PERSONA_SEED; do
    eval "_val=\"\${$_v:-}\""
    [ -n "$_val" ] || die "persona $_file is missing required variable: $_v"
  done
  # An unset array is also an "unbound variable" under bash 3.2 + set -u, so every
  # optional array is declared here before anything reads its length.
  for _a in PERSONA_AREAS PERSONA_RESOURCES PERSONA_MEETINGS PERSONA_PEOPLE \
            PERSONA_SHORTHAND PERSONA_SOURCES; do
    eval "if [ -z \"\${$_a+set}\" ]; then $_a=(); fi"
  done

  [ "${#PERSONA_PROJECTS[@]}" -gt 0 ] || die "persona $_file defines no PERSONA_PROJECTS"

  PERSONA_PRONOUNS="${PERSONA_PRONOUNS:-they/them}"
  PERSONA_LOCATION="${PERSONA_LOCATION:-unspecified}"
  PERSONA_TZ="${PERSONA_TZ:-America/Denver}"
  PERSONA_TZ_OFFSET="${PERSONA_TZ_OFFSET:--06:00}"
  PERSONA_HEADLINE="${PERSONA_HEADLINE:-$PERSONA_NAME}"
  PERSONA_TAG_ROOTS="${PERSONA_TAG_ROOTS:-}"
  PERSONA_FILE="$_file"
}

# First path segment of each project, de-duplicated, order preserved. These
# become the top-level `# Heading` sections of a weekly plan; the weekly-planning
# skill reads its project headers out of CLAUDE.md, so both have to agree.
persona_project_groups() {
  _i=0
  while [ "$_i" -lt "${#PERSONA_PROJECTS[@]}" ]; do
    field 1 "${PERSONA_PROJECTS[$_i]}" | cut -d/ -f1
    _i=$(( _i + 1 ))
  done | awk '!seen[$0]++'
}

persona_project_paths() {
  _i=0
  while [ "$_i" -lt "${#PERSONA_PROJECTS[@]}" ]; do
    field 1 "${PERSONA_PROJECTS[$_i]}"
    _i=$(( _i + 1 ))
  done
}

# Takes an array NAME, not an expansion. Under bash 3.2 with `set -u`,
# "${arr[@]}" on an empty array is an "unbound variable" error rather than an
# empty list -- the kind of bug that only shows up on the machine without brew
# bash installed. Indexing by name sidesteps it entirely.
_persona_list_block() {  # <header> <array-name>
  _hdr="$1"; _an="$2"
  eval "_n=\${#$_an[@]}"
  [ "$_n" -eq 0 ] && return 0
  printf '%s\n' "$_hdr"
  _i=0
  while [ "$_i" -lt "$_n" ]; do
    eval "_rec=\"\${$_an[\$_i]}\""
    printf -- '- %s: %s\n' "$(field 1 "$_rec")" "$(field 2 "$_rec")"
    _i=$(( _i + 1 ))
  done
  printf '\n'
}

# The shared prompt preamble. Kept tight on purpose: it is prepended to every
# one of several dozen calls, so padding it is paid for many times over.
persona_brief() {
  cat <<BRIEF
## The person this vault belongs to

Name: $PERSONA_NAME ($PERSONA_PRONOUNS) · $PERSONA_EMAIL · $PERSONA_LOCATION
In one line: $PERSONA_HEADLINE

$PERSONA_SEED

BRIEF

  printf '## Active projects (folders under Projects/)\n'
  _i=0
  while [ "$_i" -lt "${#PERSONA_PROJECTS[@]}" ]; do
    printf -- '- Projects/%s (%s): %s\n' \
      "$(field 1 "${PERSONA_PROJECTS[$_i]}")" \
      "$(field 2 "${PERSONA_PROJECTS[$_i]}")" \
      "$(field 3 "${PERSONA_PROJECTS[$_i]}")"
    _i=$(( _i + 1 ))
  done
  printf '\n'

  _persona_list_block "## Ongoing areas (folders under Areas/)" PERSONA_AREAS
  _persona_list_block "## People who appear in these notes (use these names, invent no others)" PERSONA_PEOPLE
  _persona_list_block "## Shorthand this person uses in their own notes" PERSONA_SHORTHAND

  [ -n "$PERSONA_TAG_ROOTS" ] && \
    printf '## Tag vocabulary for this vault\nPrefer these, and hierarchical children of them: %s\n\n' "$PERSONA_TAG_ROOTS"
  return 0
}

# The output contract, restated in every document prompt. Worth the repetition:
# dropping it costs a whole generation round-trip to a note that has to be thrown
# away.
persona_contract() {
  cat <<'CONTRACT'
## Output contract -- follow exactly

Emit two parts and nothing else:

TAGS: <3 to 6 comma-separated lowercase tags, hierarchical with `/` where it fits>
---BODY---
<the Markdown document, starting with a single `# ` heading>

Rules:
- No YAML frontmatter. It is added programmatically after you.
- Do not wrap the document in a code fence.
- No preamble, no sign-off, no meta-commentary about being generated.
- Write as this person writing for themselves: terse, concrete, opinionated. Not
  documentation, not marketing copy, not an essay.
- Invent specifics -- dates, row counts, latencies, dollar figures, names from the
  people list, decisions actually taken. Vagueness is the main way synthetic notes
  give themselves away.
- Use `[[Wikilinks]]` only for note titles given to you as linkable. Never invent
  a link target.
CONTRACT
}
