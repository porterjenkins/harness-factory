"""Tunables and paths for the wiki ingestion pipeline.

Everything configurable lives here. Nothing else should hardcode a path.
Environment variables override defaults so the cloud tagger can differ from local
without a code change.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

# .system/wiki/config.py -> parents[0]=wiki, [1]=.system, [2]=vault root
VAULT = Path(os.environ.get("WIKI_VAULT_PATH", Path(__file__).resolve().parents[2]))

# Obsidian CLI vault target. NEVER rely on "most recently focused vault" (spec sec.9).
VAULT_NAME = os.environ.get("WIKI_VAULT_NAME", VAULT.name)

SYSTEM_DIR = VAULT / ".system"
# The pipeline's own directory -- this package plus the manifest it owns. Keeping
# the DB beside the code that manages it means one move relocates both.
WIKI_DIR = SYSTEM_DIR / "wiki"
MANIFEST = WIKI_DIR / "manifest.sqlite"
# All logs under one roof: the action log, its archive, and the LaunchAgent's
# stdout/stderr.
LOG_DIR = SYSTEM_DIR / "log"
LOG_ARCHIVE = LOG_DIR / "log-archive.md"
RUN_LOG_DIR = LOG_DIR / "run-logs"

# Folders never ingested. Dot-folders are skipped implicitly by the walker.
EXCLUDED_DIRS = {".system", ".obsidian", ".claude", ".git", ".trash", "Templates"}

# Files that are configuration or scaffolding rather than knowledge. Tagging
# CLAUDE.md pollutes the vocabulary with terms from the vault's own instructions
# and rewrites the file agents read on every session.
EXCLUDED_FILES = set(
    os.environ.get("WIKI_EXCLUDED_FILES", "CLAUDE.md,README.md").split(",")
)

# --- Case 4 vs 5 threshold (spec sec.3) -------------------------------------
# Start permissive: favour skipping re-tags. Re-tag only when the body moved
# enough that its meaning plausibly changed.
RETAG_MIN_LINE_DELTA = int(os.environ.get("WIKI_RETAG_LINE_DELTA", "5"))
RETAG_MIN_BYTE_PCT = float(os.environ.get("WIKI_RETAG_BYTE_PCT", "0.10"))

# --- Tagging -----------------------------------------------------------------
# Per-run ceiling. Polling is cheap; tagging is not (spec sec.9).
MAX_TAG_PER_RUN = int(os.environ.get("WIKI_MAX_TAG_PER_RUN", "10"))
TAG_BATCH_SIZE = int(os.environ.get("WIKI_TAG_BATCH_SIZE", "5"))
# Per-file body budget sent to the tagger. Long notes are truncated, not skipped.
TAG_BODY_CHARS = int(os.environ.get("WIKI_TAG_BODY_CHARS", "6000"))
MAX_TAG_ATTEMPTS = int(os.environ.get("WIKI_MAX_TAG_ATTEMPTS", "3"))
CLAUDE_BIN = os.environ.get("WIKI_CLAUDE_BIN", "claude")
CLAUDE_TIMEOUT = int(os.environ.get("WIKI_CLAUDE_TIMEOUT", "300"))

# --- Obsidian CLI ------------------------------------------------------------
# The app's CLI socket (macOS/Linux: ~/.obsidian-cli.sock, or under
# XDG_RUNTIME_DIR on Linux when set). The pipeline talks to this directly
# rather than spawning the `obsidian` binary -- the binary is a second
# Electron instance of Obsidian.app, and on macOS every spawn activates the
# app and fronts its window (or launches the GUI outright when it is closed).
_sock_dir = Path.home()
if sys.platform != "darwin" and os.environ.get("XDG_RUNTIME_DIR"):
    _sock_dir = Path(os.environ["XDG_RUNTIME_DIR"])
OBSIDIAN_SOCKET = Path(os.environ.get("WIKI_OBSIDIAN_SOCKET",
                                      str(_sock_dir / ".obsidian-cli.sock")))

# Obsidian's vault registry. Vaults whose window is open are flagged
# `"open": true`; the flag is dropped when the window closes. The pipeline
# reads this before every CLI command because the app's dispatcher services
# any command by opening the target vault's window if it is closed.
if sys.platform == "darwin":
    _obs_cfg = Path.home() / "Library" / "Application Support" / "obsidian"
else:
    _obs_cfg = Path(os.environ.get("XDG_CONFIG_HOME",
                                   str(Path.home() / ".config"))) / "obsidian"
OBSIDIAN_STATE_JSON = Path(os.environ.get("WIKI_OBSIDIAN_STATE_JSON",
                                          str(_obs_cfg / "obsidian.json")))
OBSIDIAN_READY_TIMEOUT = int(os.environ.get("WIKI_OBSIDIAN_READY_TIMEOUT", "60"))
OBSIDIAN_CMD_TIMEOUT = int(os.environ.get("WIKI_OBSIDIAN_CMD_TIMEOUT", "45"))

# --- Cadence (managed internally; one LaunchAgent drives everything) --------
SWEEP_INTERVAL_DAYS = int(os.environ.get("WIKI_SWEEP_DAYS", "7"))
PRUNE_INTERVAL_DAYS = int(os.environ.get("WIKI_PRUNE_DAYS", "30"))
DELETE_GRACE_DAYS = int(os.environ.get("WIKI_DELETE_GRACE_DAYS", "30"))

# Length of the hex hash stored in the manifest and in `tagged_hash` frontmatter.
# 64 bits is far beyond collision risk at vault scale, and sec.3 falls through to
# case 1 on ambiguity anyway.
HASH_LEN = 16
