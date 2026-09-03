"""Parsing tests for the Obsidian CLI wrapper.

`run()` is stubbed throughout, so these never shell out and never need a running
GUI -- which is exactly why the "=> " decoration bug survived: the one function
that would have caught it was the one nothing covered.
"""
import itertools
import json
import pathlib
import tempfile
import unittest
from unittest import mock

from wiki import config, obsidian


class EvalDecorationTests(unittest.TestCase):
    """The CLI prefixes a returned value with "=> " on the FIRST line only."""

    def _eval(self, stdout, code="x"):
        with mock.patch.object(obsidian, "run", return_value=stdout):
            return obsidian.eval_js(code)

    def test_single_value_prefix_is_stripped(self):
        self.assertEqual(self._eval("=> 122"), "122")

    def test_stripped_value_is_int_parseable(self):
        # The actual defect: int("=> 122") raised ValueError into a bare except,
        # so wait_until_ready could never report a warm cache.
        self.assertEqual(int(self._eval("=> 122")), 122)

    def test_only_the_first_line_is_touched(self):
        self.assertEqual(self._eval("=> a.md\nb.md\nc.md"), "a.md\nb.md\nc.md")

    def test_undecorated_output_is_untouched(self):
        self.assertEqual(self._eval("plain"), "plain")

    def test_arrow_inside_the_body_is_preserved(self):
        self.assertEqual(self._eval("=> x\ny => z"), "x\ny => z")

    def test_empty_output(self):
        self.assertEqual(self._eval(""), "")


class ReadinessTests(unittest.TestCase):
    def test_ready_when_count_is_stable(self):
        with mock.patch.object(obsidian, "run", return_value="=> 122"):
            self.assertTrue(obsidian.wait_until_ready(timeout=10, poll=0))

    def test_not_ready_while_count_moves(self):
        # Unbounded: with poll=0 the loop spins until the deadline, and a finite
        # list would raise StopIteration instead of testing what it means to.
        counts = itertools.count(1)
        with mock.patch.object(obsidian, "run",
                               side_effect=lambda *a, **k: "=> %d" % next(counts)):
            self.assertFalse(obsidian.wait_until_ready(timeout=0.05, poll=0))

    def test_zero_files_is_not_ready(self):
        # A cold cache reports 0 twice; stable-but-empty must not count as warm.
        with mock.patch.object(obsidian, "run", return_value="=> 0"):
            self.assertFalse(obsidian.wait_until_ready(timeout=0.05, poll=0))

    def test_transport_errors_are_retried_not_raised(self):
        with mock.patch.object(obsidian, "run",
                               side_effect=obsidian.ObsidianUnavailable("starting")):
            self.assertFalse(obsidian.wait_until_ready(timeout=0.05, poll=0))


class VaultMtimeTests(unittest.TestCase):
    def test_first_path_is_not_glued_to_the_prefix(self):
        with mock.patch.object(obsidian, "run", return_value="=> a.md|100\nb.md|200"):
            self.assertEqual(obsidian.vault_mtimes(), {"a.md": 100, "b.md": 200})


class WindowGateTests(unittest.TestCase):
    """No command may ever be sent to a vault whose window is closed.

    Obsidian's CLI dispatcher services every command by calling
    openVaultById(), so a command against a closed vault pops its window
    onto the user's desktop -- the exact defect the socket transport was
    meant to end.
    """

    def _registry(self, tmp, payload):
        state = tmp / "obsidian.json"
        state.write_text(json.dumps(payload), encoding="utf-8")
        return state

    def test_open_flag_present_means_open(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            state = self._registry(tmp, {"vaults": {
                "abc": {"path": str(config.VAULT), "open": True}}})
            with mock.patch.object(config, "OBSIDIAN_STATE_JSON", state):
                self.assertTrue(obsidian.vault_window_open())

    def test_no_open_flag_means_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            state = self._registry(tmp, {"vaults": {
                "abc": {"path": str(config.VAULT)}}})
            with mock.patch.object(config, "OBSIDIAN_STATE_JSON", state):
                self.assertFalse(obsidian.vault_window_open())

    def test_other_vault_open_does_not_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            state = self._registry(tmp, {"vaults": {
                "abc": {"path": str(tmp / "other-vault"), "open": True}}})
            with mock.patch.object(config, "OBSIDIAN_STATE_JSON", state):
                self.assertFalse(obsidian.vault_window_open())

    def test_missing_registry_means_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = pathlib.Path(tmp) / "does-not-exist.json"
            with mock.patch.object(config, "OBSIDIAN_STATE_JSON", state):
                self.assertFalse(obsidian.vault_window_open())

    def test_corrupt_registry_means_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            state = tmp / "obsidian.json"
            state.write_text("{not json", encoding="utf-8")
            with mock.patch.object(config, "OBSIDIAN_STATE_JSON", state):
                self.assertFalse(obsidian.vault_window_open())

    def test_run_refuses_when_window_closed(self):
        # The gate must sit inside run() itself, before any socket I/O.
        with mock.patch.object(obsidian, "vault_window_open", return_value=False):
            with self.assertRaises(obsidian.ObsidianUnavailable):
                obsidian.run("eval", "code=1")

    def test_installed_requires_window_open(self):
        with mock.patch.object(obsidian, "socket_present", return_value=True), \
             mock.patch.object(obsidian, "vault_window_open", return_value=False):
            self.assertFalse(obsidian.installed())
        with mock.patch.object(obsidian, "socket_present", return_value=True), \
             mock.patch.object(obsidian, "vault_window_open", return_value=True):
            self.assertTrue(obsidian.installed())


if __name__ == "__main__":
    unittest.main()
