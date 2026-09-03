---
name: weekly-planning
description: "Build or update the user's weekly planning note for the knowledge-base vault — a Sunday-through-Saturday plan with Weekly Goals plus one action-item checklist per Project and Area, whose H1 headers are the Project and Area names themselves (read from CLAUDE.md and the Areas/ folder). Both entry points run candidate action items through the `action-item-classifier` skill (precision gate) and the `prioritization-reranker` skill (priority tag + completion-likelihood ranking) before anything is written. Has two entry points: (1) Create Weekly Plan — use whenever the user asks to \"plan my week,\" \"do my weekly planning,\" \"set up next week,\" \"start the week,\" or references a \"weekly planning note,\" even without a specific date range, and also at the start of a work week if the user asks what's on deck; it deliberately over-generates candidate items from meetings, daily notes, project activity, and carried-over work before narrowing down, so real work doesn't get missed by guessing too conservatively up front. (2) Update Weekly Plan — use when asked to \"check recent meetings for action items,\" \"sync meeting follow-ups into my week,\" \"update my weekly plan,\" \"reconcile what I finished,\" \"mark off what I already did,\" or when running as a scheduled end-of-day task (daily at 4:30pm); it first reconciles the recent daily notes — primarily today's — so anything the user already checked off there is marked complete in the weekly plan too, since the user works out of the daily note and rarely goes back to tick the same item off in the weekly plan, then scans the last two days of meeting notes, generates and classifies candidate follow-ups, and stages the survivors into the current week's plan. This skill reads the prior week's Meetings, Daily plans, and Projects activity from the vault, plus every source configured for this skill in the `## Who reads what` table in `SOURCES.md` — resolved at run time from that table, never hardcoded here — so always run its research steps rather than guessing at goals from memory."
tags:
  - skill
  - planning/weekly
  - planning
  - knowledge-base
  - automation
tagged: '2026-08-28'
tagged_hash: 679178e34b179c7d
type: spec
---

# Weekly Planning

Two entry points into this skill:

- **Create Weekly Plan** — build a new week's planning note from scratch (goals, plus a checklist
  per project and per area).
- **Update Weekly Plan** — close out what the user already checked off in their daily note, then
  scan recent meeting notes for action items and stage them into the current week's plan for the
  user to review, without touching anything they've already curated.

**Section shape.** Every task section is an H1 named for a **Project or an Area** — `# Bedrock`,
`# Family`. 

Both entry points share the same shape for turning raw material into checklist items: **generate
a wide candidate pool, cut it down for quality, then rank what's left.** Concretely, that's three
skills in sequence — candidate generation (this skill, high recall by design) →
`action-item-classifier` (precision gate) → `prioritization-reranker` (priority tag +
completion-likelihood ranking). Over-generating at the first stage and cutting hard at the second
is deliberate: a real to-do that's never generated as a candidate is gone for good, while a bad
candidate that gets generated is cheap to catch immediately after.

# Create Weekly Plan

Generates the user's weekly planning note: a single Markdown file per week, filed under
`Resources/Plans/{year}/Weekly/`, that carries their goals and action items for every active project.

## 0. Sources preflight

**This skill does not carry its own list of roles.** Read the `## Who reads what` table in
`SOURCES.md` and take every row whose `skill` is `weekly-planning` — that set, and only that set,
is what this run resolves. A teammate adds or removes a source for this skill by editing that
table; nothing in this file changes. If the table has no `weekly-planning` rows at all, ask the
user which sources this skill should read, then write the rows before continuing.

Each row gives a `role`, a `contributes` string of the form `<what to pull> → <where it lands>`,
and `required` (`always` or `optional`). For each row:

1. Look up the role in the registry table at the top of `SOURCES.md` to get the tool that fills it.
2. If there is no registry row, **ask which tool fills that role**, offering only what is actually
   connected in this session; record `none` if nothing is.
3. **Verify before use.** A row naming a tool absent from this session is stale: treat it as
   `none` for this run and say so, rather than substituting a different tool.
4. Write the confirmed answer back to `SOURCES.md`.
5. A row marked `always` that resolves to `none` or stale is a hard stop. An `optional` row
   resolved to `none` is skipped and **named when you hand the plan over** — a week planned
   without a source it normally has is missing something, and the user needs to know that before
   they trust the priorities.

### How each resolved role gets used

| role | step |
| --- | --- |
| `vault` | steps 1–2 (last week's Meetings, Daily plans, `Projects/` activity) |
| `calendar` | step 3, and a signal `prioritization-reranker` uses in step 7 |

**Any other role configured for `weekly-planning` is handled generically in step 3b** by following
its `contributes` arrow. Never drop a configured role just because this file doesn't name it.

`prioritization-reranker` resolves the `calendar` role for itself when you call it in step 7, so
there's nothing extra to pass it.

Every `vault` lookup below — finding last week's Meetings, Daily, and Projects activity, locating a prior
Weekly Planning note — goes through the **`doc-retrieval` skill's** Obsidian CLI conventions
(`vault=<vault-name>` first, preflight, path-scoped `search`, `eval` for date ranges) rather than
raw `find`/`grep` against the filesystem.

## 1. Figure out the week

Weeks run **Sunday through Saturday**. Confirm today's date (`date` in the shell, or the
`currentDate` context if present), find the Sunday on/before today, and that's the start of
"this week." If the user already has a note for the current week, treat "plan my week" as a
request to refresh/extend it; if they say "next week," shift the range forward by 7 days.

Filename and title format — follow the most recent convention in the vault (4-digit year,
no leading zeros): `Weekly Planning 8-2-2026 to 8-8-2026.md`, saved to
`Resources/Plans/{year}/Weekly/`. Write the note directly with exactly this skeleton. Do not copy
a file out of `Templates/` — see the note below:

```
---
created: "YYYY-MM-DD HH:MM:SS"
tags:
  - weekly-planning
---

# Weekly Goals
```

`created` takes the real timestamp at write time, formatted exactly as shown. Section 10 shows the
full target shape once the Project and Area checklists are added beneath `# Weekly Goals`.

**Why this skeleton lives here and not in `Templates/`.** The vault does keep a Templates-plugin
copy for when the user makes a note by hand in Obsidian, but it is not what this skill reads, and
copying it would be a bug: its `created` value is `{{date}} {{time}}`, which only Obsidian's
Templates plugin expands, and only at insert time. An agent copying that file writes those braces
literally, and every date-ranged query that later filters on `created` silently skips the note.

## 2. Gather what actually happened last week

Don't invent goals from thin air — pull them from real activity. Use the `doc-retrieval` skill for
every lookup below. For the *prior* Sunday–Saturday range:

- **Resources/Meetings/** — `obsidian vault=<vault-name> search query="path:Resources/Meetings" format=json`, then keep
  only files whose `YYYY-MM-DD` filename prefix falls in the prior week's range. Read each match in
  full for decisions, follow-ups, and open questions.
- **Resources/Plans/{year}/Daily/** — `obsidian vault=<vault-name> search query="path:Resources/Plans/{year}/Daily" format=json`,
  filtered the same way to the prior week's dates, for anything logged day-to-day that hasn't made
  it into a bigger doc yet.
- **Projects/** — date-ranged activity isn't expressible as a lexical `search`; follow the
  doc-retrieval skill's date-range guidance and use `eval`, e.g.
  `obsidian vault=<vault-name> eval code="app.vault.getMarkdownFiles().filter(f=>f.path.startsWith('Projects/')).filter(f=>f.stat.mtime>=START&&f.stat.mtime<END).map(f=>f.path).join('\\n')"`
  with `START`/`END` set to the prior week's Unix-ms bounds — these usually signal active project
  work.
- **The previous week's own Weekly Planning note** — locate it with
  `obsidian vault=<vault-name> search query="path:Resources/Plans/{year}/Weekly" format=json` and read its
  unchecked `- [ ]` items as candidates to carry forward. Don't silently drop unfinished work;
  either roll it into this week's candidate pool (step 4) or note explicitly that it's being
  deprioritized.
- **The weekly plan from two weeks ago** — same search, one note further back. Only needed to
  apply the carry-forward limit below; don't otherwise mine it for content the way you do last
  week's note.

If a thread from last week is fuzzy rather than a clean keyword (e.g. "what were we worried about
with the migration"), don't stop at one search — follow the doc-retrieval skill's expansion pattern (3–5
deliberately varied queries, merge, rank by hit count) before concluding nothing happened.

### Carry-forward limit — three weeks and it stops rolling automatically

An item is eligible to enter the candidate pool (step 4) as a normal carried-over item the first
two times it shows up unchecked. **The third consecutive week, it doesn't get carried forward
again as-is** — decide instead whether to drop it or renegotiate it, since an item that's survived
two full weeks untouched usually means the scope, owner, or timeline was wrong, not that it just
needs one more week.

To find these: for each unchecked item in last week's note, check whether an equivalent item was
*also* unchecked in the note from two weeks ago. Match the same way `daily-plan`'s reconciliation
step does — normalize both sides (strip the trailing priority tag, stray punctuation, collapse
whitespace, lowercase), then treat it as the same item on an exact match or a clean ~30+ character
prefix match. An item unchecked in both of the last two notes has now gone three straight weeks
without being finished counting this week, so:

- **Don't feed it into step 4's candidate pool as a normal carried-over item.**
- Instead, call it out explicitly wherever you hand the finished plan back to the user — the same
  place you'd note a missing calendar (step 0) or an unroutable candidate — with the item's text and how
  long it's been sitting. Let the user decide: drop it outright, or redefine it (new scope, new
  owner, new deadline) as a *fresh* item, which resets its carry count since it's no longer the
  same commitment and starts fresh through the candidate pool next time.
- If the user isn't available to decide in this run (e.g. this is an unattended/scheduled run),
  default to **dropping it from the active checklist** rather than silently carrying it a third
  time, and still report it — a dropped item the user can revive is safer than a stale item that
  quietly became permanent scenery on the weekly plan.

## 3. Check the calendar for the upcoming week — only if `calendar` resolved

Skip this step entirely if the role is `none`. Otherwise use the connected calendar's own tools
(list events with the range set to the new week's Sunday
00:00 through Saturday 23:59) to see what's already on the books. Meetings on the calendar are a
strong signal for what belongs in the Goals section and often generate their own action items
(e.g., "prep slides for Wednesday's board sync").

## 3b. Any other role configured for this skill

Step 0 resolved every `weekly-planning` row in `SOURCES.md`'s `## Who reads what` table. Steps 1–3
consumed `vault` and `calendar`. **Anything left over is gathered here**, generically — that's what
makes a teammate's added source work without editing this file.

For each leftover role that resolved to a real tool, read its `contributes` cell and split it on
the arrow:

- **Left of the arrow — what to pull.** Query the tool for exactly that, scoped to the user
  (things assigned to, addressed to, or owned by them) and to the same window steps 2–3 used: last
  week for activity, the upcoming week for commitments. Where the arrow's wording doesn't settle
  which, gather both — this is the recall stage, and step 5 does the cutting.
- **Right of the arrow — where it lands.** Almost always *the candidate pool*: what you gather
  here joins step 4's pool and goes through the same generate → classify → rank pipeline as
  everything else, rather than being written straight onto the plan. A role whose arrow points at
  Weekly Goals instead is evidence for step 8, not a checklist item.

Nothing gathered here bypasses `action-item-classifier` or `prioritization-reranker`. A source
with no hand-written step is the one most likely to produce noise, so it gets the *same* precision
gate as the rest, not a lighter one.

Name every generic role in the step 11 handoff: what it was, how many candidates it contributed,
and how many survived.

## 4. Generate a broad candidate pool

This is the recall stage — the whole point is to over-generate rather than pre-judge quality;
`action-item-classifier` does the judging next. Pull every plausible task-shaped fragment out of
what steps 2–3 gathered:

- **Meetings** — any sentence that reads as a decision, follow-up, or open question with an
  implied next step, even if the phrasing is vague or the owner unclear. Don't pre-filter for
  clarity here.
- **Daily notes** — anything logged day-to-day that never made it onto a bigger doc, including
  items that are themselves unclear. Skip anything that's really the same thing as an item you're
  already carrying forward from last week's plan (below) — don't generate a second candidate for
  work already represented there.
- **Projects/** activity — a file's mtime alone isn't a candidate; where the content itself
  implies unfinished work (an open question left in a doc, an inline TODO, a half-finished
  section), pull that out as its own candidate.
- **This week's calendar**, if resolved — generate one prep-work candidate per event that
  plausibly needs it, even where step 2's gathered notes didn't mention it explicitly (e.g. a
  board sync on the calendar implies "prep slides," whether or not anyone wrote that down).
- **Last week's unchecked items that passed the carry-forward limit** (step 2) — these enter the
  pool as-is; they're already well-formed lines; they still go through classification and ranking
  below like everything else, since a line written weeks ago is exactly the kind that can have
  drifted vague without anyone noticing.

Record each candidate's source (which meeting, which day, which project, which calendar event) —
step 6 uses this to route it to a project or area header, and it's what lets the report in step 11
trace a surviving item back to where it came from.

Don't filter for vagueness, ownership, or triviality here. Over-generating at this stage and
cutting hard at the next is the point: a real to-do missed here never resurfaces on its own, while
noise generated here gets caught immediately in step 5.

## 5. Classify candidates

Run every candidate from step 4 through the `action-item-classifier` skill; keep only what clears
its 2-of-4 bar. Meeting-derived candidates deserve the scrutiny that skill already applies —
this vault's meeting notes are exactly the verbose, poorly-diarized source it's built for.

Also apply one screen specific to this vault that the classifier itself doesn't check (it has no
concept of "the user" as a person): drop anything that reads as clearly someone else's task with
no involvement from the user, unless the source explicitly assigns it to them.

Track the drop count per source (e.g. "14 meeting-derived candidates, 5 survived") — surfacing how
aggressively step 4 over-generated is more useful to the user than silently handing over a
pre-curated list with no sense of what got cut.

## 6. Route surviving candidates to a project or area

Match each surviving candidate to one of the **Project or Area headers** enumerated in step 9 —
projects from `CLAUDE.md`, areas from the folders under `Areas/`. Never work from memory: projects
and areas get added and retired. Use the candidate's recorded source (step 4): the meeting's
subject/attendees, the daily note's context, the project folder it came from, or the calendar
event it was generated from. Use a known subproject H3 when the content clearly maps to one.

Administrative and personal work routes the same way as everything else — an email to chase for
Bedrock belongs under `# Bedrock`, a doctor's appointment under whichever area covers it. Don't
reintroduce a catch-all section for it.

**If a candidate doesn't clearly belong to any project or area**, don't invent a header and don't
quietly drop it. Hold it out of the checklist and list it with the report in step 11, saying what
it is and that it has no home — usually that means either the item needs rewording, or the user
needs a new `Areas/` folder for that responsibility. Both are the user's call, not this skill's.

## 7. Assign priority and rank

Run every routed candidate through the `prioritization-reranker` skill — it reads `PRIORITIES.md`
and recent daily-plan history on its own; there's nothing extra to gather here.
**The priority tag it returns is what goes on the checklist line** — this replaces hand-inferring
a tag from scratch. `P(completion)` isn't written into the file, but determines item order within
each project/subproject and each area: highest first, so the top of a section is
where the user should actually look first.

Carry forward any mismatch `prioritization-reranker` flags (a `[P1]` with suspiciously low
`P(completion)`, or a `[P3]` scoring surprisingly high) into the report in step 11 — worth a second
look even though it doesn't change where the item lands.

## 8. Write Weekly Goals

A short bullet list, one bullet per project or area that has real momentum this week (bold the
name, like the examples). 1–3 sub-bullets under each with the top outcomes for the week — not a
restatement of every checklist item, just the headline; the section's top-ranked item(s) from
step 7 are a natural source for what to headline, but this section is prose, not a checklist
mirror. Skip projects and areas with nothing going on rather than padding this section.

## 9. Write the Project and Area checklists

This is the part the user cares most about getting right: **always include an H1 header for every
project and every area**, even if nothing is planned for it this week — don't drop one just
because it's quiet, since the empty header itself is a useful signal ("nothing planned here this
week" is information).

**Where the headers come from — read them fresh every run, never from memory:**

- **Projects** — `CLAUDE.md`'s `# Projects` section is the authoritative enumeration: one H1 per
  top-level project, in the order `CLAUDE.md` lists them. Cross-check against the folders under
  `Projects/` if `CLAUDE.md` looks out of date, and mention the discrepancy rather than guessing.
- **Areas** — the subfolders of `Areas/` are the authoritative enumeration; `CLAUDE.md`'s
  `# Areas` section describes the folder but doesn't list its contents, so the folder wins. List
  areas alphabetically. **`Areas/` is often empty** — that's a normal state, not an error: write
  no area headers at all that week rather than inventing plausible ones.

Order the sections **projects first (in `CLAUDE.md` order), then areas (alphabetical)**, so the
same note reads the same way week to week.

Within a project or area, use an H3 for subprojects — only add a subproject header if there's
actual content for it this week (don't pre-populate empty subproject stubs). `CLAUDE.md` names the
known subprojects under each project; `Projects/<project>/` and `Areas/<area>/` subfolders are the
other signal. Other clients or subprojects can appear as the week's activity calls for it — add an
H3 following the same pattern.

Each checklist item is a `- [ ]` (or `- [x]` if the user mentions something's already done),
tagged with what step 7 assigned. Populate each project/area/subproject from the candidates step 6
routed to it, ordered by `P(completion)` descending (highest-likelihood item first).

## 10. Example of the target shape

```markdown
---
created: "2026-08-09 08:00:00"
tags:
  - weekly-planning
---

# Weekly Goals
- **<Project B>:**
  - Ship the indexing POC
  - Close out board follow-ups
- **<Project D>:** Finish endpoint testing

# <Project A>
- [ ] Scope review requirements `[P1]`

# <Project B>
- [ ] Email catch-up on the migration thread `[P2]`
### <Subproject B1>
- [ ] Read indexing white paper `[P3]`
### <Subproject B2>
- [ ] Issue-tracker + Git to warehouse ETL `[P2]`

# <Project C>

# <Project D>
- [ ] Follow up with the new client `[P2]`

# <Area A>
- [ ] Renew the insurance policy `[P2]`

# <Area B>
```

`<Project A>` and `<Area A>` and friends are placeholders — substitute the real project H1s from
`CLAUDE.md`, in its order, followed by the real area H1s from `Areas/`, alphabetically. Note the
empty `# <Project C>` and `# <Area B>` headers above: that's expected when there's genuinely
nothing to plan there, not a bug. Note also that the email catch-up sits under the project it
belongs to rather than in a generic bucket. Where a section has more than one item, its order
reflects step 7's ranking, not the order candidates happened to be generated in.

## 11. After writing

Log the run: append one line to the current month's log at `.system/log/log-YYYY-MM.csv` (pipe-delimited: `timestamp|action|path|summary`; see the `log-manager` skill). Create the file if this is the first entry of the month. Note that the note was created, and include: **every `weekly-planning` role in `SOURCES.md`'s `## Who reads what` table and what each resolved to** (naming any that came back `none` or stale), how many candidates step 4 generated vs. how many survived classification (step 5), any items dropped or flagged for renegotiation by the carry-forward limit, any candidates step 6 couldn't route to a project or area, and any priority/probability mismatches step 7 flagged.

Report the carry-forward-limit items, the unroutable candidates, and the mismatch flags back to the user directly, not just in the log — that's the point of flagging rather than silently dropping or burying them.

Do not write to `System/log.md` — that log is retired (see `.system/log/log-archive.md` for
pre-2026-08 history).

# Update Weekly Plan

A lighter-weight pass, meant to run unattended — daily at **4:30pm**, via the
`weekly-plan-daily-update` scheduled task. It does two things to the current week's plan:

- **Reconcile** completions — the user checks items off in the daily note and rarely goes back to
  the weekly plan, so anything closed in a recent daily note gets closed in the weekly plan too.
- **Stage** action items from recent meeting notes into `#### Suggested` blocks, after running
  them through the same generate → classify → rank pipeline as Create Weekly Plan.

The end-of-day slot is deliberate: it puts the run after the user has worked through the day's
note, so the day's completions land in the weekly plan the same day rather than a day late — and
before the next morning's `daily-plan-run` builds tomorrow's note off this plan, so finished work
doesn't get pulled forward as a fresh open item.

Beyond those two, it doesn't touch anything the user has written or curated.

## 1. Find this week's plan

Locate the current week's note in `Resources/Plans/{year}/Weekly/`, using the same Sunday-start logic as
Create Weekly Plan step 1. This path only *edits* an existing note — if no note exists yet for
the current week, run Create Weekly Plan first instead of improvising a new file here.

## 2. Reconcile completions from recent daily plans

the user works out of the daily note, so an item often gets checked off there while the same line
sits open in the weekly plan. Close that gap — **daily `- [x]` wins over weekly `- [ ]`**.

This is the half of the run that matters most day to day. Staging is additive and easy to catch up
on later; reconciliation is what keeps the weekly plan from drifting into a wall of stale open
boxes for work that's already done.

**The most recent daily note is the primary source.** This path is scheduled for end of day
(4:30pm), after the user has worked through today's note, so *today's* daily plan is the one
carrying the day's completions — read it first and reconcile it in full. That timing is the whole
reason this step can trust today's note: a morning run would find it freshly generated and empty,
and every completion would sit unreconciled until the next day.

**Then sweep the two preceding days as a catch-up pass**, so a skipped or failed run doesn't
strand a day's completions permanently. Re-reading a day that was already reconciled is a no-op —
the match is confidence-gated and the flip only ever goes one direction, so nothing changes on a
second pass.

**Which daily notes to read.** Files in `Resources/Plans/{year}/Daily/`, by `YYYY-MM-DD` filename prefix:
the last three days inclusive of today, **but never earlier than the current week's Sunday**.
The week boundary is a hard floor, not a rounding detail — a daily note from last week was built
off the *previous* weekly plan, and recurring work ("email catch-up," "clear compliance tasks")
legitimately reappears as a fresh open item this week. Reconciling across the boundary would
close those the moment the week started. Early in the week this leaves one or two notes in
range, sometimes zero; that's the correct answer, not a reason to widen the window.

**How to match a daily item to a weekly one.** Normalize both sides before comparing — strip the
trailing `` `[P1]` ``/`[P2]`/`[P3]` tag, strip stray trailing backticks and punctuation, collapse
whitespace, lowercase. Then treat it as a match when:

- the normalized strings are equal, or
- one is a clean prefix of the other and the shorter side is at least ~30 characters — daily
  notes often carry a truncated or annotated variant of the same line (e.g. weekly "Review Adam's
  MongoDB doc + Grit sample records — confirm data shape…" vs. daily "…(due today)" appended).

Anything short of that is **not** a match. Two items that merely share a project or a name are
not the same item. When in doubt, leave the weekly line alone and mention it in the report — a
falsely-closed item disappears from the user's week silently, which is far worse than one they have to
check off himself.

**What to do with a match.** Flip `- [ ]` to `- [x]` on that line and change nothing else: the
item text, the priority tag, the indentation, and the line's position all stay exactly as they
are. Reconciliation is a checkbox edit and nothing more.

**Boundaries on this step:**

- **One direction only.** Daily checked → weekly checked. Never the reverse: an item checked in
  the weekly plan but open in a daily note stays checked. Never uncheck anything, ever.
- **Never create a line.** If a completed daily item has no match in the weekly plan, do not add
  it — checked or unchecked. Report it as completed-but-unplanned and move on.
- Items inside `#### Suggested` are eligible to be reconciled like any other line; if the user did
  the work, it's done regardless of which block it sits in.
- Sub-bullets nested under a checklist item are context for that item, not separate items — match
  and flip only the `- [ ]` line itself.

Count the flips; step 11 reports them.

## 3. Gather recent meeting notes

**Sources.** This entry point resolves the same `weekly-planning` rows from `SOURCES.md`'s
`## Who reads what` table as Create Weekly Plan step 0 — the table is per skill, not per entry
point. Run that same preflight first. On an unattended 4:30pm run the "ask the user" steps can't
happen: treat any unresolvable role as `none`, proceed with what resolved, and name every gap in
the step 11 report. Beyond `vault`, use each resolved role the way step 3b describes, scoped to
the same past-two-days window this step uses; whatever it returns joins step 4's candidate pool
and goes through the same classify → rank pipeline.

Use the `doc-retrieval` skill to find candidates:
`obsidian vault=<vault-name> search query="path:Resources/Meetings" format=json`, then keep only files dated
within the past two days (inclusive of today, by the `YYYY-MM-DD` filename prefix). Read each
match in full rather than skimming a preview.

## 4. Generate a broad candidate pool

Same recall-first approach as Create Weekly Plan step 4, scoped to just these meeting notes: pull
out every sentence that reads as a decision, follow-up, or open question with an implied next
step — even where the phrasing is vague or the owner unclear. Don't pre-filter for concreteness or
ownership here; that's step 5's job. Over-generating and cutting hard next beats guessing
conservatively now and quietly missing something the user actually needed to see.

## 5. Classify candidates

Run every candidate from step 4 through the `action-item-classifier` skill; keep only what clears
its 2-of-4 bar.

Also apply the same vault-specific screen Create Weekly Plan step 5 does — drop anything that
reads as clearly someone else's task with no involvement from the user, unless the note explicitly
assigns it to them. This isn't one of `action-item-classifier`'s own criteria (it has no concept of
"the user" as a person), so it has to be applied here on top of, not instead of, that skill's bar.

## 6. Check for duplicates

Before doing any more work on a surviving candidate, check whether an equivalent item (same or
near-identical wording) already exists anywhere in the note — in the real checklist or in
`#### Suggested` for any section. Drop it here if so, before routing or ranking spend any more
effort on it; the same follow-up surfacing in two meetings shouldn't produce two lines, and
there's no reason to route/rank something you're about to discard anyway.

## 7. Route each surviving item to a project or area

Match each item to one of the Project or Area headers from Create Weekly Plan step 9 — projects
from `CLAUDE.md`, areas from the folders under `Areas/`, never from memory — based on the meeting's
subject, attendees, or explicit mentions. Use a known subproject H3 (again per `CLAUDE.md`) when
the content clearly maps to one. Administrative follow-ups go under the project or area they serve;
there is no catch-all section to fall back on.

If an item doesn't clearly belong to any project or area, don't stage it and don't create a header
for it — name it in the step 11 report instead, so the user can reword it or add the area.

## 8. Assign priority and P(completion)

Run every routed, surviving candidate through the `prioritization-reranker` skill, same as Create
Weekly Plan step 7. Suggested items get a real priority tag now instead of going untagged — it
gives the user a head start when they review and promote, instead of making them infer priority
from scratch. The tag doesn't change what "Suggested" means: it's still advisory and unreviewed
until the user promotes it into the section's real checklist. `P(completion)` isn't written into
the file; use it to order items within a `#### Suggested` block, highest first.

## 9. Add items to a Suggested checklist

Within the matched project (and subproject, if applicable) section, add or reuse an
`#### Suggested` H4 subsection — placed after any existing content in that section. Add each
surviving candidate as its own checklist line, tagged per step 8, highest `P(completion)` first:

```
- [ ] Item text `[P2]`
```

The tag being present doesn't promote the item — placement under `#### Suggested` is still what
marks it unreviewed. Priority gets *re-confirmed* (not just copied) when the user reviews and
promotes an item out of `#### Suggested` and into the section's real checklist, since time may
have passed since this step ran.

## 10. Don't touch anything else

Two edits are in scope for this path, and only two: adding lines under `#### Suggested`
(steps 3–9), and flipping `- [ ]` to `- [x]` on an existing line that step 2 confidently matched
to a completed daily item. Everything else is off limits — Weekly Goals, the section headers
themselves, the wording of any existing checklist item, its priority tag, its position in the list. That review
pass belongs to the user.

## 11. After writing

Log the run: append one line to the current month's log at `.system/log/log-YYYY-MM.csv` (pipe-delimited: `timestamp|action|path|summary`; see the `log-manager` skill). Create the file if this is the first entry of the month. Note which meetings were scanned, which `weekly-planning` roles resolved (and which came back `none` or stale), how many candidates were generated vs. survived classification (step 5), how many were staged, and how many items were reconciled to complete.

Report back with both halves of the run: items staged (with their assigned tag) and under which
sections, and items closed by reconciliation (naming them, and which daily note each came from).
Also name anything that was checked off in a daily note but had no confident match in the weekly
plan — that's usually either work the user never planned or a wording drift worth fixing by hand —
and anything step 7 couldn't route to a project or area.
