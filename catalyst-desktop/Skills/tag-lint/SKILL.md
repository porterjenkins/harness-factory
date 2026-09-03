---
name: tag-lint
description: Find and merge duplicate or drifting tags in the user's Obsidian vault. Use this skill when tags need cleaning up — duplicate tags, inconsistent tag naming, near-identical tags like proj/ai versus ai/proj, single-use tags, or a general "clean up my tags" request. Also use when the tag vocabulary is asked about, when reviewing what tags exist and whether they are consistent, or after a large ingest that may have introduced new tag variants.
tags:
  - skill
  - tagging
  - obsidian
  - knowledge-base
  - automation
tagged: 2026-08-27
tagged_hash: b6c4d88f90e28704
type: concept
---

# Tag Lint

This skill runs in one of **two modes**, and which one applies changes what counts
as the right answer. The tool decides and tells you; read the mode line before
acting on anything below it.

| Mode | When | What wins a conflict |
|---|---|---|
| **canon** | a `tags.md` exists and is current | the spelling declared in `tags.md`, *regardless of count* |
| **frequency** | no `tags.md`, or it is empty or stale | the higher count — count 1 is probably drift, count 40 is canon |

`tags.md` is looked for at the vault root first, then `.system/tags.md`. It does
not exist right now, so today this runs in frequency mode; nothing needs to be
created, and creating one is a deliberate choice rather than a fix.

Either way the reason drift matters is that it **ratchets**. The tagger prefers
existing tags, so whatever it invents becomes the de facto standard on the next
run and a typo introduced once will be reused. This skill is the counterweight.

**Why frequency mode is not just a degraded fallback.** With no declared list the
vault's own state is the vocabulary, which is self-maintaining and never goes
stale. A declared list is more authoritative but only while someone maintains it —
which is the failure mode the coverage guard below exists to catch.

## 1. Get the report

```bash
python3 .system/wiki/cli.py tag-lint
python3 .system/wiki/cli.py tag-lint --json      # includes a ready-to-execute merge plan
python3 .system/wiki/cli.py tag-lint --frequency # ignore tags.md and lint on counts alone
```

Counts come from `obsidian tags counts format=json` when the app is available,
falling back to scanning frontmatter otherwise. Both modes use the same three
detectors, most confident first:

- **reordered nesting** — `proj/ai` vs `ai/proj`: identical segment sets
- **case or separator only** — `Proj-AI` vs `proj_ai`
- **edit distance ≤ 2** — `mongodb` vs `mongodbb`

Plus a list of single-use tags, which are *suspects, not verdicts*.

### Canon mode adds two sections, and one refusal

- **In the vault but not in `tags.md`** — either new work that should be added to
  the list, or drift too far gone to match automatically. The tool proposes
  nothing for these and never deletes them. Deciding which they are is the
  judgement call; when it is new work, the fix is to edit `tags.md`, not to merge.
- **Declared but unused** — listed tags no vault note carries. Aspirational
  entries or leftovers from renamed projects.
- **Coverage refusal.** If `tags.md` accounts for less than 60% of the vault's
  established tags (count ≥ 5), the tool **drops to frequency mode and says why**.
  A list that has fallen behind the vault means the *list* is stale, not that the
  vault has drifted — and acting on the wrong one of those merges live tags into
  dead spellings across every note at once. Fix `tags.md` and re-run; do not force
  canon mode past this.

## 2. Judge before merging

The tool proposes; it does not decide. Apply judgement:

- **In canon mode, the list wins — but sanity-check it first.** If `tags.md` says
  `proj/ai` and the vault overwhelmingly says `ai/proj`, the tool will propose
  merging 40 notes into the spelling used by 2. That is the correct behaviour for
  a declared vocabulary and the wrong outcome if the list is simply out of date.
  Coverage passing means the list is *broadly* current, not that every line is.
- **In frequency mode, keep the higher count.** The established spelling wins,
  even if you prefer the other one aesthetically.
- **A single-use tag is not automatically wrong.** A genuinely new project starts
  at count 1. A brand-new project tag is not drift.
- **Reordered nesting is not always a duplicate.** `proj/ai` (AI work on a project) and
  `ai/proj` could in principle mean different things. Check a couple of the
  actual notes before merging.
- **Never merge across projects.** The user runs several in parallel (see `CLAUDE.md`); a tag that looks
  redundant may be load-bearing for one.

## 3. Propose to the user, then execute

Show the merge list and get approval. Do not merge silently — tags are how they
finds things, and a wrong merge is invisible until a search comes back empty.

Merges go through `processFrontMatter`, never a hand-edited YAML rewrite. There is
**no `tag:rename` CLI command**.

```bash
# Find every file carrying the losing tag
obsidian vault=<vault-name> tag name=ai/proj verbose

# Rewrite one file's tags: replace the old tag, dedupe, keep everything else
obsidian vault=<vault-name> eval code="(async () => {
  const from = 'ai/proj', to = 'proj/ai';
  const hits = app.vault.getMarkdownFiles().filter(f => {
    const t = app.metadataCache.getFileCache(f)?.frontmatter?.tags || [];
    return (Array.isArray(t) ? t : [t]).includes(from);
  });
  for (const f of hits) {
    await app.fileManager.processFrontMatter(f, fm => {
      const cur = Array.isArray(fm.tags) ? fm.tags : (fm.tags ? [fm.tags] : []);
      fm.tags = [...new Set(cur.map(t => t === from ? to : t))];
    });
  }
  return hits.map(f => f.path).join('\\n');
})()"
```

**Do not touch `tagged` or `tagged_hash`.** The ingestion pipeline depends on
them, and a merge is not a content change — rewriting them would trigger a
pointless re-tag of every file you touched.

Inline `#tags` in note bodies are not covered by the above. Check for them
separately with `search query="tag:#ai/proj"` and edit the body text directly if
any turn up.

## 4. Log it

One line per merge, not per run:

```bash
echo "$(date -Iseconds)|tag-merge|vault|merged ai/proj into proj/ai across 4 files (canon)" \
  >> .system/log/log-$(date +%Y-%m).csv
```

Note the mode in the summary, since `merged ai/proj into proj/ai` means the
opposite thing depending on which one was in effect.

## When to run this

After a large ingest, or roughly monthly. Not every run of the tagger — drift
takes time to accumulate, and merging too eagerly destroys distinctions that
turn out to matter.

In canon mode the same cadence applies to the list itself: work through the
unlisted section so `tags.md` keeps pace with the vault. A list nobody maintains
will eventually trip the coverage guard and silently stop being used, which is the
safe failure but not a useful one.
