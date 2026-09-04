#!/usr/bin/env bash
# End-to-end test: generate a populated synthetic vault, then build into it.
#
#   ./build-into-sandbox.sh                        # minimal persona, offline, no tagging
#   ./build-into-sandbox.sh --persona default --size medium
#   ./build-into-sandbox.sh --tag 10               # also run a real tagging sample
#   ./build-into-sandbox.sh --live                 # generate prose with the model
#
# Why this exists: build-vault.sh on an empty directory can only seed stub notes,
# so its tagging phase proves the plumbing and nothing about tag quality. The
# sandbox generates a corpus nobody on this project wrote; building into it is the
# only way to exercise the tagger against content with real vocabulary in it.
#
# The order is forced. sandbox-up.sh refuses to touch a directory without its own
# marker, so it cannot run second -- and it deliberately leaves Skills/ and
# Routines/ empty for the build to fill.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
. "$(cd "$ROOT/lib" && pwd)/common.sh"

PERSONA="minimal"; SIZE="small"; OUT=""; TAG=0; LIVE=0; TODAY="$(date '+%Y-%m-%d')"
while [ $# -gt 0 ]; do
  case "$1" in
    --persona) PERSONA="$2"; shift 2 ;;
    --size)    SIZE="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    --today)   TODAY="$2"; shift 2 ;;
    --tag)     TAG="$2"; shift 2 ;;
    --live)    LIVE=1; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# ${TMPDIR} ends in a slash on macOS; strip it so the path stays clean.
OUT="${OUT:-${TMPDIR:-/tmp}}"; OUT="${OUT%/}"
[ -n "${1:-}" ] || true
case "$OUT" in *catalyst-e2e-*) ;; *) OUT="$OUT/catalyst-e2e-$PERSONA" ;; esac
case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
TEMPLATE="$WORK/from-persona.md"
FAILED=0

rule "1/5  Generate the synthetic vault"
rm -rf "$OUT"
_uargs=(--persona "$PERSONA" --size "$SIZE" --today "$TODAY" --out "$OUT" --no-verify)
[ "$LIVE" = "1" ] || _uargs+=(--offline)
"$TESTS_DIR/sandbox-up.sh" "${_uargs[@]}" >"$WORK/up.log" 2>&1 \
  || { cat "$WORK/up.log"; die "sandbox-up.sh failed"; }
ok "$(find "$OUT" -name '*.md' | wc -l | tr -d ' ') note(s) generated at $OUT"

rule "2/5  Derive a build template from the persona"
"$TESTS_DIR/persona-to-template.sh" "$PERSONA" > "$TEMPLATE"
ok "$(grep -c '^# ' "$TEMPLATE" | tr -d ' ') sections derived from $PERSONA"

rule "3/5  Build into it"
# --force because the directory is deliberately non-empty; the build backs up
# anything it would overwrite before touching it.
_bargs=(--template "$TEMPLATE" --out "$OUT" --force --yes --no-verify --today "$TODAY")
[ "$LIVE" = "1" ] || _bargs+=(--offline)
[ "$TAG" = "0" ] && _bargs+=(--skip-tagging)
"$ROOT/build/build-vault.sh" "${_bargs[@]}" >"$WORK/build.log" 2>&1 \
  || { cat "$WORK/build.log"; die "build-vault.sh failed"; }
grep -E '^   (ok|warn) ' "$WORK/build.log" | tail -10 | sed 's/^/  /' >&2 || true
ok "build completed"

rule "4/5  Both verifiers must pass on the same vault"
# The builder owns the configuration and the sandbox owns the content; neither
# may break the other's contract.
if "$TESTS_DIR/sandbox-verify.sh" "$OUT" >"$WORK/sv.log" 2>&1; then
  ok "sandbox-verify: $(grep -oE '[0-9]+ checks passed' "$WORK/sv.log" | tail -1)"
else
  fail "sandbox-verify FAILED"; grep -E '^   fail' "$WORK/sv.log" | sed 's/^/    /' >&2 || true; FAILED=1
fi
if "$ROOT/build/build-verify.sh" "$OUT" >"$WORK/bv.log" 2>&1; then
  ok "build-verify:   $(grep -oE 'PASS  [0-9]+ check' "$WORK/bv.log" | tail -1)"
else
  fail "build-verify FAILED"; grep -E '^   fail' "$WORK/bv.log" | sed 's/^/    /' >&2 || true; FAILED=1
fi

rule "5/5  Tagger against real content"
if [ "$TAG" = "0" ]; then
  info "skipped (pass --tag N to tag a sample of N)"
else
  "$OUT/.system/wiki/cli.sh" rebuild >&2
  "$OUT/.system/wiki/cli.sh" run --max-tag "$TAG" >&2 || true
  _month="$(printf '%s' "$TODAY" | cut -c1-7)"
  _log="$OUT/.system/log/log-$_month.csv"
  _n="$({ grep -c '|tag|' "$_log" 2>/dev/null || true; } | tr -d ' ')"
  if [ "${_n:-0}" -gt 0 ]; then
    ok "$_n tag row(s) written -- the vocabulary the model chose:"
    ( "$OUT/.system/wiki/cli.sh" vocab 2>/dev/null | head -12 | sed 's/^/    /' ) >&2
  else
    fail "no tags written; check that \`claude\` is logged in"; FAILED=1
  fi
fi

rule "Result"
if [ "$FAILED" = "0" ]; then
  ok "PASS — vault at $OUT"
  info "tear down:  $TESTS_DIR/sandbox-down.sh --vault '$OUT'"
  exit 0
else
  fail "FAIL — see above. Vault left at $OUT for inspection."
  exit 1
fi
