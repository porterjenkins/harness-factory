"""Tag drift detection (spec sec.5, sec.8).

Two modes, resolved at runtime by `resolve_vocabulary`:

  * **canon mode** -- a declared vocabulary exists in `tags.md`. The listed
    spelling wins outright, regardless of how often the variant is used. Vault
    tags with no canon match are reported as unlisted, never merged and never
    deleted.
  * **frequency mode** -- no `tags.md`. The vault's own state is the vocabulary
    and frequency is the signal: count 1 is probably drift, count 40 is canon.
    Load-bearing here, because with nothing declared whatever the tagger invents
    becomes canon on the next run and drift ratchets.

Canon mode is only safe while the list is maintained. A stale `tags.md` would
mass-merge live tags into dead spellings, so `canon_coverage` measures how much
of the vault's established vocabulary the list actually accounts for and the
caller is expected to refuse canon mode when that falls through the floor.

This module only *finds* candidates. Merges are executed by the `tag-lint` skill
after a human approves them.
"""
from __future__ import annotations

import itertools
import re
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple


def normalize(tag: str) -> str:
    return tag.lower().replace("-", "").replace("_", "")


def segments(tag: str) -> frozenset:
    return frozenset(s for s in normalize(tag).split("/") if s)


def _levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def find_near_duplicates(counts: Dict[str, int], max_edit: int = 2) -> List[dict]:
    """Group tags that are probably the same concept.

    Three signals, most confident first:
      * reordered nesting -- `proj/ai` vs `ai/proj`: identical segment sets
      * case/separator-only difference -- `Proj/AI` vs `proj-ai`
      * small edit distance -- `mongodb` vs `mongod`
    """
    findings: List[dict] = []
    tags = sorted(counts)
    seen: set = set()

    by_segments: Dict[frozenset, List[str]] = {}
    for tag in tags:
        by_segments.setdefault(segments(tag), []).append(tag)
    for seg, group in by_segments.items():
        if len(group) > 1 and len(seg) > 1:
            findings.append(_finding(group, counts, "reordered nesting"))
            seen.update(group)

    by_norm: Dict[str, List[str]] = {}
    for tag in tags:
        by_norm.setdefault(normalize(tag), []).append(tag)
    for group in by_norm.values():
        if len(group) > 1 and not set(group) & seen:
            findings.append(_finding(group, counts, "case or separator only"))
            seen.update(group)

    for a, b in itertools.combinations(tags, 2):
        if a in seen or b in seen:
            continue
        na, nb = normalize(a), normalize(b)
        if abs(len(na) - len(nb)) > max_edit:
            continue
        if min(len(na), len(nb)) < 4:
            continue
        if _levenshtein(na, nb) <= max_edit:
            findings.append(_finding([a, b], counts, "edit distance <= %d" % max_edit))
            seen.update([a, b])

    findings.sort(key=lambda f: -f["total"])
    return findings


def _finding(group: List[str], counts: Dict[str, int], reason: str) -> dict:
    ranked = sorted(group, key=lambda t: (-counts.get(t, 0), t))
    return {
        "reason": reason,
        "keep": ranked[0],
        "keep_count": counts.get(ranked[0], 0),
        "merge": [{"tag": t, "count": counts.get(t, 0)} for t in ranked[1:]],
        "total": sum(counts.get(t, 0) for t in group),
    }


def find_singletons(counts: Dict[str, int], threshold: int = 1) -> List[Tuple[str, int]]:
    """Tags at or below `threshold` uses. Prime drift suspects, but not automatically
    wrong -- a genuinely new project starts at count 1."""
    return sorted(((t, c) for t, c in counts.items() if c <= threshold),
                  key=lambda tc: tc[0])


def merge_plan(findings: List[dict]) -> List[dict]:
    """Flatten findings into {from, to} pairs for the skill to execute."""
    plan = []
    for f in findings:
        for item in f["merge"]:
            plan.append({"from": item["tag"], "to": f["keep"],
                         "reason": f["reason"], "from_count": item["count"]})
    return plan


# --- declared vocabulary (tags.md) -------------------------------------------

CANON_LOCATIONS = ("tags.md", ".system/tags.md")

#: A vault tag is "established" at or above this count. Used only to judge
#: whether tags.md is current enough to trust -- not to judge the tags.
ESTABLISHED_AT = 5

#: Refuse canon mode below this share of established vault tags being listed.
COVERAGE_FLOOR = 0.60

_TAG_LINE = re.compile(r"^\s*(?:[-*+]\s+|\d+\.\s+)?[`#]?([A-Za-z0-9][A-Za-z0-9/_-]*)`?\s*$")


def find_canon_file(vault: Path) -> Optional[Path]:
    """First existing `tags.md` in the known locations, or None."""
    for rel in CANON_LOCATIONS:
        p = Path(vault) / rel
        if p.is_file():
            return p
    return None


def parse_canon(text: str) -> List[str]:
    """Pull tag names out of a hand-written tags.md.

    Deliberately permissive about layout -- bullets, numbered lists, backticks,
    a leading `#`, or bare lines all work -- so the file can be organised for a
    human reader. Anything that is not plausibly a single tag is skipped:
    frontmatter, headings (`# ` with a space), blank lines, HTML comments, and
    prose. A tag never contains whitespace, which is what makes prose separable.
    """
    tags: List[str] = []
    seen = set()
    in_frontmatter = False
    in_code = False
    for i, raw in enumerate(text.splitlines()):
        line = raw.rstrip()
        if i == 0 and line.strip() == "---":
            in_frontmatter = True
            continue
        if in_frontmatter:
            if line.strip() in ("---", "..."):
                in_frontmatter = False
            continue
        if line.strip().startswith("```"):
            in_code = not in_code
            continue
        if in_code or not line.strip():
            continue
        if line.lstrip().startswith(("<!--", "> ")):
            continue
        if re.match(r"^\s*#{1,6}\s", line):      # heading, not an inline tag
            continue
        m = _TAG_LINE.match(line)
        if not m:
            continue
        tag = m.group(1)
        if tag.lower() not in seen:
            seen.add(tag.lower())
            tags.append(tag)
    return tags


def load_canon(vault: Path) -> Tuple[List[str], Optional[Path]]:
    """`(tags, path)` from the first tags.md found, or `([], None)`."""
    path = find_canon_file(vault)
    if path is None:
        return [], None
    try:
        return parse_canon(path.read_text(encoding="utf-8")), path
    except OSError:
        return [], None


def canon_coverage(counts: Dict[str, int], canon: Sequence[str],
                   established_at: int = ESTABLISHED_AT) -> dict:
    """How much of the vault's established vocabulary tags.md accounts for.

    A low share means the *list* is behind the vault, not that the vault has
    drifted -- the opposite conclusion, and acting on the wrong one merges live
    tags into dead spellings across the whole vault.
    """
    canon_norm = {normalize(t) for t in canon}
    established = {t: c for t, c in counts.items() if c >= established_at}
    listed = [t for t in established if normalize(t) in canon_norm]
    missing = sorted((t for t in established if normalize(t) not in canon_norm),
                     key=lambda t: (-counts[t], t))
    total = len(established)
    return {
        "established_at": established_at,
        "established": total,
        "listed": len(listed),
        "coverage": (len(listed) / total) if total else 1.0,
        "missing": [{"tag": t, "count": counts[t]} for t in missing],
        "unused_canon": sorted(t for t in canon
                               if normalize(t) not in {normalize(v) for v in counts}),
    }


def canon_findings(counts: Dict[str, int], canon: Sequence[str],
                   max_edit: int = 2) -> Tuple[List[dict], List[Tuple[str, int]]]:
    """Match vault tags against a declared vocabulary.

    Returns `(findings, unlisted)`. Same three signals as frequency mode, but the
    canonical spelling is always the survivor -- that is the whole point of
    declaring one. `unlisted` is every vault tag with no canon match: new work
    that belongs in tags.md, or drift too far gone to match automatically. Either
    way it is the user's call, so nothing is proposed for it.
    """
    by_norm = {normalize(t): t for t in canon}
    by_segs: Dict[frozenset, str] = {}
    for t in canon:
        by_segs.setdefault(segments(t), t)
    canon_lower = {t.lower() for t in canon}

    grouped: Dict[str, List[Tuple[str, str]]] = {}
    unlisted: List[Tuple[str, int]] = []

    for tag in sorted(counts):
        if tag in canon or tag.lower() in canon_lower:
            continue
        norm = normalize(tag)
        target = by_norm.get(norm)
        reason = "case or separator only"
        if target is None:
            segs = segments(tag)
            if len(segs) > 1 and segs in by_segs:
                target, reason = by_segs[segs], "reordered nesting"
        if target is None:
            best, best_d = None, max_edit + 1
            for c in canon:
                nc = normalize(c)
                if abs(len(nc) - len(norm)) > max_edit or min(len(nc), len(norm)) < 4:
                    continue
                d = _levenshtein(norm, nc)
                if d < best_d:
                    best, best_d = c, d
            if best is not None:
                target, reason = best, "edit distance <= %d" % max_edit
        if target is None:
            unlisted.append((tag, counts[tag]))
        else:
            grouped.setdefault(target, []).append((tag, reason))

    findings = []
    for target, variants in grouped.items():
        findings.append({
            "reason": "; ".join(sorted({r for _, r in variants})) + " (vs tags.md)",
            "keep": target,
            "keep_count": counts.get(target, 0),
            "merge": [{"tag": t, "count": counts.get(t, 0)}
                      for t, _ in sorted(variants, key=lambda tr: (-counts.get(tr[0], 0), tr[0]))],
            "total": counts.get(target, 0) + sum(counts.get(t, 0) for t, _ in variants),
        })
    findings.sort(key=lambda f: -f["total"])
    return findings, sorted(unlisted, key=lambda tc: (-tc[1], tc[0]))


def resolve_vocabulary(counts: Dict[str, int], vault: Path,
                       force_frequency: bool = False) -> dict:
    """Decide which mode to run in and produce that mode's report.

    Canon mode requires a tags.md that parsed to something *and* that still
    accounts for `COVERAGE_FLOOR` of the vault's established tags. Failing
    either, this falls back to frequency mode and says why -- silently linting
    against a stale list is the one outcome worth engineering against.
    """
    canon, path = ([], None) if force_frequency else load_canon(Path(vault))
    coverage = canon_coverage(counts, canon) if canon else None

    if canon and coverage["coverage"] >= COVERAGE_FLOOR:
        findings, unlisted = canon_findings(counts, canon)
        return {"mode": "canon", "canon_path": str(path), "canon_size": len(canon),
                "coverage": coverage, "near_duplicates": findings,
                "unlisted": unlisted, "singletons": find_singletons(counts),
                "merge_plan": merge_plan(findings), "fallback_reason": None}

    if force_frequency:
        why = "frequency mode forced"
    elif path is None:
        why = "no tags.md found in %s" % ", ".join(CANON_LOCATIONS)
    elif not canon:
        why = "%s parsed to zero tags" % path
    else:
        why = ("%s covers only %d of %d established tags (%.0f%%, floor %.0f%%) -- "
               "the list looks stale, not the vault"
               % (path, coverage["listed"], coverage["established"],
                  100 * coverage["coverage"], 100 * COVERAGE_FLOOR))

    return {"mode": "frequency", "canon_path": str(path) if path else None,
            "canon_size": len(canon), "coverage": coverage,
            "near_duplicates": find_near_duplicates(counts), "unlisted": [],
            "singletons": find_singletons(counts),
            "merge_plan": merge_plan(find_near_duplicates(counts)),
            "fallback_reason": why}
