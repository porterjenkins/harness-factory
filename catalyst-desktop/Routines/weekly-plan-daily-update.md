---
created: 2026-08-05 00:00:00
tags:
  - automation
  - planning/weekly
  - workflow
  - knowledge-base
  - skill
tagged: '2026-08-31'
tagged_hash: 6873ddc368f91158
type: architecture
---

# Weekly Plan Daily Update

Runs the `weekly-planning` skill's **Update Weekly Plan** entry point automatically, once a day
at the end of the workday.

Two halves, in this order: **reconcile** what's already done, then **stage** what's newly come up.

## What it does

Each run:

1. Finds the current Sunday–Saturday week's note in `Resources/Plans/{year}/Weekly/`. If no note
   exists for this week, the run stops as a no-op.

**Reconcile — the half that matters most day to day:**

2. Reads the daily notes in `Resources/Plans/{year}/Daily/` for the last three days inclusive of
   today, never earlier than the current week's Sunday.
   - **Today's note is the primary source** — read first and reconciled in full. Since the run is
     at 4:30 PM, it's the record of what actually got done today.
   - The **two preceding days are a catch-up sweep**, so a skipped or failed run doesn't strand a
     day's completions permanently. Re-reading an already-reconciled day is a no-op.
3. For each `- [x]` there, finds the matching `- [ ]` line in the weekly plan and flips it to
   `- [x]`, changing nothing else on the line. Matching is confidence-gated (normalized text,
   equality or a clean ~30+ character prefix); no confident match means no edit, just a report.
   Never flips the other direction, never unchecks, never adds a line for a completed daily item
   that isn't already in the plan.

**Stage:**

4. Reads every meeting note in `Resources/Meetings/` dated within the past two days.
5. Pulls out concrete action items that are unassigned or clearly involve the user (skips
   items explicitly owned by someone else).
6. Routes each item to its matching project/subproject section and adds it as a
   `- [ ]` line under an `#### Suggested` subheading — staging items, not part of the curated plan.
7. Skips anything that's a near-duplicate of an item already in the plan.
8. Leaves Weekly Goals, the section headers, and the wording of every existing checklist item
   untouched.
9. Appends a one-line summary to `.system/log/log-YYYY-MM.csv` (pipe-delimited).

the user reviews `#### Suggested` items on their own schedule and promotes the ones they want
into the real checklist, re-confirming priority at that point.

## Schedule

Runs daily at **4:30 PM** via a Claude scheduled task.

- Task ID: `weekly-plan-daily-update`
- Cron: `30 16 * * *` (local time)
- Managed with `list_scheduled_tasks` / `update_scheduled_task` / `delete_scheduled_task`

**Why end of day.** the user works out of the daily note and rarely goes back to tick the same
item off in the weekly plan. A 4:30 PM run lands the day's completions in the weekly plan the same
day — and *before* the next morning's [[daily-plan-run]] (7:30 AM) builds tomorrow's note off this
plan, so finished work doesn't get pulled forward as a fresh open item. The earlier 9:00 AM slot
had the opposite effect: it fired 90 minutes after the daily note was generated, found it still
empty, and reconciled everything a day late.

## Permission mode

Runs in **Auto** permission mode. Every run of this routine — the scheduled one, or a manual
re-run — starts with the permission mode set to `Auto`, never `default` and never `Plan`.

Nobody is at the keyboard on a scheduled run, so a run in `default` mode blocks on the first
approval prompt and produces nothing at all. Auto still applies the `autoMode` soft-deny rules in
`~/.claude/settings.json`, so the guardrails above stay enforced — which is why this is Auto and
not `bypassPermissions`.

The Claude Code scheduled task says the same thing in its prompt. The scheduled-task API exposes
no structured permission-mode field, so the mode is stated in the prompt body; if that paragraph
is ever dropped from the task, the mode silently reverts to the session default.

## Related

- Skill: `Skills/weekly-planning/SKILL.md` — see the "Update Weekly Plan" section for the
  full step-by-step logic this workflow runs. Reconciliation is step 2 there; staging is 3–9.
- Sibling routines: [[daily-plan-run]] (weekdays 7:30 AM, builds the daily note from this plan)
  and [[weekly-plan-create]] (Sundays 5:30 PM, stands up the week).
- If no weekly plan note exists yet for the current week, the run falls back to a no-op
  (the skill only edits an existing note in this path — see the skill's Create Weekly Plan
  entry point for building a new week from scratch).

## Open question — priority tags on Suggested items

Unresolved as of 2026-08-28. The scheduled task's prompt says to stage `#### Suggested` items with
**no** priority tag; the skill's step 8 says to assign one via `prioritization-reranker`. The two
disagree, and the prompt itself names the skill as authoritative, so runs currently follow the
skill and tag them. Result: Suggested blocks are mixed — items staged before 2026-08-28 are
untagged, items staged on/after are tagged.

Pick one and fix whichever file is wrong:

- **Tag them** — gives a head start when reviewing; priority is re-confirmed on promotion anyway.
  Fix: drop the "no priority tag" sentence from the task prompt.
- **Don't tag them** — keeps "untagged" as the visual marker for *unreviewed*, so the curated
  checklist and the staging area never look alike. Fix: drop step 8's tagging from the skill.
