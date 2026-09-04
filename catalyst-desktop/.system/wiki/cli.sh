#!/usr/bin/env bash
# Run the wiki CLI inside the vault's uv project.
#
#   .system/wiki/cli.sh doctor
#   .system/wiki/cli.sh run --max-tag 10
#
# Bare `python3 .system/wiki/cli.py` is the trap: a freshly built vault is never
# open in Obsidian, so writes go through ruamel.yaml, and system Python does not
# have it. This wrapper is `uv run --project .system`, the same environment the
# build synced, the LaunchAgent uses, and doctor now requires.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="$(cd "$HERE/../.." && pwd)"
PROJECT="$VAULT/.system"

if ! command -v uv >/dev/null 2>&1; then
  echo "error: uv is required to run the wiki pipeline (https://docs.astral.sh/uv/)" >&2
  echo "       The no-Obsidian write path needs ruamel.yaml from .system/pyproject.toml." >&2
  exit 1
fi

if [ ! -f "$PROJECT/pyproject.toml" ]; then
  echo "error: $PROJECT/pyproject.toml is missing." >&2
  echo "       Re-run the vault build, or copy pyproject.toml and uv.lock into .system/" >&2
  echo "       and: uv sync --project $PROJECT --frozen" >&2
  exit 1
fi

# --project pins the env that has ruamel.yaml. --directory keeps vault-relative
# paths working no matter where this was invoked from.
exec uv run --project "$PROJECT" --directory "$VAULT" python "$HERE/cli.py" "$@"
