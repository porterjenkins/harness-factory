# shellcheck shell=bash
# Document simulation through `claude -p`.
#
# Every generated note body comes from here. Three things this wrapper exists to
# guarantee, all of them learned the hard way:
#
#   1. The CLI is invoked with no tools, no MCP, no skills, no session state and a
#      replaced system prompt. A generator that can read the real vault will
#      happily copy the real user's notes into the sandbox, which defeats the
#      point of a sandbox.
#   2. Prompt -> body is cached on disk. Re-running the harness is then nearly
#      free, so the interesting failure ("does the skill parse this vault?") can
#      be iterated on without paying for generation each time.
#   3. A failed or empty generation degrades to a deterministic stub instead of
#      writing a zero-byte note. A structurally valid sandbox with dull content
#      is testable; one with truncated notes silently is not.
#
# Source this after common.sh.

[ -n "${_CATALYST_LLM_SH:-}" ] && return 0
_CATALYST_LLM_SH=1

LLM_MODEL="${LLM_MODEL:-sonnet}"
LLM_TIMEOUT="${LLM_TIMEOUT:-240}"
LLM_RETRIES="${LLM_RETRIES:-2}"
LLM_OFFLINE="${LLM_OFFLINE:-0}"
LLM_CACHE_DIR="${LLM_CACHE_DIR:-$HOME/.cache/catalyst-sandbox/gen}"
LLM_USE_CACHE="${LLM_USE_CACHE:-1}"
LLM_STATS=""

# The generator is a text transformer, not an agent. Overriding the system prompt
# (rather than appending) drops the Claude Code harness preamble, which otherwise
# leaks phrasing about tools and working directories into the notes.
LLM_SYSTEM_PROMPT='You are generating synthetic Markdown documents for a test
fixture: a simulated personal knowledge vault belonging to a fictional person.
Everything you write is fiction. Follow the output contract in the prompt
exactly. Emit only the document -- no preamble, no commentary, no explanation of
what you did, and never wrap the whole document in a code fence.'

llm_init() {
  LLM_STATS="$1/llm-calls"
  : > "$LLM_STATS"
  if [ "$LLM_OFFLINE" = "1" ]; then
    info "generation: offline (deterministic stubs, no model calls)"
    return 0
  fi
  command -v claude >/dev/null 2>&1 \
    || die "claude CLI not on PATH. Install it, or re-run with --offline."
  mkdir -p "$LLM_CACHE_DIR"
  info "generation: claude -p (model=$LLM_MODEL, jobs=$JOBS, cache=$([ "$LLM_USE_CACHE" = 1 ] && echo on || echo off))"
}

# Portable watchdog. macOS has no coreutils `timeout`, and a hung CLI call would
# otherwise wedge the whole fan-out with no way out but ctrl-C.
_llm_run_timeout() {
  _secs="$1"; shift
  "$@" & _pid=$!
  # The watchdog must inherit NO caller file descriptors. Killing the subshell
  # does not reap its `sleep` child, and an orphaned sleep that still holds the
  # caller's stdout/stderr keeps a pipe open long after the script itself exits --
  # so `build-vault.sh | sed ...` hangs for the full timeout with nothing running.
  # fd 3 is jobs_init's dup of the real stderr and must be closed here too.
  ( sleep "$_secs"; kill -TERM "$_pid" 2>/dev/null ) >/dev/null 2>&1 3>&- & _killer=$!
  _rc=0
  wait "$_pid" 2>/dev/null || _rc=$?
  kill -TERM "$_killer" 2>/dev/null || true
  wait "$_killer" 2>/dev/null || true
  return "$_rc"
}

_llm_invoke() {  # _llm_invoke <prompt_file> <out_file>
  # cwd is the cache dir, not the vault: with CLAUDE.md auto-discovery on, running
  # this inside a vault would pull that vault's instructions into the generator.
  _llm_run_timeout "$LLM_TIMEOUT" \
    env -u CLAUDE_CODE_SSE_PORT \
    claude -p "$(cat "$1")" \
      --model "$LLM_MODEL" \
      --output-format text \
      --system-prompt "$LLM_SYSTEM_PROMPT" \
      --restricted \
      --disallowed-tools "Read Write Edit Glob Grep WebSearch WebFetch Task Agent" \
      --disable-slash-commands \
      --strict-mcp-config \
      --no-session-persistence \
      > "$2" 2>"$2.err"
}

# Models sometimes fence the whole answer despite instruction. Strip a single
# outer fence and any leading blank lines; leave interior fences alone, since a
# spec note legitimately contains code blocks.
_llm_clean() {
  awk '
    NR==1 && /^[ \t]*```/ { fenced=1; next }
    { lines[++n]=$0 }
    END {
      last=n
      if (fenced && lines[last] ~ /^[ \t]*```[ \t]*$/) last--
      started=0
      for (i=1;i<=last;i++) {
        if (!started && lines[i] ~ /^[ \t]*$/) continue
        started=1
        print lines[i]
      }
    }
  ' "$1"
}

# llm_raw <prompt_file> <out_file> <label> [min_bytes]
# Returns 1 when no usable text was produced; the caller decides whether to stub.
#
# min_bytes exists because the floor is per-call-shape: a document body under 200
# bytes was truncated or refused, but a list of two note titles is legitimately 30
# bytes. A single global floor silently stubbed every title call.
llm_raw() {
  local _pf="$1" _out="$2" _label="$3" _min="${4:-200}"
  local _key _ck _attempt
  _key="$(printf '%s\n' "$LLM_MODEL"; cat "$_pf")"
  _ck="$LLM_CACHE_DIR/$(printf '%s' "$_key" | { command -v shasum >/dev/null 2>&1 \
        && shasum -a 256 || sha256sum; } | awk '{print $1}')"

  if [ "$LLM_USE_CACHE" = "1" ] && [ -s "$_ck" ]; then
    cp "$_ck" "$_out"
    printf 'cache\t%s\n' "$_label" >> "$LLM_STATS"
    return 0
  fi

  _attempt=1
  while [ "$_attempt" -le "$LLM_RETRIES" ]; do
    if _llm_invoke "$_pf" "$_out.raw" && [ -s "$_out.raw" ]; then
      _llm_clean "$_out.raw" > "$_out"
      # Below the floor the model refused, apologised, or was cut off.
      if [ "$(wc -c < "$_out" | tr -d ' ')" -ge "$_min" ]; then
        [ "$LLM_USE_CACHE" = "1" ] && cp "$_out" "$_ck"
        rm -f "$_out.raw" "$_out.raw.err"
        printf 'live\t%s\n' "$_label" >> "$LLM_STATS"
        return 0
      fi
    fi
    warn "generation attempt $_attempt/$LLM_RETRIES failed: $_label"
    _attempt=$(( _attempt + 1 ))
    sleep 2
  done

  printf 'failed\t%s\n' "$_label" >> "$LLM_STATS"
  return 1
}

# llm_doc <prompt_file> <out_body> <out_tags> <stub_fn> [stub_args...]
#
# Splits the two-part output contract every document prompt asks for:
#
#   TAGS: alpha, beta/gamma
#   ---BODY---
#   # Title
#   ...
#
# Tags come back from the model because they are content-derived, but they are
# written into frontmatter by stamp_note so the YAML shape stays under our
# control.
llm_doc() {
  local _pf="$1" _body="$2" _tags="$3" _stub="$4"; shift 4

  if [ "$LLM_OFFLINE" = "1" ] || ! llm_raw "$_pf" "$_body.gen" "$(basename "$_body")"; then
    "$_stub" "$_body" "$_tags" "$@"
    return 0
  fi

  if grep -q '^---BODY---[[:space:]]*$' "$_body.gen"; then
    sed -n '1,/^---BODY---[[:space:]]*$/p' "$_body.gen" \
      | sed -n 's/^[Tt][Aa][Gg][Ss]:[[:space:]]*//p' | head -1 \
      | tr -d '#[]' > "$_tags"
    sed -n '/^---BODY---[[:space:]]*$/,$p' "$_body.gen" | sed '1d' \
      | sed '/./,$!d' > "$_body"
  else
    # No sentinel: treat the whole thing as body and fall back to the caller's
    # stub tags. Better a note with generic tags than a note whose first line is
    # a stray "TAGS:".
    sed 's/^[Tt][Aa][Gg][Ss]:.*$//' "$_body.gen" | sed '/./,$!d' > "$_body"
    "$_stub" "/dev/null" "$_tags" "$@"
  fi

  rm -f "$_body.gen"
  [ -s "$_body" ] || "$_stub" "$_body" "$_tags" "$@"
  # A body must end in exactly one newline, or the hash we stamp will not match
  # what the pipeline recomputes after any editor touches the file.
  printf '%s\n' "$(cat "$_body")" > "$_body.n" && mv "$_body.n" "$_body"
}

llm_summary() {
  [ -f "$LLM_STATS" ] || return 0
  _live="$(grep -c '^live' "$LLM_STATS" 2>/dev/null || true)"
  _cached="$(grep -c '^cache' "$LLM_STATS" 2>/dev/null || true)"
  _bad="$(grep -c '^failed' "$LLM_STATS" 2>/dev/null || true)"
  info "model calls: ${_live:-0} live, ${_cached:-0} cached, ${_bad:-0} failed"
}
