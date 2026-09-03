"""Obsidian CLI wrapper.

Speaks directly to the running Obsidian app over its CLI unix socket
(~/.obsidian-cli.sock) instead of spawning the `obsidian` binary. The binary is
a second Electron instance of Obsidian.app: on macOS every invocation registers
as an app launch, which activates the "Obsidian" bundle and yanks the GUI
window to the front -- and when the app is NOT running, the binary boots the
full GUI itself. Both are unacceptable from a 15-minute LaunchAgent. The socket
does neither: if Obsidian is running it answers silently, and if it isn't the
connect fails and callers fall back (the cloud tagger never has it either).

The wire protocol is the binary's own: one JSON header line
`{"argv": [...], "tty": false, "cwd": "..."}`, then the response streamed back
until the server closes the connection.

Rules encoded here rather than left to callers, because they fail silently:
  * No command is ever sent unless the target vault's window is ALREADY open
    (checked against Obsidian's own registry, obsidian.json). The app's CLI
    dispatcher services every command -- even a read-only eval -- by calling
    openVaultById(), so commanding a closed vault pops its window onto the
    user's desktop. Window closed means ObsidianUnavailable; callers fall
    back to disk exactly as they do when the app is not running.
  * `vault=<name>` is always the FIRST argv entry. Without it commands target
    the most-recently-focused vault.
  * `open` / `newtab` are never passed. There is no `silent` flag; nothing
    opens unless you ask it to.
  * `eval` output is decorated with "=> " on the FIRST line. Stripped centrally
    in eval_js, because every caller got it wrong independently.
  * The server always closes cleanly, even for failures -- errors are only
    distinguishable by their text ("Error: ...", "Vault not found.", the
    CLI-disabled notice). run() turns those into ObsidianUnavailable.
"""
from __future__ import annotations

import json
import re
import socket
import time
from pathlib import Path
from typing import List, Optional

from . import config


class ObsidianUnavailable(RuntimeError):
    pass


#: Responses the app returns on a clean connection that nonetheless mean the
#: command did not run. "Error: " prefixes renderer-side failures; the other
#: two come from the main-process dispatcher.
_ERROR_SENTINELS = ("Error: ", "Vault not found.",
                    "Command line interface is not enabled")


def socket_present() -> bool:
    """True when the CLI socket exists, i.e. Obsidian is (or was) running.

    A stale socket from a crashed app is possible; run() resolves that by
    failing to connect, so callers still degrade correctly.
    """
    return config.OBSIDIAN_SOCKET.exists()


def vault_window_open() -> bool:
    """True when the target vault has an open window in the running app.

    Read from Obsidian's vault registry (obsidian.json), which marks vaults
    with an open window `"open": true` and drops the flag when the window
    closes. Vaults are matched by resolved path, not name -- the registry
    stores paths. On any doubt (registry missing, unreadable, vault absent)
    report closed: the cost of a wrong False is one run of disk fallbacks,
    the cost of a wrong True is a GUI window popping up unbidden.
    """
    try:
        data = json.loads(
            config.OBSIDIAN_STATE_JSON.read_text(encoding="utf-8"))
        target = Path(config.VAULT).resolve()
        for info in (data.get("vaults") or {}).values():
            if isinstance(info, dict) and info.get("open") \
                    and Path(info.get("path", "")).resolve() == target:
                return True
    except (OSError, ValueError):
        pass
    return False


def installed() -> bool:
    """True when it is SAFE to send commands: socket up AND window open."""
    return socket_present() and vault_window_open()


def run(*params: str, timeout: Optional[int] = None) -> str:
    """Run one CLI command over the socket. vault= is injected first."""
    if not vault_window_open():
        raise ObsidianUnavailable(
            "obsidian %s: vault '%s' has no open window -- refusing to send "
            "(the CLI dispatcher would open one on the user's desktop)"
            % (" ".join(params), config.VAULT_NAME)
        )
    argv = ["vault=%s" % config.VAULT_NAME] + list(params)
    header = json.dumps({"argv": argv, "tty": False,
                         "cwd": str(config.VAULT)}) + "\n"
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout or config.OBSIDIAN_CMD_TIMEOUT)
    try:
        sock.connect(str(config.OBSIDIAN_SOCKET))
        sock.sendall(header.encode("utf-8"))
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    except OSError as exc:
        raise ObsidianUnavailable(
            "obsidian %s: no reply on %s (%s) -- is Obsidian running?"
            % (" ".join(params), config.OBSIDIAN_SOCKET, exc)
        )
    finally:
        sock.close()
    out = b"".join(chunks).decode("utf-8", "replace").strip()
    if out.startswith(_ERROR_SENTINELS):
        raise ObsidianUnavailable(
            "obsidian %s failed: %s" % (" ".join(params), out[:400]))
    return out


#: The CLI prefixes a returned value with "=> ", on the first line only:
#:   'app.vault.getMarkdownFiles().length'        -> '=> 122\n'
#:   '...map(f=>f.path).join("\n")'               -> '=> a.md\nb.md\nc.md\n'
_EVAL_DECORATION = re.compile(r"\A=>[ \t]?")


def eval_js(code: str, timeout: Optional[int] = None) -> str:
    """Execute JS inside the Obsidian process, with the CLI's decoration removed.

    Passed via subprocess argv, so there is no shell quoting to get wrong -- only
    the JS string literals inside `code`, which callers build with json.dumps.

    Stripping here rather than in callers is deliberate. Every caller previously
    parsed around the prefix and every one of them was wrong: `int("=> 122")`
    raised ValueError into a bare `except` so readiness never reported warm, and
    the first path of any multi-line result came back with "=> " glued to it.
    One decoration, one place that knows about it.
    """
    return _EVAL_DECORATION.sub("", run("eval", "code=%s" % code, timeout=timeout))


def available() -> bool:
    # eval of a literal is the cheapest command that exercises the whole
    # dispatch path (socket -> vault window -> renderer handler). The old
    # probe, `vault info=name`, is not a real command in current Obsidian
    # builds and only ever "worked" because errors used to come back on
    # stdout with exit code 0.
    try:
        return eval_js("1", timeout=10) == "1"
    except Exception:
        return False


def wait_until_ready(timeout: Optional[int] = None, poll: float = 2.0) -> bool:
    """Wait for a RUNNING Obsidian to warm up.

    This no longer launches the app (the socket transport can't, by design --
    that launch is what kept stealing window focus). It waits out the gap
    between the app starting and being ready: plugins and metadataCache still
    need to load, and a cold command can succeed while returning incomplete
    data. So poll until the markdown file count stops moving. Modal dialogs
    block the app rather than erroring, which is why this has a hard timeout.
    """
    deadline = time.time() + (timeout or config.OBSIDIAN_READY_TIMEOUT)
    previous = None
    while time.time() < deadline:
        try:
            raw = eval_js("app.vault.getMarkdownFiles().length", timeout=15)
            count = int(raw.strip())
            if count > 0 and count == previous:
                return True
            previous = count
        # Narrow, not bare: "app is still starting" is expected and retried, but a
        # parse failure is a real defect and must not be swallowed the way the
        # "=> " prefix was for the life of this function.
        except ObsidianUnavailable:
            pass
        time.sleep(poll)
    return False


def tag_counts() -> dict:
    """The tag vocabulary, with frequency (spec sec.5).

    Frequency is the quality signal used when no tags.md is declared: count 1 is probably
    drift, count 40 is canon.
    """
    raw = run("tags", "counts", "format=json")
    data = json.loads(raw)
    if isinstance(data, dict):
        return {str(k): int(v) for k, v in data.items()}
    out = {}
    for item in data:
        if isinstance(item, dict):
            name = item.get("tag") or item.get("name")
            if name:
                out[str(name)] = int(item.get("count") or item.get("total") or 0)
    return out


def open_file_paths() -> List[str]:
    """Files currently open in tabs.

    Used to skip writing to a file with unsaved changes (spec sec.9).
    Best-effort: returns [] if the shape is unrecognised, and the caller treats
    an empty list as "nothing to avoid".
    """
    try:
        raw = eval_js(
            "app.workspace.getLeavesOfType('markdown')"
            ".map(l => l.view && l.view.file && l.view.file.path).filter(Boolean).join('\\n')"
        )
    except Exception:
        return []
    return [line.strip() for line in raw.splitlines() if line.strip()]


def vault_mtimes() -> dict:
    """path -> mtime (ms) for every markdown file, in one call.

    The local enumeration step (spec sec.4 step 1). Note Obsidian reports mtime in
    milliseconds while the filesystem walker uses nanoseconds, so these are not
    interchangeable -- the pipeline uses the filesystem walk as its source of
    truth and keeps this for diagnostics and the doctor check.
    """
    raw = eval_js("app.vault.getMarkdownFiles().map(f=>f.path+'|'+f.stat.mtime).join('\\n')")
    out = {}
    for line in raw.splitlines():
        if "|" in line:
            path, _, mtime = line.rpartition("|")
            try:
                out[path] = int(mtime)
            except ValueError:
                continue
    return out
