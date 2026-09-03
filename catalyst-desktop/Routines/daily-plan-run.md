---
created: 2026-08-07 00:00:00
tags:
  - automation
  - planning/daily
  - workflow
  - knowledge-base
  - skill
tagged: '2026-08-31'
tagged_hash: 7ad5c7177740fca8
type: architecture
---

# Daily Plan Run

Runs the `daily-plan` skill automatically, once each weekday morning.

## What it does

Each run:

1. Finds or creates today's note in `Resources/Plans/{year}/Daily/` (from `Templates/Daily Note Template.md`
   if it doesn't exist yet).
2. Reads the current week's note in `Resources/Plans/{year}/Weekly/` and pulls every unchecked, curated
   action item (skipping `#### Suggested` staging items) into today's note — grouped under one H1
   per Project or Area, named for the section the item came from, priority tags carried over.
3. Searches the connected chat tool (resolved from `SOURCES.md`, never assumed) for
   DMs/mentions addressed to the user since the last daily note's timestamp that they haven't
   already replied to, and adds one `# Communication` line per unread thread.
4. Builds the `# News` brief: reads the `# External Sources` list in `SOURCES.md` and runs
   searches derived from the vault's frequent tags, projects, areas, and `PRIORITIES.md`, keeping
   only items published in the last 24 hours that bear on the user's actual work (title, date,
   link, and a 1–2 sentence description each; at most seven).
5. Never touches anything the user already wrote by hand — only adds new, non-duplicate lines.
6. Appends a one-line summary to `.system/log/log-YYYY-MM.csv` (pipe-delimited).

## Schedule

Runs weekdays at **7:30 AM** via a Claude scheduled task.

- Task ID: `daily-plan-run`
- Cron: `30 7 * * 1-5` (local time)
- Managed with `list_scheduled_tasks` / `update_scheduled_task` / `delete_scheduled_task`

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

- Skill: `Skills/daily-plan/SKILL.md` — full step-by-step logic this workflow runs.
- Depends on `Resources/Plans/{year}/Weekly/` already having a note for the current week — if the weekly
  plan hasn't been created yet, this run falls back to just checking chat, writing no task
  sections at all (see the `weekly-planning` skill / `weekly-plan-create` workflow for creating it).
