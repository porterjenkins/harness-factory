# User Profile and Preferences

- Name:
- Pronouns:
- Email:
- Location:
- Timezone:
- Shorthand:
  - ABBR = what it stands for

<!-- Free prose below. This becomes USER.md, which is read at the start of every
     session, so substance matters more than length. Cover: what they do now, what
     each role actually demands, how they prefer to work, what they find useless,
     and the people they work with most. Concrete over flattering. -->


# Projects

<!-- Active work with an outcome and an end. One folder per project under Projects/.
     Format: `- Name | kind | one-line description`  (kind and description optional)
     Nested bullets become subprojects: Projects/Enzy/Bedrock/
     A project with no end date belongs under # Areas instead. -->

- Example | migration | Replace this line. What it is, and their role in it.
  - Subproject | infra | Gets its own folder under the parent.


# Areas

<!-- Ongoing responsibility, no finish line. Same format, no subprojects.
     Leave empty if there are none. -->


# Sources

<!-- One line per role: `- role: Product` or `- role: none`.
     Known roles: vault, meetings, calendar, chat, email, issues, code,
     second-vault, memory, web.
     Only record a source you have VERIFIED is reachable from the session -- an MCP
     server or connector you can actually enumerate, not one the user owns a licence
     for. Anything unverified is `none`; the skills handle that explicitly and say so.
     A second pipe field is free-text notes, and is where consent decisions go. -->

- vault: local filesystem
- meetings: none
- calendar: none
- chat: none | private channels and DMs in scope?  record the answer and the date
- email: none
- issues: none
- code: none
- second-vault: none


# Skills

### System

<!-- Always installed. Nothing to configure. -->

- doc-retrieval
- tag-lint
- log-manager

### User

<!-- `Sources:` is a comma-separated list of role names from # Sources above.
     A skill whose roles are all `none` still installs, and says at run time which
     roles it skipped. -->

- daily-plan
  - Sources:
- weekly-planning
  - Sources:
- meeting-prep
  - Sources:


# Routines

<!-- Scheduled automations. `Frequency:` accepts plain English ("weekdays 7:30am",
     "Sundays 5:30pm", "daily 4:30pm") or a raw 5-field cron expression.
     Each is confirmed individually at build time before anything is registered. -->

- daily-plan-run
  - Frequency: weekdays 7:30am
- weekly-plan-create
  - Frequency: Sundays 5:30pm
- weekly-plan-daily-update
  - Frequency: daily 4:30pm


# Connectors

### Meetings

<!-- `granola-export` is the only supported meeting connector. Anything else:
     leave this empty and treat Resources/Meetings/ as a manual folder. -->

- none

### External notes

- none


# Priorities

<!-- Ranked, most important first. This becomes PRIORITIES.md, which the
     prioritization-reranker reads fresh on every run to assign P1/P2/P3.
     Indented sub-bullets refine an item. -->

1.
2.
3.


# Import

<!-- Optional. Empty means no import. -->

- Source: none
- Path:


# Tag Vocabulary

<!-- Optional. `frequency` (the default and the recommendation) lets the tagger
     prefer the vault's own observed tag counts. `canon` writes the list below to
     .system/tags.md and the declared spelling wins regardless of count -- only safe
     while somebody maintains the list. -->

- Mode: frequency
- Tags:


# Platform

<!-- Which OS this vault is being built on. Drives how the two background jobs get
     installed: macOS uses LaunchAgents (installed directly by the build), Windows
     uses Task Scheduler (the build writes a PowerShell script for you to run).
     `auto` — the default — detects it from the host. Set it explicitly only to
     assert what you expect; the build fails if the assertion is wrong, since you
     cannot install a LaunchAgent from Windows or a Scheduled Task from macOS. -->

- OS: auto


# Sync

<!-- Optional. Determines which exclusion rules get written. -->

- Method: none
