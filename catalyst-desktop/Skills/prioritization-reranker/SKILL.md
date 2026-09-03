---
name: prioritization-reranker
description: Take a set of candidate TODO/action items and rerank them by combining an explicit priority tag (P1/P2/P3, inferred from PRIORITIES.md and this week's calendar) with an estimated probability that the user actually finishes the item in the next day, drawn from how similar items have behaved in recent daily-plan notes. Use whenever the user asks to reprioritize, rerank, or reorder a list of tasks or action items, asks "what should I actually work on," pastes an ad hoc TODO list and wants it sorted, or when another skill (e.g. daily-plan's ten-item cap, weekly-planning's overflow) needs a principled tiebreak instead of raw weekly-plan order. Always reads PRIORITIES.md fresh and pulls real history from recent Daily notes rather than guessing at completion likelihood from the item text alone — a stale read of either input produces a ranking the user has no reason to trust.
tags:
  - skill
  - prioritization
  - planning
  - knowledge-base
  - workflow
type: concept
tagged: 2026-08-27
tagged_hash: becd19a8e63e4b3a
---

# Prioritization Reranker

Reranks a set of candidate action items using two signals: an explicit priority tag and an
estimated probability of completion (`P(completion)`) within the next day. The priority tag is
authoritative; `P(completion)` breaks ties within a tag and flags items worth a second look, but
never overrides the tag itself.

## Input

A set of candidate TODO items, as plain text — e.g. from the user directly, or pulled from a
daily/weekly plan by whatever skill is calling this one:

```
{Complete the slides, email the team}
```

Items arrive with or without an existing priority tag. If a candidate already carries a
`` `[P1]`/`[P2]`/`[P3]` `` tag from its source (e.g. it came straight off the weekly plan), that
tag is a strong prior for step 2 below but is still re-derived, not copied blindly — the point of
this skill is to check candidates against current priorities, not just echo whatever tag they
already had.

## Output

A reranked list, one entry per input candidate, each with its priority tag and `P(completion)`:

```
{(item-1, `priority-level`, P(completion)), (item-2, `priority-level`, P(completion)), ...}
```

Example:

```
{(email the team, `[P1]`, 0.93), (Complete the slides, `[P2]`, 0.80)}
```

When handing this back conversationally, a short table (item / priority / P(completion), sorted)
is more readable than the raw tuple form — use the tuple schema when another skill or script is
the consumer, prose/table when the user is.

This skill only computes and returns the ranking — it doesn't write the result into any note by
itself. If the caller wants it persisted, that's the caller's responsibility (e.g. daily-plan
writing the resulting order into today's note).

## Procedure

### 1. Read PRIORITIES.md

Read `PRIORITIES.md` at the vault root fresh, every run — never rely on a remembered copy from
earlier in the conversation. It has two parts:

- A **ranked** list of current priorities, most important first (position in the list matters —
  item 1 outranks item 4).
- **General rules** — standing preferences that modify scoring regardless of which priority an
  item maps to (e.g. "prioritize items due this week," "protect Tuesday/Thursday afternoons").

### 2. Build the completion-history dataset (D)

Use the `doc-retrieval` skill to gather the last 7 calendar days of daily-plan notes:
`obsidian vault=<vault-name> search query="path:Resources/Plans/{year}/Daily" format=json`, keep the 7 most
recent by filename date, **excluding today's own note** if it already exists (today isn't over
yet, so it can't tell you anything about same-day completion). Fewer than 7 is fine early in the
vault's life — work with what exists rather than padding the window.

For each note, read every `- [ ]`/`- [x]` line in the note's **task sections** — that is, every
H1 except `# Communication` (replies, not tasks), `# News` (a current-events brief, not tasks at
all), and `# Notes` (freeform). Task sections are named
for the Project or Area the items came from (`# Bedrock`, `# Family`); notes written before
`daily-plan` moved to that shape use `# Admin` and `# Goals` instead, and count the same way. This
is D: a per-day record of which items were open and which were checked off.

Match items across days the same way `weekly-planning`'s carry-forward limit and `daily-plan`'s
reconciliation step do: normalize both sides (strip the trailing priority tag and any
`` `(due today)` `` annotation, strip stray punctuation, collapse whitespace, lowercase), then
treat two lines as the same item on an exact match or a clean ~30+ character prefix match. Use the
same rule everywhere in this skill so results don't shift depending on which comparison triggered
the match.

From D, derive per historical item:

- **Occurrence count** — how many of the last 7 days it appears at all.
- **Checked-same-day rate** — of the days it appeared, on what fraction was it already checked
  `[x]` that same day (i.e. it was proposed and finished within the day, not carried).
- **Current streak** — how many *consecutive* most-recent days (working backward from the most
  recent prior note) it has appeared and stayed unchecked.

### 3. Assign each candidate a priority tag

For each input candidate, infer `[P1]`/`[P2]`/`[P3]` using this schema — the same one
`weekly-planning` step 6 uses; keep the two in sync if either changes:

- `` `[P1]` `` — a hard deadline this week, something blocking other people, or tied to a
  calendar event happening this week.
- `` `[P2]` `` — matters this week but isn't on fire: carried-over work with some urgency, prep
  for a meeting later this week or next week.
- `` `[P3]` `` — no real deadline, background/nice-to-have work.

Ground the inference in **PRIORITIES.md first**: an item that clearly advances the #1 ranked
priority (or is explicitly named or implied by one of the General rules) leans `[P1]` even absent
a hard deadline; an item with no connection to anything on the list, and no deadline, leans `[P3]`.
Cross-reference known deadlines, this week's calendar (if the `calendar` role in
`SOURCES.md` resolves to a connected tool — otherwise skip that signal and say so), and
anything flagged urgent/blocking in recent meeting notes. When genuinely unsure, default to `[P2]`
rather than guessing at `[P1]` or `[P3]` — same default as `weekly-planning`.

### 4. Estimate P(completion) for each candidate

`P(completion)` is the estimated likelihood the user finishes this item in the next day. This is a
heuristic score, not a calibrated statistic — build it as a base rate adjusted by a small number
of explainable factors, so the reasoning behind any given number can be explained if asked.

**Base rate, from the assigned priority tag:**

| Tag | Base rate |
| --- | --- |
| `[P1]` | 0.70 |
| `[P2]` | 0.45 |
| `[P3]` | 0.20 |

**Adjustments** (apply the ones that are actually evidenced — don't stack guesses):

- **+0.15** — the item names an explicit deadline landing today or tomorrow, or matches something
  on tomorrow's calendar (same correspondence bar as `daily-plan` step 2: an unambiguous match,
  not a loose thematic one).
- **+0.10** — the item is small and atomic (a single quick action — a reply, a short call, one
  clearly bounded edit) rather than a multi-step or open-ended deliverable. This mirrors the
  `action-item-classifier` atomicity criterion; a candidate that would itself fail that skill's
  2-of-4 bar for being a well-formed action item should get this adjustment in reverse (−0.10),
  not skipped, since a vague item is genuinely less likely to get finished as stated.
- **−0.05 per consecutive day of streak** (from step 2), up to a cap of **−0.30** — an item that
  has already survived several days unchecked is evidencing some real friction (unclear scope,
  blocked, deprioritized in practice even if not on paper), not just bad luck. This is a
  correction against the naive assumption that "it's been waiting the longest" makes it more
  likely to get done next.
- **+0.10** — checked-same-day rate (from step 2, for this item or a near-identical recurring one)
  is 0.7 or higher — this candidate's *kind* of task has a track record of getting knocked out
  quickly once it appears.
- No history at all in D (brand new item, occurrence count 0): make no streak/rate adjustment —
  rely on the base rate plus the deadline/atomicity adjustments only.

Clamp the final value to **[0.05, 0.97]** — never report certainty either direction; a "sure
thing" or "definitely won't happen" claim is exactly the kind of overconfident number that erodes
trust in the ranking the next time it's wrong.

### 5. Rank

Sort **primarily by priority tag** (`[P1]` before `[P2]` before `[P3]`), and **secondarily by
`P(completion)` descending** within the same tag. Priority tag is never demoted or promoted by
`P(completion)` — see Decision Heuristics.

### 6. Flag mismatches, don't silently rerank around them

After sorting, scan for tag/probability mismatches worth calling out even though they don't change
the sort order:

- A `[P1]` item with `P(completion)` below ~0.35 — likely stuck or under-scoped; worth a note that
  it may need to be broken down, reassigned, or escalated rather than just carried again.
- A `[P3]` item with `P(completion)` above ~0.80 — probably a fast, low-cost win being
  under-prioritized on paper; worth surfacing as "quick win" even while it stays ranked last.

List these separately in the handoff (a line or two), the same way other skills in this vault
surface caveats rather than letting a clean-looking ranking hide something worth a second look.

## Decision Heuristics

- **When `P(completion)` and the priority tag disagree, the priority tag wins the ranking.**
  `P(completion)` is a secondary sort key and a flag, never a reason to move a `[P1]` below a
  `[P2]`, or vice versa. What's explicit in `PRIORITIES.md` and the tag schema reflects a
  deliberate judgment call the user (or a prior run grounded in their stated priorities) already
  made; a probability estimate built from a week of noisy daily-note history shouldn't override
  that judgment — it should inform ordering *within* it, and surface disagreement for the user to
  see (step 6), not resolve it unilaterally.
- **Precision over false confidence.** If PRIORITIES.md is missing, empty, or clearly stale (e.g.
  references a priority that's obviously finished — cross-check against recent activity if in
  doubt), say so plainly and fall back to the deadline/calendar-driven tag inference alone rather
  than inventing a ranked list that isn't there.
- **Don't recompute D per candidate from scratch if candidates share history** — gather it once
  per run (step 2) and look each candidate up against the same dataset, so the ranking is
  internally consistent and doesn't drift between items scored earlier vs. later in the same run.
