#!/usr/bin/env python3
"""Drives a Debug run of Weir through its verification channel (ADR 0005).

Usage: scripts/weir-automation.py [--run SHORT_ID] COMMAND ...

  launch [--app PATH] [--home DIR]        start a run of this checkout's Debug build and print it as JSON
  quit [--force]                          end the run (force: even while agents run in it)
  state                                   print windows, tabs, and panes
  open LAYER [--window ID] [--pane ID]    open a layer (review needs --pane)
  focus PANE                              give PANE the keyboard, where keys from outside land
  type-line PANE TEXT --expect PROCESS [--session S] [--no-submit]
  paste PANE TEXT --expect PROCESS [--session S]
  submit PANE --expect PROCESS [--session S]
  wait layerOpen --layer LAYER [--window ID] [--timeout SECONDS]
  wait turnEnded --pane PANE [--timeout SECONDS]
  capture OUT.png [--window ID]           capture one window, Weir left behind
  commands [--window ID]                  list the command palette's rows and whether each can run
  command NAME [--window ID]              run a row (shortcut.splitRight, or splitRight)
  setting KEY [VALUE] [--unset]           read a setting, set it to VALUE (JSON: '"Menlo"', 14, true), or clear it

With several runs live, --run names the one to drive (the short ID `launch`
prints). A pane is named by its UUID, or a unique prefix of it; the run and
the generation it needs are read from `state` first, so a pane whose terminal
was made again since is refused by the app rather than typed into.

`scripts/check-automation.py` imports this file for its connection and launch
code, so the functions below raise `ChannelError` rather than exit; only
`main` turns an error into an exit status.
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import uuid

PROTOCOL = "weir-automation-protocol/1"

# Variables a coding agent's shell sets that must not reach the run's panes.
# Those of Claude Code turn off the title and the transcript saving in a
# Claude started there, which makes Weir's agent features look broken. `open` hands
# the app this process's environment, so they are taken out before it runs.
INHERITED_AGENT_VARIABLES = ("CLAUDECODE", "CLAUDE_CODE_")

class ChannelError(Exception):
    """Anything that stops a request: no run, a refused hello, a closed socket."""


def temporary_directory():
    """The per-user temporary folder the app's `$TMPDIR` names.

    A shell without TMPDIR set would fall back to /tmp and find nothing.
    65537 is _CS_DARWIN_USER_TEMP_DIR, which Python has no name for.
    """
    try:
        return os.confstr(65537) or tempfile.gettempdir()
    except (ValueError, OSError):
        return tempfile.gettempdir()


def runs_folder():
    return os.path.join(temporary_directory(), "wa")


def is_running(pid):
    """Whether `pid` is a process that has not exited.

    A run this process launched stays a zombie after it exits until we reap
    it, and `kill(pid, 0)` still succeeds on a zombie, so a child of ours is
    reaped here first, and anyone else's run is asked with `kill` alone.
    """
    try:
        reaped, _ = os.waitpid(pid, os.WNOHANG)
        if reaped == pid:
            return False
    except ChildProcessError:
        pass
    try:
        os.kill(pid, 0)
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def live_runs():
    """Every run folder whose app is still running, as (folder, info)."""
    base = runs_folder()
    runs = []
    for name in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        folder = os.path.join(base, name)
        try:
            with open(os.path.join(folder, "info.json")) as f:
                info = json.load(f)
            if not is_running(info["pid"]):
                continue
        except (OSError, ValueError, KeyError, TypeError):
            # A folder a run is still making, or one whose app is gone; the
            # next launch removes the second kind.
            continue
        info["folder"] = name
        runs.append(info)
    return runs


def find_run(short_id=None):
    """The one live run, or the one `short_id` names, with its token."""
    runs = [run for run in live_runs() if short_id in (None, run["folder"])]
    if not runs:
        raise ChannelError("no running Weir with WEIR_AUTOMATION=1 was found under " + runs_folder())
    if len(runs) > 1:
        # Other sessions may drive their own runs; picking one would type
        # into an app this caller did not start.
        names = ", ".join(run["folder"] for run in runs)
        raise ChannelError(f"several runs are live ({names}); name one with --run")
    run = runs[0]
    try:
        with open(os.path.join(runs_folder(), run["folder"], "token")) as f:
            run["token"] = f.read().strip()
    except OSError as error:
        raise ChannelError(f"could not read the run's token: {error}") from error
    return run


class Channel:
    """One authenticated connection to a run. Requests are answered in order.

    Usable as a context manager, which closes it on the way out. Every failure
    of the connection is raised as `ChannelError`, so a caller catches one
    kind of error.
    """

    def __init__(self, run, timeout=60):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.reader = None
        # Past the channel's own 30-second wait, so a reply that never comes
        # (an app stuck on its main thread) ends this call rather than hanging the
        # caller's shell.
        self.sock.settimeout(timeout)
        try:
            self.sock.connect(run["socket"])
            self.reader = self.sock.makefile("r")
            self.next_id = 0
            reply = self.call({"op": "hello", "token": run["token"], "protocol": PROTOCOL})
            if reply["status"] != "done":
                raise ChannelError("hello refused: " + reply.get("reason", ""))
        except OSError as error:
            self.close()
            raise ChannelError(f"could not connect to {run['socket']}: {error}") from error
        except ChannelError:
            self.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def call(self, request):
        """Sends one request and returns its reply; `None` values are left out."""
        self.next_id += 1
        request = {k: v for k, v in dict(request, id=str(self.next_id)).items() if v is not None}
        try:
            self.sock.sendall((json.dumps(request) + "\n").encode())
            line = self.reader.readline()
        except socket.timeout as error:
            raise ChannelError("the app did not answer in time") from error
        except OSError as error:
            raise ChannelError(f"the connection failed: {error}") from error
        if not line:
            raise ChannelError("the channel closed the connection")
        reply = json.loads(line)
        if not reply.get("id"):
            raise ChannelError("the request was refused: " + reply.get("reason", ""))
        if reply["id"] != request["id"]:
            raise ChannelError(f"a reply to request {reply['id']} arrived for request {request['id']}")
        return reply

    def close(self):
        # The file object holds the descriptor too; both go, or the app keeps
        # counting this connection against its limit.
        if self.reader:
            self.reader.close()
        self.sock.close()


def resolve_pane(channel, prefix):
    """The identity triple of the one pane whose UUID starts with `prefix`."""
    state = channel.call({"op": "state"})["state"]
    # A scratch pane shows in every window that selects scratch, so the same
    # pane can be listed more than once; it is still one pane.
    matches = {
        (pane["ref"]["run"], pane["ref"]["id"], pane["ref"]["generation"]): pane["ref"]
        for window in state["windows"]
        for tab in window["tabs"]
        for pane in tab["panes"]
        if pane["ref"]["id"].lower().startswith(prefix.lower())
    }
    if len(matches) != 1:
        raise ChannelError(f"{len(matches)} panes match {prefix}")
    return next(iter(matches.values()))


# MARK: - launching and quitting


def repository_root():
    return subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
    ).stdout.strip()


def debug_app_path(root):
    """This checkout's Debug build, from xcodebuild as `make run` finds it."""
    settings = subprocess.run(
        ["xcodebuild", "-project", "Weir.xcodeproj", "-scheme", "Weir", "-configuration", "Debug", "-showBuildSettings"],
        capture_output=True, text=True, cwd=root, check=True,
    ).stdout
    # The last of each, as the Makefile's awk reads them: the scheme prints the
    # app's settings after those of the tools it embeds.
    values = {}
    for line in settings.splitlines():
        key, separator, value = line.partition(" = ")
        if separator and key.strip() in ("BUILT_PRODUCTS_DIR", "FULL_PRODUCT_NAME"):
            values[key.strip()] = value.strip()
    return os.path.join(values["BUILT_PRODUCTS_DIR"], values["FULL_PRODUCT_NAME"])


def launch(app=None, home=None, wait=30):
    """Starts a run with the channel on and its own data, and returns it.

    The run gets `CFFIXED_USER_HOME` pointed at `home` (by default
    `build/automation-home` in this checkout, which git ignores), so it never
    reads or writes the person's `Weir Dev` session.

    It is started with `open -g -n`: `-g` keeps it behind the person's windows
    (an app started by its executable comes to the front), and `-n` makes it a
    run of its own even while another Weir Dev is open. A nonce passed in its
    environment comes back in its `info.json`, which is how this call tells
    its own run from one that another caller started at the same moment. It is
    returned once it has answered hello, not when its folder appears: the
    folder is written before the socket listens. A run that never answers is
    ended here rather than left behind.
    """
    root = repository_root()
    app = os.path.abspath(app or debug_app_path(root))
    if not os.path.isdir(app):
        raise ChannelError(f"no build at {app}; run make build first")
    home = os.path.abspath(home or os.path.join(root, "build", "automation-home"))
    os.makedirs(home, exist_ok=True)
    log = os.path.join(home, "weir.log")
    nonce = uuid.uuid4().hex
    environment = {key: value for key, value in os.environ.items() if not key.startswith(INHERITED_AGENT_VARIABLES)}
    subprocess.run(
        ["open", "-g", "-n", "-a", app,
         "--env", "WEIR_AUTOMATION=1", "--env", f"CFFIXED_USER_HOME={home}", "--env", f"WEIR_AUTOMATION_NONCE={nonce}",
         "--stdout", log, "--stderr", log],
        env=environment, check=True,
    )
    deadline = time.time() + wait
    run = None
    while time.time() < deadline:
        run = run or next((r for r in live_runs() if r.get("nonce") == nonce), None)
        if run:
            try:
                with Channel(find_run(run["folder"]), timeout=5):
                    return dict(run, home=home, log=log)
            except ChannelError:
                pass
        time.sleep(0.2)
    if run:
        os.kill(run["pid"], 15)
    raise ChannelError(f"the run did not answer within {wait} seconds; see {log}")


def quit_run(run, force=False, wait=15):
    """Ends `run` through the channel and waits for its process to exit."""
    with Channel(run) as channel:
        reply = channel.call({"op": "quit", "force": force})
    if reply["status"] != "done":
        return reply
    deadline = time.time() + wait
    while time.time() < deadline:
        if not is_running(run["pid"]):
            return reply
        time.sleep(0.2)
    raise ChannelError(f"the app did not exit within {wait} seconds")


# MARK: - command line


def build_request(args, channel):
    """The request for one command line, resolving pane prefixes first."""
    if args.command == "state":
        return {"op": "state"}
    if args.command == "open":
        pane = resolve_pane(channel, args.pane) if args.pane else None
        return {"op": "open", "layer": args.layer, "window": args.window, "pane": pane}
    if args.command in ("type-line", "paste", "submit"):
        request = {
            "op": {"type-line": "typeLine", "paste": "paste", "submit": "submit"}[args.command],
            "pane": resolve_pane(channel, args.pane),
            "text": getattr(args, "text", ""),
            "expect": {"process": args.expect, "session": args.session},
        }
        if args.command == "type-line":
            request["submit"] = not args.no_submit
        return request
    if args.command == "wait":
        pane = resolve_pane(channel, args.pane) if args.pane else None
        return {"op": "wait", "until": args.until, "layer": args.layer, "window": args.window,
                "pane": pane, "timeout": args.timeout}
    if args.command == "focus":
        return {"op": "focus", "pane": resolve_pane(channel, args.pane)}
    if args.command == "commands":
        return {"op": "commands", "window": args.window}
    if args.command == "command":
        return {"op": "command", "name": args.name, "window": args.window}
    if args.command == "setting":
        request = {"op": "setting", "key": args.key, "unset": True if args.unset else None}
        if args.value is not None:
            try:
                request["value"] = json.loads(args.value)
            except ValueError as error:
                raise ChannelError("VALUE is JSON: a string needs its quotes, as '\"Menlo\"'") from error
        return request
    raise ChannelError(f"unknown command {args.command}")


def parse_arguments():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("launch")
    p.add_argument("--app")
    p.add_argument("--home")
    p = sub.add_parser("quit")
    p.add_argument("--force", action="store_true")
    sub.add_parser("state")
    p = sub.add_parser("open")
    p.add_argument("layer")
    p.add_argument("--window")
    p.add_argument("--pane")
    for name in ("type-line", "paste", "submit"):
        p = sub.add_parser(name)
        p.add_argument("pane")
        if name != "submit":
            p.add_argument("text")
        p.add_argument("--expect", required=True)
        p.add_argument("--session")
        if name == "type-line":
            p.add_argument("--no-submit", action="store_true")
    p = sub.add_parser("wait")
    p.add_argument("until", choices=["layerOpen", "turnEnded"])
    p.add_argument("--layer")
    p.add_argument("--window")
    p.add_argument("--pane")
    p.add_argument("--timeout", type=float, default=10, help="seconds, at most 30")
    p = sub.add_parser("capture")
    p.add_argument("out")
    p.add_argument("--window")
    p = sub.add_parser("focus")
    p.add_argument("pane")
    p = sub.add_parser("commands")
    p.add_argument("--window")
    p = sub.add_parser("command")
    p.add_argument("name")
    p.add_argument("--window")
    p = sub.add_parser("setting")
    p.add_argument("key")
    p.add_argument("value", nargs="?")
    p.add_argument("--unset", action="store_true", help="clear an optional setting")
    return parser.parse_args()


def print_json(value):
    print(json.dumps(value, indent=2, ensure_ascii=False))


def main():
    args = parse_arguments()
    try:
        if args.command == "launch":
            print_json(launch(args.app, args.home))
            return 0
        run = find_run(args.run)
        if args.command == "quit":
            reply = quit_run(run, args.force)
            print_json(reply)
            return 0 if reply["status"] == "done" else 1
        with Channel(run) as channel:
            if args.command == "capture":
                reply = channel.call({"op": "capture", "window": args.window})
                if reply["status"] != "done":
                    print_json(reply)
                    return 1
                subprocess.run(["screencapture", "-x", "-o", f"-l{reply['windowNumber']}", args.out], check=True)
                print(args.out)
                return 0
            reply = channel.call(build_request(args, channel))
        print_json(reply)
        return 0 if reply["status"] == "done" else 1
    except ChannelError as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
