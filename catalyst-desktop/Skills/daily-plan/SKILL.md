---
name: daily-plan
description: Build or update the user's daily planning note for the knowledge-base vault — pulls unchecked action items from the current weekly plan, runs them through the `action-item-classifier` and `prioritization-reranker` skills, and writes the top ten (by priority tag and estimated same-day completion likelihood) into H1 sections named for the Project or Area each item belongs to, plus surfaces unanswered messages directed at the user into a Communication checklist from both whatever chat tool and whatever email inbox they have connected (vendor/automated email is filtered out), and a News brief of the last 24 hours drawn from the feeds listed in SOURCES.md plus web searches derived from the vault's own tags, projects, and areas. Which sources this skill reads is not hardcoded — it resolves its own rows from the `## Who reads what` table in `SOURCES.md` at run time, so adding or removing a source is an edit to that file, never to this skill. Use whenever the user asks to "do my daily plan," "plan today," "set up today's note," "what's on my plate today," or references a daily planning note, and also when running as a scheduled weekday-morning task. Always pulls fresh data from the weekly plan and the connected sources rather than guessing — the user's priorities and inbox shift day to day, so a stale daily note is worse than no daily note.
tags:
  - skill
  - planning/daily
  - knowledge-base
  - workflow
  - automation
tagged: '2026-09-02'
tagged_hash: 4c36f41add92f127
type: concept
---

# Daily Plan

Builds the user's daily planning note: a single Markdown file per day, filed under
`Resources/Plans/{year}/Daily/`, carrying today's action items (pulled from the current weekly plan,
grouped under one H1 per Project or Area) and a Communication section of unanswered message threads
that need a response.

**Section shape.** Task sections are H1 headers named for the Project or Area the items came from —
`# Bedrock`, `# Family` — never a generic bucket like Admin, Goals, or Personal. Unlike the weekly
plan, today's note only carries a header for a project or area that actually has an item today; a
daily note is a short list, and empty headers for every project would bury the handful of things
that matter. `# Communication`, `# News`, and `# Notes` are the only non-task H1s, and they always
come last, in that order.

## 0. Sources preflight — before steps 4 and 5

Steps 1–3 read only the vault and always work. Steps 4 and 5 read outside sources, and **must not
assume any of them exists.**

**This skill does not carry its own list of roles.** Read the `## Who reads what` table in
`SOURCES.md` and take every row whose `skill` is `daily-plan` — that set, and only that set, is
what this run resolves. A teammate adds or removes a source for this skill by editing that table;
nothing in this file changes. If the table has no `daily-plan` rows at all, ask the user which
sources this skill should read, then write the rows before continuing.

Each row gives a `role`, a `contributes` string of the form `<what to pull> → <where it lands>`,
and `required` (`always` or `optional`). Resolve every row **independently** — one role being
connected doesn't excuse skipping the others, and one being `none` doesn't block using the rest.

For each row:

1. Look up that role in the registry table at the top of `SOURCES.md` to get the tool that fills it.
2. If there is no registry row, **ask which tool fills that role** — offering only what is
   actually connected in this session (enumerate the available MCP servers and Claude connectors).
   If nothing can fill the role, record `none`.
3. **Verify before use.** If the registry names a tool that isn't present this session, treat it as
   `none` for this run and say so; do not silently switch tools.
4. **Reading a personal inbox or private chat is sensitive** — the first time a role resolves to
   a real tool (not `none`), confirm the scope with the user (for `chat`, this covers private
   channels/DMs; for `email`, confirm that reading the inbox itself is fine) and record that
   consent in the registry row's `notes`. Once recorded, don't re-ask every run.
5. Write the confirmed answer back to `SOURCES.md`.
6. A row marked `always` that resolves to `none` or stale is a hard stop — say what's missing
   rather than producing a note built on a source you couldn't read. An `optional` row that
   resolves to `none` is skipped and **named in the handoff and the step 6 log entry**.

### How each resolved role gets used

Some roles have bespoke steps below because generic handling isn't good enough for them:

| role | step |
| --- | --- |
| `vault` | steps 1–3 (weekly plan, previous daily notes) |
| `calendar` | step 2's same-day-deadline check |
| `chat`, `email` | step 4 — thread grouping, reply detection, vendor-mail filter |
| `web` | step 5 — the two-lane news brief |

**Any other role configured for `daily-plan` is handled generically in step 5b** by following its
`contributes` arrow. Never drop a configured role just because this file doesn't name it.

If **both** `chat` and `email` resolve to `none` (or neither is configured), still write the
`# Communication` header, with one line underneath: `- (no chat or email source connected)`. If
only one resolves to `none`, don't pad the section with a placeholder line — the other source
still has real content — but name the missing one in the handoff and the step 6 log entry, the
same way other gaps in this skill get surfaced rather than silently absorbed. `# News` follows the
same pattern with its own `web` row (step 5).

**What `web` means.** It's the session's own web search and fetch tools, not a configured product:
whatever this session has for running a search and for retrieving a URL. Both halves matter and
degrade separately — search alone can still produce a brief; fetch alone can still read the feeds
listed in `SOURCES.md`. Record which half is available in the registry row's `notes` rather than
flattening a partial capability to `none`. Step 5 also reads the `# External Sources` section of
`SOURCES.md` directly; that list is content, not a role, so it needs no preflight of its own
beyond noticing whether it's empty.

Every `vault` lookup below — locating the current weekly plan, finding the most recent previous
daily note — goes through the **`doc-retrieval` skill's** Obsidian CLI conventions
(`vault=<vault-name>` first, preflight, path-scoped `search`) rather than raw filesystem globbing.

## 1. Find or create today's note

Confirm today's date (`date` in the shell, or the `currentDate` context if present). Filename
follows the existing convention in the vault: `Resources/Plans/{year}/Daily/YYYY-MM-DD.md` (zero-padded,
ISO date).

- **If the file already exists**, treat this run as an update, not a rewrite: never overwrite or
  clear anything the user has already written by hand — checked-off items, notes, admin lines they
  added himself. Only add new lines per the steps below, and skip anything that's a near-duplicate
  of what's already there.
- **If it doesn't exist**, write it directly with exactly this skeleton. Do not copy a file
  out of `Templates/` — see the note below:

  ```
  ---
  created: "YYYY-MM-DD HH:MM:SS"
  tags:
    - daily-planning
  ---

  # Communication

  # News

  # Notes
  ```

  That's the whole skeleton — no task headers yet. Project and Area sections get inserted above
  `# Communication` in step 2, as items are actually routed to them. Always emit both
  `# Communication` and `# News`, and keep them present but empty when there's nothing to report,
  so the note's shape stays predictable day to day.

  `created` takes the real timestamp at write time, formatted exactly as shown.

  **Why this skeleton lives here and not in `Templates/`.** The vault does keep a
  Templates-plugin copy for when the user makes a note by hand in Obsidian, but it is not what
  this skill reads, and copying it would be a bug: its `created` value is `{{date}} {{time}}`,
  which only Obsidian's Templates plugin expands, and only at insert time. An agent copying that
  file writes those braces literally, and the note ends up with a `created` property whose value
  is the string `{{date}}`. Every date-ranged query that later filters on `created` then silently
  skips the note. Write the frontmatter yourself.

  **Older notes may still use `# Admin` / `# Goals`.** Notes written before this skill moved to
  Project/Area headers have that shape. When updating such a note, leave those sections and their
  existing lines alone — don't restructure a day the user has already worked out of — and add
  today's new items under Project/Area H1s as described below.

## 2. Pull today's action items from the weekly plan

Find the current Sunday–Saturday week's note using the `doc-retrieval` skill —
`obsidian vault=<vault-name> search query="path:Resources/Plans/{year}/Weekly" format=json` — then pick the
note whose range covers today (same week-finding logic as the `weekly-planning` skill: find the
Sunday on or before today; that note covers this week). If no weekly plan exists yet for the
current week, skip this step and add no task sections — don't improvise a weekly plan from
here, that's the `weekly-planning` skill's job.

Read every unchecked `- [ ]` item in the weekly plan's **curated** sections: every Project and
Area checklist — one H1 per project or area, plus any subproject H3s beneath it. The project/area
set is whatever the weekly plan contains; `CLAUDE.md`'s `# Projects` section and the folders under
`Areas/` are the authoritative lists if you need to reason about it. (A weekly plan written before
this skill moved to Project/Area headers may still carry `# Admin` / `# Personal` sections — read
their unchecked items too, and route them per the rules below.) **Skip `#### Suggested` / `### Suggested`
subsections** — those are unreviewed items staged by the daily meeting-scan automation, not things
the user has actually prioritized yet. This exclusion is about review status, not quality — it
stays in place regardless of the pipeline below, since promoting a Suggested item is the user's
call, not this skill's.

### Candidates → classify → rank

Everything left after the Suggested exclusion is the **candidate pool** — every unchecked item in
the curated sections, not just the ones already tagged `[P1]`. Pulling the full curated set in as
candidates (rather than pre-filtering on tag) means an item `PRIORITIES.md` actually treats as
important, but that never got hand-tagged `[P1]` on the weekly plan, still gets a fair shot at
today's note instead of being silently excluded by a stale tag.

1. **Recall — gather candidates.** All unchecked items from the curated sections, as above.
2. **Same-day-deadline flag.** For each candidate, separately check for a confirmed same-day
   deadline — either signal is sufficient:
   1. **Explicit date language in the item's own text** — a literal date, "by \<weekday\>", "EOD
      today", "due \<date\>", etc. Resolve weekday/relative language against today's actual date
      before deciding it matches; don't guess.
   2. **Today's calendar.** Check today's events (`list_events` bounded to today's date, or
      `search_events` with a keyword from the item) for a clear correspondence — matching
      person's name, project, or topic. A loose thematic resemblance isn't enough; only flag it
      if the match is unambiguous (e.g. the item says "Schedule AI testing call with Kim +
      Jeremy" and today's calendar already has that meeting on it). This flag doesn't gate
      inclusion anymore (ranking handles that) — it's evidence step 4 needs.
3. **Precision — classify.** Run each candidate through the `action-item-classifier` skill. This
   mostly matters for items that have drifted vague after several weeks of being carried forward —
   a freshly hand-written weekly item almost always clears the bar trivially. Anything that fails
   is dropped from today's candidates; it stays untouched on the weekly plan, just not proposed
   for today.
4. **Rank.** Run the surviving candidates through the `prioritization-reranker` skill — it reads
   `PRIORITIES.md` and recent daily-plan history on its own, so there's nothing extra to gather
   here. Pass along the same-day-deadline flag from step 2 so it factors into both the assigned
   priority tag and `P(completion)`. **The tag it returns supersedes whatever tag the weekly-plan
   line carries** for purposes of today's note — it reflects the current state of
   `PRIORITIES.md` and the calendar, which may have moved since the weekly-plan line was last
   tagged. This never edits the weekly-plan line itself, only what gets written into today's note.

Each item that survives classification goes under an H1 named for the **Project or Area it came
from in the weekly plan** — including administrative work (scheduling, sending an email, filling
out a form). Logistics for a project belong to that project, not to a separate bucket; that's the
whole reason Admin and Personal are gone.

- **Header name** — the weekly plan's own H1 for that section, verbatim. Project names ultimately
  come from `CLAUDE.md`'s `# Projects` section, area names from the folders under `Areas/`; take
  them from the weekly plan rather than from memory.
- **Subprojects** — keep the weekly plan's subproject breakdown, as an H3 under the project's H1,
  when the item belongs to one.
- **Only create a header when it has an item.** Don't pre-populate empty Project/Area sections.
- **Order** — projects first, in `CLAUDE.md` order, then areas, alphabetically. Within a section,
  order by step 4's ranking.
- **An item from a legacy `# Admin` / `# Personal` section of the weekly plan** — route it by its
  content to the project or area it actually belongs to. If nothing fits, leave it off today's
  note and name it in the handoff (below) rather than reviving a generic bucket to hold it.

Use the tag `prioritization-reranker` assigned. For an item that made the cut mainly because of a
same-day deadline (i.e. it isn't `[P1]`), append `` `(due today)` `` right after the item text,
before its tag, so the user can tell at a glance why it's there:

```
- [ ] Finish MACUBusiness endpoints (due today) `[P2]`
- [ ] Rob Daines response (due today)
```

Before adding a line, check it isn't a near-duplicate of something already in today's note
(any section, including items already checked off) — this is meant to run every morning, and the same
still-open item will otherwise get re-added day after day until the user finally checks it off. Do
this dedup check before classifying/ranking a candidate, not after — no point spending a
classifier or reranker call on something that's already there.

**Never propose more than ten items total, combined across every Project and Area section.** A daily note is
meant to be actually achievable in a day; a list that already reads like a full week's backlog
defeats the point of narrowing it down. Take the top ten off the reranked list (step 4's sort:
priority tag first, `P(completion)` descending within a tag) and leave the rest on the weekly plan
for another day.

Don't silently drop what doesn't make it in. When you hand the note over, and in the step 6 log
entry, name:

- Items cut by the ten-item cap (item text and which project or area it came from).
- Items dropped by the classifier (item text and which project or area) — these look different from a
  plain cap-overflow, since they signal the weekly-plan line itself may need rewording, not just
  "do it tomorrow instead."
- Any priority/probability mismatch `prioritization-reranker` flagged (e.g. a `[P1]` it also
  marked as likely stuck) — worth a second look even for items that did make today's cut.

Communication items aren't counted against the ten-item cap; it's specifically about the day's
proposed workload across the Project and Area sections.

This step only ever *reads* the weekly plan and the calendar — never edit either from here.

## 3. Nothing to pull?

If there's no weekly plan for the current week, or it has no open `[P1]` items and nothing due
today in its curated sections, write no task sections at all — the note is just `# Communication`,
`# News`, and `# Notes`. That's expected and meaningful (nothing outstanding is urgent), not a bug — move on
to Communication rather than inventing filler.

## 4. Communication — messages awaiting a reply

Pull from `chat` and `email` independently — whichever of them step 0 resolved — and merge into
one list. If neither is configured for this skill in `SOURCES.md`, or neither resolved, use the
`none` behaviour from step 0. If a teammate has configured an additional role whose `contributes`
arrow points at `# Communication`, step 5b's generic handling merges into this same list.

Read-cursor state is generally not exposed by either kind of tool — there is rarely a "list my
unread messages" call. The practical stand-in is the same for both: messages **directed at the
user** that they haven't already replied to, since the last time this note was generated.

**Shared anchor timestamp.** Find it once via the `doc-retrieval` skill:
`obsidian vault=<vault-name> search query="path:Resources/Plans/{year}/Daily" format=json`, sort the hits
by filename descending, skip today's note, and take the `created` frontmatter value of the next
most recent (i.e. the last time daily-plan ran, whether that was yesterday or further back). If
no earlier daily note exists, default to 24 hours before now. Convert to a Unix timestamp (e.g.
`date -d "<created value>" +%s`) if a tool wants one. Use this same anchor for both sources below
so the two lists cover the same window.

### Chat (if resolved)

1. Search the connected tool for messages addressed to the user (direct messages and
   @-mentions) since the anchor timestamp, most recent first. Most chat search syntaxes have an
   equivalent of `to:me` plus an `after`/`since` bound — use the tool's own filters rather than
   pulling everything and filtering locally.
2. Group hits by thread (a top-level message and its replies count as one thread, not one line
   each). For each distinct thread with no reply from the user after its last message — read the
   thread when a hit is ambiguous about whether they already responded — add one candidate:

   ```
   Reply to <person> in <channel-or-DM> re: <one-line gist>
   ```

   One candidate per unanswered *thread*, not per message: five unread replies in one thread is
   still one action item ("catch up on thread"), not five near-identical lines.
3. Skip anything the user has already replied to.

### Email (if resolved)

1. Search the connected tool for messages **addressed to the user personally** (the user is in
   `To:`, not only `Cc`/`Bcc`, and not one of a large distribution list) since the anchor
   timestamp, most recent first, using the tool's own filters.
2. Group hits by thread, same as chat — a thread with several unread messages is one candidate.
3. Skip anything the user has already replied to (a reply from the user is the last message in
   the thread).
4. **Skip vendor and automated mail** — this section is for correspondence with people, not
   notifications. Drop a thread if any of these hold, unless it's ambiguous (see below):
   - The sender address is clearly automated: `no-reply@`/`noreply@`/`do-not-reply@`,
     `notifications@`, `alerts@`, `updates@`, `mailer@`, `bounce@`, or similar.
   - The tool's own categorization marks it promotional/bulk (e.g. a Promotions, Updates, or
     Forums label/category) rather than the primary inbox category.
   - It reads as a receipt, invoice, shipping notice, newsletter, marketing send, password-reset
     or security alert, or system-generated status update rather than a message from a person.
   - It carries bulk-mail signals the tool surfaces, like an unsubscribe link/header, or the
     recipient list is large/undisclosed rather than being personally addressed.

   **When it's genuinely unclear whether the sender is a real person**, keep the thread rather
   than drop it — the signals above are usually unambiguous (a `no-reply@` address, a Promotions
   label), so an unclear case is more likely a real person than a well-disguised vendor email;
   missing an actual person's message is worse than one borderline vendor thread slipping
   through.
5. Add one candidate per surviving thread:

   ```
   Reply to <person> (email) re: <one-line gist>
   ```

### Merge and write

Combine the chat and email candidates into a single `# Communication` list, most recent first
across both sources:

```
- [ ] Reply to <person> in <channel-or-DM> re: <one-line gist>
- [ ] Reply to <person> (email) re: <one-line gist>
```

Leave `# Communication` present with just the header if nothing turns up from either source —
same reasoning as the task sections in step 3, an empty section is informative, not clutter.

## 5. News — a brief of the last 24 hours

`# News` is a short current-events brief, written **for this user specifically**: not a headline
dump, but the handful of things from the last day that bear on the projects and areas they're
actually working on. Skip this step entirely if `web` resolved to `none` in step 0 — write the
`# News` header with one line underneath, `- (no web source available this session)`, and name it
in the handoff.

### 5a. Build the query set

Two lanes feed the brief. Run both when `web` supports both; run whichever the available half
supports otherwise.

**Lane 1 — the sources the user chose.** Read the `# External Sources` section of `SOURCES.md`.
It holds two kinds of entry, and they are handled differently:

- **A bare URL** (e.g. a news aggregator, an org's blog, a product's release page) — fetch it and
  read what's on it. This is a curated list; the user put each entry there deliberately, so a
  fetch failure is worth reporting, not silently swallowing.
- **An entry nested under `Web Search:`** — a standing search directive, not a page to fetch (e.g.
  a person whose posts the user wants to track). Turn it into a search query rather than trying to
  retrieve it as a feed, since the underlying platform usually can't be fetched directly.

If the section is empty or missing, that's lane 1 done — say so in the handoff and run lane 2.

**Lane 2 — searches derived from the vault's own vocabulary.** Build 3–6 queries from what the
user actually works on:

1. **Frequent tags** — `.system/wiki/cli.sh vocab` prints the tag vocabulary with counts,
   most-used first.
2. **Projects** — `CLAUDE.md`'s `# Projects` section and its named subprojects.
3. **Areas** — the folders under `Areas/`.
4. **Current priorities** — `PRIORITIES.md`, which is the sharpest signal of the three since it's
   what the user says matters *right now*.

**Translate, don't paste.** The top of `vocab` is dominated by two kinds of tag that make terrible
search queries: vault machinery (`#skill`, `#planning`, `#knowledge-base`, `#automation`,
`#reference`, `#workflow`, `#obsidian`) and private names (an employer, a project codename) that
either return nothing or return an unrelated company. What you want is the **technology, domain,
or field underneath** — a tag on a database-migration project becomes a query about that database
and that kind of migration; an area becomes the subject that area is about. Drop any tag that
doesn't survive that translation instead of forcing it into a query.

### 5b. The 24-hour window

Only items **published in the last 24 hours** qualify. Use the tool's own recency filter where it
has one, and check the publication date on each candidate regardless — search tools surface older
material for a recent-sounding query all the time.

If the previous daily note is more than 24 hours old (a Monday run after a weekend, or a skipped
day), widen the window to cover the gap since that note, **capped at 72 hours**, and say so in the
handoff — the point is that the user doesn't miss Saturday's news on Monday, not that the brief
silently drifts into a week-in-review.

### 5c. Select and synthesize

Gather candidates broadly across both lanes, then cut hard — the same recall-then-precision shape
the rest of this skill uses. Keep an item only if it clears all three:

- **Real and retrieved.** It came back from an actual search or fetch in this run. Never write an
  item from memory, and never reconstruct a plausible headline — the model's own recollection of
  "recent news" is exactly the failure this section has to avoid.
- **In the window.** Its publication date is confirmed and inside 5b's window.
- **Relevant to this user.** It connects to a project, an area, a `PRIORITIES.md` item, or a
  standing interest the `# External Sources` list establishes. General interest isn't enough.

Then **synthesize rather than list**: where two or three items are the same story, write one entry
citing the strongest source instead of three near-duplicates, and where an item bears on the
user's work, say how in the description — that connection is the whole value of the section over
an ordinary feed reader.

**Cap the brief at seven items, and don't pad to reach it.** Three genuinely relevant stories are
a better brief than seven where four are filler; a section the user learns to skim past is worse
than a short one. If a quiet news day yields nothing that clears the bar, write the header with
`- (nothing relevant in the last 24 hours)` underneath and move on — same reasoning as an empty
Communication section.

**Don't repeat yesterday.** Before writing an item, check the previous daily note's `# News`
section (already located for step 4's anchor) and today's own, if this is a re-run. Skip anything
already covered unless there's a genuine development, in which case lead the description with
what's new.

### 5d. Write it

One entry per item, ordered by relevance to the user's current priorities — not by source, and not
by recency:

```
- **[<title>](<url>)** · <YYYY-MM-DD>
  <One or two sentences: what happened, and — where there's a real connection — what it bears on
  in <Project or Area>.>
```

Four things per entry, all four required: title, publication date, link to the original source,
and the description. Rules on each:

- **Link to the original**, not to an aggregator's comment page or a summary of it — if the
  aggregator entry is what surfaced it, follow through to the source it points at.
- **Never invent a URL or a date.** If the publication date can't be confirmed from the item
  itself, drop the item; a guessed date defeats the 24-hour window the section promises.
- **Don't force a project connection.** An item can be relevant to a standing interest without
  mapping onto a specific project — a strained "this relates to X" reads worse than a plain
  description and trains the user to distrust the ones that are real.

## 5b. Any other role configured for this skill

Step 0 resolved every `daily-plan` row in `SOURCES.md`'s `## Who reads what` table. Steps 2, 4 and
5 consumed the ones this file names by hand. **Anything left over is handled here**, generically —
that's what makes a teammate's added source work without editing this file.

For each leftover role that resolved to a real tool, read its `contributes` cell and split it on
the arrow:

- **Left of the arrow — what to pull.** Query the tool for exactly that, scoped to the user
  (things assigned to, addressed to, or owned by them — not the whole workspace) and to today,
  using step 4's shared anchor timestamp where the source has a meaningful time dimension. If the
  tool can't express the filter, pull the narrowest thing it can and cut locally; never widen the
  scope to make a query easier.
- **Right of the arrow — where it lands.** One of three shapes:
  - **A named section** (`# Communication`, `# News`, …) — merge the results into that section in
    its existing format, deduping against what's already there.
  - **A task section** — each result becomes a candidate and goes through the same pipeline as
    step 2's weekly-plan items: dedup, `action-item-classifier`, `prioritization-reranker`, then
    routed to the Project or Area H1 it belongs to. **These count against the ten-item cap**, and
    they compete with weekly-plan items on rank rather than being appended on top of them.
  - **Item ranking** (like `calendar`'s) — it's evidence, not content. Feed it to the reranker as
    a signal and write nothing of its own.
- **A new H1 the note doesn't have** — create it, and place it above `# Communication` if it's
  task-shaped, below `# News` otherwise. Don't invent a section the arrow didn't ask for.

Cap a generic role at **five lines** in its destination, and prefer the user's own items over
anything merely adjacent to them. A role that returns nothing gets no placeholder line unless it
is the only source for its section — same rule as `# Communication` and `# News`.

Name every generic role in the handoff and the step 6 log entry: what it was, how many items it
produced, and where they landed. A source nobody wrote a step for is exactly the one whose output
the user has no intuition about yet.

## 6. After writing

Append one line to the current month's log at `.system/log/log-YYYY-MM.csv` (pipe-delimited: `timestamp|action|path|summary`; see the `log-manager` skill). Create the file if this is the first entry of the month. The `summary` field should note: whether the note was created or
updated; **every role the `## Who reads what` table configured for `daily-plan`, and what each
resolved to** (naming any that came back `none` or stale); how many candidates were gathered vs.
how many survived classification vs. how many made the ten-item cap; how many email threads were
skipped as vendor/automated; how many Communication items were added; for News, whether `web` was
available, how many candidates each lane produced vs. how many made the brief, and any
`# External Sources` entry that failed to fetch; and for each role handled generically in step 5b,
how many items it produced and where they landed. Skip this if the log doesn't exist yet — don't invent the system
scaffolding described in `CLAUDE.md` if it hasn't actually been built.

## Example of the target shape

```markdown
---
created: "2026-08-10 07:30:00"
tags:
  - daily-planning
---

# <Project B>
- [ ] Schedule testing call `[P1]`
### <Subproject B1>
- [ ] Review the new indexes + sample records `[P1]`

# <Project D>
- [ ] Client response (due today)

# <Area A>
- [ ] Renew the insurance policy (due today) `[P2]`

# Communication
- [ ] Reply to a teammate in #reviews re: two-reviewer process question
- [ ] Reply to a teammate (DM) re: meeting time
- [ ] Reply to a client contact (email) re: contract redlines

# News
- **[<headline of the release note>](https://example.com/releases/x-y)** · 2026-08-27
  <One or two sentences on what shipped, and what it means for the migration work in
  <Subproject B1>.>
- **[<title of the research post>](https://example.org/posts/z)** · 2026-08-28
  <One or two sentences. No project connection claimed here — it's relevant to a standing
  interest from the External Sources list, and that's enough.>

# Notes
```

`<Project B>` and friends are placeholders — use the real headings from the weekly plan. Note the
`### <Subproject B1>` sub-heading nested under the project's H1 here: match whatever heading depth
the weekly plan used for that subproject rather than flattening it. `<Project A>` and `<Project C>`
are absent because they had no items today — that's correct for a daily note, unlike the weekly
plan where every project keeps a header.
