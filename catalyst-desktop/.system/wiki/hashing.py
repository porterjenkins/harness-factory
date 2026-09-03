"""Body-only hashing.

Frontmatter is stripped before hashing so the tagger's own writes cannot look
like a content edit (spec sec.3, and why v2 case 8 no longer exists).
"""
from __future__ import annotations

import hashlib
import re
from pathlib import Path
from typing import NamedTuple, Optional

from . import config

_FM_RE = re.compile(r"\A---\r?\n(.*?)\r?\n---[ \t]*\r?\n?", re.DOTALL)


class BodyStat(NamedTuple):
    hash: str
    bytes: int
    lines: int


def split_frontmatter(text: str):
    """Return (frontmatter_text_or_None, body). Never raises on malformed input."""
    m = _FM_RE.match(text)
    if not m:
        return None, text
    return m.group(1), text[m.end():]


def read_frontmatter_scalar(fm_text: Optional[str], key: str) -> Optional[str]:
    """Pull a single top-level scalar out of a frontmatter block.

    Deliberately not a YAML parser: rebuild only needs `tagged` and `tagged_hash`,
    and depending on a YAML library here would add a dependency the local path
    otherwise avoids entirely.
    """
    if not fm_text:
        return None
    pat = re.compile(r"^%s[ \t]*:[ \t]*(.*)$" % re.escape(key), re.MULTILINE)
    m = pat.search(fm_text)
    if not m:
        return None
    val = m.group(1).strip().strip("\"'")
    return val or None


def body_stat_from_text(text: str) -> BodyStat:
    _, body = split_frontmatter(text)
    raw = body.encode("utf-8")
    digest = hashlib.sha256(raw).hexdigest()[: config.HASH_LEN]
    # Count lines in the body only. An empty body is 0 lines, not 1.
    lines = 0 if not body.strip() else body.count("\n") + (0 if body.endswith("\n") else 1)
    return BodyStat(digest, len(raw), lines)


def body_stat(path: Path) -> BodyStat:
    return body_stat_from_text(path.read_text(encoding="utf-8", errors="replace"))
