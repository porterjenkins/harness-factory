# shellcheck shell=bash
# Hydrate the five root configuration documents.
#
# The rule, inherited from tests/README.md: STRUCTURE IS WRITTEN BY BASH AND IS
# EXACT; PROSE IS GENERATED. Every planning skill parses SOURCES.md's two tables,
# CLAUDE.md's project enumeration and PRIORITIES.md's ranked list. A model that
# writes a four-column table with three columns, or renames a role, breaks those
# skills silently and at a distance.
#
# So the model writes each document, and then `_splice` overwrites the parsed
# sections with canonical text built from the template. Splicing after the fact
# rather than asking the model to reproduce a block verbatim is what makes the
# guarantee real instead of hoped-for -- the model is never trusted with a
# structure, only with the prose around it.
#
# Source after common.sh, llm.sh and template.sh.

[ -n "${_CATALYST_HYDRATE_SH:-}" ] && return 0
_CATALYST_HYDRATE_SH=1

# llm.sh's default system prompt tells the model everything it writes is fiction --
# correct for a sandbox fixture, actively wrong here. This is a real vault for a
# real person.
LLM_SYSTEM_PROMPT='You are writing configuration and instruction documents for a
real person'"'"'s personal knowledge vault, from a filled-in intake template. Follow
the output contract in the prompt exactly. Emit only the document -- no preamble,
no commentary, no explanation of what you did, and never wrap the whole document
in a code fence. Write as the vault owner wrote it for their own assistant:
direct, specific, and willing to explain why a rule exists, because a rule whose
reason is not recorded gets broken later. Invent no facts about the person beyond
what the brief gives you.'

# ------------------------------------------------------------------- splicing

# _splice <file> <heading-line> <content-file>
#
# Replace the body under an exact heading with canonical content, or append the
# whole section when the model omitted it. Ends at the next heading of the same or
# higher level, so splicing `# Projects` does not swallow `# Areas`.
_splice() {
  _sp_f="$1"; _sp_h="$2"; _sp_c="$3"
  _sp_lvl="$(printf '%s' "$_sp_h" | awk '{ n=0; while (substr($0,n+1,1)=="#") n++; print n }')"
  awk -v h="$_sp_h" -v cf="$_sp_c" -v lvl="$_sp_lvl" '
    function emit(  line) { while ((getline line < cf) > 0) print line; close(cf); print "" }
    BEGIN { found = 0; skip = 0 }
    {
      if (!skip && $0 == h) { print; emit(); found = 1; skip = 1; next }
      if (skip) {
        # A heading at the same level or higher ends the spliced section.
        if ($0 ~ /^#+[[:space:]]/) {
          n = 0; while (substr($0, n + 1, 1) == "#") n++
          if (n <= lvl) { skip = 0; print }
          next
        }
        next
      }
      print
    }
    END { if (!found) { print ""; print h; emit() } }
  ' "$_sp_f" > "$_sp_f.spliced" && mv "$_sp_f.spliced" "$_sp_f"
}

# _strip_section <file> <heading-line>
#
# Delete a heading and its body outright. Asked for `# Projects`, models reliably
# also write their own `## Projects` further up, leaving the vault with two
# Projects sections that disagree -- and weekly-planning reads its H1 section
# headers out of this file. The duplicate is removed before the canonical one is
# spliced in.
_strip_section() {
  _ss_f="$1"; _ss_h="$2"
  _ss_lvl="$(printf '%s' "$_ss_h" | awk '{ n=0; while (substr($0,n+1,1)=="#") n++; print n }')"
  awk -v h="$_ss_h" -v lvl="$_ss_lvl" '
    BEGIN { skip = 0 }
    {
      if (!skip && $0 == h) { skip = 1; next }
      if (skip) {
        if ($0 ~ /^#+[[:space:]]/) {
          n = 0; while (substr($0, n + 1, 1) == "#") n++
          if (n <= lvl) { skip = 0; print }
          next
        }
        next
      }
      print
    }
  ' "$_ss_f" > "$_ss_f.stripped" && mv "$_ss_f.stripped" "$_ss_f"
}

# --------------------------------------------------------- canonical structures

# The role registry. Every role the template names gets a row, including the ones
# set to `none` -- a disconnected role must be visible, because the skills promise
# to name what they skipped rather than silently omit it.
_hyd_roles_table() {
  cat <<'EOF'

Which external sources the skills may read, and what fills each role. Skills
resolve roles from this table at run time instead of hardcoding a product name,
so swapping a tool is an edit here rather than a rewrite of every skill.

- A role set to `none` is **skipped and named in the skill's output**, never
  silently omitted.
- A row naming a tool that is not present in the current session is **stale**: the
  skill treats it as `none` for that run and says so, rather than substituting a
  different tool.
- A row can be **partial** — connected but degraded. Say so in `notes`, including
  what is lost, so skills can report the gap accurately.
- Skills write confirmed answers back here so they stop re-asking. Consent
  decisions get recorded in `notes` with the date.

| role | source | notes |
| --- | --- | --- |
EOF
  tmpl_roles | while IFS='|' read -r _r _s _n; do
    [ -n "$_r" ] || continue
    # A literal pipe in a notes cell would add a column and break the table for
    # every reader; markdown wants it backslash-escaped.
    _n="$(printf '%s' "$_n" | sed 's/|/\\|/g')"
    printf '| %s | %s | %s |\n' "$_r" "$_s" "$_n"
  done
}

# What a given skill pulls from a given role, and where it lands. The arrow is
# load-bearing: for a role a skill has no bespoke step for, this cell is the whole
# instruction, so it must read as `<what to pull> → <where it lands>`.
_hyd_contributes() {
  case "$1:$2" in
    daily-plan:chat)          printf 'messages awaiting a reply → `# Communication`' ;;
    daily-plan:email)         printf 'unanswered mail addressed to them, vendor noise filtered → `# Communication`' ;;
    daily-plan:web)           printf 'current events from `# External Sources` + vault-derived searches → `# News`' ;;
    daily-plan:vault)         printf 'unchecked items from the current weekly plan → task sections' ;;
    daily-plan:calendar)      printf "today's commitments → task sections" ;;
    daily-plan:meetings)      printf "yesterday's action items → task sections" ;;
    weekly-planning:calendar) printf 'upcoming commitments → Weekly Goals + prep-work candidates' ;;
    weekly-planning:meetings) printf 'action items from the week just past → candidate pool' ;;
    weekly-planning:vault)    printf 'carried-over items, recent Daily notes → candidate pool' ;;
    weekly-planning:issues)   printf 'assigned tickets and status changes → candidate pool' ;;
    weekly-planning:chat)     printf 'commitments made in conversation → candidate pool' ;;
    meeting-prep:calendar)    printf 'attendees, cadence, the next occurrence → agenda frontmatter' ;;
    meeting-prep:issues)      printf 'tickets, status updates, comments → agenda clusters' ;;
    meeting-prep:chat)        printf 'recent discussion in the relevant channels → agenda clusters' ;;
    meeting-prep:meetings)    printf 'notes from the last occurrence, open follow-ups → agenda clusters' ;;
    meeting-prep:second-vault) printf 'team or company docs on the topic → agenda clusters' ;;
    meeting-prep:vault)       printf 'project notes in the scope and horizon → agenda clusters' ;;
    memory:code)              printf 'commits, branches, review activity → `MEMORY.md`' ;;
    memory:vault)             printf 'the week'"'"'s notes, plans and meetings → `MEMORY.md`' ;;
    prioritization-reranker:vault) printf '`PRIORITIES.md`, recent Daily notes → priority tag + `P(completion)`' ;;
    doc-retrieval:vault)      printf 'note bodies, tags and links → search results' ;;
    tag-lint:vault)           printf 'the tag vocabulary and its counts → merge recommendations' ;;
    log-manager:vault)        printf '`.system/log/log-YYYY-MM.csv` → recent-activity answers' ;;
    *:vault)                  printf 'notes in scope → the skill'"'"'s output' ;;
    *)                        printf 'recent activity in scope → the skill'"'"'s output' ;;
  esac
}

# `vault` is the only role a skill can assume; everything else may be `none`.
_hyd_required() { [ "$1" = "vault" ] && printf 'always' || printf 'optional'; }

_hyd_whoreads_table() {
  cat <<'EOF'

The lookup skills resolve at run time — not documentation of what a skill
hardcodes. `daily-plan`, `meeting-prep` and `weekly-planning` carry no role list
of their own: they read their rows here, resolve each against the registry above,
and handle any role they have no bespoke step for by following its `contributes`
arrow. Adding a source to a skill is a line here and no skill edit.

`contributes` is written as `<what to pull> → <where it lands>`. That arrow is
load-bearing: for a role a skill has no bespoke step for, it is the whole
instruction — the skill pulls what the left side names, scoped to the run's date
range, and writes it where the right side points.

| skill | role | contributes | required |
| --- | --- | --- | --- |
EOF
  # System skills read the vault and nothing else.
  tmpl_records skills__system | cut -d'|' -f1 | while read -r _sk; do
    [ -n "$_sk" ] || continue
    printf '| `%s` | `vault` | %s | always |\n' "$_sk" "$(_hyd_contributes "$_sk" vault)"
  done
  # User skills read the vault plus whatever roles the template gave them.
  tmpl_records skills__user | cut -d'|' -f1 | while read -r _sk; do
    [ -n "$_sk" ] || continue
    printf '| `%s` | `vault` | %s | always |\n' "$_sk" "$(_hyd_contributes "$_sk" vault)"
    _srcs="$(tmpl_attr skills__user "$_sk" Sources)"
    # `|| true`: a skill whose `Sources:` is blank -- the state every unfilled
    # template ships in -- makes this grep match nothing and exit 1, which under
    # `set -o pipefail` aborts the entire build with no message.
    { printf '%s' "$_srcs" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      | grep -v '^$' || true; } | while read -r _role; do
        [ "$_role" = "vault" ] && continue
        printf '| `%s` | `%s` | %s | %s |\n' \
          "$_sk" "$_role" "$(_hyd_contributes "$_sk" "$_role")" "$(_hyd_required "$_role")"
      done
  done
}

# CLAUDE.md's project enumeration. weekly-planning and daily-plan read their H1
# section headers out of this list, so the names here and the folders under
# Projects/ must agree exactly.
_hyd_projects_block() {
  printf '\n- Active, outcome-bearing work — one folder per project under `Projects/`\n'
  printf -- '- The dividing line against `Areas/` is whether the work can be *finished*.\n'
  printf -- '- Projects include:\n'
  tmpl_records projects | while IFS='|' read -r _n _k _d; do
    [ -n "$_n" ] || continue
    printf -- '\t- `%s`\n' "$_n"
    [ -n "$_d" ] && printf -- '\t\t- %s\n' "$_d"
    tmpl_children projects "$_n" | while IFS='|' read -r _cn _ck _cd; do
      [ -n "$_cn" ] || continue
      printf -- '\t\t- `%s`' "$_cn"
      if [ -n "$_cd" ]; then printf ' — %s\n' "$_cd"
      elif [ -n "$_ck" ]; then printf ' — %s\n' "$_ck"
      else printf ' is a subproject of `%s`\n' "$_n"; fi
    done
  done
}

_hyd_areas_block() {
  printf '\n- Ongoing responsibilities with no completion date — maintained at a standard rather than finished\n'
  if [ -z "$(tmpl_area_names)" ]; then
    printf -- '- Currently empty. Add subfolders as needed.\n'
  else
    printf -- '- Areas include:\n'
    tmpl_records areas | while IFS='|' read -r _n _k _d; do
      [ -n "$_n" ] || continue
      _ad="${_d:-$_k}"
      printf -- '\t- `%s`' "$_n"
      [ -n "$_ad" ] && printf ' — %s' "$_ad"
      printf '\n'
    done
  fi
  printf -- '- If a folder here acquires a deadline and a definition of done, it belongs in `Projects/` instead\n'
}

_hyd_priorities_block() {
  printf '\n'
  _i=1
  tmpl_numbered priorities | while read -r _p; do
    [ -n "$_p" ] || continue
    printf '%s. %s\n' "$_i" "$_p"
    _i=$(( _i + 1 ))
  done
}

# External Sources feeds the daily-plan News step. Two grammars, and the
# difference matters: a bare URL is fetched, a nested entry is a standing search.
_hyd_external_block() {
  printf '\n'
  printf 'A **bare URL** is a page to fetch; an entry nested under `Web Search:` is a\n'
  printf 'standing search directive, not a feed to retrieve.\n\n'
  _ext="$(tmpl_records connectors__external-notes | cut -d'|' -f1 | grep -v '^none$' || true)"
  if [ -n "$_ext" ]; then
    printf '%s\n' "$_ext" | while read -r _e; do
      [ -n "$_e" ] && printf -- '- %s\n' "$_e"
    done
  else
    printf -- '- Web Search:\n'
    tmpl_records projects | cut -d'|' -f1 | while read -r _p; do
      [ -n "$_p" ] && printf -- '\t- news relevant to %s\n' "$_p"
    done
  fi
}

# ------------------------------------------------------------------ generators

# The invariants a generated CLAUDE.md must state. These are the vault's actual
# contract with the assistant: drop one and the corresponding skill breaks exactly
# as it would in a real vault. build-verify.sh asserts each concept is present.
_hyd_claude_facts() {
  cat <<'EOF'

## Facts this document MUST state (in your own words, woven into the prose)

1. The vault is organised with PARA: `Projects/` for active work with an outcome
   and an end, `Areas/` for ongoing responsibilities with no end date,
   `Resources/` for reference material, `Archive/` for anything inactive. The
   dividing line between Projects and Areas is whether the work can be finished.
2. Vault machinery sits outside PARA: `Skills/`, `Routines/`, `Templates/`,
   `Clippings/`, and `.system/`.
3. `.system/` is dot-prefixed deliberately: Obsidian ignores dot folders entirely
   and Obsidian Sync skips them, which gets the machinery excluded from both
   indexing and sync with no configuration to maintain. Note that git and Google
   Drive do NOT skip dotfolders and need explicit ignore rules.
4. All executable code lives in `.system/`. `Skills/` holds instructions for an
   agent to follow; `.system/` holds programs that run unattended.
5. What an agent may read or write is enforced externally by Claude Code's own
   permission settings (`.claude/settings*.json`), NOT by tags in this file.
   Say this explicitly.
6. `.system/wiki/manifest.sqlite` holds change-detection state only — body hashes,
   sizes, mtimes, tagging status. No tags, no content. It is excluded from sync
   and from git, and is disposable: rebuildable from frontmatter. Never hand-edit
   it.
7. `.system/.env` is the single config file for every connector, namespaced by the
   connector that owns them (`GRANOLA_API_KEY`, ...). Wrappers load it
   prefix-filtered, so a bug in one connector never sees another's credentials.
   The prefix convention is load-bearing, not cosmetic.
8. Never hardcode an absolute path. Scripts derive the vault root from their own
   location; launchd plists are rendered from `.template` files at install time.
9. The action log is `.system/log/log-YYYY-MM.csv`, append-only, rotated monthly,
   pipe-delimited with fields `timestamp|action|path|summary`. Summaries must be
   single-line. Read it only with `tail`, `head` or `grep` — never in full.
10. Search runs through the Obsidian CLI against the running Obsidian app. Always
    pass `vault=<vault-name>` as the FIRST parameter, where the vault name is this
    vault folder's basename. Never pass `open` or `newtab` in automation. For
    fuzzy questions, run 3–5 varied lexical queries and rank by how many hit each
    path.
11. The ingestion pipeline writes two frontmatter keys that must never be
    hand-edited or stripped: `tagged` (date of the last tagger pass) and
    `tagged_hash` (body hash as of that pass). `domain` is derived from the folder
    path and is never stored in frontmatter.
12. `Resources/Meetings/` is read-only to agents — auto-exported notes must never
    be clobbered — and agent-authored agendas go in `Resources/Agendas/` instead.
13. Root documents beside this one: `USER.md` (who the user is),
    `PRIORITIES.md` (what they want prioritised now), `SOURCES.md` (which external
    sources are connected and what fills each role), `MEMORY.md` (the evolving
    model of the user, revised in place, kept under ~200 lines).
EOF
}

# Record a stub fallback. Falling back is correct when the model is unreachable,
# but doing it SILENTLY on a live build is how four generated documents came back
# as canned text and still passed verification. job_run bodies are subshells, so
# this is tracked in a file rather than a counter.
_hyd_stub() {
  _fn="$1"; _out="$2"; _label="$3"
  "$_fn" "$_out"
  [ "$LLM_OFFLINE" = "1" ] || printf '%s\n' "$_label" >> "$WORK/stubbed"
}

_stub_claude_md() {
  cat > "$1" <<'EOF'
# Knowledge Base Architecture

The vault is organized with PARA: `Projects/` for active work with an outcome and
an end, `Areas/` for ongoing responsibilities with no end date, `Resources/` for
reference material, and `Archive/` for anything inactive. The dividing line
between Projects and Areas is whether the work can be *finished*.

Vault machinery sits outside PARA: `Skills/`, `Routines/`, `Templates/`,
`Clippings/`, and `.system/`.

What an agent may read or write is enforced externally by Claude Code's own
permission settings (`.claude/settings*.json`), not by tags in this file.

## `.system/`

Dot-prefixed deliberately: Obsidian ignores dot folders entirely, and Obsidian
Sync skips hidden files and folders too. Git and Google Drive do not — those need
explicit ignore rules. All executable code lives here. `Skills/` holds
instructions for an agent to follow; `.system/` holds programs that run
unattended.

- `wiki/manifest.sqlite` — change-detection state only: body hashes, sizes,
  mtimes, tagging status. No tags, no content. Excluded from sync and git, and
  disposable. Never hand-edit it.
- `.env` — the single config file for every connector, namespaced by the connector
  that owns each variable. Wrappers load it prefix-filtered, so one connector never
  sees another's credentials. The prefix convention is load-bearing.
- `log/log-YYYY-MM.csv` — append-only action log, pipe-delimited:
  `timestamp|action|path|summary`. Summaries are single-line. Read it with `tail`,
  `head` or `grep` only.

Never hardcode an absolute path. Scripts derive the vault root from their own
location, and launchd plists are rendered from `.template` files at install time.

## Search & Retrieval

Search runs through the Obsidian CLI against the running Obsidian app. Always pass
`vault=<vault-name>` as the first parameter — the vault folder's basename.
Obsidian must be running. Never pass `open` or `newtab` in automation. For
conceptual questions, run 3–5 deliberately varied queries and rank by how many
hit each path.

## Frontmatter written by the pipeline

Do not strip or hand-edit these: `tagged` (date of the last tagger pass) and
`tagged_hash` (body hash as of that pass). `domain` is derived from folder path
and is never stored in frontmatter.

## Root documents

`USER.md` is who the user is. `PRIORITIES.md` is what they want prioritized now.
`SOURCES.md` is which external sources are connected and what fills each role.
`MEMORY.md` is the evolving model of the user, revised in place and kept under
~200 lines.

# Projects

# Areas

# Resources

Reference material consulted across projects. `Resources/Plans/{year}/` holds
daily and weekly planning notes. `Resources/Meetings/{year}/` is **read-only to
agents** — auto-exported notes must never be clobbered. Agent-authored agendas go
to `Resources/Agendas/{year}/` instead.

# Archive

Grouped by year. Moving a note here is not deletion: it stays indexed, tagged and
searchable.
EOF
}

_gen_claude_md() {
  _prompt="$WORK/prompt-claude.txt"; _body="$WORK/body-claude.md"
  {
    cat <<'HDR'
Write the `CLAUDE.md` for a personal Obsidian knowledge vault. This is the
operating manual the AI assistant reads at the start of every session: it defines
the directory structure, how search works, and which rules exist and why.

Write it as the vault owner wrote it for their own assistant -- direct, specific,
and willing to explain *why* a rule exists, because a rule whose reason is not
recorded gets broken later. Structure it with Markdown headings. 900-1400 words.
Start with `# Knowledge Base Architecture`.

Include `# Projects` and `# Areas` as top-level (single-`#`) headings with a
one-line intro each; their contents are filled in mechanically afterward, so do
not enumerate the projects yourself. Do NOT also write a `## Projects` or
`## Areas` subsection anywhere else in the document -- exactly one section per
name. Also include `# Resources` and `# Archive` sections.

HDR
    template_brief
    _hyd_claude_facts
    cat <<'FOOT'

Output contract: emit the document and nothing else. No YAML frontmatter, no outer
code fence, no preamble, no sign-off.
FOOT
  } > "$_prompt"

  if [ "$LLM_OFFLINE" = "1" ] || ! llm_raw "$_prompt" "$_body" "CLAUDE.md" 800; then
    _hyd_stub _stub_claude_md "$_body" CLAUDE.md
  fi

  # CLAUDE.md carries no frontmatter and is excluded from tagging
  # (WIKI_EXCLUDED_FILES defaults to "CLAUDE.md,README.md"), so it is written
  # straight out rather than stamped.
  cp "$_body" "$VAULT/CLAUDE.md"
  _hyd_projects_block > "$WORK/blk-projects.md"
  _hyd_areas_block    > "$WORK/blk-areas.md"
  for _dup in "## Projects" "## Areas" "### Projects" "### Areas"; do
    _strip_section "$VAULT/CLAUDE.md" "$_dup"
  done
  _splice "$VAULT/CLAUDE.md" "# Projects" "$WORK/blk-projects.md"
  _splice "$VAULT/CLAUDE.md" "# Areas"    "$WORK/blk-areas.md"
}

_stub_user_md() {
  {
    printf '# %s\n\n' "$(tmpl_kv "$TMPL_USER" Name)"
    _pp="$(tmpl_prose "$TMPL_USER")"
    [ -n "$_pp" ] && printf '%s\n\n' "$_pp"
    printf '## Professional\n\n### Current roles\n\n'
    tmpl_records projects | while IFS='|' read -r _n _k _d; do
      [ -n "$_n" ] || continue
      printf -- '- **%s**' "$_n"
      [ -n "$_k" ] && printf ' (%s)' "$_k"
      [ -n "$_d" ] && printf ' — %s' "$_d"
      printf '\n'
    done
    printf '\n### Shorthand\n\n'
    tmpl_children "$TMPL_USER" Shorthand | cut -d'|' -f1 | while read -r _s; do
      [ -n "$_s" ] || continue
      _abbr="$(printf '%s' "${_s%%=*}" | sed 's/[[:space:]]*$//')"
      _exp="$(printf '%s' "${_s#*=}" | sed 's/^[[:space:]]*//')"
      printf -- '- **%s** = %s\n' "$_abbr" "$_exp"
    done
  } > "$1"
}

_gen_user_md() {
  _prompt="$WORK/prompt-user.txt"; _body="$WORK/body-user.md"
  {
    cat <<'HDR'
Write the `USER.md` for a personal knowledge vault: the file the AI assistant
reads at the start of every session to know who it is working for. Written by the
owner about themselves, in first person where natural.

Cover, using Markdown headings: who they are and what they do now; their current
roles and what each actually demands of them; how they prefer to work (writing
style, planning cadence, what they find useless); and a `### Shorthand` section
expanding the abbreviations they use in their own notes, one per line in the form
`- **ABBR** = expansion`.

600-900 words. Concrete over flattering -- include what they are impatient with.
Start with a `# ` heading that is their name. Use only what the brief gives you;
invent no biography.

HDR
    template_brief
    cat <<'FOOT'

Output contract: emit the document and nothing else. No YAML frontmatter, no outer
code fence, no preamble.
FOOT
  } > "$_prompt"

  if [ "$LLM_OFFLINE" = "1" ] || ! llm_raw "$_prompt" "$_body" "USER.md" 500; then
    _hyd_stub _stub_user_md "$_body" USER.md
  fi
  stamp_note "$VAULT/USER.md" "$_body" "person" "person,knowledge-base" ""
}

# SOURCES.md is a registry, not an essay: two machine-parsed tables and a list,
# wrapped in rules that are identical across every vault. Splicing model prose
# around them bought nothing and cost a real hazard -- a level-1 splice of
# `# Connected sources` swallows its own `## Who reads what` child. So the whole
# document is assembled here, deterministically, and no model call is made.
_gen_sources_md() {
  _body="$WORK/body-sources.md"
  {
    printf '# Connected sources\n'
    _hyd_roles_table
    printf '\n## Who reads what\n'
    _hyd_whoreads_table
    cat <<'EOF'

### Adding a source to a skill

Two pasted rows and no skill edit: one in the registry above naming what fills
the role, one in `Who reads what` naming which skill reads it and what it
contributes. A role with no row gets asked about at run time, not guessed at.

Keep this current when adding a skill — it is also how you tell what breaks if a
source goes away.
EOF
    printf '\n# External Sources\n'
    _hyd_external_block
  } > "$_body"
  stamp_note "$VAULT/SOURCES.md" "$_body" "architecture" "architecture,knowledge-base,sources" ""
  ok "SOURCES.md assembled ($(tmpl_roles | wc -l | tr -d ' ') roles)"
}

_stub_priorities_md() {
  {
    printf '# Current priorities\n\n'
    printf '# Standing Obligation\n\n'
    printf -- '- Weekly planning session, start of the week.\n'
    printf -- '- Daily triage each working morning.\n\n'
    printf '## Not right now\n\n'
    printf -- '- Anything without an owner or a date.\n\n'
    printf '# General rules\n\n'
    printf -- '- A commitment made to another person outranks one made only to yourself.\n'
    printf -- '- Work due this week outranks work that is merely important.\n'
    printf -- '- An item that maps to a calendar block is likelier to get done than one that does not.\n'
    printf -- '- Protect the first working hour; do not schedule reactive work into it.\n'
    printf -- '- When two items tie, prefer the one that unblocks somebody else.\n'
  } > "$1"
}

_gen_priorities_md() {
  _prompt="$WORK/prompt-priorities.txt"; _body="$WORK/body-priorities.md"
  {
    cat <<'HDR'
Write `PRIORITIES.md` for a personal knowledge vault: what this person wants
prioritised right now. The `prioritization-reranker` skill reads it fresh on every
run to assign P1/P2/P3 tags to action items, so it must be specific enough to
rank against.

Use exactly these headings, in this order:

# Current priorities
# Standing Obligation
## Not right now
# General rules

`# Current priorities` is filled in mechanically afterward -- write only a
one-line introduction under it and no list. Under `# Standing Obligation`, list
recurring commitments with their cadence in prose. Under `## Not right now`, list
what is explicitly deferred. Under `# General rules`, give 4-6 prioritisation
heuristics this person would actually endorse, drawn from the brief -- things like
what beats what when two items collide, and what deserves protected time.

250-450 words.

HDR
    template_brief
    _pl="$(tmpl_numbered priorities)"
    [ -n "$_pl" ] && printf 'Their ranked priorities, for context (do not restate as a list):\n%s\n\n' "$_pl"
    cat <<'FOOT'
Output contract: emit the document and nothing else. No YAML frontmatter, no outer
code fence, no preamble.
FOOT
  } > "$_prompt"

  if [ "$LLM_OFFLINE" = "1" ] || ! llm_raw "$_prompt" "$_body" "PRIORITIES.md" 200; then
    _hyd_stub _stub_priorities_md "$_body" PRIORITIES.md
  fi
  stamp_note "$VAULT/PRIORITIES.md" "$_body" "concept" "planning,priorities,knowledge-base" ""

  _hyd_priorities_block > "$WORK/blk-priorities.md"
  _splice "$VAULT/PRIORITIES.md" "# Current priorities" "$WORK/blk-priorities.md"
}

_stub_memory_md() {
  {
    printf '# Memory\n\n## Current context\n\n'
    tmpl_records projects | while IFS='|' read -r _n _k _d; do
      [ -n "$_n" ] || continue
      printf '### %s' "$_n"
      [ -n "$_k" ] && printf ' — %s' "$_k"
      printf '\n\n'
      [ -n "$_d" ] && printf '**Goal:** %s\n\n' "$_d"
      printf '**State (%s):** newly created vault; nothing observed yet.\n\n' "$TODAY"
    done
    printf '## Working preferences\n\n## Projects\n\n## Areas\n\n'
    printf '## Achievements\n\n## Goals & commitments\n\n## Recurring friction\n\n'
    printf '## Changelog\n\n- **%s** — vault created from the implementation template.\n' "$TODAY"
  } > "$1"
}

_gen_memory_md() {
  _prompt="$WORK/prompt-memory.txt"; _body="$WORK/body-memory.md"
  {
    cat <<'HDR'
Write the initial `MEMORY.md` for a personal knowledge vault: the single evolving
model of the user, read at the start of every session and revised in place rather
than appended to.

Use exactly these H2 sections, in exactly this order -- the `memory` routine
asserts the order:

# Memory
## Current context
## Working preferences
## Projects
## Areas
## Achievements
## Goals & commitments
## Recurring friction
## Changelog

Under `## Current context`, write one `### <Project>` block per project from the
brief, each with a bolded `**Goal:**` line and a `**State:**` line. This is a
brand-new vault, so state honestly that nothing has been observed yet rather than
inventing progress. Under `## Working preferences`, record how they want to be
worked with, from the brief. Leave `## Achievements`, `## Goals & commitments` and
`## Recurring friction` present but nearly empty -- a line saying they fill in as
evidence accumulates. End `## Changelog` with a single dated bullet noting the
vault was created.

Under 200 lines. Invent nothing not in the brief.

HDR
    template_brief
    cat <<'FOOT'

Output contract: emit the document and nothing else. No YAML frontmatter, no outer
code fence, no preamble.
FOOT
  } > "$_prompt"

  if [ "$LLM_OFFLINE" = "1" ] || ! llm_raw "$_prompt" "$_body" "MEMORY.md" 300; then
    _hyd_stub _stub_memory_md "$_body" MEMORY.md
  fi
  # `updated` is machine-parsed: the memory routine resolves its gather window
  # from this date through today, capped at 30 days.
  printf 'updated: %s\n' "$TODAY" > "$WORK/fm-memory.txt"
  stamp_note "$VAULT/MEMORY.md" "$_body" "concept" "memory,knowledge-base" "" "$WORK/fm-memory.txt"
}

# ---------------------------------------------------------------- entry point

hydrate_configs() {
  job_run "CLAUDE.md"     _gen_claude_md
  job_run "USER.md"       _gen_user_md
  job_run "PRIORITIES.md" _gen_priorities_md
  job_run "MEMORY.md"     _gen_memory_md
  jobs_drain
  _gen_sources_md          # deterministic, no model call
  if [ -s "$WORK/stubbed" ]; then
    warn "these documents fell back to canned stubs instead of being generated:"
    sed 's/^/        /' "$WORK/stubbed" >&2
    warn "the vault is structurally valid but its prose is generic. Check that"
    warn "\`claude -p\` works, then re-run -- generation is cached, so it is cheap."
  else
    ok "five root documents written"
  fi
}
