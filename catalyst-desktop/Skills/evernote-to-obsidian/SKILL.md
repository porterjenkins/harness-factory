---
name: evernote-to-obsidian
description: Convert Evernote .enex export files into Obsidian-ready Markdown notes, with embedded resources (images, PDFs, audio, etc.) extracted to an attachments folder and linked with Obsidian syntax. Use this skill whenever the user mentions converting an Evernote export, "enex to obsidian", ".enex" files, or importing Evernote notes into the vault. Works on a single .enex file or a whole directory of them.
tags:
  - skill
  - etl
  - obsidian
  - knowledge-base
  - automation
tagged: 2026-08-27
tagged_hash: c3bca6bd795676f7
type: concept
---

# Evernote to Obsidian Conversion

## Overview

Converts Evernote `.enex` export(s) into an Obsidian vault of Markdown notes.
Each note gets YAML frontmatter (`title`, `created`, `updated`, `tags`,
`source: evernote`); embedded resources are extracted into an
`attachments/` folder and linked back into the note body — `![[file]]` for
images/PDFs, `[[file]]` for everything else.

Evernote tags are normalized for Obsidian: lowercased, with whitespace
replaced by dashes (e.g. `3rd Year Review` -> `3rd-year-review`).

Evernote internal note links (`[Note Title](evernote:///view/...)`) are
rewritten as Obsidian wiki links (`[[Note Title]]`), with the title run
through the same filename sanitizer used for note files so links resolve
in the vault. Note: if the target note lives in a different notebook that
hasn't been imported (or was imported to another folder), the wiki link
will be unresolved until that note exists in the vault.

The bundled script (`scripts/enex_to_obsidian.py`) handles both single-note
and batch conversion through the same interface: `--input` accepts either
one `.enex` file or a directory of them.

## Environment Setup

Preferred — `uv` (no manual install step):

```bash
uv run scripts/enex_to_obsidian.py --input <input> --output <output>
```

`uv` reads the inline PEP 723 dependency block at the top of the script and
installs `html2text` into an ephemeral environment automatically.

Fallback — plain pip:

```bash
pip install html2text --break-system-packages
python scripts/enex_to_obsidian.py --input <input> --output <output>
```

## Single Doc Mode

Convert one `.enex` file into a specific output folder:

```bash
uv run scripts/enex_to_obsidian.py \
  --input "/path/to/Notebook.enex" \
  --output "/path/to/output_folder"
```

## Batch Mode

Convert an entire directory of `.enex` files into one shared output folder.
The script globs `*.enex` in the input directory; note title collisions
across files are auto-deduped (e.g. `Note (2).md`):

```bash
uv run scripts/enex_to_obsidian.py \
  --input "/path/to/evernote_export_folder" \
  --output "/path/to/output_folder"
```

## Output Structure

```
output_folder/
  Note Title.md          # frontmatter + markdown body
  Another Note.md
  attachments/
    image1.png
    document.pdf
```

## Gotchas

- Note filename collisions (including across multiple `.enex` files in one
  batch run) are deduped with a `" (2)"`, `" (3)"` suffix.
- Attachment filename collisions are deduped with a short md5 hash suffix.
- A note body referencing a resource that couldn't be matched shows
  `*[missing attachment: <hash>]*` in place of the link — worth grep-ing
  output for this string after a large batch run.
- The script creates `--output` if it doesn't exist but does not clear an
  existing output folder — re-running into the same output directory is
  additive, not a clean rebuild.

## Logging

One line per **run**, not per note — a batch import of 40 notes from one `.enex` is one action,
not 40. Only log when `--output` lands inside the vault (i.e. `.system/` actually
exists at its root); skip it for conversions into a scratch/external folder, same reasoning as
`daily-plan` not inventing scaffolding that isn't there.

```bash
echo "$(date -Iseconds)|create|<output folder>|imported N note(s) from <input>, M attachment(s)" \
  >> .system/log/log-$(date +%Y-%m).csv
```

Pull `N` and the attachment count from the script's own summary output (see Verification below)
rather than re-counting by hand.

## Verification After a Run

- Check stdout: it prints `<file>.enex: N note(s)` per input file and
  `-> <slug>.md` per note written, ending with `Done. Vault written to:
  <output>`.
- Spot check one output note's frontmatter and body render correctly in
  Obsidian, and that any images/PDFs it references actually exist in
  `attachments/`.
