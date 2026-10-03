"""Frontmatter writes.

Two paths, per spec sec.5:
  1. processFrontMatter via `obsidian eval` -- Obsidian's own writer. Atomic per
     file, batchable, and touches frontmatter only, which is what makes v2 case 8
     (the post-tagging feedback loop) impossible.
  2. ruamel.yaml round-trip -- the cloud fallback when no app is available.
     Round-trip mode preserves hand-authored formatting and comments.

Never hand-edit YAML.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List, Tuple

from . import config, obsidian
from .hashing import read_frontmatter_scalar, split_frontmatter


class WriteError(RuntimeError):
    pass


def verify_written(vault: Path, updates: Dict[str, dict]) -> List[str]:
    """Confirm on disk which files actually received their frontmatter.

    Ground truth, deliberately. The Obsidian CLI decorates `eval` output (a
    returned value comes back prefixed, e.g. `=> CLAUDE.md`), so parsing stdout
    for paths yields strings that match no file and no manifest row. Re-reading
    the frontmatter is immune to whatever the CLI decides to print.
    """
    confirmed = []
    for rel, props in updates.items():
        expected = props.get("tagged_hash")
        try:
            text = (vault / rel).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        fm_text, _ = split_frontmatter(text)
        if not fm_text:
            continue
        if expected:
            if read_frontmatter_scalar(fm_text, "tagged_hash") == expected:
                confirmed.append(rel)
        elif read_frontmatter_scalar(fm_text, "tagged"):
            confirmed.append(rel)
    return confirmed


def write_via_obsidian(updates: Dict[str, dict]) -> List[str]:
    """Apply {path: {property: value}} inside the Obsidian process, one call.

    Returns whatever the CLI echoed back. Advisory only -- callers must confirm
    with verify_written(); see the note there about output decoration.
    """
    if not updates:
        return []
    payload = json.dumps(updates, ensure_ascii=True)
    code = (
        "(async () => { const U = " + payload + "; const done = [];"
        " for (const [p, props] of Object.entries(U)) {"
        "   const f = app.vault.getAbstractFileByPath(p);"
        "   if (!f) continue;"
        "   await app.fileManager.processFrontMatter(f, fm => {"
        "     for (const [k, v] of Object.entries(props)) { fm[k] = v; }"
        "   });"
        "   done.push(p);"
        " } return done.join('\\n'); })()"
    )
    raw = obsidian.eval_js(code, timeout=max(60, 5 * len(updates)))
    out = []
    for line in raw.splitlines():
        line = line.strip().lstrip("=>").strip()
        if line in updates:
            out.append(line)
    return out


def write_via_ruamel(vault: Path, updates: Dict[str, dict]) -> List[str]:
    """Cloud path. Requires ruamel.yaml; owning YAML correctness is the cost of
    running without the app (spec sec.5)."""
    try:
        from ruamel.yaml import YAML  # type: ignore
    except ImportError as exc:  # pragma: no cover - environment dependent
        raise WriteError(
            "ruamel.yaml is required for the no-Obsidian write path. "
            "Run via .system/wiki/cli.sh (uv run --project .system), "
            "not bare python3."
        ) from exc

    import io

    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 4096
    # Match Obsidian's own frontmatter style ("  - tag") so pipeline writes and
    # hand edits do not produce spurious diffs against each other.
    yaml.indent(mapping=2, sequence=4, offset=2)

    from ruamel.yaml.comments import CommentedMap

    written = []
    for rel, props in updates.items():
        target = vault / rel
        try:
            text = target.read_text(encoding="utf-8")
            fm_text, body = split_frontmatter(text)

            data = None
            if fm_text:
                try:
                    data = yaml.load(fm_text)
                except Exception:
                    # Malformed frontmatter -- e.g. an unquoted `key: value`
                    # inside a description. Skip rather than guess: rewriting a
                    # block we could not parse risks destroying content, and
                    # crashing here would abort the whole batch for one bad file.
                    written.append(None)
                    continue
            if not isinstance(data, dict):
                data = CommentedMap()

            for key, value in props.items():
                data[key] = value

            buf = io.StringIO()
            yaml.dump(data, buf)
            new_text = "---\n" + buf.getvalue().rstrip("\n") + "\n---\n" + body
            tmp = target.with_suffix(target.suffix + ".tmp")
            tmp.write_text(new_text, encoding="utf-8")
            tmp.replace(target)
            written.append(rel)
        except Exception:
            # One unwritable file must never take the batch down with it.
            continue
    return [w for w in written if w]


def write(vault: Path, updates: Dict[str, dict],
          prefer_obsidian: bool = True) -> Tuple[List[str], str]:
    """Write frontmatter, returning (paths_confirmed_on_disk, mechanism_used).

    The return value is always verified against the filesystem rather than taken
    from the writer's own report. A path that comes back here is one whose
    frontmatter demonstrably changed -- anything else would let the manifest
    record a file as tagged when it isn't, and it would never be retried.
    """
    if prefer_obsidian and obsidian.installed():
        try:
            write_via_obsidian(updates)
            confirmed = verify_written(vault, updates)
            if confirmed:
                return confirmed, "processFrontMatter"
        except Exception:
            pass
    write_via_ruamel(vault, updates)
    return verify_written(vault, updates), "ruamel"
