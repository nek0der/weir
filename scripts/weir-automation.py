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
                                          while `state` says they would land on one of Weir's own controls,
                                          never a pane or a sheet (ADR 0006); fails if the app dropped one;
                                          needs the Accessibility grant for this terminal

With several runs live, --run names the one to drive (the short ID `launch`
prints). A pane is named by its UUID, or a unique prefix of it; the run and
the generation it needs are read from `state` first, so a pane whose terminal
was made again since is refused by the app rather than typed into.

`scripts/check-automation.py` imports this file for its connection and launch
code, so the functions below raise `ChannelError` rather than exit; only
`main` turns an error into an exit status.
"""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import plistlib
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
# controls in a project window, with no sheet up, is where it lands.
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


# Why the app would drop a key posted now (`AutomationPostedKeyRefusal`), as
# `state` reports it in `postedKeys`, in the words a failed reply gives.
REFUSALS = {
    "settingsShown": "Settings is open, and a key could land there; close it first",
    "quickTerminalShown": "the quick terminal is shown, and a key could land in its pane; hide it first",
    "notOneWindow": "the run shows no window or several, and a key could land in any of them; keys need exactly one",
    "sheet": "a sheet or an alert is up, and Return could answer it for the person; keys are never posted there",
    "pane": "a terminal pane holds the keyboard; send Return there with submit and text with typeLine",
    "nothingHoldsKeyboard": "nothing in the window holds the keyboard; open the control the key is for first",
}


def posted_keys_state(channel):
    """`state`'s `postedKeys`, with the window's `keyboard` beside it."""
    snapshot = channel.call({"op": "state"})["state"]
    target = snapshot["postedKeys"]
    window = next((w for w in snapshot["windows"] if w["id"] == target.get("window")), None)
    return target, (window or {}).get("keyboard")


def post_keys(run, channel, names, window_id=None):
    """Posts the keys, one request to a run at a time: the counts it reads
    back are the run's, not the request's, so two at once would read each
    other's keys."""
    with open(os.path.join(runs_folder(), run["folder"], "posted-keys.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return _post_keys(run, channel, names, window_id)


def _post_keys(run, channel, names, window_id):
    """Posts each key in turn, after `state` says before each one that it
    would land on one of Weir's own controls in the window shown, never a
    terminal pane, where Return runs code, or a sheet, where Return answers
    for the person (ADR 0006). The app judges the window as it judges each
    key again on arrival (`AutomationPostedKeys`), since the keyboard can move
    between this read and the key, and counts the keys its gate sees and
    drops. So after posting, this waits until the gate has seen every key, or
    a second at most, and fails if it dropped one. The counts say nothing of
    what a key did, so the caller reads its effect with `state` or
    `capture`."""
    keys = [(name, *parse_key(name)) for name in names]
    posted = []
    first = None
    keyboard = None
    for name, code, flags in keys:
        target, keyboard = posted_keys_state(channel)
        first = first or target
        refusal = target.get("refusal")
        if refusal:
            return {"status": "failed", "posted": posted, "keyboard": keyboard,
                    "reason": REFUSALS.get(refusal, f"the app would drop the key ({refusal})")}
        if window_id and not target["window"].lower().startswith(window_id.lower()):
            return {"status": "failed", "posted": posted, "reason": f"the window shown is {target['window']}, not {window_id}"}
        post_key(run["pid"], code, flags)
        posted.append(name)
        time.sleep(0.05)
    # A key a control's own monitor takes first (a dropdown's Esc) never
    # reaches the gate, so a key the gate has not seen is not a failure; the
    # wait ends early once it has seen them all.
    deadline = time.monotonic() + 1
    while True:
        target, keyboard = posted_keys_state(channel)
        if target["seen"] - first["seen"] >= len(posted) or time.monotonic() >= deadline:
            break
        time.sleep(0.05)
    dropped = target["dropped"] - first["dropped"]
    if dropped:
        return {"status": "failed", "posted": posted, "keyboard": keyboard,
                "reason": f"the app dropped {dropped} of the {len(posted)} keys posted, since the keyboard moved before they arrived"}
    return {"status": "done", "posted": posted, "keyboard": keyboard}


def repository_root():
    return subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
    ).stdout.strip()


def debug_app_path(root):
    """This checkout's Debug build, found as `make run` finds it."""
    return subprocess.run(
        [os.path.join(root, "scripts", "built-app-path.sh"), "Debug"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()


def screencapture_window(window_number, path, timeout=30):
    """Writes window `window_number` to `path`, without its shadow or a sound.

    The window number is the one a `capture` reply names. A capture that never
    returns, as when a Screen Recording prompt waits for an answer, stops after
    `timeout` seconds rather than holding the caller.
    """
    subprocess.run(["screencapture", "-x", "-o", f"-l{window_number}", path], timeout=timeout, check=True)


# A run's bundle identifier starts with this, so its user defaults, and what
# AppKit and Sparkle keep there, are a domain of its own rather than the person's
# `com.nekoder.Weir.dev`. The app refuses the channel under any other identifier
# (`AutomationChannel.automationBundlePrefix`).
AUTOMATION_BUNDLE_PREFIX = "com.nekoder.Weir.automation-"


def automation_bundle_id(home):
    """The identifier a run in `home` gets: one per home, so the user defaults
    are the home's own, as its data folder is. It ends in `.dev`, which is how
    the app tells a Debug build: its data folder's name, no automatic update
    checks, and hook links of its own."""
    digest = hashlib.sha256(os.path.realpath(home).encode()).hexdigest()[:8]
    return f"{AUTOMATION_BUNDLE_PREFIX}{digest}.dev"


def forget_home(home):
    """Takes what a run in `home` left outside it away: the copy's entry in
    Launch Services and its user defaults domain, which `cfprefsd` keeps under
    the account's `~/Library/Preferences` by the home's identifier. For a
    home about to be removed; nothing reads either again."""
    for name in os.listdir(home) if os.path.isdir(home) else []:
        if name.endswith(".app"):
            unregister_copy(os.path.realpath(os.path.join(home, name)))
    # Through `defaults`, so `cfprefsd` drops the domain it holds too; a
    # domain that was never written is not an error here. `defaults delete`
    # leaves the file behind with an empty dictionary, which goes too.
    identifier = automation_bundle_id(home)
    subprocess.run(["defaults", "delete", identifier], capture_output=True)
    leftover = os.path.join(os.path.expanduser("~"), "Library", "Preferences", identifier + ".plist")
    try:
        with open(leftover, "rb") as f:
            if plistlib.load(f) == {}:
                os.remove(leftover)
    except (OSError, plistlib.InvalidFileException):
        pass


def build_stamp(app):
    """What changes whenever the build at `app` does: the hash of its seal,
    which lists every resource, and its executable's time and size."""
    contents = os.path.join(app, "Contents")
    with open(os.path.join(contents, "Info.plist"), "rb") as f:
        executable = plistlib.load(f)["CFBundleExecutable"]
    with open(os.path.join(contents, "_CodeSignature", "CodeResources"), "rb") as f:
        seal = hashlib.sha256(f.read()).hexdigest()
    status = os.stat(os.path.join(contents, "MacOS", executable))
    return f"{seal} {status.st_mtime_ns} {status.st_size}"


@contextlib.contextmanager
def automation_copy(app, home):
    """A copy of `app` in `home` under `automation_bundle_id(home)`, made again when
    the build has changed since.

    macOS keeps an app's user defaults by bundle identifier under the
    account's own `~/Library/Preferences`, whatever `CFFIXED_USER_HOME` says,
    so a run of the build itself would read and write the person's domain:
    their language, and the frames and folders AppKit and Sparkle save there.
    The copy is an APFS clone, so it costs almost no space, and it is signed
    again ad hoc, as a Debug build is, since its `Info.plist` changed. A copy
    that a live run is using is never replaced under it, and two launches into
    one home take turns: the copy is yielded with the home's lock held, so the
    caller starts it before another launch can replace it."""
    # Resolved, as `ps` names a running copy's executable (`/private/tmp`, not
    # `/tmp`), so the check below finds a live run of it.
    copy = os.path.realpath(os.path.join(home, os.path.basename(app.rstrip("/"))))
    with open(os.path.join(home, "app-copy.lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield _make_copy(app, home, copy)


def _make_copy(app, home, copy):
    """`automation_copy`'s work, with the home's lock held."""
    stamp_path = os.path.join(home, "app-copy-stamp")
    stamp = build_stamp(app)
    try:
        with open(stamp_path) as f:
            if f.read() == stamp and os.path.isdir(copy):
                return copy
    except OSError:
        pass
    executables = os.path.join(copy, "Contents", "MacOS") + os.sep
    running = subprocess.run(["ps", "-axo", "comm="], capture_output=True, text=True, check=True).stdout
    if any(line.startswith(executables) for line in running.splitlines()):
        raise ChannelError(f"a run of the copy in {home} is still open, and the build has changed; quit it first")
    fresh = copy + ".new"
    shutil.rmtree(fresh, ignore_errors=True)
    if subprocess.run(["cp", "-cR", app, fresh], capture_output=True).returncode != 0:
        shutil.rmtree(fresh, ignore_errors=True)
        subprocess.run(["ditto", app, fresh], check=True)
    info_path = os.path.join(fresh, "Contents", "Info.plist")
    with open(info_path, "rb") as f:
        info = plistlib.load(f)
    info["CFBundleIdentifier"] = automation_bundle_id(home)
    with open(info_path, "wb") as f:
        plistlib.dump(info, f)
    # The entitlements only: the hardened runtime of a build signed with a Team
    # ID would turn on library validation, and the libraries in the copy, which
    # keep that Team ID, would then be refused by the ad hoc executable.
    subprocess.run(
        ["codesign", "--force", "--sign", "-", "--preserve-metadata=entitlements", fresh],
        capture_output=True, check=True,
    )
    shutil.rmtree(copy, ignore_errors=True)
    os.rename(fresh, copy)
    with open(stamp_path, "w") as f:
        f.write(stamp)
    return copy


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
    reads or writes the person's `Weir Dev` session, and it runs from a copy of
    the build there with a bundle identifier of its own (`automation_copy`), so
    it never reads or writes their user defaults either.

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
    bundle_id = automation_bundle_id(home)
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
    with automation_copy(app, home) as copy:
        # The folders go last, as the documents `open` hands the new run.
        subprocess.run(
            ["open", "-g", "-n", "-a", copy, *settings, "--stdout", log, "--stderr", log, *folders],
            env=environment, check=True,
        )
    deadline = time.time() + wait
    run = None
    while time.time() < deadline:
        run = run or next((r for r in live_runs() if r.get("nonce") == nonce), None)
        if run:
            try:
                with Channel(find_run(run["folder"]), timeout=5):
                    return dict(run, home=home, log=log, bundleID=bundle_id)
            except ChannelError:
                pass
        time.sleep(0.2)
    # The run, or, when it has not written its folder yet, every process of
    # this copy that no other live run names: the one this call started.
    others = {r["pid"] for r in live_runs() if r.get("nonce") != nonce}
    pids = [run["pid"]] if run else [pid for pid in copy_processes(copy) if pid not in others]
    for pid in pids:
        os.kill(pid, 15)
    end = time.time() + 5
    while any(is_running(pid) for pid in pids) and time.time() < end:
        time.sleep(0.2)
    # As `quit_run` does, so a copy whose run never answered is not left
    # offered as an app for folders.
    unregister_copy(copy)
    raise ChannelError(f"the run did not answer within {wait} seconds; see {log}")


LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def running_copy(pid):
    """The automation copy process `pid` runs from, or `None` for any other app."""
    executable = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    bundle = executable.split("/Contents/MacOS/")[0] if "/Contents/MacOS/" in executable else None
    try:
        with open(os.path.join(bundle, "Contents", "Info.plist"), "rb") as f:
            identifier = plistlib.load(f).get("CFBundleIdentifier", "")
    except (OSError, TypeError, plistlib.InvalidFileException):
        return None
    return bundle if identifier.startswith(AUTOMATION_BUNDLE_PREFIX) else None


def copy_processes(bundle):
    """The process IDs running the executable of the copy at `bundle`."""
    executables = os.path.join(bundle, "Contents", "MacOS") + os.sep
    listing = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True, check=True).stdout
    pids = []
    for line in listing.splitlines():
        pid, _, command = line.strip().partition(" ")
        if command.strip().startswith(executables):
            pids.append(int(pid))
    return pids


def unregister_copy(bundle):
    """Takes the copy at `bundle` out of Launch Services, which `open` added it
    to, so it is not offered as an app for folders or found by Spotlight. A copy
    started anyway refuses to run outside the channel (`WeirLaunch`)."""
    subprocess.run([LSREGISTER, "-u", bundle], capture_output=True)


def quit_run(run, force=False, wait=15):
    """Ends `run` through the channel and waits for its process to exit."""
    bundle = running_copy(run["pid"])
    with Channel(run) as channel:
        reply = channel.call({"op": "quit", "force": force})
    if reply["status"] != "done":
        return reply
    deadline = time.time() + wait
    while time.time() < deadline:
        if not is_running(run["pid"]):
            if bundle:
                unregister_copy(bundle)
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
                screencapture_window(reply["windowNumber"], args.out)
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
