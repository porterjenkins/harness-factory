---
name: action-item-classifier
description: Decide whether a candidate action item — typically one pulled from meeting notes or other loosely-structured text — is concrete enough to become a real task, or should be discarded as noise. Use whenever extracting, staging, or reviewing action items from meeting notes, transcripts, or verbose source text, especially inside another skill's pipeline (e.g. weekly-planning's "Update Weekly Plan" meeting scan, meeting-prep follow-ups) before adding a candidate to a checklist. Deliberately biased toward precision over recall for meeting/transcript-derived candidates — meeting notes are verbose and suffer from poor diarization (who actually owns what), so this skill favors dropping an ambiguous candidate over polluting the user's task list with something vague or unowned. That bias loosens for terse, human-authored-looking shorthand (a short line naming a specific person, system, file, or project, in the style of the user's own notes) — brevity there is a positive signal, not vagueness, and gets leaned toward keeping rather than discarding. Not meant to gate something the user just typed directly in conversation as an explicit instruction — that's already concrete by virtue of being explicit; this skill is for judgment calls on candidates pulled out of someone else's source text.
tags:
  - skill
  - automation
  - planning
  - knowledge-base
  - workflow
type: concept
tagged: 2026-08-27
tagged_hash: e66d3341ca4841bd
---

# Action Item Classifier

Filters a candidate action item — usually extracted from a meeting note or other messy source —
down to a yes/no on whether it's concrete enough to go on the user's task list. Meant to be called
as a step inside another skill's extraction pipeline, not run standalone against a whole document.

## Procedure

1. Take one candidate action item at a time (not a whole list at once — batching invites comparing
   candidates to each other instead of judging each on its own merits).
2. **If the candidate text looks truncated** — cuts off mid-word or mid-clause, or trails a dash
   or comma with nothing after it — don't score the fragment as it stands. Go back to the source
   and pull the complete line first. Only treat it as genuinely incomplete (see the human-shorthand
   heuristic below) once you've confirmed the source itself trails off, not just the extraction.
3. Score it against four criteria:
   - **A specific deliverable** — a concrete artifact or outcome (slides, a reviewed PR, a written
     plan) rather than an abstract intention or open-ended "look into."
   - **Atomic and measurable** — a single unit of work with a clear done-state, not a bundle of
     undefined sub-tasks folded into one line.
   - **Descriptive and clear** — reads unambiguously on its own: what to do, and for/with whom
     where that matters, without requiring outside context the reader doesn't have. Terse is not
     the same as unclear — see "Terse isn't vague" below before marking a short item down for
     brevity alone.
   - **A specific timeframe** — a deadline, date, or a clearly-scoped occasion ("by Thursday EOD,"
     "for Mon 2:00 meeting").
4. **Keep the item only if it satisfies at least 2 of the 4 criteria** — or if it reads as clear
   human-authored shorthand per the heuristic below, even where strict literal scoring falls a
   little short. Fewer than 2, with no shorthand signal, → discard.

## Decision Heuristics (when it's not obvious)

- **Prioritize precision over recall.** A missed real action item resurfaces the next time the
  source is scanned; a spurious one sits on the user's list until they notice and remove it by
  hand. When genuinely torn, discard.
- **Meeting-note candidates get extra scrutiny.** These sources tend to be verbose and suffer from
  poor diarization — the note may not reliably capture who was actually assigned what. Weight that
  uncertainty against "descriptive and clear" specifically: an item with a well-defined deliverable
  but no clear, confidently-attributed owner should usually fail regardless of how good the rest of
  the item reads.
- **Undefined referents sink an item even if the shape looks right.** Jargon, codenames, or scope
  words ("the two engine blockers," "all open questions," "the current few") that aren't resolved
  in the item's own text count against both deliverable-specificity and clarity — don't assume the
  reader (or the user, days later) will still remember what they meant.
- **Compound asks usually fail atomicity.** If a candidate bundles multiple distinct actions into
  one line, don't stage it as-is — split it into separate candidates and score each one, or discard
  the bundle if splitting would require guessing at intent.
- **A named deliverable and a named timeframe together are the strongest signal** and will almost
  always clear the bar on their own (2 of 4) even when the phrasing is terse — see the positive
  examples below.
- **Terse isn't vague — human shorthand gets read charitably.** A short line naming concrete,
  specific nouns (a person, a named system/technology, a file, a script, a project, or a named
  list kept elsewhere) is compressed human shorthand, not an incomplete thought. Don't require
  full-sentence grammar or an explicit timeframe from an item a knowledgeable author would
  instantly recognize — grade "descriptive and clear" (and often "specific deliverable") on
  whether it names something concrete, not on whether it reads like prose. See the
  human-authored-shorthand examples below.
- **Opaque codes are not the same as compressed shorthand.** A bare identifier that requires an
  external lookup to mean anything — a workstream code, a ticket number with no other context
  ("ws22," "the ws187 pilot") — still sinks an item per the undefined-referents heuristic above,
  even though it's also short. The difference from shorthand like "Build-from-setup-file" or
  "Langchain to Redshift ETL" is self-containment: shorthand names *what the thing is* in the
  words themselves; an opaque code just points somewhere else the reader can't follow.
- **A clarifying trailing fragment isn't the same as a bundled ask.** "Compound asks usually fail
  atomicity" (above) targets genuinely distinct, unrelated tasks joined onto one line. A single
  technical initiative followed by a comma-joined fragment that scopes *what it's for* — e.g.
  "Langchain to Redshift ETL; user queries" (the ETL, for user queries) — is one thing described
  in two clauses, not two things. When in doubt, ask whether the second clause could stand alone
  as its own action; if it can't (it's not a task, just context), it's scoping, not bundling.
- **Lean toward keeping likely self-authored notes, not discarding them.** The precision-over-recall
  default above is calibrated for meeting/transcript-derived candidates, where verbosity and bad
  diarization make false positives common. It applies with less force to a candidate that reads as
  the user's own terse capture (matches the shorthand pattern above, no ownership ambiguity since
  there's no third party to misattribute to) — there, a missed note is worse than a slightly terse
  or even incomplete one surfacing for the user to flesh out themselves, since they're the one who
  knows what they meant.

## Worked Examples

### Positive (kept)

| Candidate | Why it clears the bar |
| --- | --- |
| Prep slides for meeting with Lincoln Nadauld | Specific deliverable (slides) tied to a named meeting |
| Define Bedrock migration phases and the 30–60 day completion plan with DP and Riley — which leaderboards move first, customer transition sequencing | Clear, atomic deliverable (a phased plan) with defined scope and named collaborators |
| Prep slides for Enzy Mon 2:00 | Deliverable + timeframe (a specific, named meeting) |
| Review the pull request (PR-123) by Thursday end-of-day | Deliverable (review PR-123) + explicit deadline |
| Complete email backlog (53 unread messages) by Friday at 1 pm | Atomic, quantified deliverable + explicit deadline |

### Human-authored shorthand (kept)

Terse, personal-note-style captures — not vague, just short. Compare each to the negative
examples below: the difference is concrete, self-contained nouns vs. genuinely undefined ones.

| Candidate | Why it clears the bar |
| --- | --- |
| Get AWS secrets to Tom | Already clears the ordinary bar on its own (deliverable + named recipient + atomic) — included here as a calibration example of terse-but-specific phrasing, not because it needs the shorthand allowance |
| Check to make sure that *(truncated mid-sentence)* | Retrieve the full line from the source before judging (step 2) rather than scoring the fragment. If the source genuinely ends there, the terse, first-person-note style still signals real intent — lean toward keeping per "lean toward keeping likely self-authored notes" rather than discarding a real thought for being short |
| Build-from-setup-file | Self-descriptive compressed phrasing (build using the setup file) — the compression is grammatical, not referential; unlike an opaque code (`ws22`), the words themselves say what the thing is |
| Langchain to Redshift ETL; user queries, | One technical initiative (an ETL pipeline) with a trailing clause scoping what it's for (user queries) — not two bundled tasks. Terse but names concrete, specific systems |
| Work through the AI Assistant Refinements list | Names a specific, bounded external artifact (the list itself lives elsewhere) — gives it both a deliverable (work through that list) and clarity, even with no explicit timeframe |

### Negative (discarded)

| Candidate | Why it fails |
| --- | --- |
| Bring the migration go-live checklist to the team for review — enumerate all open questions | Too vague: "the team" is unresolved, and "all open questions" isn't a bounded, defined set |
| Check in on Riley's clone-to-YAML migration recipe (Linear AI-55) — repeatable, AI-assisted, with review built in | "Check in on" isn't a deliverable or a done-state, and no timeframe is given — reads as a status ping, not a task |
| Get Adam to clear the two engine blockers — post-resolution dedup blocking the ws22 parity leg, upload-landing intake blocking the ws187 pilot | Unresolved jargon ("ws22," "ws187," "the two engine blockers") — no reader can act on this without context the item itself doesn't supply |
| Spread Mongo depth beyond the current few — take Sterling up on his offer | No deliverable, no measurable output, no timeframe — an intention, not a task |
| Plan for Tom's contract ending at month-end — Atlas infrastructure knowledge transfer plus guardrails so new contributors can't break things silently | "Plan for X" has no defined deliverable — compare to the Bedrock example above, which names the actual output (a phased plan) instead of just gesturing at the topic |

## Output

When called from inside another skill's pipeline, don't just silently drop what fails the bar —
report it as screened out (one line per discarded candidate, with which criterion count it hit) so
the calling skill can surface that in its own run summary. Matches the transparency pattern used
elsewhere in this vault (e.g. `weekly-planning`'s Update Weekly Plan reports staged items *and*
what it screened out) — an agent silently deciding what didn't make the cut, with no trace, is
harder for the user to trust than one that shows its work.

If the calling skill has no natural place to surface screened-out items, at minimum keep a count
("N of M candidates staged, N-M discarded") rather than reporting only the survivors.
