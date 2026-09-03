# shellcheck shell=bash
# Vault skeleton: PARA directories, the two root instruction documents, and the
# machinery files a skill expects to find.
#
# The split here is deliberate. Anything a skill *parses* -- frontmatter keys, the
# sources.md table, the log's field order, plan filenames -- is written by bash and
# is exact. Anything a skill *reads as prose* -- CLAUDE.md, USER.md, note bodies --
# is generated, so tests exercise wording the author did not choose.
#
# Source after common.sh, llm.sh and persona.sh.

[ -n "${_CATALYST_SCAFFOLD_SH:-}" ] && return 0
_CATALYST_SCAFFOLD_SH=1

scaffold_dirs() {
  _year="$(date_fmt "$TODAY" '+%Y')"
  _prev=$(( _year - 1 ))

  mkdir -p \
    "$VAULT/Projects" \
    "$VAULT/Areas" \
    "$VAULT/Resources/Meetings" \
    "$VAULT/Resources/Plans/$_year/Daily" \
    "$VAULT/Resources/Plans/$_year/Weekly" \
    "$VAULT/Archive/$_prev" \
    "$VAULT/Clippings" \
    "$VAULT/Skills" \
    "$VAULT/Routines" \
    "$VAULT/Templates" \
    "$VAULT/.claude" \
    "$VAULT/.obsidian" \
    "$VAULT/.system/log/run-logs" \
    "$VAULT/.system/wiki" \
    "$VAULT/.system/connectors" \
    "$VAULT/.system/vault-bundle"

  persona_project_paths | while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    mkdir -p "$VAULT/Projects/$_p/sources"
  done

  _i=0
  while [ "$_i" -lt "${#PERSONA_AREAS[@]}" ]; do
    mkdir -p "$VAULT/Areas/$(field 1 "${PERSONA_AREAS[$_i]}")"
    _i=$(( _i + 1 ))
  done

  ok "directory skeleton ($(find "$VAULT" -type d | wc -l | tr -d ' ') dirs)"
}

# ------------------------------------------------------- CLAUDE.md and USER.md

# The invariants a generated CLAUDE.md must state. These are the vault's actual
# contract with the assistant: change one here and the corresponding skill breaks
# in the sandbox exactly as it would in a real vault, which is the point.
_scaffold_claude_facts() {
  _year="$(date_fmt "$TODAY" '+%Y')"
  cat <<FACTS
Facts the document MUST state (all of them, in your own prose and ordering):

1. The vault is organised with PARA: \`Projects/\` for active work with an outcome
   and an end; \`Areas/\` for ongoing responsibilities with no end date;
   \`Resources/\` for reference material consulted across projects; \`Archive/\`
   for anything inactive, grouped as \`Archive/{year}/\`. The test for
   Projects-vs-Areas is whether the work can be finished.
2. Vault machinery sits outside PARA at the root and is infrastructure, not
   knowledge: \`Skills/\`, \`Routines/\`, \`Templates/\`, \`Clippings/\`, \`.system/\`.
3. Every directory carries exactly one access tag, and the document must define
   all three: \`ai-read-only\` (agent may read, never write),
   \`ai-read-frontmatter-only\` (agent may read anything but may only add
   frontmatter, properties, tags and connections), \`ai-read-write\` (agent may
   create files and edit any part of existing ones).
4. \`.system/\` is \`ai-read-write\`, dot-prefixed so Obsidian and Obsidian Sync
   ignore it entirely. All executable code lives there; \`Skills/\` holds
   instructions for an agent to follow, \`.system/\` holds programs that run
   unattended. It contains \`wiki/\` (the ingestion pipeline and its
   \`manifest.sqlite\`, which is disposable, per-machine, and never synced or
   hand-edited), \`connectors/\`, \`vault-bundle/\`, \`log/\`, and \`sources.md\`.
5. Never hardcode an absolute path: scripts derive the vault root from their own
   location.
6. The action log is \`.system/log/log-YYYY-MM.csv\`, append-only, rotated
   monthly, pipe-delimited with fields \`timestamp|action|path|summary\`. The
   summary must be single-line. It is appended one line per action, not per run,
   and read only with \`tail\`, \`head\` or \`grep\` -- never in full.
7. Frontmatter written by the ingestion pipeline must never be stripped or
   hand-edited: \`tagged\` (date of the last tagger pass) and \`tagged_hash\`
   (body hash as of that pass). \`domain\` is derived from the folder path and is
   never stored in frontmatter.
8. Search runs through the Obsidian CLI against the running Obsidian app. There is
   no vector or semantic search. Always pass \`vault=<vault-name>\` as the first
   parameter, where \`<vault-name>\` is this vault folder's basename
   (\`$(basename "$VAULT")\`) and is never hardcoded into a skill. Obsidian must be
   running; preflight and fail loudly if it is not. Never pass \`open\` or
   \`newtab\` in automation. For fuzzy questions, run 3-5 deliberately varied
   lexical queries and rank by how many hit each path, rather than trusting one
   search.
9. \`Resources/Plans/\` is grouped by year: \`Resources/Plans/{year}/Daily/\` and
   \`Resources/Plans/{year}/Weekly/\`. Obsidian's Daily Notes setting points at
   \`Resources/Plans/$_year/Daily\`.
10. \`Resources/Meetings/\` is \`ai-read-write\` but agent \`Edit\`/\`Write\` is
    DENIED there in \`.claude/settings.local.json\`, so auto-exported meeting notes
    are never clobbered. Note that the deny rule is a literal path glob that must
    be updated in the same change if the folder ever moves.
11. \`USER.md\` lives at the vault root, is read at the start of every session, and
    holds personalisation details.
12. A "# Projects" section enumerating each project folder listed in the brief,
    with a sentence or two on each, using the exact folder paths given. Sub-folders
    must appear under their parent.
FACTS
}

_stub_claude_md() {  # <body_out> <tags_out>
  _year="$(date_fmt "$TODAY" '+%Y')"
  cat > "$1" <<STUB
# Knowledge Base Architecture + Permissions

This vault is organised with **PARA**: \`Projects/\` for active work with an
outcome and an end, \`Areas/\` for ongoing responsibilities with no end date,
\`Resources/\` for reference material consulted across projects, and \`Archive/\`
for anything inactive. The dividing line between a project and an area is whether
the work can be *finished*. Completed work moves to \`Archive/{year}/\`.

Vault machinery -- \`Skills/\`, \`Routines/\`, \`Templates/\`, \`Clippings/\`,
\`.system/\` -- sits outside PARA at the root. It is infrastructure, not knowledge.

Each directory is marked with one access tag:
- \`ai-read-only\`: read only; never write new files or change existing ones
- \`ai-read-frontmatter-only\`: read anything; write only frontmatter, properties, tags and connections
- \`ai-read-write\`: read and write, including new files and edits to any part of a file

## \`.system/\` \`ai-read-write\`

Dot-prefixed deliberately: Obsidian ignores dot folders entirely and Obsidian Sync
skips hidden files, so the manifest is excluded from indexing and sync with no
configuration to maintain. Nothing here is meant to be opened in Obsidian.

All executable code lives here. \`Skills/\` holds instructions for an agent to
follow; \`.system/\` holds programs that run unattended with no agent in the loop.

- \`wiki/\` -- the ingestion pipeline and \`manifest.sqlite\`, which holds only
  change-detection state. The manifest is per-machine, excluded from sync and git,
  disposable, and never hand-edited.
- \`connectors/\` -- inbound feeds from external services
- \`vault-bundle/\` -- compiles skills and automations for install into another environment
- \`log/log-YYYY-MM.csv\` -- append-only action log, rotated monthly, pipe-delimited
  as \`timestamp|action|path|summary\`. One line per action, not per run. Summary
  must be single-line. Read it only with \`tail\`, \`head\` or \`grep\`.
- \`sources.md\` -- which external sources are connected; skills resolve this at run time

**Never hardcode an absolute path.** Scripts derive the vault root from their own location.

## \`USER.md\` (vault root) \`ai-read-write\`

Personalisation details about the user. Read at the beginning of every session.

## Search & Retrieval

All search runs through the **Obsidian CLI** against the running Obsidian app.
There is no semantic or vector search.

- Always pass \`vault=<vault-name>\` as the **first** parameter. \`<vault-name>\`
  is this vault folder's basename -- $(basename "$VAULT") here -- and is never
  hardcoded into a skill.
- Obsidian must be running. Preflight with \`obsidian vault info=name\` and fail
  loudly if it is not.
- Never pass \`open\` or \`newtab\` in automation.
- For fuzzy questions, run 3-5 deliberately varied lexical queries, then dedupe
  and rank by how many hit each path.

## Frontmatter written by the pipeline

Do not strip or hand-edit these: \`tagged\` (date of the last tagger pass) and
\`tagged_hash\` (body hash as of that pass). \`domain\` is derived from the folder
path and is never stored in frontmatter.

# Skills \`ai-read-write\`
Skill files guiding critical functions. Scripts belonging to one skill live beside
it in that skill's \`scripts/\` folder.

# Routines \`ai-read-write\`
Automations to execute on a regular basis.

# Projects \`ai-read-write\`
Active, outcome-bearing work.
STUB

  _i=0
  while [ "$_i" -lt "${#PERSONA_PROJECTS[@]}" ]; do
    printf -- '- `%s`\n\t- %s\n' \
      "$(field 1 "${PERSONA_PROJECTS[$_i]}")" \
      "$(field 3 "${PERSONA_PROJECTS[$_i]}")" >> "$1"
    _i=$(( _i + 1 ))
  done

  cat >> "$1" <<STUB2

# Areas \`ai-read-write\`
Ongoing responsibilities with no completion date -- maintained at a standard
rather than finished. If a folder here acquires a deadline and a definition of
done, it belongs in \`Projects/\`.
STUB2

  _i=0
  while [ "$_i" -lt "${#PERSONA_AREAS[@]}" ]; do
    printf -- '- `%s` -- %s\n' \
      "$(field 1 "${PERSONA_AREAS[$_i]}")" \
      "$(field 2 "${PERSONA_AREAS[$_i]}")" >> "$1"
    _i=$(( _i + 1 ))
  done

  cat >> "$1" <<STUB3

# Resources \`ai-read-write\`
Reference material not tied to a single active project.

## Resources/Plans \`ai-read-write\`
Grouped by year. \`Daily/\` holds daily notes and tasks; \`Weekly/\` holds
in-depth weekly planning sessions. Obsidian's Daily Notes setting points at
\`Resources/Plans/$_year/Daily\`.

## Resources/Meetings \`ai-read-write\` -- **agent writes denied**
Meeting notes, auto-exported. \`.claude/settings.local.json\` **denies** agent
\`Edit\`/\`Write\` under this folder so exported notes are never clobbered. The
rule is a literal path glob: if this folder moves, update the deny rule in the
same change or the protection silently disappears.

# Archive \`ai-read-write\`
Grouped by year. Inactive and compacted notes. Search it only when a query is
explicitly historical, or when nothing turns up in the active folders. Moving a
note here is not deletion: it stays indexed, tagged and searchable.
STUB3

  printf 'reference, architecture, knowledge-base\n' > "$2"
}

_stub_user_md() {  # <body_out> <tags_out>
  {
    printf '# %s\n\n' "$PERSONA_NAME"
    printf '%s\n\n' "$PERSONA_HEADLINE"
    printf 'Pronouns: %s · Email: %s · Location: %s · Timezone: %s\n\n' \
      "$PERSONA_PRONOUNS" "$PERSONA_EMAIL" "$PERSONA_LOCATION" "$PERSONA_TZ"
    printf '## Background\n\n%s\n\n' "$PERSONA_SEED"

    printf '## Current work\n\n'
    _i=0
    while [ "$_i" -lt "${#PERSONA_PROJECTS[@]}" ]; do
      printf -- '- **%s** -- %s\n' \
        "$(field 1 "${PERSONA_PROJECTS[$_i]}")" \
        "$(field 3 "${PERSONA_PROJECTS[$_i]}")"
      _i=$(( _i + 1 ))
    done
    printf '\n'

    if [ "${#PERSONA_AREAS[@]}" -gt 0 ]; then
      printf '## Standing responsibilities\n\n'
      _i=0
      while [ "$_i" -lt "${#PERSONA_AREAS[@]}" ]; do
        printf -- '- **%s** -- %s\n' \
          "$(field 1 "${PERSONA_AREAS[$_i]}")" \
          "$(field 2 "${PERSONA_AREAS[$_i]}")"
        _i=$(( _i + 1 ))
      done
      printf '\n'
    fi

    if [ "${#PERSONA_PEOPLE[@]}" -gt 0 ]; then
      printf '## People\n\n'
      _i=0
      while [ "$_i" -lt "${#PERSONA_PEOPLE[@]}" ]; do
        printf -- '- %s -- %s\n' \
          "$(field 1 "${PERSONA_PEOPLE[$_i]}")" \
          "$(field 2 "${PERSONA_PEOPLE[$_i]}")"
        _i=$(( _i + 1 ))
      done
      printf '\n'
    fi

    if [ "${#PERSONA_SHORTHAND[@]}" -gt 0 ]; then
      printf '### Shorthand\n\n'
      _i=0
      while [ "$_i" -lt "${#PERSONA_SHORTHAND[@]}" ]; do
        printf -- '- **%s** = %s\n' \
          "$(field 1 "${PERSONA_SHORTHAND[$_i]}")" \
          "$(field 2 "${PERSONA_SHORTHAND[$_i]}")"
        _i=$(( _i + 1 ))
      done
    fi
  } > "$1"
  printf 'reference, bio\n' > "$2"
}

_gen_claude_md() {
  _p="$WORK/prompt-claude.txt"; _b="$WORK/body-claude.md"; _t="$WORK/tags-claude.txt"
  {
    cat <<'HDR'
Write the `CLAUDE.md` for a personal Obsidian knowledge vault. This is the
operating manual the AI assistant reads at the start of every session: it defines
the directory structure, what the assistant may and may not write where, and how
search works. Write it as the vault owner wrote it for their own assistant --
direct, specific, occasionally explaining *why* a rule exists, because a rule
whose reason is not recorded gets broken later.

Structure it with Markdown headings. Around 900-1400 words. Start with
`# Knowledge Base Architecture + Permissions`.

HDR
    persona_brief
    _scaffold_claude_facts
    cat <<'FOOT'

Output contract: emit the same two-part form.

TAGS: <3 to 5 tags>
---BODY---
<the CLAUDE.md, starting with `# Knowledge Base Architecture + Permissions`>

No YAML frontmatter, no outer code fence, no commentary.
FOOT
  } > "$_p"

  llm_doc "$_p" "$_b" "$_t" _stub_claude_md
  stamp_note "$VAULT/CLAUDE.md" "$_b" "reference" "$(cat "$_t")" "$TODAY"
}

_gen_user_md() {
  _p="$WORK/prompt-user.txt"; _b="$WORK/body-user.md"; _t="$WORK/tags-user.txt"
  {
    cat <<'HDR'
Write the `USER.md` for a personal knowledge vault: the file the AI assistant
reads at the start of every session to know who it is working for. Written by the
owner about themselves, in first person where natural.

Cover, using Markdown headings: who they are and what they do now; current roles
and what each actually demands of them; how they prefer to work (writing style,
planning cadence, what they find useless); the people they work with most; and a
`### Shorthand` section expanding the abbreviations they use in their own notes.
Include the pronouns, email, location and timezone given below as a compact line
of details.

600-900 words. Concrete over flattering -- include what they are bad at or
impatient with. Start with a `# ` heading that is their name.

HDR
    persona_brief
    printf 'Pronouns: %s. Timezone: %s.\n\n' "$PERSONA_PRONOUNS" "$PERSONA_TZ"
    cat <<'FOOT'
Output contract:

TAGS: <3 to 5 tags>
---BODY---
<the USER.md>

No YAML frontmatter, no outer code fence, no commentary.
FOOT
  } > "$_p"

  llm_doc "$_p" "$_b" "$_t" _stub_user_md
  stamp_note "$VAULT/USER.md" "$_b" "person" "$(cat "$_t")" "$TODAY"
}

scaffold_root_docs() {
  job_run "CLAUDE.md" _gen_claude_md
  job_run "USER.md"   _gen_user_md
}

# ------------------------------------------------------------- machinery files

scaffold_sources_md() {
  {
    cat <<'HDR'
# Connected sources

Which external sources the skills may read, and what fills each role. Skills
resolve roles from this table at run time instead of hardcoding a product name.

Rules the skills follow:

- A role set to `none` is **skipped and named in the output**, never silently omitted.
- A row naming a tool that is not present in the current session is **stale**: the
  skill treats it as `none` for that run and says so, rather than substituting a
  different tool.
- Edit this file to add, change, or disconnect a source.

| role | source | notes |
| --- | --- | --- |
HDR
    _i=0
    while [ "$_i" -lt "${#PERSONA_SOURCES[@]}" ]; do
      printf '| %s | %s | %s |\n' \
        "$(field 1 "${PERSONA_SOURCES[$_i]}")" \
        "$(field 2 "${PERSONA_SOURCES[$_i]}")" \
        "$(field 3 "${PERSONA_SOURCES[$_i]}")"
      _i=$(( _i + 1 ))
    done
    cat <<'FOOT'

> Generated sandbox. Every external role defaults to `none` so a test run cannot
> reach a live service. Point a role at a real connector deliberately, per test.
FOOT
  } > "$VAULT/.system/sources.md"
  ok "sources.md (all external roles default to none)"
}

scaffold_log() {
  _month="$(date_fmt "$TODAY" '+%Y-%m')"
  _log="$VAULT/.system/log/log-$_month.csv"
  # Seeded with real-looking history: a skill that reads the log to answer "what
  # changed recently" needs something to find, and the log-manager skill's read
  # patterns (tail/grep) need more than one line to be exercised.
  {
    printf '%sT08:12:04|bootstrap|.system/|sandbox vault created by catalyst-desktop/tests/sandbox-up.sh\n' "$(date_add "$TODAY" -21)"
    printf '%sT08:12:06|ingest|Projects/|initial pass: enumerated and hashed all notes\n' "$(date_add "$TODAY" -21)"
    printf '%sT09:02:11|tag|Projects/%s/|tagger pass over project notes\n' "$(date_add "$TODAY" -14)" "$(persona_project_paths | head -1)"
    printf '%sT09:40:55|ingest|Resources/Meetings/|picked up %s new meeting note(s)\n' "$(date_add "$TODAY" -7)" "$MEETING_COUNT"
    printf '%sT07:31:20|create-weekly-plan|Resources/Plans/%s/Weekly/|weekly plan drafted from prior week meetings and dailies\n' "$(week_start "$TODAY")" "$(date_fmt "$TODAY" '+%Y')"
    printf '%sT09:05:02|daily-plan|Resources/Plans/%s/Daily/|daily note created from template; pulled open P1 items from the weekly plan\n' "$TODAY" "$(date_fmt "$TODAY" '+%Y')"
  } > "$_log"
  ok "action log seeded ($(wc -l < "$_log" | tr -d ' ') lines, $(basename "$_log"))"
}

scaffold_settings() {
  # The deny glob has to be absolute and therefore per-sandbox, which is exactly
  # why it is rendered here rather than committed.
  cat > "$VAULT/.claude/settings.local.json" <<JSON
{
  "permissions": {
    "allow": [
      "Read",
      "Glob",
      "Grep",
      "Edit(**/*.md)",
      "Write(**/*.md)",
      "Bash(ls *)",
      "Bash(cat *)",
      "Bash(head *)",
      "Bash(tail *)",
      "Bash(grep *)",
      "Bash(find *)",
      "Bash(stat *)",
      "Bash(wc *)",
      "Bash(date *)",
      "Bash(mkdir -p *)",
      "Bash(echo *)",
      "Bash(obsidian *)"
    ],
    "deny": [
      "Edit($VAULT/Resources/Meetings/**)",
      "Write($VAULT/Resources/Meetings/**)"
    ],
    "defaultMode": "auto"
  }
}
JSON
  ok "settings.local.json (Meetings/ writes denied)"
}

scaffold_obsidian() {
  _year="$(date_fmt "$TODAY" '+%Y')"
  printf '{\n  "alwaysUpdateLinks": true\n}\n' > "$VAULT/.obsidian/app.json"
  cat > "$VAULT/.obsidian/daily-notes.json" <<JSON
{
  "folder": "Resources/Plans/$_year/Daily",
  "template": "Templates/Daily Note Template"
}
JSON
  printf '{\n  "folder": "Templates"\n}\n' > "$VAULT/.obsidian/templates.json"
  printf '[\n  "file-explorer",\n  "global-search",\n  "backlink",\n  "tag-pane",\n  "daily-notes",\n  "templates",\n  "properties"\n]\n' \
    > "$VAULT/.obsidian/core-plugins.json"
  ok "obsidian config (daily notes -> Resources/Plans/$_year/Daily)"
}

scaffold_templates() {
  cat > "$VAULT/Templates/Daily Note Template.md" <<'TPL'
---
created: "{{date}} {{time}}"
tags:
  - daily-planning
---

# Admin



# Goals



# Notes
TPL
  cat > "$VAULT/Templates/Weekly Planning.md" <<'TPL'
---
created: "{{date}} {{time}}"
tags:
  - weekly-planning
---

# Weekly Goals


# Admin


# Personal
TPL
  # Skills/ and Routines/ are left empty on purpose: the build script compiles
  # them in. A note saying so beats a future reader assuming the scaffolder is
  # broken.
  cat > "$VAULT/Skills/README.md" <<'TPL'
Intentionally empty in a fresh sandbox.

Skills and routines are installed by the build script, not by the sandbox
scaffolder. Compile them into this vault, then run the harness against it.
TPL
  cp "$VAULT/Skills/README.md" "$VAULT/Routines/README.md"
  ok "templates ($(ls "$VAULT/Templates" | wc -l | tr -d ' ') files); Skills/ and Routines/ left for the build script"
}

scaffold_welcome() {
  cat > "$VAULT/Welcome.md" <<TPL
---
tags:
  - reference
type: reference
---

# Welcome

Simulated vault for testing the Catalyst AI desktop service. Everything in it --
the person, their employers, projects, colleagues and notes -- is fiction,
generated by \`catalyst-desktop/tests/sandbox-up.sh\`.

- Persona: \`$(basename "$PERSONA_FILE")\`
- Generated: $TODAY
- Structure: PARA (\`Projects/\`, \`Areas/\`, \`Resources/\`, \`Archive/\`)

Start with [[CLAUDE.md]] for the vault's rules and [[USER.md]] for who it belongs to.
TPL
}

# Machine-readable record of what this sandbox is. Doubles as the safety marker
# that sandbox-down.sh requires before it will delete anything.
scaffold_manifest() {
  cat > "$VAULT/.sandbox-manifest.json" <<JSON
{
  "kind": "catalyst-sandbox-vault",
  "version": 1,
  "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "anchor_date": "$TODAY",
  "persona": {
    "id": "$(json_escape "$PERSONA_ID")",
    "file": "$(json_escape "$(basename "$PERSONA_FILE")")",
    "name": "$(json_escape "$PERSONA_NAME")",
    "vault_name": "$(json_escape "$(basename "$VAULT")")"
  },
  "generation": {
    "mode": "$([ "$LLM_OFFLINE" = 1 ] && echo offline || echo claude-cli)",
    "model": "$(json_escape "$LLM_MODEL")",
    "size": "$(json_escape "$SIZE")",
    "jobs": $JOBS
  },
  "counts": {
    "docs_per_project": $DOCS_PER_PROJECT,
    "docs_per_area": $DOCS_PER_AREA,
    "resources": $RESOURCE_COUNT,
    "meetings": $MEETING_COUNT,
    "dailies": $DAILY_COUNT,
    "weeklies": $WEEKLY_COUNT,
    "markdown_files": $(find "$VAULT" -name '*.md' -not -path '*/.obsidian/*' | wc -l | tr -d ' ')
  }
}
JSON
}
