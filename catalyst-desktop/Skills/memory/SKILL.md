---
name: memory
description: Maintain `MEMORY.md` — the single, evolving, high-level record of who the user is, how they work, where each of their Projects and Areas stands, and what they have achieved and committed to. Use whenever the user asks to "update memory," "what do you know about me," "what did I work on this week," "summarize my week," "update my project status," or asks you to remember a preference, goal, or achievement. Also runs unattended as a Friday end-of-week scheduled task. The weekly run gathers fresh from every source resolved at run time from `SOURCES.md` — vault notes and meetings plus whatever chat, issue tracker, email, code host, and calendar are connected — then *reconciles* what it found against what `MEMORY.md` already says rather than appending another snapshot. Never write the file from recollection: memory that is updated from memory drifts, and drift is invisible.
tags:
  - skill
  - knowledge-base
  - workflow
  - automation
  - memory
type: spec
---

# Memory

Maintains exactly one file: **`MEMORY.md`** at the vault root.

It is a *model*, not a log. Each run makes the model more accurate — confirming what still holds,
replacing what changed, adding what is new — rather than stacking another dated snapshot on the
pile. A reader who has never met the user should be able to read `MEMORY.md` in two minutes and
know how to work with them.

The predecessor to this skill wrote a dated retrospective per week. That produced accurate notes
nobody re-read and a picture that had to be reassembled from a dozen files. One file that gets
better is worth more than fifty that get older.

## What belongs in it

Two kinds of content, and nothing else:

- **Semantic memory** — durable facts about the work. What each project is *for*, where it
  stands, what got achieved, what has been committed to and by when.
- **Personalization memory** — how the user works and wants to be worked with. Preferences,
  rhythms, standing constraints, communication style, recurring friction.

Every line must survive all three questions:

1. **Will it still matter in a month?** If not, drop it.
2. **Is it a state, pattern, or outcome — rather than a single event?** If it is one event, either
   compress it into the state it produced or drop it.
3. **Would knowing it change how you respond to the user?** If not, drop it.

Ticket IDs, individual commits, meeting-by-meeting play-by-play, this week's blockers: these are
**evidence**, not memory. Evidence lives in `Resources/Meetings/`, `Resources/Plans/`, and
`Archive/`. Cite it, link it, do not copy it here.

## What it is not — the neighboring files

| File | Owns | Written by |
| --- | --- | --- |
| `USER.md` | Stable identity: bio, roles, research record, shorthand | The user, rarely |
| `PRIORITIES.md` | What matters *right now*, ranked | The user |
| `Resources/Plans/` | Intent — what was planned | The planning skills |
| `MEMORY.md` | Evolving understanding — state, progress, achievements, preferences | **This skill** |

The dividing line against `USER.md`: if a fact is about *who the user is* and would still be true
in a year, it belongs there. If it is about *where things stand*, it belongs here. Do not
duplicate `USER.md` into `MEMORY.md` — assume its contents are already known. When a run turns up
something that genuinely changes `USER.md` (a role ended, a title changed, a paper landed),
**say so in the report and offer the edit**; make it silently only when it is unambiguous and
purely additive.

The dividing line against `PRIORITIES.md`: that file is the user's own statement of what they
want to be true. This one records what *is* true. When they disagree, that gap is one of the most
useful things a run can surface — say it plainly rather than quietly aligning the memory to the
stated priority.

## 0. Sources preflight — before gathering anything

This skill reads from sources outside the vault. **Never assume one is available, and never name
a product the user has not connected.** There is no default chat tool, issue tracker, or code
host here — those are resolved, not known.

| Role | What it contributes | Required |
| --- | --- | --- |
| `vault` | daily/weekly plans, project docs, the action log | always — local filesystem |
| `meetings` | what was discussed and decided, and who owns the follow-ups | always — in the vault |
| `chat` | decisions made in conversation, commitments, open loops | optional |
| `issues` | what was filed, assigned, moved, closed | optional |
| `email` | external correspondence, deadlines, things awaiting a reply | optional |
| `code` | commits, branches, review activity — the hands-on work | optional |
| `calendar` | where the time actually went | optional |
| `second-vault` | work recorded in a team or company knowledge base | optional |

**Resolve every role before gathering:**

1. Read `SOURCES.md`. It maps each role to a connected tool, or to `none`.
2. If there is no row for a role, **ask which source should fill it** — offering only what is
   actually connected in this session. If nothing can, record `none` rather than guessing.
3. **Verify before use.** A row naming a tool absent from this session is stale: treat it as
   `none` for this run and say so. Never substitute a different tool without asking.
4. **Verify a `code` source can authenticate.** A code-host CLI installed but not logged in is
   *partial*: local history still reads, but review activity and anything pushed from another
   machine are invisible. Say which of the two you got.
5. Write confirmed answers back to `SOURCES.md` so the next run does not re-ask.
6. A role resolved to `none` is **named in the run's report**, never silently omitted.

On an unattended run, steps 2–3 cannot ask: treat any unresolvable role as `none`, proceed with
what resolved, and name every gap.

## 1. Read `MEMORY.md` first — before gathering

This is the step that makes the skill work. Reading it first turns the gather from "collect
everything that happened" into "look for confirmation, contradiction, and change" — a far
narrower and more accurate search, and the only way to notice that something stopped happening.

Note the `updated` date in its frontmatter; §2 needs it.

If the file does not exist, create it from the skeleton in §5 and treat this as a **cold start**:
seed it from `USER.md`, `PRIORITIES.md`, the `Projects/` and `Areas/` folder structure, and any
existing notes under `Archive/Memories/`, then run the normal gather over a 30-day window.

## 2. Resolve the window

- **Default:** the day after `updated` in `MEMORY.md` frontmatter → today. Anchoring on the last
  successful run rather than on "this week" means a skipped or failed run loses nothing.
- **Cap at 30 days.** A longer gap gets the most recent 30 days plus an explicit note in the
  report that the earlier stretch was not covered.
- **Cold start:** the last 30 days.
- If the user names a range ("since I got back," "the last two weeks"), resolve it to explicit
  dates from today's date first.
- Use the **same resolved range across every source.** A week of tickets mixed with a month of
  chat produces a misleading picture.

## 3. Gather — one subagent per resolved source, in parallel

Dispatch concurrently; each source is independent and this is the slowest part of the run. Give
each subagent the resolved date range, the user's identity in that system, the project names from
`Projects/` and `PRIORITIES.md` as search terms, **the relevant current claims from `MEMORY.md`
to check against**, and these standing instructions:

- **Read-only. Always.** Never send a message, reply, draft, or schedule; never create, edit,
  transition, comment on, or close a ticket; never label, trash, or modify mail; never commit,
  push, or change repository state. A record must not mutate what it describes.
- **Distinguish what the user did from what happened around them.** "Filed the ticket" and "a
  teammate closed the ticket" are different facts, and the memory is wrong if it conflates them.
- **Report emptiness as a finding.** A search returning nothing is information. Say so; never
  fill a gap with plausible-sounding content.
- Filter automated noise from human signal — vendor mail, bot commits, CI chatter — but note the
  *pattern* if it is itself meaningful.
- Prefer short direct quotes for decisions and commitments; paraphrase everything else.

While they run, read the vault yourself: daily notes and weekly plans in `Resources/Plans/{year}/`,
meeting notes in `Resources/Meetings/{year}/` dated in range, project files modified in range, and
the run's log lines (`tail`/`grep` only — never `cat` a whole log; see `log-manager`).

## 4. Reconcile — the core of the skill

Do not append. For every candidate fact, choose one of four verbs:

- **Confirm** — it matches something already in `MEMORY.md`. Update that line's `as of` date.
  Do not restate it, and do not add a second line saying the same thing differently.
- **Revise** — it contradicts an existing line. **Replace the line; never leave both.** When the
  change itself is meaningful, the *change* is the durable fact: "Moved off Dropbox Sign in favor
  of building contract signing in-house (Aug 2026)" beats silently swapping one noun for another.
- **Add** — it is genuinely new. Place it in the right section at the right altitude, per the
  three-question test above.
- **Retire** — it is finished, abandoned, or no longer true. Completed work moves to
  **Achievements** as one line; abandoned work is deleted, unless *why* it was abandoned is worth
  keeping.

**Silence is not deletion.** A project no source mentioned this window keeps its section, marked
`no movement since {date}`. Dormancy is a real fact about a portfolio, and an empty window may
only mean the sources could not see the work.

**Contradictions between sources are signal.** A plan item marked done with no corroborating
work, or a system showing zero activity where activity was expected, often means a broken
integration or a wrong account — worth more to the user than another bullet of summary. Surface
it in the report; do not smooth it over in the file.

**Never overwrite something the user told you directly** with an inference drawn from a source.
A stated preference outranks an observed pattern; if the two conflict, keep the stated version
and note the tension.

### Size discipline

`MEMORY.md` is read at the start of every session. **Target under ~200 lines.** Growth without
compression is this skill's characteristic failure — a file that gets longer every week until it
is too expensive to read and too vague to use.

When a section outgrows its space, **compress rather than truncate**: fold the oldest three
entries into one summarizing line ("Shipped the Q3 SOC 2 remediation, the Covariant dashboard,
and the Bedrock plan — Aug 2026"), and leave a `[[wiki link]]` to where the detail lives. Never
drop a fact without either compressing it or writing it somewhere that survives.

## 5. Write `MEMORY.md`

Path: `MEMORY.md`, vault root. Frontmatter:

```yaml
---
tags:
  - memory
  - reference
type: reference
updated: {YYYY-MM-DD}
---
```

**Do not write `tagged` or `tagged_hash`** — the ingestion pipeline owns those and sets them on
its next pass. Writing them by hand, or carrying a stale hash across an edit, lets a manifest
rebuild silently absorb the change.

Sections, in this order:

1. **Current context** — three to five lines on what is true right now: where the user's attention
   is, what phase the main work is in, what changed most recently. This is what a reader needs
   before anything else.
2. **Working preferences** — how they want work done. Written as instructions, not observations.
3. **Projects** — one `###` per top-level folder under `Projects/`, read from the filesystem
   rather than assumed. Each carries **Goal**, **State** (with an as-of date), and **Next
   milestone**. Two to five lines each; a project with more to say than that has a project doc.
4. **Areas** — standing responsibilities from `Areas/`, each with the standard being held. If the
   folder is empty, say so in one line rather than inventing entries.
5. **Achievements** — dated, newest first, one line each. Only what will still be worth knowing
   in a year.
6. **Goals & commitments** — outcomes the user is working toward, at the altitude of "transform
   Enzy through the Bedrock migration" or "earn Continuing Faculty Status at BYU." Not a task
   list.

   Two tests, and an item must pass both:
   - **Could he still be working toward it in three months?** If it finishes in one sitting — an
     email, a deck, a form, a single decision — it is a task. Tasks belong in the weekly and daily
     plans, and are **deleted from here**, not demoted.
   - **Does it change the state of a project, a business, or his career?** A dated checkpoint on
     the way to a goal is a **milestone**: nest it under its goal as a sub-bullet. Never list a
     milestone as a peer of the goal it serves.

   Give each goal a horizon and, where they exist, its milestones with absolute dates. Deadlines
   are never relative.
7. **Recurring friction** — durable patterns that keep costing the user something. Not this
   week's blockers; the thing that shows up in three different weeks.
8. **Changelog** — one line per run: date, window covered, what changed. This is the only
   append-only section, and it is how a wrong turn gets traced later.

Link project docs, meetings, and plans with `[[wiki links]]` so the file joins the graph and the
evidence stays one hop away.

## 6. Log and report

Append exactly one line to `.system/log/log-YYYY-MM.csv` (append-only, pipe-delimited
`timestamp|action|path|summary`; strip `|` and newlines from the summary). See `log-manager`.

Then report briefly, leading with anything that failed:

- Sources that resolved to `none`, came back empty, or were partial.
- **What changed in the model** — revisions and retirements, not the additions. "Bedrock moved
  from planning to execution; Catalyst dormant three weeks" is the useful report. A list of
  everything added is not.
- Any gap between `PRIORITIES.md` and what the sources actually show.
- Any `USER.md` edit worth making.

## Off-cycle updates

The user saying "remember that…", stating a preference, or correcting how you work is a valid
entry point. Write it straight into **Working preferences** (or the right section) immediately —
no gather, no window, one changelog line. Waiting for the weekly run to record something the
user just said is how a preference gets lost.

## Related

- `Skills/weekly-planning/SKILL.md` — the forward-looking counterpart. That skill writes
  intentions; this one records what became of them. Read the plan as *input*, never as a
  substitute for gathering: it records what was intended, not what happened.
- `Skills/doc-retrieval/SKILL.md` — vault search, rather than improvised queries.
- `Skills/log-manager/SKILL.md` — reading and appending to the action log safely.
- `Routines/memory.md` — the Friday 5:00 PM scheduled run.
- `Archive/Memories/` — the dated weekly retrospectives this skill replaced. Kept as evidence and
  still linkable; nothing new is written there.
