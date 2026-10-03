---
name: doc-retrieval
description: Find documents in the user's Obsidian knowledge base. Use this skill whenever you need to locate notes, search the vault, answer a question from the knowledge base, look up what the user has written about a topic, find notes by tag or property or date, or trace links between notes. Trigger on requests like "what do I have on X", "find my notes about Y", "what did I write last week", "everything tagged Z", "what links to this note", or any question whose answer lives in the vault rather than in your own knowledge. Also use before answering questions about the user's projects, meetings, or plans, since the vault is the source of truth for those.
tags:
  - skill
  - knowledge-base
  - obsidian
  - search
  - workflow
tagged: 2026-08-27
tagged_hash: d0c71b7fa5a6bdaf
type: concept
---

# Document Retrieval

All retrieval runs through the **Obsidian CLI** against the running Obsidian app.

## Preflight — do this first, every time

```bash
obsidian vault=<vault-name> vault info=name
```

If this fails, **stop and say so.** Do not fall back to grepping the filesystem
without telling the user — silently degrading to a worse search is how a wrong "I
found nothing" gets delivered confidently.

Two rules that fail silently if you forget them:

- **`vault=<vault-name>` is always the first parameter**, before the command.
  Without it, commands target whichever vault was most recently focused.
- **Never pass `open` or `newtab`.** They hijack the user's editor. There is no
  `silent` flag; nothing opens unless you ask it to.

If the app is not running, the first command launches it — but launching is not
being ready. Poll until the file count stabilises before trusting any result:

```bash
.system/wiki/cli.sh doctor    # does this properly, including the readiness poll
```

## Pick the cheapest path that can express the query

| Intent | Command |
| --- | --- |
| Keyword, jargon, ticket ID | `obsidian vault=<vault-name> search query="<project codename> migration" format=json` |
| Need the matching lines | `obsidian vault=<vault-name> search:context query="..."` |
| Tag | `obsidian vault=<vault-name> tag name=<project>/<subproject> verbose` |
| Property | `obsidian vault=<vault-name> search query="[owner:\"Riley\"]"` |
| Folder-scoped | `obsidian vault=<vault-name> search query="..." path=Projects/<project>` |
| Compound | `obsidian vault=<vault-name> search query="tag:#<project> path:Projects <codename>"` |
| Date range | `obsidian vault=<vault-name> base:query file=<base> format=json`, else `eval` |
| Link graph | `backlinks`, `links`, `orphans`, `deadends`, `unresolved` |
| Anything the above can't express | `obsidian vault=<vault-name> eval code="..."` |

### Search operators available inside `query=`

`tag:` · `path:` · `file:` · `content:` · `line:` · `block:` · `section:` ·
`task:` · `task-todo:` · `task-done:` · `match-case:` · `ignore-case:` ·
`[property]` · `[property:value]` · `[property:null]` · `[property:<n]` ·
regex `/.../` · `OR` · `-` negation · parentheses.

These compose, so one `search` call often replaces a multi-step plan. Reach for
`eval` only when the syntax genuinely can't express the query:

```bash
obsidian vault=<vault-name> eval code="app.vault.getMarkdownFiles().filter(f=>app.metadataCache.getFileCache(f)?.frontmatter?.status==='draft').map(f=>f.path).join('\\n')"
```

## Conceptual or fuzzy questions: expand, don't guess

Obsidian search is **lexical only**. A natural-language question matches nothing
on its own, and a single search will produce a confident false negative. There is
no embedding layer to fall back on — you are it.

**Generate 3–5 deliberately varied queries, run each, then merge.** Vary them by
*kind*, not by wording, so they fail independently:

1. project codename — the internal name for the effort
2. synonym set — `risk OR concern OR blocker`
3. tag lookup — `tag:#<project>/<subproject>`
4. domain jargon — `atlas cutover rollback`
5. exact phrase — `"data migration"`

Then dedupe by path and **rank by how many expansions hit each path.** A note
matched by four of five expansions is far more likely relevant than one matched by
a single broad term. Read the top few in full before answering.

Worked example:

```
Question: "what were we worried about with the database migration"

obsidian vault=<vault-name> search query="<codename> mongodb migration" format=json
obsidian vault=<vault-name> search query="mongo risk OR concern OR blocker" format=json
obsidian vault=<vault-name> search query="tag:#<project>/<codename>" format=json
obsidian vault=<vault-name> search query="atlas cutover rollback" format=json
obsidian vault=<vault-name> search query="\"data migration\" downtime" format=json

→ merge → dedupe by path → sort by hit count → read top 3–5
```

You already hold the vocabulary embeddings would have supplied: `CLAUDE.md` tells
you which codename maps to which effort, "worried about" maps to
risk/blocker/concern language, and `vocab` tells you which tags are in play. Use it.

## Vault map

The vault follows PARA. `Projects/` holds active, outcome-bearing work, one folder
per project. **`CLAUDE.md` is the authoritative list of projects, their subprojects,
and what each codename means** — read it rather than assuming, since projects get
added and retired. `Projects/` subfolders are the cross-check.

`Areas/` holds ongoing responsibilities with no end date. `Resources/` holds
reference material — `Resources/Plans/{year}/` (daily + weekly) and
`Resources/Meetings/`. `Archive/{year}/` holds inactive and compacted notes;
search it only when a query is explicitly historical or turns up nothing live.

Vault machinery sits outside PARA at the root: `Skills/`, `Routines/`,
`Templates/`, `Clippings/`. All executable code lives under `.system/`.

`domain` is derived from the folder path and is never a frontmatter property —
scope by `path=` instead of searching for a domain property.

## Logging

Log once the retrieval is done — **one line per question answered, not per
`obsidian` call.** The 3–5 expansion queries for a fuzzy question are one
search, not five; don't flood the log with each variant.

```bash
echo "$(date -Iseconds)|search|<path or ->|<topic> (<n> queries, <m> hits)" \
  >> .system/log/log-$(date +%Y-%m).csv
```

- `path` — the folder you scoped to (`path=` argument), or `-` if unscoped.
- `summary` — the topic in a few words plus a rough hit count. Not the literal
  query strings; see [[log-manager]] for the single-line/no-`|` rules.

Example: `2026-08-10T09:12:03|search|Projects/<project>|migration risk (4 queries, 6 hits)`

## Gotchas

- **Settings → Excluded files silently filters `search`.** Files can be invisible
  with no error. If a note you're confident exists doesn't turn up, check this
  before concluding it isn't there.
- **`.system/` is invisible to Obsidian** by design. The manifest and logs are
  not searchable; read them with bash.
- **Recently written files may lag** the app's index briefly.
- **`unresolved`** lists links pointing at notes that don't exist — useful for
  spotting stubs worth creating, not just for retrieval.
