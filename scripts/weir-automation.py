#!/usr/bin/env python3
"""Drives a Debug run of Weir through its verification channel (ADR 0005).

Usage: scripts/weir-automation.py [--run SHORT_ID] COMMAND ...

  launch [--app PATH] [--home DIR] [--project FOLDER ...] [--demo [--layer L] [--appearance dark] [--language ja]]
                                          start a run of this checkout's Debug build and print it as JSON;
                                          --project opens each folder in it as a project, --demo shows the
                                          demo's projects (and --layer one of its layers) instead
  quit [--force]                          end the run (force: even while agents run in it)
  state                                   print windows, tabs, and panes
  open LAYER [--window ID] [--pane ID]    open a layer (review needs --pane)
  focus PANE                              give PANE the keyboard, where keys from outside land
  type-line PANE TEXT --expect PROCESS [--session S] [--no-submit]
  paste PANE TEXT --expect PROCESS [--session S]
  submit PANE --expect PROCESS [--session S]
  wait layerOpen --layer LAYER [--window ID] [--timeout SECONDS]
  wait turnEnded --pane PANE [--timeout SECONDS]
  capture OUT.png [--window ID | --settings]
                                          capture one window (or Settings), Weir left behind
  commands [--window ID]                  list the command palette's rows and whether each can run
  command NAME [--window ID] [--new-window]
                                          run a row (shortcut.splitRight, or splitRight); --new-window
                                          commits it as ⌘Return does
  setting KEY [VALUE] [--unset]           read a setting, set it to VALUE (JSON: '"Menlo"', 14, true), or clear it
  keys KEY ... [--window ID]              post named keys (escape, down, return, cmd+return) to the run, only
                                          while it shows one window and one of Weir's own controls there holds
                                          the keyboard (ADR 0006); needs the Accessibility grant for this terminal

With several runs live, --run names the one to drive (the short ID `launch`
prints). A pane is named by its UUID, or a unique prefix of it; the run and
the generation it needs are read from `state` first, so a pane whose terminal
was made again since is refused by the app rather than typed into.

`scripts/check-automation.py` imports this file for its connection and launch
code, so the functions below raise `ChannelError` rather than exit; only
`main` turns an error into an exit status.
"""

import argparse
import hashlib
import json
import os
import shutil
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


# MARK: - posted keys (ADR 0006)

# The keys `keys` posts, by name, as macOS key codes. Named keys only: each
# has one code on every keyboard layout and types no text (no space), so
# neither the layout nor an input method changes what arrives. Text goes
# through `typeLine` and `paste`.
KEY_CODES = {
    "return": 36, "enter": 76, "tab": 48, "delete": 51, "forwarddelete": 117, "escape": 53,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
}
MODIFIER_FLAGS = {"cmd": 0x100000, "shift": 0x20000, "option": 0x80000, "ctrl": 0x40000}

# The marker the app tells a posted key by (`AutomationPostedKeys.marker`),
# "WEIRKEYS": a key that carries it is dropped unless one of Weir's own
# controls in a project window is where it lands.
POSTED_KEY_MARKER = 0x5745_4952_4B45_5953

# One key down and up, posted to a process: PID CODE FLAGS MARKER [TEXT]. A
# marker of 0 leaves the key unmarked, as a person's is, which only
# `check-automation.py` posts, to stand in for the person's own typing; TEXT
# is then the character the key types.
POST_KEY_SWIFT = r"""
import AppKit
import CoreGraphics
let args = CommandLine.arguments
guard args.count >= 5, let pid = Int32(args[1]), let code = UInt16(args[2]), let flags = UInt64(args[3]),
      let marker = Int64(args[4]) else { exit(1) }
guard AXIsProcessTrusted() else { print("not trusted"); exit(2) }
let source = CGEventSource(stateID: .hidSystemState)
for down in [true, false] {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { exit(3) }
    event.flags = CGEventFlags(rawValue: flags)
    if marker != 0 {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }
    if args.count > 5 {
        var unit = Array(args[5].utf16)
        event.keyboardSetUnicodeString(stringLength: unit.count, unicodeString: &unit)
    }
    event.postToPid(pid)
    usleep(20_000)
}
"""


def parse_key(name):
    """`cmd+return` as its key code and modifier flags."""
    *modifiers, key = name.lower().split("+")
    if key not in KEY_CODES:
        raise ChannelError(f"no key named {key!r}; keys are {', '.join(KEY_CODES)}, with {'+'.join(MODIFIER_FLAGS)}+ before one")
    flags = 0
    for modifier in modifiers:
        if modifier not in MODIFIER_FLAGS:
            raise ChannelError(f"no modifier named {modifier!r}; modifiers are {', '.join(MODIFIER_FLAGS)}")
        flags |= MODIFIER_FLAGS[modifier]
    return KEY_CODES[key], flags


def key_poster(root):
    """The helper that posts one key, built once per version of its source."""
    digest = hashlib.sha256(POST_KEY_SWIFT.encode()).hexdigest()[:12]
    folder = os.path.join(root, "build", "automation-keys")
    binary = os.path.join(folder, f"post-key-{digest}")
    if not os.path.exists(binary):
        os.makedirs(folder, exist_ok=True)
        # Built under names of this call's own and moved into place whole, so
        # two first runs at once never read each other's half-written files.
        work = tempfile.mkdtemp(dir=folder)
        source = os.path.join(work, "post-key.swift")
        with open(source, "w") as f:
            f.write(POST_KEY_SWIFT)
        try:
            built = subprocess.run(["swiftc", "-O", source, "-o", os.path.join(work, "post-key")],
                                   capture_output=True, text=True, timeout=300)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ChannelError(f"could not build the key poster: {error}") from error
        if built.returncode != 0:
            raise ChannelError("could not build the key poster: " + built.stderr)
        os.replace(os.path.join(work, "post-key"), binary)
        shutil.rmtree(work, ignore_errors=True)
    return binary


def post_key(pid, code, flags=0, marked=True, text=None):
    """Posts one key down and up to `pid`, marked as the client's unless
    `marked` is false."""
    command = [key_poster(repository_root()), str(pid), str(code), str(flags), str(POSTED_KEY_MARKER if marked else 0)]
    if text is not None:
        command.append(text)
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ChannelError(f"could not post the key: {error}") from error
    if done.returncode == 2:
        raise ChannelError("this terminal needs the Accessibility grant to post keys (System Settings > Privacy & Security > Accessibility)")
    if done.returncode != 0:
        raise ChannelError(f"could not post the key: {done.stdout}{done.stderr}")


def keyboard_window(channel):
    """The one window a posted key can reach, as `state` reads it now, or why
    there is none to name. While the run is behind the person's windows it has
    no key window it can report (`NSApp.keyWindow` is nil), yet a posted key
    still lands in one of its windows; with one project window shown and
    Settings closed, that is the only place it can land."""
    snapshot = channel.call({"op": "state"})["state"]
    if snapshot.get("settings"):
        return None, "Settings is open, and a key could land there; close it first"
    shown = [w for w in snapshot["windows"] if w["isOnScreen"]]
    if len(shown) != 1:
        return None, f"the run shows {len(shown)} windows, and a key could land in any of them; keys need exactly one"
    return shown[0], None


def post_keys(run, channel, names, window_id=None):
    """Posts each key in turn, reading `state` before each one. The run must
    show one window (`window_id`, when given), and one of Weir's own controls
    must hold its keyboard, never a terminal pane, where Return runs code
    (ADR 0006). The app checks the same again as each key arrives
    (`AutomationPostedKeys.mayDeliver`), since the keyboard can move between
    this read and the key; the two checks change together.
    The run reports nothing back, so the caller
    reads the result with `state` or `capture`."""
    keys = [(name, *parse_key(name)) for name in names]
    posted = []
    for name, code, flags in keys:
        window, refusal = keyboard_window(channel)
        if window is None:
            return {"status": "failed", "posted": posted, "reason": refusal}
        if window_id and not window["id"].lower().startswith(window_id.lower()):
            return {"status": "failed", "posted": posted, "reason": f"the window shown is {window['id']}, not {window_id}"}
        holder = window.get("keyboard")
        if not holder:
            return {"status": "failed", "posted": posted,
                    "reason": "nothing in the window holds the keyboard; open the control the key is for first"}
        if holder["kind"] != "control":
            return {"status": "failed", "posted": posted, "keyboard": holder,
                    "reason": "a terminal pane holds the keyboard; send Return there with submit and text with typeLine"}
        post_key(run["pid"], code, flags)
        posted.append(name)
        time.sleep(0.05)
    window, _ = keyboard_window(channel)
    return {"status": "done", "posted": posted, "keyboard": (window or {}).get("keyboard")}


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


# The demo's layers (`DemoFixture.OpenLayer`), which `--layer` opens at launch.
DEMO_LAYERS = ["needs-attention", "all-projects", "review", "approval-list", "approval-card"]


def launch(app=None, home=None, wait=30, projects=(), demo=None):
    """Starts a run with the channel on and its own data, and returns it.

    `projects` are folders handed to the run as Finder's Open With hands them,
    which the app opens as projects: the run's own data starts with none, and
    Open Folder… asks through a panel the channel cannot answer. `demo` starts
    the demo's made-up projects instead (`DemoFixture`), as a dict of its
    `WEIR_DEMO_*` settings (`layer`, `appearance`, `language`), `{}` for the
    plain window.

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
    folders = [os.path.abspath(folder) for folder in projects]
    missing = [folder for folder in folders if not os.path.isdir(folder)]
    if missing:
        raise ChannelError(f"not a folder: {', '.join(missing)}")
    settings = ["--env", "WEIR_AUTOMATION=1", "--env", f"CFFIXED_USER_HOME={home}", "--env", f"WEIR_AUTOMATION_NONCE={nonce}"]
    if demo is not None:
        settings += ["--env", "WEIR_DEMO=1"]
        for name, value in demo.items():
            if value:
                settings += ["--env", f"WEIR_DEMO_{name.upper()}={value}"]
    # The folders go last, as the documents `open` hands the new run.
    subprocess.run(
        ["open", "-g", "-n", "-a", app, *settings, "--stdout", log, "--stderr", log, *folders],
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
        return {"op": "command", "name": args.name, "window": args.window,
                "newWindow": True if args.new_window else None}
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
    p.add_argument("--project", action="append", default=[], help="a folder to open as a project; repeat for more")
    p.add_argument("--demo", action="store_true", help="the demo's projects instead of empty data")
    p.add_argument("--layer", choices=DEMO_LAYERS, help="with --demo: the layer to open")
    p.add_argument("--appearance", choices=["dark"], help="with --demo: the dark look")
    p.add_argument("--language", choices=["ja"], help="with --demo: the Japanese UI")
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
    p.add_argument("--settings", action="store_true", help="the Settings window")
    p = sub.add_parser("focus")
    p.add_argument("pane")
    p = sub.add_parser("commands")
    p.add_argument("--window")
    p = sub.add_parser("command")
    p.add_argument("name")
    p.add_argument("--window")
    p.add_argument("--new-window", action="store_true", help="as ⌘Return commits the row")
    p = sub.add_parser("keys")
    p.add_argument("keys", nargs="+", help="escape, return, tab, up, down, ..., with cmd+, shift+, option+, ctrl+ before one")
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
            if not args.demo and (args.layer or args.appearance or args.language):
                raise ChannelError("--layer, --appearance, and --language go with --demo")
            demo = {"layer": args.layer, "appearance": args.appearance, "language": args.language} if args.demo else None
            print_json(launch(args.app, args.home, projects=args.project, demo=demo))
            return 0
        run = find_run(args.run)
        if args.command == "quit":
            reply = quit_run(run, args.force)
            print_json(reply)
            return 0 if reply["status"] == "done" else 1
        with Channel(run) as channel:
            if args.command == "capture":
                reply = channel.call({"op": "capture", "window": args.window,
                                      "settings": True if args.settings else None})
                if reply["status"] != "done":
                    print_json(reply)
                    return 1
                subprocess.run(["screencapture", "-x", "-o", f"-l{reply['windowNumber']}", args.out], check=True)
                print(args.out)
                return 0
            if args.command == "keys":
                reply = post_keys(run, channel, args.keys, args.window)
                print_json(reply)
                return 0 if reply["status"] == "done" else 1
            reply = channel.call(build_request(args, channel))
        print_json(reply)
        return 0 if reply["status"] == "done" else 1
    except ChannelError as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
