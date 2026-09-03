"""The append-only action log (spec sec.7).

Contract, enforced here so no caller has to remember it:
  * pipe-delimited `timestamp|action|path|summary`
  * one line per action, not per run
  * `summary` is single-line; pipes and newlines are stripped
  * rotated monthly
Reads are deliberately not implemented. Use tail/head/grep (see the
`log-manager` skill). A function that returned the whole log would eventually
be called.
"""
from __future__ import annotations

import datetime as _dt
from pathlib import Path

from . import config

FIELD_SEP = "|"


def _sanitize(value: str) -> str:
    if value is None:
        return ""
    out = str(value).replace("\r", " ").replace("\n", " ").replace(FIELD_SEP, "/")
    return " ".join(out.split())


def log_path(when: _dt.datetime = None) -> Path:
    when = when or _dt.datetime.now()
    return config.LOG_DIR / ("log-%s.csv" % when.strftime("%Y-%m"))


def append(action: str, path: str, summary: str, when: _dt.datetime = None) -> None:
    when = when or _dt.datetime.now()
    target = log_path(when)
    target.parent.mkdir(parents=True, exist_ok=True)
    row = FIELD_SEP.join([
        when.replace(microsecond=0).isoformat(),
        _sanitize(action),
        _sanitize(path),
        _sanitize(summary),
    ])
    with target.open("a", encoding="utf-8") as fh:
        fh.write(row + "\n")
