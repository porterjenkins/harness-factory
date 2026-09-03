"""Change detection: the six cases of spec sec.3.

Pure logic. No I/O beyond reading file bodies, no database, no network -- so it
is fully testable and lives in .system/ as code rather than in a skill (spec sec.2).
"""
from __future__ import annotations

import collections
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, NamedTuple, Optional, Set

from . import config
from .hashing import BodyStat, body_stat

# Case numbers match the spec table exactly.
NEW = 1
MOVED = 2
UNCHANGED = 3
CHEAP_EDIT = 4
REAL_EDIT = 5
DELETED = 6

CASE_NAMES = {
    NEW: "new", MOVED: "moved", UNCHANGED: "unchanged",
    CHEAP_EDIT: "cheap-edit", REAL_EDIT: "real-edit", DELETED: "deleted",
}


class DiskEntry(NamedTuple):
    """What a single stat() call tells us. Both fields feed the pre-filter."""
    mtime: int
    size: int


@dataclass
class Decision:
    path: str
    case: int
    stat: Optional[BodyStat] = None
    mtime: int = 0
    file_bytes: int = 0
    from_path: Optional[str] = None   # case 2 only
    reason: str = ""

    @property
    def needs_tagging(self) -> bool:
        return self.case in (NEW, REAL_EDIT)


@dataclass
class Plan:
    decisions: List[Decision] = field(default_factory=list)
    observed: Set[str] = field(default_factory=set)
    hashed: int = 0

    def by_case(self) -> Dict[int, List[Decision]]:
        out = collections.defaultdict(list)
        for d in self.decisions:
            out[d.case].append(d)
        return out


def walk_vault(vault: Path) -> Dict[str, DiskEntry]:
    """Every ingestable markdown file, as {vault-relative posix path: DiskEntry}.

    Dot-directories are skipped wholesale, which is the same rule Obsidian and
    Obsidian Sync apply, and why .system/ needs no exclusion config (spec sec.2).
    """
    out: Dict[str, DiskEntry] = {}
    for p in vault.rglob("*.md"):
        rel = p.relative_to(vault)
        parts = rel.parts
        if any(part.startswith(".") for part in parts[:-1]):
            continue
        if any(part in config.EXCLUDED_DIRS for part in parts[:-1]):
            continue
        if _is_conflict_fork(rel.name):
            continue
        if rel.name in config.EXCLUDED_FILES or rel.as_posix() in config.EXCLUDED_FILES:
            continue
        try:
            st = p.stat()
            out[rel.as_posix()] = DiskEntry(st.st_mtime_ns, st.st_size)
        except OSError:
            continue
    return out


_CONFLICT_MARKERS = ("conflicted copy", ".sync-conflict", "conflict-", ".conflict")


def _is_conflict_fork(name: str) -> bool:
    """Sync conflict forks must never be tagged as legitimate new content (spec sec.9).

    A silently tagged conflict fork is worse than a visible failure, so these are
    excluded here and reported separately by the caller.
    """
    low = name.lower()
    return any(marker in low for marker in _CONFLICT_MARKERS)


def find_conflict_forks(vault: Path) -> List[str]:
    found = []
    for p in vault.rglob("*.md"):
        rel = p.relative_to(vault)
        if any(part.startswith(".") for part in rel.parts[:-1]):
            continue
        if _is_conflict_fork(rel.name):
            found.append(rel.as_posix())
    return found


def is_real_edit(old_bytes: Optional[int], old_lines: Optional[int], new: BodyStat) -> bool:
    """Case 4 vs case 5.

    Sizes are a proxy for edit magnitude -- a hash says *changed*, not *how much*
    (spec sec.3/sec.4). Missing baselines are treated as a real edit: better to
    re-tag once than to silently skip.
    """
    if old_bytes is None or old_lines is None:
        return True
    if abs(new.lines - old_lines) >= config.RETAG_MIN_LINE_DELTA:
        return True
    denom = max(old_bytes, 1)
    return (abs(new.bytes - old_bytes) / denom) >= config.RETAG_MIN_BYTE_PCT


def classify(vault: Path, disk: Dict[str, DiskEntry], rows: Dict[str, dict],
             full_rehash: bool = False) -> Plan:
    """Classify every file on disk against the manifest.

    `rows` maps path -> mapping with keys mtime, file_bytes, body_hash,
    body_bytes, body_lines, status. `disk` maps path -> DiskEntry.
    """
    plan = Plan(observed=set(disk))

    # A row is a move candidate only if its path is NOT on disk. Computed up
    # front from the full disk listing rather than from seen_at stamping order.
    unobserved_by_hash: Dict[str, List[str]] = collections.defaultdict(list)
    for path, row in rows.items():
        if path in disk:
            continue
        if (row.get("status") or "") == "deleted":
            continue
        unobserved_by_hash[row["body_hash"]].append(path)

    claimed: Set[str] = set()

    for path in sorted(disk):
        entry = disk[path]
        mtime, size = entry.mtime, entry.size
        row = rows.get(path)

        # --- pre-filter (spec sec.3) ------------------------------------------
        # Two guards, because either alone loses data silently:
        #   * mtime compared by INEQUALITY, never `>`. mtime does not advance
        #     monotonically once sync is involved -- a file can arrive carrying
        #     the origin device's older timestamp, which `>` would never re-hash.
        #   * file size, because mtime resolution is filesystem-dependent. Where
        #     granularity is coarse (1s), rewriting a file inside the same second
        #     leaves mtime untouched; size catches any edit that changes length.
        # An edit changing neither mtime nor length is caught only by the weekly
        # full-rehash sweep. That residue is why the sweep exists.
        # `pending` bypasses the pre-filter deliberately: a file whose tagging
        # was deferred by the ceiling or failed mid-run has unchanged mtime and
        # size, so the shortcut below would classify it `unchanged` forever and
        # it would never be retried. Pending means outstanding work.
        if row is not None and not full_rehash \
                and row.get("mtime") == mtime and row.get("file_bytes") == size \
                and (row.get("status") or "") not in ("deleted", "pending"):
            plan.decisions.append(Decision(path, UNCHANGED, mtime=mtime, file_bytes=size,
                                           reason="mtime and size unchanged; not hashed"))
            continue

        try:
            stat = body_stat(vault / path)
        except OSError as exc:
            plan.decisions.append(Decision(path, UNCHANGED, mtime=mtime, file_bytes=size,
                                           reason="unreadable: %s" % exc))
            continue
        plan.hashed += 1

        if row is not None and (row.get("status") or "") != "deleted":
            if row["body_hash"] == stat.hash:
                plan.decisions.append(Decision(path, UNCHANGED, stat, mtime, size,
                                               reason="hash unchanged; mtime/size touched"))
            elif is_real_edit(row.get("body_bytes"), row.get("body_lines"), stat):
                plan.decisions.append(Decision(path, REAL_EDIT, stat, mtime, size,
                                               reason="body delta above threshold"))
            else:
                plan.decisions.append(Decision(path, CHEAP_EDIT, stat, mtime, size,
                                               reason="body delta below threshold"))
            continue

        # No live row at this path -> new or moved.
        candidates = [c for c in unobserved_by_hash.get(stat.hash, []) if c not in claimed]
        if len(candidates) == 1:
            src = candidates[0]
            claimed.add(src)
            plan.decisions.append(Decision(path, MOVED, stat, mtime, size, from_path=src,
                                           reason="hash matches unobserved %s" % src))
        else:
            # Zero candidates: genuinely new. More than one: ambiguous, and
            # guessing would ping-pong a row between duplicate-bodied files
            # (spec sec.3). Fall through to case 1 either way.
            reason = "new content" if not candidates else (
                "ambiguous move (%d candidates); treating as new" % len(candidates))
            plan.decisions.append(Decision(path, NEW, stat, mtime, size, reason=reason))

    return plan
