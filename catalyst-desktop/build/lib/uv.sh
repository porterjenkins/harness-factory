# shellcheck shell=bash
# Install uv if the host does not already have it.
#
# Source after common.sh. Called from build-vault.sh preflight. The wiki CLI is
# `uv run --project .system`; a missing uv used to be a hard stop that sent
# people to a website. Vault owners are not going to do that, so the build does.

[ -n "${_CATALYST_UV_SH:-}" ] && return 0
_CATALYST_UV_SH=1

# Put a directory on PATH if it is not already there. The standalone installer
# edits the shell profile, which does not apply to this process, to launchd, or
# to a terminal that was already open.
_uv_bindir_on_path() {
  _dir="${1:-}"
  [ -n "$_dir" ] && [ -d "$_dir" ] || return 0
  case ":$PATH:" in
    *":$_dir:"*) ;;
    *) PATH="$_dir:$PATH"; export PATH ;;
  esac
}

_uv_ok() {
  command -v uv >/dev/null 2>&1 && uv --version >/dev/null 2>&1
}

# Official standalone installer. macOS/Linux use the shell script; Windows uses
# the PowerShell script so the user-level PATH is updated for Task Scheduler,
# not only for Git Bash.
_uv_install() {
  _host="$(uname -s 2>/dev/null || echo unknown)"
  case "$_host" in
    MINGW*|MSYS*|CYGWIN*)
      _ps="$(command -v powershell.exe || command -v pwsh.exe || true)"
      [ -n "$_ps" ] || return 1
      "$_ps" -NoProfile -ExecutionPolicy Bypass -Command \
        "irm https://astral.sh/uv/install.ps1 | iex"
      ;;
    *)
      if command -v curl >/dev/null 2>&1; then
        curl -LsSf --retry 3 https://astral.sh/uv/install.sh | sh
      elif command -v wget >/dev/null 2>&1; then
        wget -qO- https://astral.sh/uv/install.sh | sh
      else
        return 1
      fi
      ;;
  esac
}

# Locate uv, installing it if needed. Idempotent: an existing copy (Homebrew,
# WinGet, a prior build) is left alone. On success, this process can `command -v
# uv` even if the user's terminal has not been restarted.
ensure_uv() {
  if _uv_ok; then
    ok "uv present ($(command -v uv))"
    return 0
  fi

  _uv_bindir_on_path "$HOME/.local/bin"
  _uv_bindir_on_path "$HOME/.cargo/bin"
  hash -r 2>/dev/null || true
  if _uv_ok; then
    ok "uv present ($(command -v uv))"
    return 0
  fi

  step "installing uv (one-time; a few seconds, needs the network)"
  if ! _uv_install; then
    die "could not install uv (needed to run the wiki pipeline).

       The build tried the official installer and it failed. This is usually a
       missing network connection. On macOS and Linux the installer needs curl or
       wget; on Windows it needs PowerShell. Check that this machine is online and
       re-run. If it still fails, escalate — do not ask the user to install a
       package manager."
  fi

  _uv_bindir_on_path "$HOME/.local/bin"
  _uv_bindir_on_path "$HOME/.cargo/bin"
  hash -r 2>/dev/null || true
  if _uv_ok; then
    ok "uv installed ($(command -v uv))"
    return 0
  fi

  die "uv was installed but this session still cannot find it.

       Open a new terminal and re-run the build. If it still fails, escalate —
       do not ask the user to install a package manager."
}
