---
created: 2026-08-05 00:00:00
tags:
  - automation
  - planning/weekly
  - workflow
  - knowledge-base
  - skill
tagged: '2026-08-31'
tagged_hash: f794450b8dc2c966
type: architecture
---

# Weekly Plan Create

Runs the `weekly-planning` skill's **Create Weekly Plan** entry point automatically, once a
week, to stand up the new week's planning note before the user starts their Monday.

## What it does

Each run:

1. Figures out the current Sunday–Saturday week and confirms whether a note already exists
   for it in `Resources/Plans/{year}/Weekly/` (refreshes/extends it if so, rather than duplicating).
2. Reviews the *prior* week — `Resources/Meetings/`, `Resources/Plans/{year}/Daily/`, `Projects/` activity, and any
   unchecked `- [ ]` items left in last week's plan — to ground this week's goals in what
   actually happened rather than guessing.
3. Checks the calendar for the upcoming week to surface meeting-driven goals and prep items.
4. Writes Weekly Goals and the full per-Project and per-Area checklist (section headers
   read from `CLAUDE.md`'s `# Projects` and the folders under `Areas/` — always including every
   project and area header, even if empty), tagging each checklist item `[P1]`/`[P2]`/`[P3]`.
5. Appends a one-line summary to `.system/log/log-YYYY-MM.csv` (pipe-delimited).

## Schedule

Runs every **Sunday at 5:30 PM** via a Claude scheduled task.

- Task ID: `weekly-plan-create`
- Cron: `30 17 * * 0` (local time)
- Managed with `list_scheduled_tasks` / `update_scheduled_task` / `delete_scheduled_task`

Deliberately Sunday evening rather than Monday morning: weeks run Sunday–Saturday, and
`daily-plan-run` fires at 7:30 AM on weekdays. A Monday-morning create would land *after* Monday's
daily run had already looked for the week's note and found nothing, so Monday's daily plan would
fall back to chat-only every week and the week's goals wouldn't reach a daily note until Tuesday.
Creating the note before the week's first daily run closes that gap.

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

- Skill: `Skills/weekly-planning/SKILL.md` — see the "Create Weekly Plan" section for the
  full step-by-step logic this workflow runs.
- Pairs with `Routines/weekly-plan-daily-update.md`, which runs the same skill's Update
  Weekly Plan path daily at 9am to stage meeting action items into whatever note this
  workflow creates.
