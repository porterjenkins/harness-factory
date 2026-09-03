"""Headless tagger.

Invokes `claude -p`. Headless mode does not auto-trigger slash-command skills, so
the expected output shape is stated explicitly in the prompt rather than
referenced by skill name (spec sec.5).

The tagger is the only step in the pipeline that calls an LLM. Everything else is
deterministic and lives in plain code.
"""
from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

from . import config
from .hashing import split_frontmatter

PROMPT_VERSION = "1"

_SYSTEM = """You tag notes for a personal/company knowledge base kept in Obsidian.

For each note you are given, choose Obsidian tags. Rules:

1. STRONGLY PREFER tags that already exist in the vocabulary below. The count next
   to each tag is how many notes already use it. A high count means the tag is
   established and you should reuse it. A count of 1 usually means it was a
   mistake -- do not propagate it.
2. Only invent a new tag when nothing in the vocabulary fits. If you invent one,
   follow the existing naming style (lowercase, `/` for nesting, e.g. `project/subproject`).
3. Use 2-6 tags per note. Fewer good tags beat many weak ones.
4. Do NOT include a leading `#`.
5. Do NOT invent a `domain` tag or property -- domain is derived from the folder path.

Return ONLY a JSON object mapping each note's exact path to its result:

{"<path>": {"tags": ["a", "b/c"], "type": "meeting-note", "summary": "one line"}}

`type` is one of: entity, concept, source-summary, decision, person, project,
meeting-note, architecture, announcement. `summary` is a single plain-text line,
no pipes. Output nothing but the JSON object."""


@dataclass
class TagResult:
    path: str
    tags: List[str]
    type: Optional[str] = None
    summary: str = ""


def build_prompt(vocabulary: Dict[str, int], notes: Dict[str, str]) -> str:
    if vocabulary:
        vocab_lines = "\n".join(
            "%s (%d)" % (tag, count)
            for tag, count in sorted(vocabulary.items(), key=lambda kv: (-kv[1], kv[0]))
        )
    else:
        vocab_lines = "(vault has no tags yet -- you are establishing the vocabulary)"

    parts = [_SYSTEM, "", "## Existing tag vocabulary", vocab_lines, "", "## Notes to tag"]
    for path, body in notes.items():
        snippet = body.strip()
        if len(snippet) > config.TAG_BODY_CHARS:
            snippet = snippet[: config.TAG_BODY_CHARS] + "\n...[truncated]"
        parts += ["", "### PATH: %s" % path, "```markdown", snippet, "```"]
    return "\n".join(parts)


def _extract_json(text: str) -> dict:
    """Tolerate fenced blocks and surrounding chatter."""
    text = text.strip()
    fence = re.search(r"```(?:json)?\s*(.*?)```", text, re.DOTALL)
    if fence:
        text = fence.group(1).strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    start, depth = None, 0
    for i, ch in enumerate(text):
        if ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0 and start is not None:
                try:
                    return json.loads(text[start:i + 1])
                except json.JSONDecodeError:
                    start = None
    raise ValueError("no JSON object found in tagger output: %s" % text[:300])


def invoke(prompt: str) -> str:
    # stdin MUST be closed explicitly. `claude -p` waits ~3s for piped stdin and
    # then errors; under launchd there is no stdin at all, so without DEVNULL the
    # unattended job fails on every run.
    proc = subprocess.run(
        [config.CLAUDE_BIN, "-p", prompt],
        stdin=subprocess.DEVNULL,
        capture_output=True, text=True, timeout=config.CLAUDE_TIMEOUT,
    )
    if proc.returncode != 0:
        raise RuntimeError("claude -p failed (%d): %s"
                           % (proc.returncode, (proc.stderr or proc.stdout).strip()[:400]))
    return proc.stdout


def tag_batch(vault: Path, paths: List[str], vocabulary: Dict[str, int],
              invoker=None) -> Dict[str, TagResult]:
    """Tag a batch of notes. `invoker` is injectable so tests never shell out."""
    notes = {}
    for rel in paths:
        try:
            text = (vault / rel).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        _, body = split_frontmatter(text)
        notes[rel] = body
    if not notes:
        return {}

    raw = (invoker or invoke)(build_prompt(vocabulary, notes))
    data = _extract_json(raw)

    results: Dict[str, TagResult] = {}
    for path, payload in data.items():
        if path not in notes:
            continue
        if isinstance(payload, list):
            payload = {"tags": payload}
        if not isinstance(payload, dict):
            continue
        tags = [str(t).lstrip("#").strip() for t in (payload.get("tags") or []) if str(t).strip()]
        if not tags:
            continue
        results[path] = TagResult(
            path=path,
            tags=tags,
            type=(str(payload["type"]).strip() if payload.get("type") else None),
            summary=str(payload.get("summary") or "").replace("|", "/").strip(),
        )
    return results
