# shellcheck shell=bash
# Document simulation, in four dependency-ordered phases.
#
#   1. titles   -- one call per project/area, so note names are coherent as a set
#                  and every note knows what its siblings are called (real vaults
#                  are dense with wikilinks; a corpus with no link graph is a poor
#                  test of retrieval)
#   2. corpus   -- project, area, resource, archive and clipping notes, plus
#                  meeting notes. All independent, all parallel.
#   3. weeklies -- need the project list and recent meeting titles
#   4. dailies  -- need their own week's weekly plan, because the daily-plan skill
#                  pulls open P1 items out of it. Generating dailies first produces
#                  a vault where that skill has nothing coherent to find.
#
# Source after common.sh, llm.sh and persona.sh.

[ -n "${_CATALYST_DOCGEN_SH:-}" ] && return 0
_CATALYST_DOCGEN_SH=1

# Rotates notes through "already ingested" and "pending ingestion" states. Every
# Nth note is written with no `tagged`/`tagged_hash`, which is what a note looks
# like between landing in the vault and the tagger's next pass -- a state the
# pipeline and the tag-lint skill both have to handle.
UNTAGGED_EVERY="${UNTAGGED_EVERY:-4}"

# Derived from a hash of the note's own path rather than a counter. Generation
# runs in parallel subshells, so a counter increments a copy and is lost -- the
# rotation would silently never fire and every note would come out tagged.
_tagged_date_for() {  # <date> <key>
  [ "$UNTAGGED_EVERY" -gt 0 ] || { printf '%s' "$1"; return; }
  _h="$(printf '%s' "$2" | { command -v shasum >/dev/null 2>&1 && shasum -a 256 \
        || sha256sum; } | cut -c1-4)"
  if [ $(( 0x$_h % UNTAGGED_EVERY )) -eq 0 ]; then
    printf ''
  else
    printf '%s' "$1"
  fi
}

_safe_title() {  # legal in a filename, and legal as a wikilink target
  printf '%s' "$1" | sed -e 's/[\/:|#^\[\]]/-/g' -e 's/  */ /g' \
    -e 's/^[[:space:].-]*//' -e 's/[[:space:].-]*$//'
}

# ------------------------------------------------------------- phase 1: titles

_stub_titles() {  # <out> <count> <subject>
  : > "$1"
  _i=1
  while [ "$_i" -le "$2" ]; do
    case $(( _i % 5 )) in
      1) printf '%s Notes\n'          "$3" >> "$1" ;;
      2) printf '%s Plan\n'           "$3" >> "$1" ;;
      3) printf '%s Open Questions\n' "$3" >> "$1" ;;
      4) printf '%s Decision Log\n'   "$3" >> "$1" ;;
      0) printf '%s Status Summary\n' "$3" >> "$1" ;;
    esac
    _i=$(( _i + 1 ))
  done
}

# _gen_titles <out_file> <count> <label> <context...>
_gen_titles() {
  local _out="$1" _n="$2" _label="$3"; shift 3
  local _pf
  _pf="$WORK/prompt-titles-$(slug "$_label").txt"
  {
    printf 'Invent %s note titles that would plausibly exist in this folder of a personal knowledge vault.\n\n' "$_n"
    printf '%s\n\n' "$*"
    persona_brief
    cat <<'FOOT'
Rules:
- One title per line. Nothing else -- no numbering, no bullets, no quotes, no commentary.
- Title Case, 2-7 words. No file extension.
- Vary the kind of document: a plan, a spec, a decision log, raw notes from
  digging into something, a scoping doc, a retro, a comparison, a one-pager.
- No colons, slashes or brackets in a title.
FOOT
  } > "$_pf"

  # A short list of titles is a legitimate 30-byte response, so this call gets a
  # much lower length floor than a document body.
  if [ "$LLM_OFFLINE" = "1" ] || ! llm_raw "$_pf" "$_out.raw" "titles:$_label" 8; then
    _stub_titles "$_out" "$_n" "$_label"
    return 0
  fi
  sed -e 's/^[[:space:]]*[-*0-9.)]*[[:space:]]*//' -e 's/^["'"'"']//' -e 's/["'"'"']$//' \
      -e 's/[\/:|#^\[\]]/-/g' -e 's/[[:space:]]*$//' "$_out.raw" \
    | grep -v '^$' | awk '!seen[tolower($0)]++' | head -"$_n" > "$_out"
  rm -f "$_out.raw" "$_out.raw.err"
  [ -s "$_out" ] || _stub_titles "$_out" "$_n" "$_label"
}

docgen_titles() {
  mkdir -p "$WORK/titles"
  _i=0
  while [ "$_i" -lt "${#PERSONA_PROJECTS[@]}" ]; do
    _rec="${PERSONA_PROJECTS[$_i]}"
    _path="$(field 1 "$_rec")"
    job_run "titles-proj-$(slug "$_path")" \
      _gen_titles "$WORK/titles/proj-$(slug "$_path").txt" "$DOCS_PER_PROJECT" "$_path" \
      "The folder is Projects/$_path -- a $(field 2 "$_rec") project. $(field 3 "$_rec")"
    _i=$(( _i + 1 ))
  done
  _i=0
  while [ "$_i" -lt "${#PERSONA_AREAS[@]}" ]; do
    _rec="${PERSONA_AREAS[$_i]}"
    _name="$(field 1 "$_rec")"
    job_run "titles-area-$(slug "$_name")" \
      _gen_titles "$WORK/titles/area-$(slug "$_name").txt" "$DOCS_PER_AREA" "$_name" \
      "The folder is Areas/$_name -- an ongoing responsibility with no completion date, not a project. $(field 2 "$_rec")"
    _i=$(( _i + 1 ))
  done
  jobs_drain
  ok "note titles planned ($(cat "$WORK"/titles/*.txt 2>/dev/null | wc -l | tr -d ' ') titles)"
}

# ------------------------------------------------------------- phase 2: corpus

_stub_body() {  # <body_out> <tags_out> <title> <context> <tags>
  cat > "$1" <<STUB
# $3

$4

## Where this stands

- Drafted $TODAY. Offline stub: no model was called for this note.
- Owner: $PERSONA_NAME

## Open questions

- [ ] Confirm scope with the people named in the brief
- [ ] Decide what the next checkpoint actually needs to show
- [x] Write this note down somewhere durable

## Notes

Placeholder body with the structure of a real note -- headings, a checklist, and a
paragraph -- so structural assertions hold without spending tokens on prose.
STUB
  printf '%s\n' "${5:-reference}" > "$2"
}

# _gen_doc <out_path> <type> <title> <linkable_file> <kind_prompt_fn> <fallback_tags> <context...>
_gen_doc() {
  local _out="$1" _type="$2" _title="$3" _links="$4" _kind="$5" _ftags="$6"; shift 6
  local _s _pf _bf _tf
  _s="$(slug "$_title")"
  _pf="$WORK/prompt-$_s.txt"; _bf="$WORK/body-$_s.md"; _tf="$WORK/tags-$_s.txt"

  {
    "$_kind" "$_title" "$*"
    printf '\n'
    persona_brief
    if [ -n "$_links" ] && [ -s "$_links" ]; then
      printf '## Linkable notes (the only valid `[[Wikilink]]` targets)\n'
      sed 's/^/- /' "$_links"
      printf '\nLink 1-3 of them where a reference is genuinely warranted. Do not link for the sake of linking.\n\n'
    fi
    persona_contract
  } > "$_pf"

  llm_doc "$_pf" "$_bf" "$_tf" _stub_body "$_title" "$*" "$_ftags"
  stamp_note "$_out" "$_bf" "$_type" "$(cat "$_tf")" "$(_tagged_date_for "$(date_add "$TODAY" -2)" "$_out")"
  rm -f "$_pf" "$_bf" "$_tf"
  note "wrote ${_out#"$VAULT/"}"
}

_kind_project() {
  printf 'Write the note titled "%s" from a personal knowledge vault.\n\n' "$1"
  printf '%s\n\n' "$2"
  cat <<'K'
It is a working document inside an active project: written to think with, not to
publish. Whatever the title implies it is -- a plan, a spec, a decision log, raw
investigation notes -- commit to that form fully. 400-800 words.

Include at least one of: a Markdown table of options or phases with real numbers;
a checklist with a mix of `- [ ]` and `- [x]` items; a "Decision" or "Open
questions" section that names who has to weigh in. Record dead ends and things
that turned out wrong -- a project note with no discarded options reads as
generated.
K
}

_kind_area() {
  printf 'Write the note titled "%s" from a personal knowledge vault.\n\n' "$1"
  printf '%s\n\n' "$2"
  cat <<'K'
It lives under `Areas/` -- an ongoing responsibility maintained at a standard,
with no completion date and no definition of done. So: standing cadences,
recurring obligations, a checklist that resets, the current state of something
being kept up rather than finished. Nothing that reads like a project with a
deadline. 300-600 words.
K
}

_kind_resource() {
  printf 'Write the reference note titled "%s" from a personal knowledge vault.\n\n' "$1"
  printf '%s\n\n' "$2"
  cat <<'K'
It lives under `Resources/` -- reference material consulted across several
projects, not tied to any one of them. Written as a durable working reference the
owner returns to: definitions, a comparison table, rules of thumb, and
specifically the failure modes and gotchas that only come from having been burned.
400-700 words. Do not frame it as a tutorial for someone else.
K
}

_kind_archive() {
  printf 'Write the note titled "%s" from a personal knowledge vault.\n\n' "$1"
  printf '%s\n\n' "$2"
  cat <<'K'
It has been ARCHIVED: the work it describes finished, was cancelled, or was
superseded, some time last year. Write it as it stood at the end -- outcome
stated, loose ends noted, and a short closing line about what was learned or what
replaced it. Past tense. 300-500 words.
K
}

_kind_clipping() {
  printf 'Write the note titled "%s" -- a web article saved into a personal knowledge vault.\n\n' "$1"
  printf '%s\n\n' "$2"
  cat <<'K'
It is a saved article, not the owner's own writing: a clipped external piece
relevant to their work. Write the article body itself, condensed -- headings,
a couple of pull quotes, concrete claims -- and end with a short
`## Why I saved this` section in the owner's voice connecting it to a specific
project of theirs. 300-500 words. The publication and author are fictional.
K
}

docgen_corpus() {
  # Project notes. Siblings are passed as linkable targets, so a project's notes
  # reference each other the way a real project folder's do.
  _i=0
  while [ "$_i" -lt "${#PERSONA_PROJECTS[@]}" ]; do
    _rec="${PERSONA_PROJECTS[$_i]}"
    _path="$(field 1 "$_rec")"
    _tf="$WORK/titles/proj-$(slug "$_path").txt"
    _n=0
    while IFS= read -r _title; do
      [ -n "$_title" ] || continue
      _title="$(_safe_title "$_title")"
      job_run "doc-$(slug "$_path")-$(slug "$_title")" \
        _gen_doc "$VAULT/Projects/$_path/$_title.md" "project" "$_title" "$_tf" \
        _kind_project "$(slug "$(printf '%s' "$_path" | cut -d/ -f1)")" \
        "It sits in Projects/$_path, a $(field 2 "$_rec") project. $(field 3 "$_rec")"
      _n=$(( _n + 1 ))
    done < "$_tf"
    _i=$(( _i + 1 ))
  done

  # Area notes.
  _i=0
  while [ "$_i" -lt "${#PERSONA_AREAS[@]}" ]; do
    _rec="${PERSONA_AREAS[$_i]}"
    _name="$(field 1 "$_rec")"
    _tf="$WORK/titles/area-$(slug "$_name").txt"
    while IFS= read -r _title; do
      [ -n "$_title" ] || continue
      _title="$(_safe_title "$_title")"
      job_run "doc-area-$(slug "$_name")-$(slug "$_title")" \
        _gen_doc "$VAULT/Areas/$_name/$_title.md" "area" "$_title" "$_tf" \
        _kind_area "$(slug "$_name")" \
        "It sits in Areas/$_name. $(field 2 "$_rec")"
    done < "$_tf"
    _i=$(( _i + 1 ))
  done

  # Resource notes, taken straight from the persona's reference list.
  _i=0
  while [ "$_i" -lt "${#PERSONA_RESOURCES[@]}" ] && [ "$_i" -lt "$RESOURCE_COUNT" ]; do
    _rec="${PERSONA_RESOURCES[$_i]}"
    _title="$(_safe_title "$(field 1 "$_rec")")"
    job_run "doc-res-$(slug "$_title")" \
      _gen_doc "$VAULT/Resources/$_title.md" "reference" "$_title" "" \
      _kind_resource "reference" "$(field 2 "$_rec")"
    _i=$(( _i + 1 ))
  done

  # Archived notes, dated to last year, so historical search has something to find.
  _prev=$(( $(date_fmt "$TODAY" '+%Y') - 1 ))
  _i=0
  while [ "$_i" -lt "$ARCHIVE_COUNT" ]; do
    _rec="${PERSONA_PROJECTS[$(( _i % ${#PERSONA_PROJECTS[@]} ))]}"
    _path="$(field 1 "$_rec")"
    _title="$(_safe_title "$(printf '%s' "$_path" | tr '/' ' ') Retro $_prev")"
    job_run "doc-archive-$(slug "$_title")" \
      _gen_doc "$VAULT/Archive/$_prev/$_title.md" "archive" "$_title" "" \
      _kind_archive "archive" \
      "It concerns work related to Projects/$_path, closed out during $_prev. $(field 3 "$_rec")"
    _i=$(( _i + 1 ))
  done

  # Clippings -- saved external material, which is a different shape from anything
  # the owner writes and therefore worth having in the corpus.
  if [ "${#PERSONA_RESOURCES[@]}" -gt 0 ]; then
    _i=0
    while [ "$_i" -lt "$CLIPPING_COUNT" ]; do
      _rec="${PERSONA_RESOURCES[$(( _i % ${#PERSONA_RESOURCES[@]} ))]}"
      _title="$(_safe_title "$(field 1 "$_rec") - Field Report")"
      job_run "clip-$(slug "$_title")" \
        _gen_clipping "$VAULT/Clippings/$_title.md" "$_title" "$(field 2 "$_rec")"
      _i=$(( _i + 1 ))
    done
  fi

  docgen_meetings
  jobs_drain
}

# ------------------------------------------------------------------- clippings

_gen_clipping() {  # <out> <title> <context>
  local _out="$1" _title="$2" _ctx="$3"
  local _s _fm _pf _bf _tf
  _s="$(slug "$_title")"
  _fm="$WORK/fm-$_s.txt"
  {
    printf 'source: "https://%s.example.com/%s"\n' \
      "$(slug "$(printf '%s' "$_title" | cut -d' ' -f1)")" "$(slug "$_title")"
    printf 'author: "%s"\n' "A. Contributor"
    printf 'published: %s\n' "$(date_add "$TODAY" -45)"
    printf 'clipped: %s\n' "$(date_add "$TODAY" -12)"
  } > "$_fm"

  _pf="$WORK/prompt-$_s.txt"; _bf="$WORK/body-$_s.md"; _tf="$WORK/tags-$_s.txt"
  {
    _kind_clipping "$_title" "$_ctx"
    printf '\n'
    persona_brief
    persona_contract
  } > "$_pf"
  llm_doc "$_pf" "$_bf" "$_tf" _stub_body "$_title" "$_ctx" "clipping, reference"
  stamp_note "$_out" "$_bf" "clipping" "$(cat "$_tf")" \
    "$(_tagged_date_for "$(date_add "$TODAY" -10)" "$_out")" "$_fm"
  rm -f "$_pf" "$_bf" "$_tf" "$_fm"
  note "wrote ${_out#"$VAULT/"}"
}

# -------------------------------------------------------------------- meetings

_kind_meeting() {
  printf 'Write the meeting note for "%s" held on %s.\n\n' "$1" "$2"
  printf '%s\n\n' "$3"
  cat <<'K'
This is an auto-transcribed meeting note, the way a tool like Granola produces
one: not minutes, not a summary essay. Shape it as `### Speaker` sections in
speaking order, each a tight nested bullet list of what that person actually said
-- numbers, blockers, disagreements, half-formed ideas. Then a final
`### Action Items` section as `- [ ]` checkboxes, each naming an owner.

300-600 words. Two people should visibly disagree about something, and at least
one item should be left explicitly unresolved. Start with a single `# ` heading
that is the date followed by the meeting title.
K
}

_gen_meeting() {  # <out> <title> <date> <attendees_csv>
  local _out="$1" _title="$2" _date="$3" _att="$4"
  local _s _fm _pf _bf _tf
  _s="$(slug "$_date-$_title")"
  _fm="$WORK/fm-$_s.txt"

  # Granola-shaped frontmatter, written by hand: the connector's output format is
  # a parsing contract for the meeting-prep and weekly-planning skills.
  {
    printf 'title: %s\n' "$_title"
    printf 'date: %s\n' "$_date"
    printf 'start_time: "%sT%s:00%s"\n' "$_date" "$(printf '%02d:%02d' $(( 9 + (_MEET_N % 7) )) $(( (_MEET_N % 2) * 30 )))" "$PERSONA_TZ_OFFSET"
    printf 'end_time: "%sT%s:00%s"\n' "$_date" "$(printf '%02d:%02d' $(( 9 + (_MEET_N % 7) + 1 )) $(( (_MEET_N % 2) * 30 )))" "$PERSONA_TZ_OFFSET"
    printf 'owner: %s\n' "$PERSONA_NAME"
    printf 'owner_email: %s\n' "$PERSONA_EMAIL"
    printf 'attendees:\n'
    printf '%s' "$_att" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      | grep -v '^$' | sed 's/^/  - /'
    printf 'granola_url: "https://notes.granola.example/d/%s"\n' "$(_sha256_str "$_s" | cut -c1-32)"
    printf 'granola_id: not_%s\n' "$(_sha256_str "$_s" | cut -c1-16)"
    printf 'source: granola\n'
  } > "$_fm"

  _pf="$WORK/prompt-$_s.txt"; _bf="$WORK/body-$_s.md"; _tf="$WORK/tags-$_s.txt"
  {
    _kind_meeting "$_title" "$_date" "Attendees: $_att."
    printf '\n'
    persona_brief
    persona_contract
  } > "$_pf"
  llm_doc "$_pf" "$_bf" "$_tf" _stub_body "$_date $_title" "Attendees: $_att." "meeting"
  # Meetings arrive from the connector untagged and are tagged on the next pass,
  # so a share of them legitimately have no `tagged` key at all.
  stamp_note "$_out" "$_bf" "meeting" "$(cat "$_tf")" \
    "$(_tagged_date_for "$(date_add "$_date" 1)" "$_out")" "$_fm"
  rm -f "$_pf" "$_bf" "$_tf" "$_fm"
  note "wrote ${_out#"$VAULT/"}"
}

_sha256_str() {
  printf '%s' "$1" | { command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum; } \
    | awk '{print $1}'
}

_MEET_N=0
docgen_meetings() {
  [ "${#PERSONA_MEETINGS[@]}" -gt 0 ] || return 0
  _n=0; _back=1
  while [ "$_n" -lt "$MEETING_COUNT" ]; do
    _date="$(date_add "$TODAY" "-$_back")"
    if is_weekend "$_date"; then _back=$(( _back + 1 )); continue; fi
    _rec="${PERSONA_MEETINGS[$(( _n % ${#PERSONA_MEETINGS[@]} ))]}"
    _title="$(_safe_title "$(field 1 "$_rec")")"
    _MEET_N=$_n
    job_run "meet-$(slug "$_date-$_title")" \
      _gen_meeting "$VAULT/Resources/Meetings/$_date $_title.md" \
      "$_title" "$_date" "$(field 3 "$_rec")"
    _n=$(( _n + 1 ))
    _back=$(( _back + 2 ))
  done
  info "queued $MEETING_COUNT meeting note(s)"
}

# --------------------------------------------------- template-shape normalisers
#
# The plan notes have a fixed section skeleton -- it comes from Templates/, and the
# daily-plan and weekly-planning skills index into it by heading. Generation is
# reliable but not perfect: roughly one note in forty comes back missing a section.
# Rather than let that be a coin flip the fixture fails on, the skeleton is
# enforced here. Same division of labour as everywhere else: structure is bash's
# job, prose is the model's.

_normalize_daily() {  # <body_file> -- exactly Admin / Goals / Notes, in order
  awk '
    # `#*`, not `#+`: the heading occasionally comes back unprefixed ("Notes" on
    # its own line). Matching only hashed headings swallowed that line into the
    # previous section and then appended an empty one below it.
    /^#*[[:space:]]*Admin[[:space:]]*:?[[:space:]]*$/ { cur="admin"; next }
    /^#*[[:space:]]*Goals[[:space:]]*:?[[:space:]]*$/ { cur="goals"; next }
    /^#*[[:space:]]*Notes[[:space:]]*:?[[:space:]]*$/ { cur="notes"; next }
    { if (cur != "") buf[cur] = buf[cur] $0 "\n" }
    END {
      # Content before the first known heading is off-contract (usually a stray
      # title line) and is dropped rather than left to confuse a heading parser.
      printf "# Admin\n%s\n# Goals\n%s\n# Notes\n%s",
             buf["admin"], buf["goals"], buf["notes"]
    }
  ' "$1" > "$1.norm"
  # Collapse runs of blank lines, then guarantee exactly one trailing newline --
  # the body is about to be hashed into `tagged_hash`.
  awk 'NF==0 { if (blank++) next } NF { blank=0 } { print }' "$1.norm" > "$1.norm2"
  printf '%s\n' "$(cat "$1.norm2")" > "$1"
  rm -f "$1.norm" "$1.norm2"
}

_normalize_weekly() {  # <body_file> -- guarantee the three template sections exist
  for _sec in "# Weekly Goals" "# Admin" "# Personal"; do
    grep -qE "^#*[[:space:]]*${_sec#\# }[[:space:]]*:?[[:space:]]*$" "$1" || {
      # Append rather than reorder: the project-group sections below carry their
      # own meaningful order, and rewriting them would be a bigger intervention
      # than the problem warrants.
      printf '\n%s\n' "$_sec" >> "$1"
    }
  done
  printf '%s\n' "$(cat "$1")" > "$1.norm" && mv "$1.norm" "$1"
}

# ------------------------------------------------------------ phase 3: weeklies

_stub_weekly() {  # <body_out> <tags_out> <label>
  {
    printf '# Weekly Goals\n\n'
    persona_project_groups | sed 's/^/- **/;s/$/:** hold the line this week/'
    printf '\n# Admin\n- [ ] Inbox to zero `[P2]`\n- [x] Submit expenses `[P3]`\n'
    printf '\n# Personal\n- [ ] Book the thing `[P3]`\n'
    persona_project_groups | while IFS= read -r _g; do
      printf '\n# %s\n- [ ] Move the main workstream forward `[P1]`\n- [x] Clear last week'"'"'s follow-up `[P2]`\n' "$_g"
    done
  } > "$1"
  printf 'planning/weekly, planning\n' > "$2"
}

_gen_weekly() {  # <week_start>
  local _ws="$1" _we _label _year _out _s _pf _bf _tf _fm
  _we="$(date_add "$_ws" 6)"
  _label="Weekly Planning $(date_plan_label "$_ws") to $(date_plan_label "$_we")"
  _year="$(date_fmt "$_ws" '+%Y')"
  _out="$VAULT/Resources/Plans/$_year/Weekly/$_label.md"
  _s="$(slug "$_label")"
  _pf="$WORK/prompt-$_s.txt"; _bf="$WORK/body-$_s.md"; _tf="$WORK/tags-$_s.txt"
  _fm="$WORK/fm-$_s.txt"

  printf 'created: %s 06:%02d:00\n' "$_ws" $(( 10 + (_WEEK_N % 40) )) > "$_fm"

  {
    printf 'Write the weekly planning note for the week of %s through %s.\n\n' "$_ws" "$_we"
    cat <<'K'
This is the owner's own working plan, and it is parsed by their assistant, so the
structure is fixed:

- `# Weekly Goals` -- a short bulleted list, grouped in bold by project group,
  saying what would make the week a success. Prose bullets, not checkboxes.
- `# Admin` -- checkbox items for administrative chores
- `# Personal` -- checkbox items from life outside work
- One `# <Project Group>` section per project group listed below, in that order,
  each holding checkbox action items. Where a group has sub-projects, use `###
  <Sub-project>` subsections beneath it.

Every checkbox item under a project group, Admin or Personal must:
- be written as `- [ ]` for open or `- [x]` for already done -- about a third done
- end with a priority marker: `` `[P1]` `` (this week, non-negotiable),
  `` `[P2]` `` (should), or `` `[P3]` `` (nice to have)
- name something specific and consequential -- a decision, a person to unblock, a
  number to hit -- not "work on X"

Some items may carry an indented sub-bullet with detail. Do not add any section
that is not listed above. Start with `# Weekly Goals`.

K
    printf '## Project groups, in order\n'
    persona_project_groups | sed 's/^/- /'
    printf '\n'
    _i=0
    while [ "$_i" -lt "${#PERSONA_PROJECTS[@]}" ]; do
      printf -- '- Projects/%s -- %s\n' \
        "$(field 1 "${PERSONA_PROJECTS[$_i]}")" "$(field 3 "${PERSONA_PROJECTS[$_i]}")"
      _i=$(( _i + 1 ))
    done
    printf '\n'
    if [ -s "$WORK/recent-meetings.txt" ]; then
      printf '## Meetings from the preceding weeks -- draw follow-ups from these\n'
      sed 's/^/- /' "$WORK/recent-meetings.txt"
      printf '\n'
    fi
    persona_brief
    persona_contract
  } > "$_pf"

  llm_doc "$_pf" "$_bf" "$_tf" _stub_weekly "$_label"
  _normalize_weekly "$_bf"
  stamp_note "$_out" "$_bf" "project" "$(cat "$_tf")" "$(date_add "$_ws" 1)" "$_fm"
  rm -f "$_pf" "$_bf" "$_tf" "$_fm"
  note "wrote ${_out#"$VAULT/"}"
}

_WEEK_N=0
docgen_weeklies() {
  # Meeting titles feed the weekly plans' follow-up items, tying the two together
  # the way the weekly-planning skill expects.
  ls "$VAULT/Resources/Meetings" 2>/dev/null | sed 's/\.md$//' | sort \
    > "$WORK/recent-meetings.txt" || : > "$WORK/recent-meetings.txt"

  _n=0
  while [ "$_n" -lt "$WEEKLY_COUNT" ]; do
    _ws="$(week_start "$(date_add "$TODAY" "-$(( _n * 7 ))")")"
    _WEEK_N=$_n
    job_run "weekly-$_ws" _gen_weekly "$_ws"
    _n=$(( _n + 1 ))
  done
  jobs_drain
  ok "$WEEKLY_COUNT weekly plan(s)"
}

# ------------------------------------------------------------- phase 4: dailies

_stub_daily() {  # <body_out> <tags_out> <date>
  cat > "$1" <<STUB
# Admin
- [ ] Slack catch-up
- [x] Expense report
- [ ] Reply to the auditor

# Goals
- [ ] Move the top project item forward
- [x] Review the open decision doc
- [ ] Draft the follow-up note

# Notes
Offline stub for $3.
STUB
  printf 'planning, planning/daily\n' > "$2"
}

_gen_daily() {  # <date>
  local _d="$1" _year _out _s _pf _bf _tf _fm _wk _wkfile
  _year="$(date_fmt "$_d" '+%Y')"
  _out="$VAULT/Resources/Plans/$_year/Daily/$_d.md"
  _s="daily-$_d"
  _pf="$WORK/prompt-$_s.txt"; _bf="$WORK/body-$_s.md"; _tf="$WORK/tags-$_s.txt"
  _fm="$WORK/fm-$_s.txt"

  printf 'created: "%s 0%d:%02d"\n' "$_d" $(( 7 + (_DAY_N % 3) )) $(( 5 + (_DAY_N % 50) )) > "$_fm"

  _wk="$(week_start "$_d")"
  _wkfile="$(ls "$VAULT/Resources/Plans/$(date_fmt "$_wk" '+%Y')/Weekly/" 2>/dev/null \
             | grep -F "$(date_plan_label "$_wk") to" | head -1)"

  {
    printf 'Write the daily note for %s (%s).\n\n' "$_d" "$(date_fmt "$_d" '+%A')"
    cat <<'K'
It is a short triage list the owner writes each morning, derived from that week's
plan. Exactly three sections, in this order, and nothing else:

- `# Admin` -- 3-6 checkbox items: small chores, messages owed, scheduling
- `# Goals` -- 3-6 checkbox items: the substantive work for today, pulled from the
  week's open P1 items below
- `# Notes` -- two or three lines of terse running commentary written during the
  day: what actually happened, what slipped, one thing that surprised them. Prose,
  not checkboxes.

Roughly half the checkboxes should be `- [x]`, since this note was written in the
morning and worked through during the day. No priority markers here -- those live
in the weekly plan. Short: under 250 words. No `# ` title line beyond the three
section headings; start directly with `# Admin`.

K
    if [ -n "$_wkfile" ] && [ -f "$VAULT/Resources/Plans/$(date_fmt "$_wk" '+%Y')/Weekly/$_wkfile" ]; then
      printf '## This week'"'"'s plan -- pull today'"'"'s Goals from its open items\n\n'
      sed -n '/^---$/,/^---$/!p' \
        "$VAULT/Resources/Plans/$(date_fmt "$_wk" '+%Y')/Weekly/$_wkfile" \
        | grep -E '^(#|- \[)' | head -60
      printf '\n'
    fi
    persona_brief
    persona_contract
  } > "$_pf"

  llm_doc "$_pf" "$_bf" "$_tf" _stub_daily "$_d"
  _normalize_daily "$_bf"
  stamp_note "$_out" "$_bf" "daily-note" "$(cat "$_tf")" "$(date_add "$_d" 1)" "$_fm"
  rm -f "$_pf" "$_bf" "$_tf" "$_fm"
  note "wrote ${_out#"$VAULT/"}"
}

_DAY_N=0
docgen_dailies() {
  _n=0; _back=0
  while [ "$_n" -lt "$DAILY_COUNT" ]; do
    _d="$(date_add "$TODAY" "-$_back")"
    if is_weekend "$_d"; then _back=$(( _back + 1 )); continue; fi
    _DAY_N=$_n
    job_run "daily-$_d" _gen_daily "$_d"
    _n=$(( _n + 1 )); _back=$(( _back + 1 ))
  done
  jobs_drain
  ok "$DAILY_COUNT daily note(s)"
}
