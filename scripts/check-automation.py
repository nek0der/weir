#!/usr/bin/env python3
"""Checks the verification channel (ADR 0005) against a real run of Weir.

Usage: scripts/check-automation.py [--keys] [--agents [NAMES]] [--only SECTIONS] [--app PATH] [--keep]

`make check-automation` runs it. Each invocation launches a fresh Debug run
with its own data, runs the sections below in order, quits it, and exits 0
only when every check passed. It never touches the person's Weir Dev session.

  (always)   connection and authentication, state, layers, commands, the
             palette rows the channel leans on, settings, typing, the channel's own unsent text, paste, waiting,
             disconnects, the command line, tmux (when installed), quitting
  --keys     the person's unsent text and the client's posted keys, also
             while a sheet is up (keys sent from outside, which need the
             Accessibility grant for this terminal), and captures of the window and of Settings (which
             need Screen Recording)
  --agents   Claude Code, Codex, OpenCode, Antigravity, and Kiro, each started
             in a pane of its own, prompted, waited on, and quit; each costs a
             little model use. `--agents claude,codex` checks only those, for
             a day one agent's plan has no use left
  --keep     leave the run open at the end, to look at it

Adding a check: put it in the section it belongs to, give it a name that says
what must hold, and assert the reason as well as the status where a refusal is
expected, so a request refused for a different cause does not pass. A section
starts from a scratch pane at a shell prompt and leaves one behind; anything a
section changes (a setting, a layer, a split) it puts back before it returns.
The channel cannot close Settings, so sections that open it leave it open
until the run quits.
"""

import argparse
import importlib.util
import json
import os
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def load_client():
    """`weir-automation.py`, imported by path because its name has a dash."""
    spec = importlib.util.spec_from_file_location("weir_automation", os.path.join(HERE, "weir-automation.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


client = load_client()
ChannelError = client.ChannelError

# Keys from outside, as a person typing would send them: posted to the app's
# process, so they reach whichever pane has the keyboard. Written to a file at
# run time and run with `swift`, because a check script cannot post events.
# The key codes `post_keys` types the person's letters with, on a US layout.
PERSON_KEY_CODES = {
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
    "k": 40, "n": 45, "m": 46, " ": 49, "\n": 36,
}


class Checks:
    """Collects results and prints one line per check as it runs."""

    def __init__(self):
        self.results = []

    def section(self, title):
        print(f"\n== {title}", flush=True)

    def check(self, name, holds, detail=""):
        self.results.append((name, bool(holds)))
        print(("PASS " if holds else "FAIL ") + name + ("" if holds else f"\n     {detail}"), flush=True)
        return bool(holds)

    def refused(self, name, reply, *words):
        """A refusal for the expected reason: `failed`, with each of `words` in it."""
        reason = reply.get("reason", "")
        holds = reply.get("status") == "failed" and all(word in reason for word in words)
        return self.check(name, holds, reply)

    def summary(self):
        passed = sum(holds for _, holds in self.results)
        print(f"\n{passed}/{len(self.results)} checks passed")
        for name, holds in self.results:
            if not holds:
                print(f"  failed: {name}")
        return passed == len(self.results)


class Run:
    """The run under check, with the helpers the sections share."""

    def __init__(self, info, scratch):
        self.info = info
        self.scratch = scratch
        self.channel = client.Channel(info)

    def call(self, request):
        return self.channel.call(request)

    def connect(self, hello=True):
        """A second connection, raw: for checks of the connection itself."""
        return RawConnection(self.info, hello)

    def panes(self):
        """The panes of the selected tab of every window."""
        state = self.call({"op": "state"})["state"]
        return [pane for window in state["windows"] for tab in window["tabs"] if tab["isSelected"] for pane in tab["panes"]]

    def pane(self, ref):
        return next((pane for pane in self.panes() if pane["ref"]["id"] == ref["id"]), None)

    def type(self, op, ref, text=None, expect=None, submit=None, session=None):
        return self.call({"op": op, "pane": ref, "text": text, "submit": submit,
                          "expect": {"process": expect or self.shell, "session": session}})

    def until(self, condition, seconds=10.0):
        """Polls `condition` instead of sleeping a fixed time; returns its last value."""
        deadline = time.time() + seconds
        while True:
            value = condition()
            if value or time.time() >= deadline:
                return value
            time.sleep(0.2)

    def in_front(self, ref, process, seconds=20.0):
        return self.until(lambda: (self.pane(ref) or {}).get("foregroundProcess") == process, seconds)

    def marker(self, name):
        """A file a typed command creates, so a check can see the command ran."""
        path = os.path.join(self.scratch, name)
        if os.path.exists(path):
            os.remove(path)
        return path

    def post_keys(self, text):
        """Types `text` as the person would, with unmarked keys the app takes
        for theirs, unlike the client's `keys`, which it drops at a pane."""
        for character in text:
            if character in PERSON_KEY_CODES:
                client.post_key(self.info["pid"], PERSON_KEY_CODES[character], marked=False, text=character)

    def capture(self, path, **fields):
        """Captures to `path` the window the request's `fields` name: the run's
        window when there are none, Settings with `settings=True`."""
        reply = self.call({"op": "capture", **fields})
        if reply["status"] != "done":
            return reply
        client.screencapture_window(reply["windowNumber"], path)
        return reply


class RawConnection:
    """A connection that sends lines as given and reads replies as they come."""

    def __init__(self, info, hello):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(40)
        self.sock.connect(info["socket"])
        self.reader = self.sock.makefile("r")
        self.next_id = 0
        if hello:
            reply = self.send(json.dumps({"id": "h", "op": "hello", "token": info["token"], "protocol": client.PROTOCOL}))
            assert reply and reply["status"] == "done", reply

    def send(self, line):
        self.sock.sendall(line.encode() + b"\n")
        return self.read()

    def read(self):
        line = self.reader.readline()
        return json.loads(line) if line else None

    def is_closed(self, wait=5):
        """Whether the app closed this connection; closes this end either way.

        A timeout is not a close: a connection the app wrongly kept open and
        silent would otherwise pass as closed once the read gave up.
        """
        self.sock.settimeout(wait)
        try:
            closed = self.reader.readline() == ""
        except socket.timeout:
            closed = False
        except (ConnectionResetError, BrokenPipeError):
            closed = True
        self.close()
        return closed

    def close(self):
        self.reader.close()
        self.sock.close()


# MARK: - sections


def connection(run, checks):
    checks.section("connection and authentication")
    c = run.connect(hello=False)
    reply = c.send('{"id":"1","op":"state"}')
    checks.refused("a request before hello is refused", reply or {}, "hello")
    checks.check("...and its connection is closed", c.is_closed())
    c = run.connect(hello=False)
    reply = c.send(json.dumps({"id": "1", "op": "hello", "token": "wrong", "protocol": client.PROTOCOL}))
    checks.check("a wrong token is refused and closed", "token" in reply.get("reason", "") and c.is_closed(), reply)
    c = run.connect(hello=False)
    reply = c.send(json.dumps({"id": "1", "op": "hello", "token": run.info["token"], "protocol": "weir-automation-protocol/9"}))
    checks.check("another protocol version is refused and closed", "hello" in reply.get("reason", "") and c.is_closed(), reply)
    c = run.connect(hello=False)
    reply = c.send("not json")
    checks.check("a line that is no request, before hello, is refused and closed",
                 "not a request" in reply.get("reason", "") and c.is_closed(), reply)
    c = run.connect()
    reply = c.send('{"id":"7","op":"open","layer":"nope"}')
    checks.check("an unknown layer is named in the reason, with the request's ID", reply["id"] == "7" and "layer" in reply["reason"], reply)
    reply = c.send('{"id":"8","op":"fly"}')
    checks.check("an unknown operation is refused with its ID", reply["id"] == "8" and reply["status"] == "failed", reply)
    c.sock.sendall(b"x" * 70000 + b"\n")
    checks.check("a line past 64 KiB closes the connection", c.is_closed())
    # `run.channel` holds one connection; three more reach the limit of four.
    others = [run.connect() for _ in range(3)]
    checks.check("a fifth connection is closed", run.connect(hello=False).is_closed())
    for other in others:
        other.close()
    checks.check("a connection opens again once others close", run.until(lambda: _connects(run), 3))
    folder = os.path.join(client.runs_folder(), run.info["folder"])
    checks.check("the socket is the owner's alone", _mode(run.info["socket"]) == 0o600)
    checks.check("the run folder is the owner's alone", _mode(folder) == 0o700)
    checks.check("the token file is the owner's alone", _mode(os.path.join(folder, "token")) == 0o600)


def _connects(run):
    try:
        c = run.connect()
        c.close()
        return True
    except (OSError, AssertionError):
        return False


def _mode(path):
    return os.stat(path).st_mode & 0o777


def state(run, checks):
    checks.section("state")
    snapshot = run.call({"op": "state"})["state"]
    checks.check("state names this run", snapshot["run"] == run.info["run"], snapshot["run"])
    checks.check("state lists a window", len(snapshot["windows"]) >= 1)
    panes = run.panes()
    checks.check("a fresh run has one pane, at a shell", len(panes) == 1 and panes[0].get("foregroundProcess"), panes)
    checks.check("a pane is named by run, ID, and generation", set(panes[0]["ref"]) == {"run", "id", "generation"})


# The shortcut action that closes each layer `open` opens, where it toggles.
LAYER_TOGGLES = {
    "allProjects": "allProjects",
    "notificationHistory": "notificationHistory",
    "keyboardShortcuts": "keyboardShortcuts",
    "planUsage": "planUsage",
}


def layers(run, checks):
    checks.section("layers")
    for layer in ["needsAttention", "allProjects", "notificationHistory", "keyboardShortcuts", "planUsage"]:
        before = run.call({"op": "wait", "until": "layerOpen", "layer": layer, "timeout": 0})
        opened = run.call({"op": "open", "layer": layer})
        waited = run.call({"op": "wait", "until": "layerOpen", "layer": layer, "timeout": 5})
        checks.check(f"{layer}: closed before, opened by open, seen by wait",
                     before["status"] == "timedOut" and opened["status"] == "done" and waited["status"] == "done",
                     (before, opened, waited))
        again = run.call({"op": "open", "layer": layer})
        checks.check(f"{layer}: opening it again says it is already open", again.get("reason") == "already open", again)
        if layer in LAYER_TOGGLES:
            run.call({"op": "command", "name": LAYER_TOGGLES[layer]})
        else:
            # The Needs Attention menu closes when another layer opens.
            run.call({"op": "open", "layer": "planUsage"})
            run.call({"op": "command", "name": "planUsage"})
        closed = run.until(lambda: run.call({"op": "wait", "until": "layerOpen", "layer": layer, "timeout": 0})["status"] == "timedOut", 5)
        checks.check(f"{layer}: closed again for the next check", closed)
    checks.refused("open review without a pane is refused", run.call({"op": "open", "layer": "review"}), "pane")
    checks.refused("a wait for review without a pane is refused",
                   run.call({"op": "wait", "until": "layerOpen", "layer": "review", "timeout": 1}), "pane")
    checks.refused("a window that does not exist is refused",
                   run.call({"op": "open", "layer": "needsAttention", "window": "00000000-0000-0000-0000-000000000000"}), "window")


def commands(run, checks):
    checks.section("commands")
    rows = {row["id"]: row for row in run.call({"op": "commands"})["commands"]}
    checks.check("commands lists the shortcut actions", sum(i.startswith("shortcut.") for i in rows) >= 50, len(rows))
    checks.check("zooming a split is disabled with one pane", rows["shortcut.toggleSplitZoom"]["isEnabled"] is False,
                 rows["shortcut.toggleSplitZoom"])
    first = run.panes()[0]["ref"]
    split = run.call({"op": "command", "name": "splitDown"})
    checks.check("a command by its short name runs (split down)", split["status"] == "done" and run.until(lambda: len(run.panes()) == 2, 5), split)
    rows = {row["id"]: row for row in run.call({"op": "commands"})["commands"]}
    checks.check("a command's enabled state follows the window (zoom is on with two panes)",
                 rows["shortcut.toggleSplitZoom"]["isEnabled"] is True, rows["shortcut.toggleSplitZoom"])
    new = next(pane["ref"] for pane in run.panes() if pane["ref"]["id"] != first["id"])
    checks.check("a new pane starts at generation 1", new["generation"] == 1, new)
    close = run.call({"op": "command", "name": "shortcut.closeSurface"})
    checks.check("a command by its full ID runs (close the focused pane)", close["status"] == "done" and run.until(lambda: len(run.panes()) == 1, 5), close)
    checks.check("the pane left is the first one", run.panes()[0]["ref"]["id"] == first["id"])
    disabled = next(i for i, row in rows.items() if not row["isEnabled"])
    checks.refused(f"a disabled command is refused ({disabled})", run.call({"op": "command", "name": disabled}), "disabled")
    checks.refused("an unknown command is refused", run.call({"op": "command", "name": "noSuchThing"}), "no command")
    checks.refused("a command without a name is refused", run.call({"op": "command"}), "name")


# The rows the palette offers for controls with no keyboard shortcut, which
# the channel reaches through `command` (ADR 0005, "Adding an operation").
AGENT_ROWS = ["newTab.claude", "newTab.codex", "newTab.antigravity", "newTab.opencode", "newTab.kiro"]
SETTINGS_SECTIONS = ["general", "appearance", "font", "terminal", "tabsAndPanes", "quickTerminal",
                     "keyboard", "integrations", "review", "advanced"]


def palette_rows(run, checks):
    checks.section("palette rows")
    rows = {row["id"]: row for row in run.call({"op": "commands"})["commands"]}
    # Running a row would start an agent. The installed set can be empty.
    agent_rows = [name for name in rows if name.startswith("newTab.")]
    checks.check("the agent tab rows are an enabled subset of the known agent rows",
                 set(agent_rows) <= set(AGENT_ROWS) and all(rows[name]["isEnabled"] for name in agent_rows), agent_rows)
    checks.check("a row opens Settings on each section",
                 all(f"settings.section.{name}" in rows for name in SETTINGS_SECTIONS), sorted(i for i in rows if i.startswith("settings.")))
    checks.check("moving a pane to a new tab is off with one pane", rows["pane.moveToNewTab"]["isEnabled"] is False, rows["pane.moveToNewTab"])

    def window():
        return run.call({"op": "state"})["state"]["windows"][0]

    hidden = run.call({"op": "command", "name": "view.toggleIconBars"})
    checks.check("Hide Icon Bars hides them, as state says", hidden["status"] == "done" and run.until(lambda: window()["areIconBarsHidden"], 5), hidden)
    shown = run.call({"op": "command", "name": "view.toggleIconBars"})
    checks.check("running it again shows them", shown["status"] == "done" and run.until(lambda: not window()["areIconBarsHidden"], 5), shown)

    run.call({"op": "command", "name": "splitDown"})
    run.until(lambda: len(run.panes()) == 2, 5)
    moved = run.call({"op": "command", "name": "pane.moveToNewTab"})
    checks.check("Move Pane to New Tab makes a tab of the focused pane",
                 moved["status"] == "done" and run.until(lambda: len(window()["tabs"]) == 2 and len(run.panes()) == 1, 5), moved)
    run.call({"op": "command", "name": "closeTab"})
    checks.check("the moved pane's tab closes again for the next check", run.until(lambda: len(window()["tabs"]) == 1, 5), window()["tabs"])

    checks.check("state names no dropdown while none is open", window().get("dropdown") is None, window().get("dropdown"))
    run.call({"op": "command", "name": "showOpenTabs"})
    checks.check("state names the dropdown a command opened", run.until(lambda: window().get("dropdown") == "openTabs", 5), window().get("dropdown"))
    run.call({"op": "command", "name": "showOpenTabs"})
    checks.check("the dropdown closes again", run.until(lambda: window().get("dropdown") is None, 5), window().get("dropdown"))

    for name in ["keyboard", "general"]:
        opened = run.call({"op": "command", "name": f"settings.section.{name}"})
        seen = run.until(lambda: (run.call({"op": "state"})["state"].get("settings") or {}).get("section") == name, 5)
        checks.check(f"the {name} row opens Settings on {name}, as state says", opened["status"] == "done" and seen, opened)


def settings(run, checks):
    checks.section("settings")
    cases = [
        ("font.size", 15.5), ("font.size", 15), ("font.ligatures", True), ("appearance.colorScheme", "light"),
        ("appearance.backgroundOpacity", 0.8), ("font.family", "Menlo"),
    ]
    originals = {key: run.call({"op": "setting", "key": key})["value"] for key, _ in cases}
    checks.check("an optional setting left unset reads as null", originals.get("font.family") is None, originals)
    # Put back in `finally`, so a later section never runs with these, even
    # when a check here stops on an error.
    try:
        for key, value in cases:
            changed = run.call({"op": "setting", "key": key, "value": value})
            read = run.call({"op": "setting", "key": key})
            checks.check(f"{key} = {value!r} is set and read back",
                         changed["status"] == "done" and read.get("value") == value, (changed, read))
        for key, value in [("font.size", "big"), ("appearance.colorScheme", "purple"), ("font.ligatures", "yes")]:
            checks.refused(f"{key} refuses {value!r}", run.call({"op": "setting", "key": key, "value": value}), "take that value")
        for key, why in [("font.sise", "not a setting"), ("nonsense", "not a setting"), ("font.size.inner", "inside a value"),
                         ("font..size", "named like"), ("", "named like")]:
            checks.refused(f"the key {key!r} is refused", run.call({"op": "setting", "key": key, "value": 1}), why)
        checks.refused("schemaVersion is refused", run.call({"op": "setting", "key": "schemaVersion", "value": 9}), "schemaVersion")
        days = run.call({"op": "setting", "key": "advanced.turnRetention.days"})["value"]
        checks.refused("a narrower turn retention is refused, since Settings asks before it deletes records",
                       run.call({"op": "setting", "key": "advanced.turnRetention.days", "value": days - 1}), "retention")
        # ⌘T is New Tab's. Modifiers are written as their raw value: 1 is ⌘.
        checks.refused("a binding another action holds is refused, as the Keyboard pane refuses it",
                       run.call({"op": "setting", "key": "keyboard.overrides.splitRight", "value": {"key": "t", "modifiers": 1}}),
                       "Keyboard pane")
        saved = os.path.join(run.info["home"], "Library", "Application Support", "Weir Dev", "settings.json")
        checks.check("settings.json holds the change", run.until(lambda: _font_family(saved) == "Menlo", 5), saved)
        cleared = run.call({"op": "setting", "key": "font.family", "unset": True})
        checks.check("unset clears an optional setting", cleared["status"] == "done" and cleared.get("value") is None, cleared)
    finally:
        for key, value in originals.items():
            request = {"op": "setting", "key": key}
            request.update({"unset": True} if value is None else {"value": value})
            run.call(request)
    restored = {key: run.call({"op": "setting", "key": key}).get("value") for key in originals}
    checks.check("every changed setting is put back", restored == originals, (restored, originals))


def _font_family(path):
    try:
        with open(path) as f:
            return json.load(f).get("font", {}).get("family")
    except (OSError, ValueError):
        return None


def typing(run, checks):
    checks.section("typing")
    ref = run.panes()[0]["ref"]
    marker = run.marker("typed")
    reply = run.type("typeLine", ref, f"touch {shlex.quote(marker)}")
    checks.check("typeLine runs a command at the shell", reply["status"] == "done" and reply.get("submitted")
                 and run.until(lambda: os.path.exists(marker), 3), reply)
    checks.refused("another expected process is refused", run.type("typeLine", ref, "echo no", expect="opencode"), "not opencode")
    for text, why in [("", "empty"), ("a\tb", "a tab"), ("a\nb", "a newline"), ("a\x7fb", "DEL"), ("a\x1bb", "ESC"), ("a\x85b", "C1")]:
        reply = run.type("typeLine", ref, text)
        checks.refused(f"typeLine refuses {why}", reply, "typeLine")
    reply = run.type("typeLine", ref, "echo 日本語の行")
    checks.check("typeLine takes text beyond ASCII", reply["status"] == "done", reply)
    checks.refused("paste refuses empty text", run.type("paste", ref, ""), "paste needs text")
    checks.refused("submit refuses text", run.type("submit", ref, "x"), "submit takes no text")
    checks.refused("typing without expect is refused", run.call({"op": "typeLine", "pane": ref, "text": "echo no"}), "expect")
    checks.refused("a stale generation is refused", run.type("typeLine", dict(ref, generation=ref["generation"] + 1), "echo no"), "made again")
    checks.refused("a pane of another run is refused", run.type("typeLine", dict(ref, run="OTHER"), "echo no"), "another run")
    checks.refused("a pane that does not exist is refused",
                   run.type("typeLine", dict(ref, id="00000000-0000-0000-0000-000000000000"), "echo no"), "no such pane")
    checks.refused("a session that is not the pane's is refused", run.type("typeLine", ref, "echo no", session="not-a-session"), "session")


def channel_drafts(run, checks):
    checks.section("the channel's own unsent text")
    ref = run.panes()[0]["ref"]
    marker = run.marker("kept")
    reply = run.type("typeLine", ref, f"touch {shlex.quote(marker)}", submit=False)
    checks.check("typeLine without submit leaves the text and marks a draft",
                 reply["status"] == "done" and reply.get("submitted") is False and run.pane(ref)["hasUnsubmittedInput"], reply)
    checks.check("...and runs nothing yet", not run.until(lambda: os.path.exists(marker), 1))
    checks.refused("typing into it is refused as the channel's own", run.type("typeLine", ref, "echo more"), "submit it first")
    checks.refused("pasting into it is refused as the channel's own", run.type("paste", ref, "echo more"), "submit it first")
    reply = run.type("submit", ref)
    checks.check("submit sends it", reply["status"] == "done" and run.until(lambda: os.path.exists(marker), 3), reply)
    checks.check("...and the draft mark goes with it", not run.pane(ref)["hasUnsubmittedInput"])


def paste(run, checks):
    checks.section("paste")
    ref = run.panes()[0]["ref"]
    first, second = run.marker("pasted-1"), run.marker("pasted-2")
    reply = run.type("paste", ref, f"touch {shlex.quote(first)}\ntouch {shlex.quote(second)}")
    checks.check("a multi-line paste reaches the shell as one paste", reply["status"] == "done", reply)
    checks.check("...without running it", not run.until(lambda: os.path.exists(first) or os.path.exists(second), 1))
    checks.refused("...and it is the channel's: typing into it is refused", run.type("typeLine", ref, "echo more"), "submit it first")
    reply = run.type("submit", ref)
    checks.check("submit runs both lines", reply["status"] == "done"
                 and run.until(lambda: os.path.exists(first) and os.path.exists(second), 3), reply)


def person_drafts(run, checks):
    checks.section("the person's unsent text (--keys)")
    ref = run.panes()[0]["ref"]
    # Keys from outside land in the pane with the keyboard. A pane given the
    # keyboard has been seen to lose it again a moment later (not solved yet,
    # docs/verification-channel.md), so focus is asked until it holds.
    def focus_holds():
        run.call({"op": "focus", "pane": ref})
        time.sleep(0.3)
        return run.pane(ref)["hasKeyboard"]

    checks.check("focus gives the pane the keyboard", run.until(focus_holds, 5), run.pane(ref))
    run.post_keys("echo person")
    checks.check("keys from outside mark a draft", run.until(lambda: run.pane(ref)["hasUnsubmittedInput"], 3), run.pane(ref))
    for op in ["typeLine", "paste", "submit"]:
        reply = run.type(op, ref, None if op == "submit" else "echo channel")
        checks.refused(f"{op} is refused over the person's draft", reply, "person")
    run.post_keys("\n")
    checks.check("the person's Return clears the draft", run.until(lambda: not run.pane(ref)["hasUnsubmittedInput"], 3))
    marker = run.marker("lapsed")
    run.type("typeLine", ref, f"touch {shlex.quote(marker)}; : ", submit=False)
    run.post_keys("x")
    time.sleep(0.5)
    checks.refused("after the person adds a key, the channel's text is no longer its to submit", run.type("submit", ref), "person")
    checks.check("...and nothing ran", not run.until(lambda: os.path.exists(marker), 1))
    # The person's extra key is an argument to `:`, so the marker stays the
    # same when their Return eventually sends the line.
    run.post_keys("\n")
    checks.check("the person's Return runs the line and clears the draft",
                 run.until(lambda: os.path.exists(marker) and not run.pane(ref)["hasUnsubmittedInput"], 3))


def posted_keys(run, checks):
    checks.section("posted keys (--keys)")

    def window():
        return run.call({"op": "state"})["state"]["windows"][0]

    def post(*names):
        return client.post_keys(run.info, run.channel, list(names))

    def posted_keys():
        return run.call({"op": "state"})["state"]["postedKeys"]

    checks.check("a fresh run's keyboard is on its pane", (window().get("keyboard") or {}).get("kind") == "pane", window().get("keyboard"))
    checks.refused("a key is not posted while a pane holds the keyboard", post("return"), "terminal pane")
    # Past the client's check, as a key would arrive after the keyboard moved
    # back to the pane: the app itself drops it (`AutomationPostedKeys`).
    ref = run.panes()[0]["ref"]
    run.call({"op": "focus", "pane": ref})
    marker = run.marker("posted-return")
    run.type("typeLine", ref, f"touch {shlex.quote(marker)}", submit=False)
    before = posted_keys()
    client.post_key(run.info["pid"], client.KEY_CODES["return"])
    run.until(lambda: posted_keys()["seen"] > before["seen"], 5)
    checks.check("the app drops a posted Return bound for a pane, past the client's check", not os.path.exists(marker))
    after = posted_keys()
    checks.check("...and counts it as seen and dropped, which the client reads",
                 (after["seen"] - before["seen"], after["dropped"] - before["dropped"]) == (1, 1), (before, after))
    run.type("submit", ref)
    checks.check("the line it was dropped on is intact, and the channel's own submit runs it", run.until(lambda: os.path.exists(marker), 5))
    run.call({"op": "command", "name": "newTab"})
    run.until(lambda: len(window()["tabs"]) == 2, 5)
    first = window()["tabs"][0]["id"]
    run.call({"op": "command", "name": "showOpenTabs"})
    run.until(lambda: window().get("dropdown") == "openTabs", 5)
    checks.check("Open Tabs takes the keyboard as it opens",
                 run.until(lambda: (window().get("keyboard") or {}).get("kind") == "control", 5), window().get("keyboard"))
    posted = post("up", "return")
    chosen = run.until(lambda: next(t for t in window()["tabs"] if t["isSelected"])["id"] == first and window().get("dropdown") is None, 5)
    checks.check("↑ and Return posted to Open Tabs choose the tab above and close it", posted["status"] == "done" and chosen, (posted, window()))
    run.call({"op": "command", "name": "showOpenTabs"})
    run.until(lambda: (window().get("keyboard") or {}).get("kind") == "control", 5)
    posted = post("escape")
    checks.check("Escape posted to Open Tabs closes it", posted["status"] == "done" and run.until(lambda: window().get("dropdown") is None, 5), posted)
    checks.check("a key name that is not one is refused before anything is posted",
                 _raises(lambda: post("a")), "posted a letter")
    run.call({"op": "command", "name": f"tab.{window()['tabs'][1]['id']}"})
    run.call({"op": "command", "name": "closeTab"})
    checks.check("the added tab closes again for the next check", run.until(lambda: len(window()["tabs"]) == 1, 5), window()["tabs"])


def _raises(action):
    try:
        action()
    except ChannelError:
        return True
    return False


def captures(run, checks):
    checks.section("captures (--keys)")
    windows = run.call({"op": "state"})["state"]["windows"]
    checks.check("the run is not the key window (it stays behind)", not windows[0]["isKey"], windows[0]["isKey"])
    ref = run.panes()[0]["ref"]
    before, after = os.path.join(run.scratch, "before.png"), os.path.join(run.scratch, "after.png")
    run.type("typeLine", ref, "clear")
    time.sleep(1)
    run.capture(before)
    run.type("typeLine", ref, "echo the pane draws while it is behind other windows")
    time.sleep(1)
    reply = run.capture(after)
    checks.check("a capture of the window is written", reply["status"] == "done" and os.path.getsize(after) > 10000, reply)
    # Different capture bytes establish a fresh output observation, not which
    # view changed or whether the terminal's pixels were redrawn.
    with open(before, "rb") as a, open(after, "rb") as b:
        checks.check("the capture data changed after typing behind other windows", a.read() != b.read())
    checks.refused("a window that does not exist is refused", run.call({"op": "capture", "window": "00000000-0000-0000-0000-000000000000"}), "window")
    closed = run.call({"op": "capture", "settings": True})
    checks.check("a capture of Settings while it is closed is not observable", closed["status"] == "notObservable", closed)
    run.call({"op": "command", "name": "settings.section.font"})
    run.until(lambda: run.call({"op": "state"})["state"].get("settings"), 5)
    settings_path = os.path.join(run.scratch, "settings.png")
    reply = run.capture(settings_path, settings=True)
    checks.check("a capture of Settings is written", reply["status"] == "done" and os.path.getsize(settings_path) > 10000, reply)


def waiting(run, checks):
    checks.section("waiting")
    ref = run.panes()[0]["ref"]
    started = time.time()
    reply = run.call({"op": "wait", "until": "turnEnded", "pane": ref, "timeout": 1})
    checks.check("turnEnded on a pane with no agent times out", reply["status"] == "timedOut" and time.time() - started < 3, reply)
    started = time.time()
    reply = run.call({"op": "wait", "until": "turnEnded", "pane": ref, "timeout": -5})
    checks.check("a negative timeout is clamped to none", reply["status"] == "timedOut" and time.time() - started < 2, reply)
    reply = run.call({"op": "wait", "until": "turnEnded", "pane": dict(ref, generation=99), "timeout": 1})
    checks.check("turnEnded on a stale pane is not observable", reply["status"] == "notObservable", reply)
    checks.refused("turnEnded without a pane is refused", run.call({"op": "wait", "until": "turnEnded", "timeout": 1}), "pane")
    checks.refused("a wait without until is refused", run.call({"op": "wait", "timeout": 1}), "until")


def disconnects(run, checks):
    checks.section("disconnects")
    ref = run.panes()[0]["ref"]
    # Disconnecting releases connection slots even while requests are waiting.
    # Reusing a slot does not establish that its former task was canceled.
    for _ in range(3):
        c = run.connect()
        c.sock.sendall((json.dumps({"id": "w", "op": "wait", "until": "turnEnded", "pane": ref, "timeout": 25}) + "\n").encode())
        c.close()
    checks.check("connections of clients that left mid-wait are freed", run.until(lambda: _connects_and_holds(run), 5))
    started = time.time()
    checks.check("the other clients are answered at once", run.call({"op": "state"})["status"] == "done" and time.time() - started < 1)


def _connects_and_holds(run):
    """Opens the three connections left under the limit, or fails."""
    try:
        held = [run.connect() for _ in range(3)]
    except (OSError, AssertionError):
        return False
    for c in held:
        c.close()
    return True


def command_line(run, checks):
    checks.section("the command line")
    cli = [sys.executable, "-I", os.path.join(HERE, "weir-automation.py")]
    out = subprocess.run(cli + ["--run", run.info["folder"], "state"], capture_output=True, text=True, timeout=60)
    checks.check("--run names the run to drive", out.returncode == 0 and run.info["run"] in out.stdout, out.stderr)
    environment = {key: value for key, value in os.environ.items() if key != "TMPDIR"}
    out = subprocess.run(cli + ["--run", run.info["folder"], "state"], capture_output=True, text=True, timeout=60, env=environment)
    checks.check("the run is found without TMPDIR set", out.returncode == 0, out.stderr)
    # A folder name of this check's own, so two checks at once do not share it.
    fake = os.path.join(client.runs_folder(), f"check-{os.getpid()}")
    os.makedirs(fake, mode=0o700, exist_ok=True)
    try:
        with open(os.path.join(fake, "info.json"), "w") as f:
            json.dump({"run": "FAKE", "pid": os.getpid(), "socket": "/nonexistent", "protocol": "x"}, f)
        out = subprocess.run(cli + ["state"], capture_output=True, text=True, timeout=60)
        checks.check("with two live runs and no --run, the command line refuses to guess",
                     out.returncode != 0 and "several runs" in out.stderr, out.stderr)
    finally:
        shutil.rmtree(fake, ignore_errors=True)
    out = subprocess.run(cli + ["--run", run.info["folder"], "open", "nope"], capture_output=True, text=True, timeout=60)
    checks.check("a bad request's reason is shown", out.returncode != 0 and "layer" in out.stdout + out.stderr, out.stdout + out.stderr)
    out = subprocess.run(cli + ["--run", run.info["folder"], "type-line", "ffffffff", "x", "--expect", "zsh"],
                         capture_output=True, text=True, timeout=60)
    checks.check("a pane prefix that matches nothing is refused", out.returncode != 0 and "0 panes match" in out.stderr, out.stderr)


def tmux(run, checks):
    if not shutil.which("tmux"):
        checks.section("tmux (skipped: not installed)")
        return
    checks.section("tmux")
    ref = run.panes()[0]["ref"]
    # A tmux server of this run's own (-L), so a check never touches the
    # person's sessions or another run's, and ending it ends only ours.
    server = f"weir-check-{run.info['folder']}"
    try:
        run.type("typeLine", ref, f"tmux -L {server} new -s check")
        in_tmux = run.until(lambda: (run.pane(ref) or {}).get("isInTmux"), 10)
        checks.check("a pane running tmux reads as in tmux at once", in_tmux, run.pane(ref))
        front = (run.pane(ref) or {}).get("foregroundProcess") or "tmux"
        checks.refused("typing into a tmux pane is refused", run.type("typeLine", ref, "echo inside", expect=front), "tmux")
    finally:
        subprocess.run(["tmux", "-L", server, "kill-server"], capture_output=True)
    checks.check("when tmux ends, the pane is a shell again", run.in_front(ref, run.shell, 10), run.pane(ref))


# Each agent's command and its own quit command, sent as a line at its prompt.
AGENTS = {"claude": "/exit", "codex": "/quit", "opencode": "/exit", "agy": "/quit", "kiro-cli": "/quit"}


def launch_arguments(command, folder):
    """What each agent's command needs for the check, after its name.

    Kiro loads hooks only under its v3 engine, as Weir's own launches pass it
    (`AgentKind.startCommand`). The rest keeps away the questions these
    agents ask at launch: whether to trust a folder, which Kiro and `agy` ask
    in each new worktree, and Codex's offer to update itself. The check's
    first prompt would otherwise land in the question, and its Return would
    pick the default answer for the person. Each option holds for this launch
    only and saves nothing in the person's settings.
    """
    if command == "kiro-cli":
        # `--trust-workspace` is `chat`'s option, which `kiro-cli` alone
        # refuses; the shim reports a `chat` launch as it does a bare one.
        return " chat --v3 --trust-workspace"
    if command == "agy":
        return " --settings " + shlex.quote(json.dumps({"trustedWorkspaces": [folder]}))
    if command == "codex":
        return " -c check_for_update_on_startup=false"
    return ""


def agents(run, checks):
    """Each agent in a pane of its own, closed afterwards whatever happened.

    An agent that stops answering (out of model use, say) then stays in a pane
    no later check uses, instead of in front of the shell they all type into.
    The pane's close confirmation is off meanwhile, since only the person
    could answer it.
    """
    first = run.panes()[0]["ref"]
    work = client.repository_root()
    confirm = run.call({"op": "setting", "key": "confirmations.closePane"})["value"]
    run.call({"op": "setting", "key": "confirmations.closePane", "value": "never"})
    try:
        for command in run.agents:
            checks.section(f"agent: {command} (--agents)")
            if not shutil.which(command):
                checks.check(f"{command} is installed", False, "not on PATH")
                continue
            run.call({"op": "command", "name": "splitDown"})
            run.until(lambda: len(run.panes()) == 2, 5)
            ref = next((pane["ref"] for pane in run.panes() if pane["ref"]["id"] != first["id"]), None)
            if not checks.check(f"{command}: a pane of its own opens", ref is not None, run.panes()):
                continue
            run.until(lambda: (run.pane(ref) or {}).get("foregroundProcess") == run.shell, 10)
            try:
                _agent(run, checks, ref, command, work)
            finally:
                run.call({"op": "focus", "pane": ref})
                run.call({"op": "command", "name": "shortcut.closeSurface"})
                checks.check(f"{command}: its pane closes, and the first is left",
                             run.until(lambda: [p["ref"]["id"] for p in run.panes()] == [first["id"]], 10), run.panes())
    finally:
        run.call({"op": "setting", "key": "confirmations.closePane", "value": confirm})


def _agent(run, checks, ref, command, work):
    """Starts the agent, sends it a typed and a pasted prompt, and quits it."""
    quit_line = AGENTS[command]
    run.type("typeLine", ref, f"cd {shlex.quote(work)} && {command}{launch_arguments(command, work)}")
    if not checks.check(f"{command} comes to the front", run.in_front(ref, command), run.pane(ref)):
        return
    time.sleep(4)
    _agent_turn(run, checks, ref, command, "typeLine", "Reply with exactly: one line ok. Do not run any tools.")
    _agent_turn(run, checks, ref, command, "paste", "Reply with exactly: paste ok.\nDo not run any tools.")
    checks.check(f"{command}: no draft is left after the turns", not run.pane(ref)["hasUnsubmittedInput"], run.pane(ref))
    quit_reply = run.call({"op": "quit"})
    checks.refused(f"{command}: quit without force is refused while it runs", quit_reply, "agents are running")
    run.type("typeLine", ref, quit_line, expect=command)
    if not run.in_front(ref, run.shell, 15):
        # Some agents ask once more before they quit.
        run.type("typeLine", ref, quit_line, expect=command)
    checks.check(f"{command}: quits back to the shell", run.in_front(ref, run.shell, 10), run.pane(ref))


def _agent_turn(run, checks, ref, command, op, text):
    """Sends one prompt and waits for its turn to end.

    The wait goes on another connection and starts first, so a fast turn is
    not missed; the agent must be at rest before either, or the wait would
    see the end of a turn still finishing. After the wait, the agent's state
    is one that ends a turn, which is what makes this the prompt's turn.
    """
    at_rest = run.until(lambda: not (run.pane(ref) or {}).get("isMidTurn"), 30)
    checks.check(f"{command}: at rest before the {op}", at_rest, run.pane(ref))
    waiter = run.connect()
    try:
        waiter.sock.sendall((json.dumps({"id": "w", "op": "wait", "until": "turnEnded", "pane": ref, "timeout": 30}) + "\n").encode())
        # The channel has no acknowledgment that the wait sampled its initial
        # state. This delay allows a sample under normal scheduling, and the
        # turn can be missed if registration takes longer.
        time.sleep(0.3)
        sent = run.type(op, ref, text, expect=command)
        if op == "paste" and sent["status"] == "done":
            sent = run.type("submit", ref, expect=command)
        waited = waiter.read() or {"status": "closed"}
    finally:
        waiter.close()
    after = run.pane(ref) or {}
    checks.check(f"{command}: {op} is sent and its turn's end is waited for",
                 sent["status"] == "done" and waited["status"] == "done", (sent, waited))
    checks.check(f"{command}: the turn ended in a state that ends one", after.get("agentState") in ("finished", "error"), after)


def held_paste(run, checks):
    """Last before quitting: it leaves the paste confirmation up, which only the person can answer."""
    checks.section("a paste into a program without bracketed paste")
    ref = run.panes()[0]["ref"]
    run.type("typeLine", ref, "cat")
    checks.check("cat comes to the front", run.in_front(ref, "cat", 5), run.pane(ref))
    reply = run.type("paste", ref, "first line\nsecond line", expect="cat")
    checks.check("the paste is held by the confirmation, not reported done",
                 reply["status"] == "notObservable" and "confirmation" in reply["reason"], reply)
    checks.refused("submit does not send a held paste as the channel's", run.type("submit", ref, expect="cat"), "person")


def posted_keys_on_a_sheet(run, checks):
    """After `held_paste`, whose paste confirmation is the sheet a posted
    Return must never answer: Allow would paste into the program."""
    checks.section("posted keys while a sheet is up (--keys)")
    snapshot = run.call({"op": "state"})["state"]
    window = snapshot["windows"][0]
    checks.check("the paste confirmation is up as a sheet, which holds the keyboard",
                 window["hasSheet"] and (window.get("keyboard") or {}).get("kind") == "sheet", window)
    checks.check("state says a posted key would be dropped there",
                 snapshot["postedKeys"].get("refusal") == "sheet", snapshot["postedKeys"])
    checks.refused("a key is not posted while a sheet is up", client.post_keys(run.info, run.channel, ["return"]), "sheet")
    before = snapshot["postedKeys"]
    client.post_key(run.info["pid"], client.KEY_CODES["return"])

    def seen():
        keys = run.call({"op": "state"})["state"]["postedKeys"]
        return keys if keys["seen"] > before["seen"] else None

    after = run.until(seen, 5)
    checks.check("the app drops a posted Return bound for the sheet, past the client's check",
                 bool(after) and after["dropped"] - before["dropped"] == 1, (before, after))
    time.sleep(1)
    checks.check("...and the confirmation is still up, unanswered", run.call({"op": "state"})["state"]["windows"][0]["hasSheet"])


def quitting(run, checks, keep):
    checks.section("quitting")
    if keep:
        checks.check("left open (--keep)", True)
        return
    folder = os.path.join(client.runs_folder(), run.info["folder"])
    run.channel.close()
    try:
        reply = client.quit_run(run.info)
    except ChannelError as error:
        reply = {"status": "failed", "reason": str(error)}
    checks.check("quit ends the run without a confirmation", reply["status"] == "done", reply)
    checks.check("...and removes its run folder", run.until(lambda: not os.path.exists(folder), 5), folder)


def _make_sure_it_quit(launched, home):
    """Waits for the check's run to exit before its home can be removed."""
    home_path = os.path.realpath(home)
    if launched:
        pid = launched["pid"]
        if client.is_running(pid):
            try:
                client.quit_run(client.find_run(launched["folder"]), force=True)
            except (ChannelError, OSError):
                pass
        pids = {pid}
    else:
        # Launch can time out before it returns a PID. Only inspect real app
        # copies immediately inside this invocation's fresh home.
        try:
            with os.scandir(home_path) as entries:
                pids = {pid for entry in entries if entry.name.endswith(".app") and entry.is_dir(follow_symlinks=False)
                        for pid in client.copy_processes(entry.path)}
        except (OSError, subprocess.SubprocessError) as error:
            raise ChannelError(f"could not confirm the run exited; its home was kept at {home}: {error}") from error

    for pid in sorted(pids):
        if client.is_running(pid):
            copy = client.running_copy(pid)
            if copy is None or os.path.dirname(os.path.realpath(copy)) != home_path:
                if not client.is_running(pid):
                    continue
                raise ChannelError(f"could not identify process {pid} as this run; its home was kept at {home}")
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            except OSError as error:
                raise ChannelError(f"could not end process {pid}; its home was kept at {home}: {error}") from error

    deadline = time.monotonic() + 5
    while any(client.is_running(pid) for pid in pids):
        if time.monotonic() >= deadline:
            raise ChannelError(f"the run did not exit after SIGTERM; its home was kept at {home}")
        time.sleep(0.2)


# MARK: - main


def selected_sections(args, parser):
    sections = [connection, state]
    if args.keys:
        # Early, on the run's first pane as it started: after the commands
        # section has split and closed panes, a pane given the keyboard
        # has been seen to lose it again (not solved yet,
        # docs/verification-channel.md).
        sections += [person_drafts, posted_keys, captures]
    sections += [layers, commands, palette_rows, settings, typing, channel_drafts, paste, waiting, disconnects, command_line, tmux]
    if args.agents:
        sections += [agents]
    # Last: it leaves the paste confirmation up, which only quitting clears.
    sections += [held_paste]
    if args.keys:
        # It needs that confirmation up.
        sections += [posted_keys_on_a_sheet]
    if args.only is not None:
        wanted = set(args.only.split(","))
        if "posted_keys_on_a_sheet" in wanted:
            # It needs the confirmation that section leaves up.
            wanted.add("held_paste")
        available = {section.__name__ for section in sections}
        unknown = wanted - available
        if unknown:
            parser.error(f"--only: unavailable sections {', '.join(sorted(unknown))!r}; "
                         f"available sections: {', '.join(sorted(available))}. "
                         "Enable --keys or --agents for their sections.")
        sections = [section for section in sections if section.__name__ in wanted]
    return sections


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keys", action="store_true", help="also check the person's typing and captures")
    parser.add_argument("--agents", nargs="?", const=",".join(AGENTS), metavar="NAMES",
                        help="also check the coding agents: all, or those named, comma separated (" + ",".join(AGENTS) + ")")
    parser.add_argument("--app", help="the Weir Dev.app to run (default: this checkout's Debug build)")
    parser.add_argument("--keep", action="store_true", help="leave the run open at the end")
    parser.add_argument("--only", help="run only these sections, by function name, comma separated (for working on one)")
    args = parser.parse_args()
    chosen = args.agents.split(",") if args.agents is not None else []
    unknown = [name for name in chosen if name not in AGENTS]
    if unknown:
        parser.error(f"--agents: no agent named {', '.join(repr(name) for name in unknown)}; the names are {', '.join(AGENTS)}")

    sections = selected_sections(args, parser)
    checks = Checks()
    launched = None
    # A fresh data folder each time, so no earlier run's session, settings, or
    # split panes change what these checks see.
    build = os.path.join(client.repository_root(), "build")
    os.makedirs(build, exist_ok=True)
    home = tempfile.mkdtemp(prefix="check-automation-", dir=build)
    scratch = os.path.join(home, "scratch")
    os.makedirs(scratch)
    try:
        launched = client.launch(args.app, home)
        info = dict(client.find_run(launched["folder"]), home=home)
        print(f"run {info['folder']} (pid {info['pid']}), data in {home}")
        run = Run(info, scratch)
        run.until(lambda: run.panes() and run.panes()[0].get("foregroundProcess"), 15)
        run.shell = run.panes()[0].get("foregroundProcess")
        run.agents = chosen
        for section in sections:
            try:
                section(run, checks)
            except Exception as error:  # A section that breaks is one failure, not the end of the run.
                checks.check(f"{section.__name__} ran to its end", False, repr(error))
        quitting(run, checks, args.keep)
    except ChannelError as error:
        checks.check("the run launched and answered", False, str(error))
    finally:
        if not args.keep:
            _make_sure_it_quit(launched, home)
            client.forget_home(home)
            shutil.rmtree(home, ignore_errors=True)
    return 0 if checks.summary() else 1


if __name__ == "__main__":
    sys.exit(main())
