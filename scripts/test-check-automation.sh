#!/usr/bin/env bash
# Weir — self-test for check-automation argument validation and run cleanup.
#
# Run from the repository root. The client and process lifetime are stubbed.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
python3 -I -B - "${REPO_ROOT}/scripts/check-automation.py" <<'PYTHON'
import contextlib
import importlib.util
import io
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("check_automation", sys.argv[1])
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class CheckAutomationTests(unittest.TestCase):
    def run_main(self, *arguments):
        with patch.object(sys, "argv", [spec.origin, *arguments]), contextlib.redirect_stdout(io.StringIO()):
            return check.main()

    def assert_invalid_before_run(self, arguments, *diagnostics):
        with contextlib.redirect_stderr(io.StringIO()) as stderr, \
                patch.object(check.client, "repository_root", side_effect=AssertionError("started preparing a run")) as root, \
                patch.object(check.client, "launch") as launch:
            with self.assertRaises(SystemExit) as failure:
                self.run_main(*arguments)
            self.assertEqual(failure.exception.code, 2)
            for diagnostic in diagnostics:
                self.assertIn(diagnostic, stderr.getvalue())
            root.assert_not_called()
            launch.assert_not_called()

    def test_invalid_selection_stops_before_preparing_a_run(self):
        cases = [
            ("unknown", "unknown"),
            ("connection,unknown", "unknown"),
            ("", "unavailable sections ''"),
            ("connection,", "unavailable sections ''"),
            ("person_drafts", "person_drafts"),
            ("agents", "agents"),
        ]
        for selection, diagnostic in cases:
            with self.subTest(selection=selection):
                self.assert_invalid_before_run(("--only", selection), "--only: unavailable sections", diagnostic)

    def test_empty_agent_names_stop_before_preparing_a_run(self):
        for arguments in [("--agents", ""), ("--agents", "", "--only", "agents"), ("--agents", "claude,,codex")]:
            with self.subTest(arguments=arguments):
                self.assert_invalid_before_run(arguments, "--agents: no agent named ''")

    def stub_run(self, directory, stack):
        metadata = {"pid": 43210, "folder": "stub"}
        run = types.SimpleNamespace(
            until=lambda condition, seconds: condition(),
            panes=lambda: [{"foregroundProcess": "zsh"}],
        )
        stack.enter_context(patch.object(check.client, "repository_root", return_value=directory))
        launch = stack.enter_context(patch.object(check.client, "launch", return_value=metadata))
        stack.enter_context(patch.object(check.client, "find_run", return_value=metadata))
        stack.enter_context(patch.object(check, "Run", return_value=run))
        return launch, run

    def test_valid_selection_runs_in_script_order(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.ExitStack() as stack:
            launch, run = self.stub_run(directory, stack)
            called = []

            def record_section(name):
                def section(run, checks):
                    called.append(name)
                section.__name__ = name
                return section

            order = ["connection", "captures", "typing", "agents", "held_paste"]
            for name in order:
                stack.enter_context(patch.object(check, name, record_section(name)))
            stack.enter_context(patch.object(check, "quitting"))
            status = self.run_main("--keys", "--agents", "codex", "--only", ",".join(reversed(order)), "--keep")
            self.assertEqual(status, 0)
            self.assertEqual(called, order)
            self.assertEqual(run.agents, ["codex"])
            launch.assert_called_once()

    def check_failed_run_cleanup(self, *, exits, reports_pid):
        with tempfile.TemporaryDirectory() as directory, contextlib.ExitStack() as stack:
            launch, _ = self.stub_run(directory, stack)
            clock = 0
            home = None
            signaled = False
            ended = False
            pid = 43210

            def start(app, run_home):
                nonlocal home
                home = Path(run_home)
                if reports_pid:
                    return {"folder": "stub", "pid": pid}
                (home / "Owned.app").mkdir()
                (home / "scratch" / "Nested.app").mkdir()
                outside = Path(directory) / "Outside.app"
                outside.mkdir()
                (home / "Linked.app").symlink_to(outside)
                raise check.ChannelError("launch did not answer")

            def signal_process(actual_pid, sig):
                nonlocal signaled
                self.assertEqual(actual_pid, pid)
                self.assertEqual(sig, signal.SIGTERM)
                self.assertTrue(home.is_dir())
                signaled = True

            def is_running(actual_pid):
                self.assertEqual(actual_pid, pid)
                if not ended:
                    self.assertTrue(home.is_dir())
                return not ended

            def advance(seconds):
                nonlocal clock, ended
                clock += seconds
                if exits and signaled:
                    ended = True

            def forget_home(path):
                self.assertTrue(ended)
                self.assertEqual(Path(path), home)
                self.assertTrue(home.is_dir())

            def connection(run, checks):
                raise ValueError("section failed")

            launch.side_effect = start
            stack.enter_context(patch.object(check, "connection", connection))
            stack.enter_context(patch.object(check, "quitting"))
            force_quit = stack.enter_context(patch.object(check.client, "quit_run"))
            if exits:
                force_quit.side_effect = check.ChannelError("channel closed")
            else:
                force_quit.return_value = {"status": "failed", "reason": "quit refused"}
            copies = stack.enter_context(patch.object(check.client, "copy_processes", return_value=[pid]))
            stack.enter_context(patch.object(check.client, "is_running", side_effect=is_running))
            stack.enter_context(patch.object(check.client, "running_copy", side_effect=lambda _: str(home / "Owned.app")))
            forgot = stack.enter_context(patch.object(check.client, "forget_home", side_effect=forget_home))
            stack.enter_context(patch.object(check.os, "kill", side_effect=signal_process))
            stack.enter_context(patch.object(check.time, "monotonic", side_effect=lambda: clock))
            stack.enter_context(patch.object(check.time, "sleep", side_effect=advance))

            if exits:
                self.assertEqual(self.run_main("--only", "connection"), 1)
                forgot.assert_called_once()
                self.assertFalse(home.exists())
            else:
                with self.assertRaisesRegex(check.ChannelError, "did not exit after SIGTERM") as failure:
                    self.run_main("--only", "connection")
                self.assertIn(str(home), str(failure.exception))
                forgot.assert_not_called()
                self.assertTrue(home.is_dir())
                self.assertGreaterEqual(clock, 5)
                self.assertLess(clock, 5.3)
            self.assertTrue(signaled)
            if reports_pid:
                force_quit.assert_called_once_with({"folder": "stub", "pid": pid}, force=True)
                copies.assert_not_called()
            else:
                force_quit.assert_not_called()
                copies.assert_called_once_with(str(home.resolve() / "Owned.app"))

    def test_failed_quit_removes_the_home_only_after_exit(self):
        self.check_failed_run_cleanup(exits=True, reports_pid=True)

    def test_failed_quit_keeps_the_home_while_the_process_is_alive(self):
        self.check_failed_run_cleanup(exits=False, reports_pid=True)

    def test_launch_timeout_only_checks_the_owned_copy_and_keeps_its_home(self):
        self.check_failed_run_cleanup(exits=False, reports_pid=False)

    def test_unavailable_process_listing_keeps_the_home(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.ExitStack() as stack:
            launch, _ = self.stub_run(directory, stack)
            def start(app, home):
                (Path(home) / "Owned.app").mkdir()
                raise check.ChannelError("launch did not answer")

            launch.side_effect = start
            stack.enter_context(patch.object(check.client, "copy_processes", side_effect=subprocess.CalledProcessError(1, "ps")))
            forgot = stack.enter_context(patch.object(check.client, "forget_home"))
            with self.assertRaisesRegex(check.ChannelError, "could not confirm the run exited"):
                self.run_main("--only", "connection")
            home = Path(launch.call_args.args[1])
            self.assertTrue(home.is_dir())
            forgot.assert_not_called()

    def test_a_pid_outside_this_home_is_never_signaled(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.ExitStack() as stack:
            launch, _ = self.stub_run(directory, stack)
            stack.enter_context(patch.object(check, "quitting"))
            stack.enter_context(patch.object(check.client, "quit_run", return_value={"status": "failed"}))
            stack.enter_context(patch.object(check.client, "is_running", return_value=True))
            stack.enter_context(patch.object(check.client, "running_copy", return_value=f"{directory}/Other.app"))
            forgot = stack.enter_context(patch.object(check.client, "forget_home"))
            sent_signal = stack.enter_context(patch.object(check.os, "kill"))
            with self.assertRaisesRegex(check.ChannelError, "could not identify process"):
                self.run_main("--only", "state")
            self.assertTrue(Path(launch.call_args.args[1]).is_dir())
            forgot.assert_not_called()
            sent_signal.assert_not_called()


unittest.main(argv=[sys.argv[0]])
PYTHON
