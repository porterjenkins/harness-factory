---
name: meeting-prep
description: Draft an agenda for an upcoming meeting given a scope (a project or subproject named in CLAUDE.md, a topic, or a group like "the AI team" or "eng+prod managers") and a time horizon (e.g. "last week," "last month," a date range). Use whenever the user asks to prep for a meeting, draft/build an agenda, get ready for a sync, or asks "what's on deck for X" / "check recent activity for X." Pulls recent activity from the vault (especially Meetings) plus whatever calendar, issue-tracker, chat, or second knowledge base the user has connected — sources are resolved at run time from the `## Who reads what` table in `SOURCES.md`, never hardcoded here. Then drafts a short progress-and-follow-ups agenda. Always run the research steps — don't draft from memory, since the user's projects move fast and stale agendas are worse than no agenda. Output is always a DRAFT for the user to review before sending.
tags:
  - skill
  - knowledge-base
  - workflow
  - planning
  - automation
tagged: '2026-09-02'
tagged_hash: 002d49f3c1f95f7f
type: concept
---

# Meeting Prep

Builds a short agenda for an upcoming meeting from two inputs: a **scope** (what the meeting is
about) and a **time horizon** (how far back to look for recent activity). If either is missing or
ambiguous, ask the user before starting — don't guess a scope or silently default the horizon to
"last week."

## 0. Sources preflight — before any research step

This skill reads from sources outside the vault. **Never assume one is available, and never
name a product the user has not connected.**

**This skill does not carry its own list of roles.** Read the `## Who reads what` table in
`SOURCES.md` and take every row whose `skill` is `meeting-prep` — that set, and only that set, is
what this run resolves. A teammate adds or removes a source for this skill by editing that table;
nothing in this file changes. If the table has no `meeting-prep` rows at all, ask the user which
sources this skill should read, then write the rows before continuing.

Each row gives a `role`, a `contributes` string of the form `<what to pull> → <where it lands>`,
and `required` (`always` or `optional`).

**Resolve every role before searching anything:**

1. Look up each role in the registry table at the top of `SOURCES.md`. It maps the role to a
   connected tool, or to `none`.
2. If that file is missing, or has no registry row for a role, **ask the user which source should
   fill it** — and offer only what is actually connected in this session. Enumerate the MCP
   servers and Claude connectors available to you and present those; if nothing can fill a role,
   say so and record `none` rather than guessing at a product they might have.
3. **Verify before use.** A role mapped to a tool that is not present in this session is a stale
   entry: tell the user, treat it as `none` for this run, and do not fall back to a different
   tool without asking.
4. Write confirmed answers back to `SOURCES.md` so the next run does not re-ask.
5. A role marked `always` that resolves to `none` or stale is a hard stop — this skill cannot
   draft an honest agenda without the vault and the meeting notes. An `optional` role resolved to
   `none` is **skipped and named in the output's Notes section.** Never omit a source silently,
   and never substitute your own knowledge for a source you could not read — a confident agenda
   built from memory is the failure this skill exists to prevent.

### How each resolved role gets used

Some roles have bespoke steps below because generic handling isn't good enough for them:

| role | step |
| --- | --- |
| `second-vault` | step 2 — action-log grep plus the scope's subdirectory |
| `vault`, `meetings` | step 3 |
| `issues` | step 4 |
| `calendar` | step 5 — attendees, cadence, next occurrence |
| `chat` | step 5b |

**Any other role configured for `meeting-prep` is handled generically in step 5c** by following
its `contributes` arrow. Never drop a configured role just because this file doesn't name it.

## 1. Resolve scope and time horizon

- **Scope** can be a project name, a topic, or a group of people. Treat it as a search
  keyword/theme across every resolved source — don't assume it maps to exactly one folder, or to
  one project in any single system. Use the available search and retrieval skills to collect
  existing documents by scope.
- **Time horizon** is almost always relative ("last week," "last month," "since we last met").
  Resolve it to an explicit date range using today's date before searching anything, and use the
  same range consistently across **every** resolved source, so the agenda doesn't mix a week of
  ticket activity with a month of knowledge-base activity.

## 2. Check the second vault — only if `second-vault` resolved

Skip this entire section if the role is `none`. When present, it is often the richest source for
work done outside this vault.

- `.system/log/log-YYYY-MM.csv` — pipe-delimited, one line per action. Select the month files
  covering the resolved date range, then `grep` for the scope keyword (case-insensitive; also try
  obvious synonyms — a scope like "AI team" should also catch the codename that team's project
  goes by). Fields are `timestamp|action|path|summary`, so `cut -d'|' -f1,4` gives a readable
  timeline. Never `cat` a whole log file. If a `.system/log/log-archive.md` exists it holds older
  prose-format entries — `grep -n "^## \[" .system/log/log-archive.md` works there.
- The subdirectory matching the scope. Read source writeups and standup notes that fall in the
  date range; the log entry is a summary, the source file has the numbers.

## 3. Check this vault

- **`Resources/Meetings/`** — find the most recent meeting note(s) matching the scope (filenames start with
  the date; grep file contents for the scope keyword if the filename doesn't make it obvious).
  Read the most recent one in full for its "Next Steps"/follow-up items — anything left unchecked
  or unresolved is a candidate to carry forward, not to drop silently. If multiple meetings in the
  horizon match the scope, skim all of them but only need the last one in depth.
- **`Projects/`** — any project doc under the matching project folder, modified within the date
  range, is a signal of active work worth a line in the agenda. Read the project list from this
  vault's `CLAUDE.md` rather than assuming one.
- `.system/log/log-YYYY-MM.csv` in this vault — same grep approach as step 2.

## 4. Check the issue tracker — only if `issues` resolved

Skip if the role is `none`. Otherwise use whatever the user connected, through its own tools:

- Look for a project matching the scope; if found, pull its issues (filtered to the resolved date
  range by updated/created date), any status updates, and recent comments.
- If the scope doesn't map cleanly to one project — a team or topic scope often doesn't — search
  issues by free text instead, still bounded by the date range.
- **An empty result is a real result, not a reason to skip next time.** Some projects track their
  real progress in the knowledge base rather than in tickets. Check every run, and record in the
  Notes section that it came back empty.

## 5. Check the calendar — only if `calendar` resolved

Skip if the role is `none`; note in the agenda that attendees and cadence are unconfirmed.
Otherwise search events for the scope to find the relevant recurring meeting, and pull:
  - **Attendees** — goes in the agenda frontmatter and tells you who the audience is (which
    affects tone/detail level — a leadership sync gets less engineering detail than an engineering
    working session).
  - **Regularity** — is this weekly, biweekly, ad hoc? This matters for scoping "recent activity":
    a weekly meeting agenda should mostly cover since-last-meeting, even if the requested horizon
    is longer.
  - **The actual next occurrence** — its date/time goes in the agenda frontmatter. If the user named
    a specific date instead, use that.
- If nothing matches, note in the agenda that no recurring meeting was found and use the
  requested time horizon as-is.

## 5b. Check chat — only if `chat` resolved

Skip if `none`. Search the connected chat tool for the scope keyword within the resolved date
range, and pull only what a person would call a decision, a blocker, or an open question. Chat is
noisy: two or three genuine items beat fifteen fragments.

## 5c. Any other role configured for this skill

Step 0 resolved every `meeting-prep` row in `SOURCES.md`'s `## Who reads what` table. Steps 2–5b
consumed the ones this file names by hand. **Anything left over is handled here**, generically —
that's what makes a teammate's added source work without editing this file.

For each leftover role that resolved to a real tool, read its `contributes` cell and split it on
the arrow:

- **Left of the arrow — what to pull.** Search that tool for the resolved scope (step 1), bounded
  by the resolved date range, exactly as steps 4 and 5b do for issues and chat. Try the scope's
  obvious synonyms and codenames too; a scope rarely maps cleanly onto one project in a system
  nobody wrote a step for.
- **Right of the arrow — where it lands.** For nearly every added role this is *agenda clusters*:
  the results join the same pool step 6 clusters by topic, not a section of their own. Only give a
  role its own section if its arrow explicitly names one.

Apply step 5b's chat rule to anything noisy: pull only what a person would call a decision, a
blocker, or an open question, and take two or three genuine items over fifteen fragments.

**An empty result is a real result.** Record it in the Notes section the same way step 4 does for
an empty issue tracker, and name the role there whether it contributed or not — a source nobody
wrote a step for is exactly the one whose output the user has no intuition about yet.

## 6. Write the agenda

Group what you found into a small number of topic clusters — driven by what actually happened,
not a fixed template. An engineering working session might cluster into "query performance," "ETL
pipeline," "infra sizing"; an eng+prod managers sync might cluster by team or by initiative. Don't
force activity into categories it doesn't fit, and don't pad a cluster that only has one real
bullet.

Frontmatter:

```yaml
---
title: <Scope> — Agenda (DRAFT)
date: YYYY-MM-DD
start_time: "YYYY-MM-DDTHH:MM:SS-06:00"
end_time: "YYYY-MM-DDTHH:MM:SS-06:00"
owner: <the user's name — see USER.md>
attendees:
  - <from calendar>
---
```

Body — one numbered section per cluster, each with exactly two bolded sub-bullets:

```markdown
# <Scope> — Agenda (DRAFT)

## N. <topic> (<owner if one person clearly drove it>)
**Recent progress**
- short bullet
- short bullet

**Follow-up items**
- short bullet
- short bullet
```

Keep every bullet to one line. No intro paragraph, no meeting-length estimates, no filler —
sections and their two sub-bullets are the whole agenda unless the user asks for more.

Finish with a final section flagging anything that couldn't be verified so the user knows what's
inferred vs. confirmed. **Every `meeting-prep` role in `SOURCES.md`'s `## Who reads what` table
that resolved to `none` or stale, and every connected source that came back empty, gets a line
here** — e.g. "no issue tracker connected," "calendar had no match," "chat returned nothing in
this window." Roles handled generically in step 5c get a line whether or not they contributed.
This section is what keeps a thin agenda honest instead of looking authoritative.

```markdown
## Notes
- <caveat, if any>
```

## 7. Save and deliver

Save to this vault, in `Resources/Agendas/{year}/` — a sibling of `Resources/Meetings/`, not a
subfolder of it, so agent-authored drafts never sit inside the auto-exported record they will
eventually be checked against:
`Resources/Agendas/{year}/{date} <Scope> - Agenda (DRAFT).md`, where `{year}` is the year of the
meeting being prepped. Create the `{year}` folder if it doesn't exist yet. The `(DRAFT)` marker
belongs in both the filename and the frontmatter `title` — this is always a draft for the user to
review, never sent as-is.

**Never write anywhere under `Resources/Meetings/`.** Those folders hold Granola auto-exports and
are read-only to agents — `.claude/settings.local.json` denies `Edit`/`Write` across the whole
tree. `Resources/Agendas/` is the only place this skill writes. If a write there is refused, the
permissions have drifted out of sync with this skill — say so rather than silently falling back to
a scratchpad.

Use `present_files` to hand it over. Don't summarize the contents back at length — a one- or
two-sentence outcome summary is enough; the user can read the doc.

## 8. Log it

Append one line to the current month's log at `.system/log/log-YYYY-MM.csv` (pipe-delimited:
`timestamp|action|path|summary`; see the `log-manager` skill) — `create`, path is the agenda file
from step 7, summary notes the scope, the resolved date range, and — for **every**
`meeting-prep` role in `SOURCES.md`'s `## Who reads what` table — what it resolved to and whether
it was skipped (`none`/stale), searched-and-empty, or contributed.
