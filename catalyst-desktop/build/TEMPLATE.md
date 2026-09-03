<!-- The implementation interview, as a document.
     Fill this in with the user, then hand it to the build:
         ./build/build-vault.sh --template <this file> --out <vault path>
     The H1 headings are the contract. An empty section means "none" and is fine;
     a missing one is rejected. -->

# Projects

<!-- Active work with an outcome and an end. One folder per project.
     `- Name | kind | one-line description`  (kind and description optional)
     Nested bullets become subprojects: Projects/Enzy/Bedrock/
     At least one is required — projects are the taxonomy every plan is built on. -->


# Areas

<!-- Ongoing responsibility, no finish line. `- Name | description` -->


# Sources
<!-- Only name a tool you have VERIFIED is reachable from your session — a
     connector you can actually enumerate, not one the user owns a licence for.
     Anything unverified is `none`, which the skills handle by naming what they
     skipped. A second `|` field is free-text notes, and is where consent
     decisions go (e.g. private-channel search, with the date). -->

- Email:
- Messaging (slack, teams, telegram etc...):
- Meetings:
- Calendar:
- Project management (linear, notion, monday.com, etc..):

# Skills

### System
<!-- Always installed. These are invoked by other skills and by the routines
     rather than by the user directly, so most have nothing to configure. The
     exception is `memory`, which reads `code` when a repository is connected —
     leave its Sources empty if not. -->

- `doc-retrieval`
- `tag-lint`
- `log-manager`
- `action-item-classifier`
- `prioritization-reranker`
- `memory`
    - Sources:

### User
- `daily-plan`
    - Sources:
- `weekly-plan`
    - Sources:
- `meeting-prep`
    - Sources:

<!-- `Sources:` is a comma-separated list of the roles above. A skill whose roles
     are all `none` still installs, and reports which roles it skipped. -->

# Routines
<!-- `Frequency:` takes plain English ("weekdays 7:30am", "Sundays 5:30pm") or a
     raw 5-field cron expression. Each is confirmed individually at build time. -->

- `weekly-plan-create`
    - Frequency:
- `weekly-plan-update`
    - Frequency:
- `daily-plan-run`
    - Frequency:


# Connectors

### Meetings
<!-- `granola-export` is the only supported meeting connector. Leave empty to
     treat Resources/Meetings/ as a manual folder. -->

### External notes
<!-- Feeds for the daily news brief. A bare URL is fetched; an entry nested under
     `Web Search:` is a standing search directive. -->

# Priorities

<!-- Ranked, most important first. Read fresh on every run to assign P1/P2/P3. -->


# User Profile and Preferences

<!-- Becomes USER.md, read at the start of every session, so substance matters
     more than length. Cover what they do now, what each role demands, how they
     prefer to work, and what they find useless. -->

- Name:
- Pronouns:
- Email:
- Location:
- Timezone:
- Shorthand:
    - ABBR = what it stands for


# Operating System (windows vs macos)

<!-- Drives how the two background jobs install: macOS uses LaunchAgents
     (installed directly), Windows uses Task Scheduler (the build writes a
     PowerShell script). Leave empty or `auto` to detect from the host. Setting it
     explicitly asserts what you expect, and the build fails if the assertion is
     wrong — you cannot install a LaunchAgent from Windows. -->

- OS: auto
