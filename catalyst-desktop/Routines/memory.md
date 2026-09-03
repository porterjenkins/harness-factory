---
created: 2026-08-28
tags:
  - automation
  - memory
  - knowledge-base
  - workflow
  - skill
type: architecture
tagged: '2026-08-31'
tagged_hash: c2ef5ce8ba443b99
---

# Memory

Runs the `memory` skill automatically at the end of the work week, updating the single evolving
`MEMORY.md` at the vault root from every source connected in `SOURCES.md`.

## What it does

Each run:

1. **Resolves sources first.** Reads `SOURCES.md` and maps each role — `chat`, `issues`,
   `email`, `code`, `calendar`, `second-vault` — to whatever tool currently fills it. Nothing is
   hardcoded to a product. An unattended run can't ask, so any role that resolves to `none`, names
   a tool absent from the session, or fails to authenticate is skipped and **named in the run's
   report** rather than quietly dropped.
2. **Reads `MEMORY.md` before gathering.** The current model determines what to look for:
   confirmation, contradiction, or change. Gathering blind and reconciling afterward finds more
   noise and misses the things that *stopped* happening.
3. Resolves the window from `MEMORY.md`'s `updated` date through today, capped at 30 days. Same
   range across every source.
4. Dispatches one read-only subagent per resolved external source, in parallel, while reading the
   vault directly: daily notes and weekly plans, meeting notes dated in range, project files
   modified in range, and the run's log lines.
5. **Reconciles rather than appends** — confirm / revise / add / retire — and rewrites
   `MEMORY.md` in place: current context → working preferences → projects → areas → achievements
   → goals and commitments → recurring friction → changelog.
6. Appends one line to `.system/log/log-YYYY-MM.csv`.

## Schedule

Runs **Fridays at 5:00 PM** via a Claude scheduled task.

- Task ID: `weekly-memory` (the ID predates the rename to `memory` and is not editable; the
  prompt it runs is current)
- Cron: `0 17 * * 5` (local time)
- Managed with `list_scheduled_tasks` / `update_scheduled_task` / `delete_scheduled_task`

**Why Friday at 5:00 PM.** The work week is over, so the sources are complete — but it's still a
workday, which means anything the run surfaces lands while there's a chance to act on it before
Monday.

**Why not 4:30.** That slot belongs to [[weekly-plan-daily-update]], and the scheduler applies a
fixed per-task jitter rather than running tasks in creation order — at 4:30 this task fired around
4:32 and reconciliation around 4:35, so the run read the weekly plan *before* Friday's completions
had been folded in. 5:00 PM puts this cleanly after reconciliation with ~25 minutes of headroom.

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

## Design notes

**Why one evolving file, not a weekly snapshot.** The previous version of this routine wrote
`Archive/Memories/Weekly Memory - {date}.md` every Friday. The notes were accurate and nobody
re-read them: answering "where does Bedrock stand?" meant reassembling a picture from a dozen
files, each a point-in-time slice. `MEMORY.md` is loaded at the start of every session, so a model
that improves each week compounds in a way a stack of snapshots never did. The existing dated
notes stay in `Archive/Memories/` as evidence; nothing new is written there.

**Why it reads its own memory first.** Reconciling after the fact treats every source as a blank
slate and re-derives what was already known. Reading first turns the gather into a search for
change — and change is the only thing worth writing down.

**Why silence isn't deletion.** A project no source mentioned keeps its section, marked
`no movement since {date}`. An empty window may mean the work stalled, or only that the connected
sources couldn't see it — and dormancy across a portfolio is itself worth knowing.

**Why it's capped at ~200 lines.** The file is read every session, so unbounded growth is a real
cost, not a tidiness concern. Sections that outgrow their space get compressed into summarizing
lines with `[[wiki links]]` to the detail — never truncated.

**Read-only, without exception.** Every subagent is instructed never to send, reply, draft,
schedule, comment, transition, label, commit, or push. A record must not mutate what it
describes, and an unattended run has no one watching to catch it.

**Emptiness is a finding.** A source returning nothing gets reported as nothing, never backfilled
with plausible content. Cross-source contradictions — a plan item marked done with no work behind
it, a system showing zero activity where activity was expected — get surfaced rather than smoothed
over. These usually mean a broken integration or a wrong account.

**Frontmatter.** The routine writes `tags`, `type: reference`, and `updated`, and deliberately
does **not** write `tagged` / `tagged_hash` — the ingestion pipeline owns those.

## Related

- Skill: `Skills/memory/SKILL.md` — the authoritative logic; this file describes the schedule and
  the reasoning, not the steps.
- Sibling routines: [[weekly-plan-daily-update]] (daily 4:30 PM), [[daily-plan-run]] (weekdays
  7:30 AM), [[weekly-plan-create]] (Sundays 5:30 PM).
- Source registry: `SOURCES.md` — add, change, or disconnect a source there and this routine picks
  it up on the next run with no edit here.
