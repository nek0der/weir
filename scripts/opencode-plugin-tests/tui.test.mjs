// Weir's OpenCode plugin on a stream of events: session ownership, turn accounting,
// and failure handling. Most cases stub external calls; plugin lifecycle cases also
// launch a temporary shell helper. OpenCode itself is stubbed throughout.
// `make test` runs this with `node --test`.

import assert from "node:assert/strict"
import { test } from "node:test"
import { chmodSync, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import plugin, {
  bounded,
  createSupervisor,
  FOCUS_ANSWER_LIMIT_MS,
  FOCUS_REQUEST_LIMIT_MS,
  NOT_RECORDED_EXIT,
  SHOWN_TRIES,
  focusRequestPath,
  hookHelperPath,
  hookTimeLimit,
  isSessionTitle,
  autoAcceptsFrom,
  installGate,
  LAUNCHED_KEY,
  notSentMessage,
  paneEnvironment,
  parseDecision,
  shutDown,
  SUPERVISOR_KEY,
  takeFocusRequest,
  writeFocusAnswer,
} from "../../Weir/Resources/opencode-plugin/tui.js"

function harness({
  shown = "ses_a",
  waits = {},
  prepared = true,
  launchPrompt = false,
  launchPreparation,
  autoAccepts = false,
} = {}) {
  const sent = []
  const worktreeCalls = []
  const interrupted = []
  const replies = []
  const running = new Set()
  let clock = 1_000
  let route = shown ? { type: "session", sessionID: shown } : { type: "home" }
  const approvals = []
  const envs = []
  let tabs
  let runCount = 0
  const ctx = {
    ui: { router: { current: () => route }, tabs: { list: () => tabs } },
    data: {
      session: {
        status: (id) => (running.has(id) ? "running" : "idle"),
        get: () => undefined,
        permission: { list: (id) => waits[id] ?? [] },
        form: { list: () => [] },
      },
    },
    client: {
      session: {
        interrupt: async ({ sessionID }) => {
          interrupted.push(sessionID)
        },
      },
      permission: {
        reply: async (body) => {
          replies.push(body)
        },
      },
    },
  }
  const io = {
    now: () => clock,
    sleep: async (ms) => {
      clock += ms
    },
    setTimer: () => {},
    cwd: () => "/repo",
    launchPrompt: () => launchPrompt,
    launchPreparation: () => launchPreparation,
    log: () => {},
    launchRun: () => "LAUNCH",
    autoAccepts: () => autoAccepts,
    newRun: () => `RUN${(runCount += 1)}`,
    hook: async (body, _limit, runEnv) => {
      sent.push(JSON.parse(body))
      envs.push(runEnv)
    },
    worktreeHook: async (body) => {
      worktreeCalls.push(JSON.parse(body))
    },
    prepare: async (body, _limit, runEnv) => {
      sent.push(JSON.parse(body))
      envs.push(runEnv)
      return prepared
    },
    approval: (body, _limit, runEnv) => {
      let finish
      const entry = {
        body: JSON.parse(body),
        runEnv,
        cancelled: false,
        answer: (output) => finish(output),
        result: new Promise((resolve) => {
          finish = resolve
        }),
        cancel: () => {
          entry.cancelled = true
          finish("")
        },
      }
      approvals.push(entry)
      return entry
    },
  }
  const supervisor = createSupervisor(ctx, io)
  const event = async (type, data, extra = {}) => {
    await supervisor.onEvent({ id: "evt", type, created: 1, data, ...extra })
    await supervisor.settled()
  }
  const names = () => sent.map((item) => item.hook_event_name)
  return {
    ctx,
    supervisor,
    event,
    names,
    sent,
    envs,
    io,
    setTabs: (next) => {
      tabs = next.map((sessionID) => ({ sessionID }))
    },
    envOf: (name) => envs[sent.findLastIndex((item) => item.hook_event_name === name)],
    worktreeCalls,
    setWorktreeHook: (hook) => {
      io.worktreeHook = hook
    },
    interrupted,
    replies,
    approvals,
    running,
    show: (next) => {
      route = next ? { type: "session", sessionID: next } : { type: "home" }
    },
    advance: (ms) => {
      clock += ms
    },
    last: (name) => sent.findLast((item) => item.hook_event_name === name),
  }
}

/** Enter in a session, then the events OpenCode sends for it. */
async function submit(h, sessionID, text = "go") {
  await h.supervisor.prepare()
  await h.event("session.inbox.enqueued", {
    sessionID,
    inboxID: `in_${text}`,
    item: { type: "user", payload: { text }, delivery: "steer" },
  })
  await h.event("session.execution.started", { sessionID })
  await h.event("session.inbox.delivered", { sessionID, inboxID: `in_${text}` })
}

test("a turn begins from its Enter and ends with what it added up to", async () => {
  const h = harness()
  await submit(h, "ses_a", "fix it")
  await h.event("session.step.started", {
    sessionID: "ses_a",
    agent: "build",
    model: { id: "m", providerID: "p", variant: "default" },
  })
  const tokens = { input: 10, output: 3, reasoning: 2, cache: { read: 5, write: 1 } }
  await h.event("session.step.ended", { sessionID: "ses_a", tokens })
  await h.event("session.step.ended", { sessionID: "ses_a", tokens })
  await h.event("session.text.ended", { sessionID: "ses_a", text: "Done." })
  await h.event("session.execution.succeeded", { sessionID: "ses_a" })
  assert.deepEqual(h.names(), [
    "weir.prepare",
    "weir.session",
    "session.execution.started",
    "session.step.started",
    "session.execution.succeeded",
  ])
  const started = h.last("session.execution.started")
  assert.equal(started.prompt, "fix it")
  assert.equal(started.preparation, h.last("weir.prepare").preparation)
  const ended = h.last("session.execution.succeeded")
  assert.equal(ended.reply, "Done.")
  assert.deepEqual(ended.usage, { input: 20, output: 6, reasoning: 4, cacheRead: 10, cacheWrite: 2, isPartial: false })
})

test("the settings go only when they change", async () => {
  const h = harness()
  await submit(h, "ses_a")
  const step = (id) =>
    h.event("session.step.started", { sessionID: "ses_a", agent: "build", model: { id, providerID: "p" } })
  await step("m")
  await step("m")
  await step("n")
  assert.deepEqual(
    h.sent.filter((item) => item.hook_event_name === "session.step.started").map((item) => item.data),
    [
      { sessionID: "ses_a", agent: "build", model: { id: "m", providerID: "p" } },
      { sessionID: "ses_a", agent: "build", model: { id: "n", providerID: "p" } },
    ],
  )
})

test("a session another pane drives says nothing here", async () => {
  const h = harness({ shown: "ses_other" })
  await h.event("session.execution.started", { sessionID: "ses_other" })
  await h.event("session.tool.called", { sessionID: "ses_other", id: "t", input: {} })
  await h.event("session.execution.succeeded", { sessionID: "ses_other" })
  assert.deepEqual(h.names(), [])
  h.running.add("ses_other")
  await h.supervisor.stopOwned()
  assert.deepEqual(h.interrupted, [], "closing a pane that only shows a session stops nothing")
})

test("an execution with no Enter is this pane's only with a fresh key press", async () => {
  const h = harness()
  h.supervisor.checkShown()
  await h.supervisor.settled()
  h.sent.length = 0
  h.supervisor.onKey()
  h.advance(5_000)
  await h.event("session.execution.started", { sessionID: "ses_a" })
  assert.deepEqual(h.names(), [], "the key press is too old")
  h.supervisor.onKey()
  await h.event("session.execution.started", { sessionID: "ses_a" })
  assert.deepEqual(h.names(), ["session.execution.started"])
  assert.equal(h.last("session.execution.started").preparation, undefined, "and it has no saved start")
})

test("another pane's new session is not claimed by an input from the home screen", async () => {
  const h = harness({ shown: null })
  await h.supervisor.prepare()
  const preparation = h.last("weir.prepare").preparation
  await h.event("session.execution.started", { sessionID: "ses_theirs" })
  assert.ok(!h.names().includes("session.execution.started"))
  h.show("ses_mine")
  await h.event("session.execution.started", { sessionID: "ses_mine" })
  const starts = h.sent.filter((body) => body.hook_event_name === "session.execution.started")
  assert.equal(starts.length, 1)
  assert.equal(starts[0].data.sessionID, "ses_mine")
  assert.equal(starts[0].preparation, preparation)
  assert.deepEqual(h.envOf("session.execution.started"), {})
})

test("a preparation that failed leaves the turn with no saved start", async () => {
  const h = harness({ prepared: false })
  await submit(h, "ses_a")
  assert.equal(h.last("session.execution.started").preparation, undefined)
})

test("a session in another tab goes on as its own run", async () => {
  const h = harness()
  await submit(h, "ses_a")
  h.show("ses_b")
  await submit(h, "ses_b")
  // A tab is not a nested launch: what launched the process stays as it is.
  assert.deepEqual(h.envOf("session.execution.started"), { WEIR_AGENT_RUN_ID: "RUN1" })
  assert.equal(h.last("weir.session").pane_family, "LAUNCH")
  assert.equal(h.last("session.execution.interrupted"), undefined, "A stays open")
  // What A does behind B still reaches a hook and the helper, under A's run.
  await h.event("session.step.ended", { sessionID: "ses_a", tokens: { input: 7, output: 1 } })
  await h.event("session.step.ended", { sessionID: "ses_b", tokens: { input: 100, output: 10 } })
  await h.event("permission.asked", { id: "per_a", sessionID: "ses_a", action: "shell" })
  assert.deepEqual(h.envOf("permission.asked"), {})
  assert.equal(h.last("permission.asked").data.sessionID, "ses_a")
  assert.deepEqual(h.approvals[0].runEnv, {})
  h.approvals[0].answer('{"decision":"once"}')
  await h.supervisor.settled()
  await new Promise((resolve) => setImmediate(resolve))
  assert.deepEqual(h.replies, [{ sessionID: "ses_a", requestID: "per_a", decision: "once" }])
  await h.event("session.execution.succeeded", { sessionID: "ses_a" })
  const a = h.last("session.execution.succeeded")
  assert.equal(a.data.sessionID, "ses_a")
  assert.equal(a.usage.input, 7)
  assert.deepEqual(h.envOf("session.execution.succeeded"), {})
  assert.equal(h.supervisor.state().turn.sessionID, "ses_b")
  await h.event("session.execution.succeeded", { sessionID: "ses_b" })
  assert.equal(h.last("session.execution.succeeded").usage.input, 100)
  assert.equal(h.envOf("session.execution.succeeded").WEIR_AGENT_RUN_ID, "RUN1")
})

test("the first session takes the launch's run, however it came", async () => {
  const home = harness({ shown: null })
  await home.supervisor.prepare()
  assert.deepEqual(home.envOf("weir.prepare"), {}, "the start is saved under the launch's run")
  home.show("ses_new")
  await home.event("session.execution.started", { sessionID: "ses_new" })
  const starts = home.sent.filter((body) => body.hook_event_name === "session.execution.started")
  assert.equal(starts.length, 1)
  assert.equal(starts[0].data.sessionID, "ses_new")
  assert.equal(starts[0].preparation, home.last("weir.prepare").preparation)
  assert.deepEqual(home.envOf("session.execution.started"), {})
  // The next input on the home screen names a run before its session exists.
  home.show(undefined)
  await home.supervisor.prepare()
  assert.equal(home.envOf("weir.prepare").WEIR_AGENT_RUN_ID, "RUN1")
  home.show("ses_two")
  await home.event("session.execution.started", { sessionID: "ses_two" })
  assert.equal(home.envOf("session.execution.started").WEIR_AGENT_RUN_ID, "RUN1")

  const resumed = harness({ shown: "ses_old" })
  await resumed.supervisor.launch("ses_old")
  await resumed.supervisor.settled()
  assert.deepEqual(resumed.envOf("weir.launch"), {})
  assert.equal(resumed.supervisor.state().runs.get("ses_old"), "LAUNCH")
})

test("the screen is reported on the launch's run when it changes, past the reports", async () => {
  const h = harness()
  await submit(h, "ses_a")
  h.sent.length = 0
  h.envs.length = 0
  h.supervisor.checkShown()
  h.supervisor.checkShown()
  await h.supervisor.settled()
  assert.deepEqual(h.names(), ["weir.shown"], "once")
  assert.equal(h.last("weir.shown").shown_run, "LAUNCH")
  h.show("ses_b")
  h.supervisor.checkShown()
  await h.supervisor.settled()
  assert.deepEqual(h.names().slice(0, 2), ["weir.shown", "weir.shown"], "ahead of what the session reports")
  assert.equal(h.sent[1].shown_run, "RUN1")
  assert.deepEqual(h.envs[1], {}, "on the launch's record")
  const sessionIndex = h.sent.findIndex((body) => body.hook_event_name === "weir.session")
  assert.ok(sessionIndex > 1)
  assert.equal(h.sent[sessionIndex].data.sessionID, "ses_b")
  assert.deepEqual(h.envs[sessionIndex], { WEIR_AGENT_RUN_ID: "RUN1" })
  // Restore the launch record's resume hint after the sibling's start overwrites it.
  const shownIndices = h.sent.flatMap((body, index) => body.hook_event_name === "weir.shown" ? [index] : [])
  assert.equal(shownIndices.length, 3)
  const repeatedIndex = shownIndices[2]
  assert.ok(repeatedIndex > sessionIndex)
  assert.equal(h.sent[repeatedIndex].data.sessionID, "ses_b")
  assert.equal(h.sent[repeatedIndex].shown_run, "RUN1")
  assert.deepEqual(h.envs[repeatedIndex], {})
})

test("a stalled turn snapshot does not block screen reports", { timeout: 5_000 }, async (t) => {
  const h = harness()
  await submit(h, "ses_a")
  let release
  const gate = new Promise((resolve) => (release = resolve))
  t.after(() => release())
  let entered
  const started = new Promise((resolve) => (entered = resolve))
  let reported
  const shown = new Promise((resolve) => (reported = resolve))
  const hook = h.io.hook
  h.io.hook = async (body, limit, env) => {
    const name = JSON.parse(body).hook_event_name
    if (name === "session.execution.succeeded") {
      entered()
      await gate
    }
    await hook(body, limit, env)
    if (name === "weir.shown") reported()
  }
  const ending = h.supervisor.onEvent({ id: "e", type: "session.execution.succeeded", created: 1, data: { sessionID: "ses_a" } })
  await started
  h.sent.length = 0
  h.envs.length = 0
  h.show("ses_b")
  h.supervisor.checkShown()
  await shown
  assert.deepEqual(h.names(), ["weir.shown"], "the screen is reported while the terminal snapshot remains held")
  assert.equal(h.last("weir.shown").shown_run, "RUN1")
  assert.deepEqual(h.envs, [{}])
  release()
  await ending
  await h.supervisor.settled()
})

test("a closed tab ends its run once its turn is over, and reopening revives it", async () => {
  const h = harness()
  h.setTabs(["ses_a", "ses_b"])
  await submit(h, "ses_a")
  h.show("ses_b")
  h.supervisor.checkShown()
  await h.supervisor.settled()
  h.setTabs(["ses_b"])
  h.supervisor.checkShown()
  await h.supervisor.settled()
  assert.equal(h.last("weir.closed"), undefined, "closing a tab leaves its execution running")
  await h.event("session.execution.succeeded", { sessionID: "ses_a" })
  h.supervisor.checkShown()
  await h.supervisor.settled()
  const closed = () => h.sent.filter((body) => body.hook_event_name === "weir.closed").map((body) => body.data.sessionID)
  assert.deepEqual(closed(), ["ses_a"])
  assert.ok(h.names().indexOf("session.execution.succeeded") < h.names().indexOf("weir.closed"))
  assert.deepEqual(h.envOf("weir.closed"), {})
  // The last tab goes.
  h.setTabs([])
  h.show(null)
  h.supervisor.checkShown()
  await h.supervisor.settled()
  assert.deepEqual(closed(), ["ses_a", "ses_b"])
  assert.deepEqual(h.envOf("weir.closed"), { WEIR_AGENT_RUN_ID: "RUN1" })
  h.supervisor.checkShown()
  await h.supervisor.settled()
  assert.deepEqual(closed(), ["ses_a", "ses_b"])
  // Reopened, B reports again, under its own run.
  h.sent.length = 0
  h.envs.length = 0
  h.setTabs(["ses_b"])
  h.show("ses_b")
  h.supervisor.checkShown()
  await h.supervisor.settled()
  const reopened = h.sent.filter((body) => body.hook_event_name === "weir.session")
  assert.equal(reopened.length, 1)
  assert.equal(reopened[0].data.sessionID, "ses_b")
  assert.deepEqual(h.envOf("weir.session"), { WEIR_AGENT_RUN_ID: "RUN1" })
  assert.deepEqual(closed(), [])
  assert.equal(h.last("weir.shown").shown_run, "RUN1")
})

test("going home and back reports the session again", async () => {
  const h = harness()
  await submit(h, "ses_a")
  h.supervisor.checkShown()
  await h.supervisor.settled()
  h.sent.length = 0
  h.show(null)
  h.supervisor.checkShown()
  h.show("ses_a")
  h.supervisor.checkShown()
  await h.supervisor.settled()
  assert.equal(h.last("weir.shown").shown_run, "LAUNCH")
  assert.equal(h.last("weir.shown").shown_home, false)
})

test("a closed tab holding a wait stays a wait until its turn is over", async () => {
  const h = harness()
  h.setTabs(["ses_a", "ses_b"])
  await submit(h, "ses_a")
  h.supervisor.checkShown()
  await h.supervisor.settled()
  await h.event("permission.asked", { id: "per_a", sessionID: "ses_a", action: "shell" })
  h.show("ses_b")
  h.setTabs(["ses_b"])
  h.supervisor.checkShown()
  await h.supervisor.settled()
  assert.equal(h.last("weir.closed"), undefined)
  assert.equal(h.approvals[0].cancelled, false, "the card can still answer it")
  h.approvals[0].answer('{"decision":"once"}')
  await new Promise((resolve) => setImmediate(resolve))
  assert.deepEqual(h.replies, [{ sessionID: "ses_a", requestID: "per_a", decision: "once" }])
  await h.event("permission.replied", { requestID: "per_a", sessionID: "ses_a", reply: "once" })
  assert.equal(h.last("weir.closed"), undefined)
  await h.event("session.execution.succeeded", { sessionID: "ses_a" })
  h.supervisor.checkShown()
  await h.supervisor.settled()
  const closed = h.sent.filter((body) => body.hook_event_name === "weir.closed")
  assert.deepEqual(closed.map((body) => body.data.sessionID), ["ses_a"])
  assert.deepEqual(h.envOf("weir.closed"), {})
})

test("going home reports one explicit home event without a session run", async () => {
  const h = harness()
  await submit(h, "ses_a")
  h.supervisor.checkShown()
  await h.supervisor.settled()
  h.sent.length = 0
  h.show(null)
  h.supervisor.checkShown()
  h.supervisor.checkShown()
  await h.supervisor.settled()
  assert.deepEqual(h.names(), ["weir.shown"])
  assert.equal(h.last("weir.shown").shown_home, true)
  assert.equal(h.last("weir.shown").shown_run, undefined)
})

test("what is on screen is said until it is written, and the latest wins", { timeout: 5_000 }, async () => {
  const h = harness()
  await submit(h, "ses_a")
  await h.supervisor.settled()
  const hook = h.io.hook
  const said = []
  let refusals = 2
  h.io.hook = async (body, limit, env) => {
    const report = JSON.parse(body)
    if (report.hook_event_name !== "weir.shown") return hook(body, limit, env)
    said.push(report.shown_run)
    if (refusals > 0) {
      refusals -= 1
      return NOT_RECORDED_EXIT
    }
    return 0
  }
  h.supervisor.checkShown()
  await h.supervisor.settled()
  assert.deepEqual(said, ["LAUNCH", "LAUNCH", "LAUNCH"], "again until written")
  // Register siblings first so their queued starts cannot add screen reports.
  for (const session of ["ses_b", "ses_c", "ses_a"]) {
    h.show(session)
    h.supervisor.checkShown()
    await h.supervisor.settled()
  }
  said.length = 0
  let release
  const held = new Promise((resolve) => (release = resolve))
  let entered
  const started = new Promise((resolve) => (entered = resolve))
  h.io.hook = async (body, limit, env) => {
    const report = JSON.parse(body)
    if (report.hook_event_name !== "weir.shown") return hook(body, limit, env)
    said.push(report.shown_run)
    if (said.length === 1) {
      entered()
      await held
      return NOT_RECORDED_EXIT
    }
    return 0
  }
  try {
    h.show("ses_b")
    h.supervisor.checkShown()
    await started
    h.show("ses_c")
    h.supervisor.checkShown()
    h.show("ses_a")
    h.supervisor.checkShown()
    assert.deepEqual(said, ["RUN1"], "only one write can be in flight")
  } finally {
    release()
  }
  await h.supervisor.settled()
  assert.deepEqual(said, ["RUN1", "LAUNCH"], "the superseded screen is never written")
})

test("a status that will not change is not said again, nor a fact past its tries", async () => {
  const h = harness()
  const said = []
  let status = 0
  h.io.hook = async (body) => {
    if (JSON.parse(body).hook_event_name === "weir.shown") said.push(body)
    return status
  }
  // Both sessions known, so a switch says only the one thing.
  h.supervisor.checkShown()
  h.show("ses_b")
  h.supervisor.checkShown()
  await h.supervisor.settled()
  said.length = 0
  status = 1
  h.show("ses_a")
  h.supervisor.checkShown()
  await h.supervisor.settled()
  assert.equal(said.length, 1, "a missing helper exits 1, and will again")
  said.length = 0
  status = NOT_RECORDED_EXIT
  h.show("ses_b")
  h.supervisor.checkShown()
  await h.supervisor.settled()
  assert.equal(said.length, SHOWN_TRIES)
  // A new fact starts afresh.
  said.length = 0
  h.show("ses_a")
  h.supervisor.checkShown()
  await h.supervisor.settled()
  assert.equal(said.length, SHOWN_TRIES)
})

test("a screen not written by the end of its tries is said again as the turns are checked", async () => {
  const h = harness()
  h.ctx.client.session.get = async () => ({})
  let status = NOT_RECORDED_EXIT
  const said = []
  h.io.hook = async (body) => {
    if (JSON.parse(body).hook_event_name === "weir.shown") said.push(body)
    return status
  }
  h.supervisor.checkShown()
  await h.supervisor.settled()
  assert.equal(said.length, SHOWN_TRIES)
  said.length = 0
  status = 0
  await h.supervisor.reconcile()
  await h.supervisor.settled()
  assert.equal(said.length, 1, "written now")
  said.length = 0
  await h.supervisor.reconcile()
  await h.supervisor.settled()
  assert.equal(said.length, 0, "and not again")
})

test("no screen-report retry is spawned after quitting", { timeout: 5_000 }, async () => {
  const h = harness()
  const said = []
  let finishSleep
  let enteredSleep
  const sleeping = new Promise((resolve) => (enteredSleep = resolve))
  h.io.sleep = () => new Promise((resolve) => {
    finishSleep = resolve
    enteredSleep()
  })
  h.io.hook = async (body) => {
    if (JSON.parse(body).hook_event_name === "weir.shown") said.push(body)
    return NOT_RECORDED_EXIT
  }
  h.supervisor.checkShown()
  try {
    await sleeping
    assert.equal(said.length, 1)
    await h.supervisor.quit()
  } finally {
    finishSleep?.()
    await h.supervisor.settled()
  }
  assert.equal(said.length, 1)
})

test("a launch with --auto says so, on the launch and every session", async () => {
  const h = harness({ autoAccepts: true })
  await h.supervisor.launch(undefined)
  await submit(h, "ses_a")
  h.show("ses_b")
  await submit(h, "ses_b")
  assert.equal(h.last("weir.launch").auto_accept, true)
  assert.deepEqual(
    h.sent.filter((item) => item.hook_event_name === "weir.session")
      .map((item) => [item.data.sessionID, item.auto_accept]),
    [["ses_a", true], ["ses_b", true]],
  )
  assert.deepEqual(h.envOf("session.execution.started"), { WEIR_AGENT_RUN_ID: "RUN1" })
})

test("an approval goes to the card whole, or not at all", async () => {
  const h = harness()
  await submit(h, "ses_a")
  const long = "x".repeat(20_000)
  await h.event("permission.asked", { id: "per_1", sessionID: "ses_a", action: "shell", resources: [long, "b"] })
  assert.deepEqual(h.approvals[0].body.data.resources, [long, "b"], "nothing cut, nothing dropped")
  const huge = "y".repeat(1_000_000)
  await h.event("permission.asked", { id: "per_2", sessionID: "ses_a", action: "shell", resources: [huge] })
  assert.equal(h.approvals.length, 1, "too large for the helper: OpenCode's prompt only")
})

for (const delivery of ["steer", "queue"]) {
  test(`an input sent from another pane while a session works joins that pane's turn (${delivery}, recorded)`, async () => {
    const recorded = JSON.parse(
      readFileSync(new URL("./fixtures/two-panes-input-while-busy.json", import.meta.url), "utf8").replaceAll("DELIVERY", delivery),
    )
    const replay = async (h, steps) => {
      h.supervisor.checkShown()
      await h.supervisor.settled()
      for (const step of steps) {
        if (step.prepare) await h.supervisor.prepare()
        else if (step.keys) for (let key = 0; key < step.keys; key += 1) h.supervisor.onKey()
        else await h.event(step.type, step.data)
        h.advance(500)
      }
      await h.supervisor.settled()
    }
    const right = harness({ shown: "ses_q" })
    await replay(right, recorded.right)
    const left = harness({ shown: "ses_q" })
    await replay(left, recorded.left)
    // One execution, the right pane's: its turn runs until the queued input is answered.
    assert.deepEqual(right.names().filter((name) => name.startsWith("session.execution")), [
      "session.execution.started",
      "session.execution.succeeded",
    ])
    assert.equal(right.last("session.execution.started").prompt, "SLOW 12")
    assert.deepEqual(left.names().filter((name) => name.startsWith("session.execution")), [], "no turn of its own")
    assert.equal(left.supervisor.state().running.size, 0, "nothing for closing the left pane to stop")
  })
}

test("--auto is read as its command line reads it", () => {
  assert.equal(autoAcceptsFrom(["opencode", "--auto"]), true)
  assert.equal(autoAcceptsFrom(["opencode", "--auto=true"]), true)
  assert.equal(autoAcceptsFrom(["opencode", "--auto", "--session", "s"]), true)
  assert.equal(autoAcceptsFrom(["opencode", "--auto", "false"]), false)
  assert.equal(autoAcceptsFrom(["opencode", "--auto=false"]), false)
  assert.equal(autoAcceptsFrom(["opencode", "--auto", "--no-auto"]), false)
  assert.equal(autoAcceptsFrom(["opencode"]), false)
})

test("the Enter gate leaves single-line dialog inputs alone", () => {
  const supervisor = { prepare: async () => {}, discardPreparation: () => {} }
  let layer
  const ctx = {
    keymap: { shortcuts: () => ["return"], layer: (make) => (layer = make()), dispatch: () => {} },
    ui: { router: { current: () => ({ type: "session", sessionID: "ses_a" }) } },
    data: { session: { status: () => "idle", permission: { list: () => [] }, form: { list: () => [] } } },
    renderer: { currentFocusedRenderable: { plainText: "find" } },
  }
  installGate(ctx, supervisor)
  assert.equal(layer.enabled(), true, "the prompt's words")
  class InputRenderable {}
  ctx.renderer.currentFocusedEditor = new InputRenderable()
  assert.equal(layer.enabled(), false, "a dialog's filter")
  ctx.renderer.currentFocusedEditor = { singleLine: true }
  assert.equal(layer.enabled(), false, "one line, however it is named")
  ctx.renderer.currentFocusedEditor = { singleLine: false }
  assert.equal(layer.enabled(), true)
})

test("a fork is a session of its own, not a subagent", async () => {
  const h = harness()
  await submit(h, "ses_a")
  await h.event("session.forked", { sessionID: "ses_fork", parentID: "ses_a" })
  h.show("ses_fork")
  h.supervisor.checkShown()
  await h.supervisor.settled()
  assert.equal(h.last("weir.shown").data.sessionID, "ses_fork")
  await submit(h, "ses_fork")
  assert.equal(h.last("session.execution.started").data.sessionID, "ses_fork")
  assert.deepEqual(h.envOf("session.execution.started"), { WEIR_AGENT_RUN_ID: "RUN1" })
  await h.event("session.execution.succeeded", { sessionID: "ses_fork" })
  assert.equal(h.last("session.execution.succeeded").data.sessionID, "ses_fork")
  assert.deepEqual(h.envOf("session.execution.succeeded"), { WEIR_AGENT_RUN_ID: "RUN1" })
  await h.event("session.execution.succeeded", { sessionID: "ses_a" })
  assert.equal(h.last("session.execution.succeeded").data.sessionID, "ses_a")
  assert.deepEqual(h.envOf("session.execution.succeeded"), {})
})

test("a session's name is told from OpenCode's stand-in for one", () => {
  assert.equal(isSessionTitle("Fix login"), true)
  assert.equal(isSessionTitle("New session - 2026-11-02T03:04:05.678Z"), false)
  assert.equal(isSessionTitle("Child session - 2026-11-02T03:04:05.678Z"), false)
  assert.equal(isSessionTitle("New session"), true, "a name a person gave")
  assert.equal(isSessionTitle(""), false)
  assert.equal(isSessionTitle(undefined), false)
})

test("a resumed session's name is reported with it, and the stand-in never", async () => {
  const h = harness()
  h.ctx.client.session.get = async ({ sessionID }) =>
    sessionID === "ses_a"
      ? { title: "STUB", model: { id: "m", providerID: "p" }, agent: "build" }
      : { title: "New session - 2026-11-02T03:04:05.678Z" }
  await h.supervisor.launch("ses_a")
  await h.supervisor.settled()
  assert.equal(h.last("weir.title").title, "STUB")
  assert.equal(h.last("weir.title").data.sessionID, "ses_a")
  // A session brought onto the screen from OpenCode's own list, or a tab reopened.
  h.sent.length = 0
  h.envs.length = 0
  h.ctx.client.session.get = async () => ({ title: "Older work" })
  h.show("ses_old")
  h.supervisor.checkShown()
  await h.supervisor.settled()
  assert.equal(h.last("weir.title").title, "Older work")
  assert.deepEqual(h.envOf("weir.title"), { WEIR_AGENT_RUN_ID: "RUN1" })
  // A new session's stand-in says nothing, nor does a rename to it.
  h.sent.length = 0
  h.ctx.client.session.get = async () => ({ title: "New session - 2026-11-02T03:04:05.678Z" })
  h.show("ses_new")
  h.supervisor.checkShown()
  await h.event("session.renamed", { sessionID: "ses_new", title: "New session - 2026-11-02T03:04:05.678Z" })
  await h.supervisor.settled()
  assert.equal(h.last("weir.title"), undefined)
})

test("a hook is told a time a little short of the wait for it", () => {
  assert.equal(hookTimeLimit(10_000), "8000")
  assert.equal(hookTimeLimit(600_000), "598000")
  assert.equal(hookTimeLimit(1_500), "1200")
  assert.equal(hookTimeLimit(500), "1000")
})

test("a command cut to fit says it is not whole", async () => {
  const h = harness()
  await submit(h, "ses_a")
  const long = `git worktree add -b x /wt/x ${" ".repeat(9_000)}; true`
  await h.event("session.tool.called", { sessionID: "ses_a", id: "t1", name: "shell", input: { command: long } })
  await h.event("session.tool.success", { sessionID: "ses_a", id: "t1", name: "shell" })
  assert.equal(h.last("session.tool.success").command_complete, false)
  await h.event("session.tool.called", { sessionID: "ses_a", id: "t2", name: "shell", input: { command: "git status" } })
  await h.event("session.tool.success", { sessionID: "ses_a", id: "t2", name: "shell" })
  assert.equal(h.last("session.tool.success").command_complete, true)
})

test("a focus request brings a session of this pane forward, and only that", () => {
  const h = harness()
  const focused = []
  h.ctx.ui.tabs.focus = (id) => focused.push(id)
  h.supervisor.checkShown()
  const ask = (sessionId, at = 1_000) => {
    h.io.takeFocusRequest = () => ({ sessionId, at })
    h.supervisor.checkFocus()
  }
  ask("ses_a")
  assert.deepEqual(focused, ["ses_a"])
  ask("ses_foreign")
  assert.deepEqual(focused, ["ses_a"], "nothing this pane has to do with")
  h.advance(FOCUS_REQUEST_LIMIT_MS + 1)
  ask("ses_a")
  assert.deepEqual(focused, ["ses_a"], "too old: the person has moved on")
})

test("a request with a nonce is answered with the route read then", () => {
  const h = harness()
  h.supervisor.checkShown()
  const answers = []
  h.io.answerFocus = (answer) => answers.push(answer)
  const timers = []
  h.io.setTimer = (work) => timers.push(work)
  h.ctx.ui.tabs.focus = () => {}
  h.io.takeFocusRequest = () => ({ sessionId: "ses_a", nonce: "n1", at: 1_000 })
  h.supervisor.checkFocus()
  assert.deepEqual(answers, [{ nonce: "n1", sessionId: "ses_a", rootSessionId: "ses_a" }])

  // Not there yet: it is looked at again until it is, and not before.
  answers.length = 0
  h.show("ses_b")
  h.supervisor.checkShown()
  h.io.takeFocusRequest = () => ({ sessionId: "ses_a", nonce: "n2", at: 1_000 })
  h.supervisor.checkFocus()
  assert.deepEqual(answers, [])
  h.show("ses_a")
  timers.shift()()
  assert.deepEqual(answers, [{ nonce: "n2", sessionId: "ses_a", rootSessionId: "ses_a" }])

  // Never there: it says what is on screen, which the paste refuses.
  answers.length = 0
  h.show("ses_b")
  h.io.takeFocusRequest = () => ({ sessionId: "ses_a", nonce: "n3", at: 1_000 })
  h.supervisor.checkFocus()
  h.advance(FOCUS_ANSWER_LIMIT_MS + 1)
  timers.shift()()
  assert.deepEqual(answers, [{ nonce: "n3", sessionId: "ses_b", rootSessionId: "ses_b" }])

  // No session named, from home: no session is the answer.
  answers.length = 0
  h.show(null)
  h.io.takeFocusRequest = () => ({ nonce: "n4", at: h.io.now() })
  h.supervisor.checkFocus()
  assert.deepEqual(answers, [{ nonce: "n4", sessionId: null, rootSessionId: null }])

  // A subagent's view says so: its route and its root apart.
  answers.length = 0
  h.ctx.data.session.root = (id) => (id === "ses_child" ? "ses_a" : id)
  h.show("ses_child")
  h.io.takeFocusRequest = () => ({ nonce: "n6", at: h.io.now() })
  h.supervisor.checkFocus()
  assert.deepEqual(answers, [{ nonce: "n6", sessionId: "ses_child", rootSessionId: "ses_a" }])
  h.ctx.data.session.root = undefined

  // One this pane does not have is answered at once.
  answers.length = 0
  h.show("ses_a")
  h.io.takeFocusRequest = () => ({ sessionId: "ses_foreign", nonce: "n5", at: h.io.now() })
  h.supervisor.checkFocus()
  assert.deepEqual(answers, [{ nonce: "n5", sessionId: "ses_a", rootSessionId: "ses_a" }])
})

test("a focus request file is taken once, whole, and can only name a session", (t) => {
  const directory = mkdtempSync(join(tmpdir(), "weir-focus-"))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  const path = join(directory, "PANE.json")
  writeFileSync(path, JSON.stringify({ sessionId: "ses_abc123", nonce: "N-1", at: 5 }))
  assert.deepEqual(takeFocusRequest(path), { sessionId: "ses_abc123", nonce: "N-1", at: 5 })
  assert.equal(takeFocusRequest(path), undefined)
  for (const body of [
    '{"sessionId":"../../etc","at":5}',
    '{"sessionId":"ses_a","nonce":"a b","at":5}',
    '{"sessionId":"ses_a"}',
    "not json",
    "",
    "x".repeat(2000),
  ]) {
    writeFileSync(path, body)
    assert.equal(takeFocusRequest(path), undefined, body)
  }
  assert.deepEqual(readdirSync(directory), [], "nothing left behind")
  assert.equal(takeFocusRequest(undefined), undefined)
  writeFocusAnswer(path, { nonce: "N", sessionId: null })
  assert.deepEqual(JSON.parse(readFileSync(`${path}.N.answer`, "utf8")), { nonce: "N", sessionId: null })
  const run = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaa1"
  assert.ok(
    focusRequestPath({ WEIR_OPENCODE_SESSIONS_DIR: "/a/sessions", WEIR_PANE_ID: "P", WEIR_AGENT_RUN_ID: run }).endsWith(
      `/a/tab-focus/${run.toUpperCase()}.json`,
    ),
    "named for the process, not the pane",
  )
  assert.equal(focusRequestPath({ WEIR_OPENCODE_SESSIONS_DIR: "/a/sessions", WEIR_AGENT_RUN_ID: "../x" }), undefined)
  assert.equal(statSync(`${path}.N.answer`).mode & 0o777, 0o600)
  assert.deepEqual(readdirSync(directory), ["PANE.json.N.answer"])
})

test("a new session's report comes before its start, whichever asked first", async () => {
  for (const screenFirst of [false, true]) {
    const h = harness({ shown: null })
    h.supervisor.checkShown()
    await h.supervisor.prepare()
    h.show("ses_new")
    if (screenFirst) h.supervisor.checkShown()
    const starting = h.supervisor.onEvent({ id: "e", type: "session.execution.started", created: 1, data: { sessionID: "ses_new" } })
    if (!screenFirst) h.supervisor.checkShown()
    await starting
    await h.supervisor.settled()
    const reports = h.sent.filter((body) => body.hook_event_name === "weir.session" || body.hook_event_name === "session.execution.started")
    assert.deepEqual(reports.map((body) => [body.hook_event_name, body.data.sessionID]), [
      ["weir.session", "ses_new"], ["session.execution.started", "ses_new"],
    ], `screenFirst=${screenFirst}`)
    assert.deepEqual(h.envOf("weir.session"), {})
    assert.deepEqual(h.envOf("session.execution.started"), {})
  }
})

test("an input that never made a session gives the launch's run back", async () => {
  const timers = []
  const h = harness({ shown: null })
  h.io.setTimer = (work) => timers.push(work)
  await h.supervisor.prepare()
  timers.shift()()
  h.show("ses_a")
  h.supervisor.checkShown()
  await h.supervisor.settled()
  assert.equal(h.last("weir.shown").shown_run, "LAUNCH", "no second run beside an empty one")
  // Nor does taking it back spend the next input's.
  h.show(null)
  h.supervisor.checkShown()
  await h.supervisor.prepare()
  h.supervisor.discardPreparation()
  await h.supervisor.prepare()
  assert.deepEqual(h.envOf("weir.prepare"), { WEIR_AGENT_RUN_ID: "RUN2" })
})

test("a compaction-only turn's end waits for the session's report when quitting", { timeout: 5_000 }, async (t) => {
  const h = harness()
  let release
  const gate = new Promise((resolve) => (release = resolve))
  t.after(() => release())
  let began
  const started = new Promise((resolve) => (began = resolve))
  const order = []
  h.io.hook = async (body) => {
    const name = JSON.parse(body).hook_event_name
    if (name === "weir.session") {
      began()
      await gate
    }
    order.push(name)
  }
  await h.event("session.inbox.enqueued", {
    sessionID: "ses_a",
    inboxID: "in_c",
    item: { type: "compaction", payload: {}, delivery: "steer" },
  })
  h.supervisor.checkShown()
  h.supervisor.onKey()
  await h.supervisor.onEvent({ id: "e", type: "session.execution.started", created: 1, data: { sessionID: "ses_a" } })
  await h.supervisor.onEvent({ id: "e2", type: "session.compaction.started", created: 1, data: { sessionID: "ses_a", reason: "manual" } })
  assert.equal(h.supervisor.state().turn?.isCompactionOnly, true)
  assert.equal(h.supervisor.state().turn?.isCompacting, true)
  await started
  const quitting = h.supervisor.quit()
  await new Promise((resolve) => setImmediate(resolve))
  assert.equal(order.includes("session.compaction.failed"), false, "the end must wait for the session report")
  release()
  await quitting
  await h.supervisor.settled()
  const session = order.indexOf("weir.session")
  const failed = order.indexOf("session.compaction.failed")
  assert.equal(order.filter((name) => name === "session.compaction.failed").length, 1)
  assert.ok(session >= 0 && failed > session, order.join())
})

test("the run is reserved before the wait, shared by the prepare, the screen, and the start", async () => {
  const h = harness({ shown: null })
  let finish
  const prepared = new Promise((resolve) => (finish = resolve))
  h.io.prepare = async (body, _limit, runEnv) => {
    h.sent.push(JSON.parse(body))
    h.envs.push(runEnv)
    await prepared
    return true
  }
  // The launch's run went to a session on another tab first.
  h.show("ses_old")
  h.supervisor.checkShown()
  h.show(null)
  h.supervisor.checkShown()
  const preparing = h.supervisor.prepare()
  assert.equal(h.envOf("weir.prepare").WEIR_AGENT_RUN_ID, "RUN1", "named before the wait")
  finish()
  await preparing
  // The screen reaches the new session before its start's event does.
  h.show("ses_new")
  h.supervisor.checkShown()
  await h.supervisor.settled()
  assert.equal(h.last("weir.shown").shown_run, "RUN1")
  await h.event("session.execution.started", { sessionID: "ses_new" })
  assert.equal(h.envOf("session.execution.started").WEIR_AGENT_RUN_ID, "RUN1")
  const generation = h.last("weir.prepare").preparation
  assert.match(generation, /^[0-9a-f-]{36}$/i)
  assert.equal(h.last("session.execution.started").preparation, generation, "the start saved is its own")
})

test("an input waiting on the home screen does not take what a known session goes on with", async () => {
  const h = harness()
  await submit(h, "ses_a")
  await h.event("session.inbox.enqueued", {
    sessionID: "ses_a",
    inboxID: "in_syn",
    item: { type: "synthetic", payload: { text: "more" }, delivery: "steer" },
  })
  await h.event("session.execution.succeeded", { sessionID: "ses_a" })
  h.show(null)
  h.supervisor.checkShown()
  await h.supervisor.prepare()
  const generation = h.last("weir.prepare").preparation
  await h.event("session.execution.started", { sessionID: "ses_a" })
  const started = h.last("session.execution.started")
  assert.equal(started.preparation, undefined, "the home input's start stays for its session")
  assert.equal(h.supervisor.state().preparation.expected, true)
  assert.equal(h.supervisor.state().preparation.generation, generation)
  assert.equal(started.prompt_kind, "synthetic")
  assert.deepEqual(h.envOf("session.execution.started"), {})
  h.show("ses_new")
  h.supervisor.checkShown()
  await h.event("session.execution.started", { sessionID: "ses_new" })
  assert.equal(h.last("session.execution.started").data.sessionID, "ses_new")
  assert.equal(h.last("session.execution.started").preparation, generation)
  assert.deepEqual(h.envOf("session.execution.started"), { WEIR_AGENT_RUN_ID: "RUN1" })
  assert.equal(h.supervisor.state().preparation, undefined)
})

test("the key that moved to a tab claims nothing another pane starts there", async () => {
  const h = harness()
  await submit(h, "ses_a")
  await h.event("session.execution.succeeded", { sessionID: "ses_a" })
  h.supervisor.checkShown()
  h.supervisor.onKey()
  h.show("ses_b")
  await h.event("session.execution.started", { sessionID: "ses_b" })
  assert.equal(h.supervisor.state().turns.has("ses_b"), false, "before the screen is read")
  h.supervisor.checkShown()
  await h.supervisor.settled()
  await h.event("session.execution.started", { sessionID: "ses_b" })
  assert.equal(h.supervisor.state().turns.has("ses_b"), false, "after it too")
  // A key with the tab already on screen is the person's.
  h.supervisor.onKey()
  await h.event("session.execution.started", { sessionID: "ses_b" })
  assert.equal(h.supervisor.state().turns.has("ses_b"), true)
})

test("a key on the home screen claims the session it made, not one it moved to", async () => {
  const h = harness({ shown: null })
  h.supervisor.checkShown()
  h.supervisor.onKey()
  h.show("ses_old")
  await h.event("session.execution.started", { sessionID: "ses_old" })
  assert.equal(h.supervisor.state().turns.has("ses_old"), false)
  h.show(null)
  h.supervisor.checkShown()
  h.supervisor.onKey()
  await h.event("session.created", { sessionID: "ses_new" })
  h.show("ses_new")
  await h.event("session.execution.started", { sessionID: "ses_new" })
  assert.equal(h.supervisor.state().turns.has("ses_new"), true)
})

test("quitting does not let an end overtake its own start", { timeout: 5_000 }, async (t) => {
  const h = harness()
  const order = []
  let release
  const gate = new Promise((resolve) => (release = resolve))
  t.after(() => release())
  let entered
  const started = new Promise((resolve) => (entered = resolve))
  h.io.hook = async (body) => {
    const name = JSON.parse(body).hook_event_name
    if (name === "weir.session") {
      entered()
      await gate
    }
    order.push(name)
  }
  await h.supervisor.prepare()
  const starting = h.supervisor.onEvent({ id: "e", type: "session.execution.started", created: 1, data: { sessionID: "ses_a" } })
  await started
  const quitting = h.supervisor.quit()
  assert.deepEqual(order, [], "the start's session report is still held")
  release()
  await starting
  await quitting
  await h.supervisor.settled()
  assert.deepEqual(order, ["weir.session", "session.execution.started", "session.execution.interrupted"])
})

test("quitting ends every open turn, under its own run", async () => {
  const h = harness()
  await submit(h, "ses_a")
  h.show("ses_b")
  await submit(h, "ses_b")
  await h.supervisor.settled()
  h.sent.length = 0
  h.envs.length = 0
  await h.supervisor.quit()
  assert.deepEqual(h.names(), ["session.execution.interrupted", "session.execution.interrupted"])
  assert.deepEqual(h.envs, [{}, { WEIR_AGENT_RUN_ID: "RUN1" }])
  assert.deepEqual(h.sent.map((body) => [body.data.sessionID, body.data.reason, body.usage.isPartial]), [
    ["ses_a", "quit", true], ["ses_b", "quit", true],
  ])
  assert.equal(h.supervisor.state().turns.size, 0)
})

test("a title between turns is reported alone", async () => {
  const h = harness()
  await submit(h, "ses_a")
  await h.event("session.execution.succeeded", { sessionID: "ses_a" })
  assert.equal(h.last("session.execution.succeeded").data.sessionID, "ses_a")
  h.sent.length = 0
  h.envs.length = 0

  await h.event("session.renamed", { sessionID: "ses_a", title: "Fix login" })
  assert.deepEqual(h.names(), ["weir.title"])
  assert.deepEqual(h.last("weir.title").data, { sessionID: "ses_a" })
  assert.equal(h.last("weir.title").title, "Fix login")
  assert.deepEqual(h.envs, [{}])

  await h.event("session.renamed", { sessionID: "ses_other", title: "Not ours" })
  assert.deepEqual(h.names(), ["weir.title"])
  assert.equal(h.last("weir.title").title, "Fix login")
})

test("a subagent's end does not end the turn, and what it used counts", async () => {
  const h = harness()
  await submit(h, "ses_a")
  await h.event("session.created", { sessionID: "ses_kid", parentID: "ses_a" })
  await h.event("session.execution.started", { sessionID: "ses_kid" })
  await h.event("session.tool.called", { sessionID: "ses_kid", id: "t", input: {} })
  await h.event("session.step.ended", {
    sessionID: "ses_kid",
    tokens: { input: 7, output: 1, reasoning: 0, cache: { read: 0, write: 0 } },
  })
  await h.event("session.text.ended", { sessionID: "ses_kid", text: "the subagent's words" })
  await h.event("session.execution.succeeded", { sessionID: "ses_kid" })
  assert.equal(h.last("session.execution.succeeded"), undefined)
  assert.equal(h.last("session.tool.called"), undefined)
  await h.event("session.execution.succeeded", { sessionID: "ses_a" })
  const ended = h.last("session.execution.succeeded")
  assert.equal(ended.usage.input, 7)
  assert.equal(ended.reply, undefined)
})

test("a wait-clearing reply is forwarded only after the last pending approval is allowed", async () => {
  const h = harness()
  await submit(h, "ses_a")
  await h.event("permission.asked", { id: "per_1", sessionID: "ses_a", action: "shell", resources: ["a"] })
  await h.event("permission.asked", { id: "per_2", sessionID: "ses_a", action: "shell", resources: ["b"] })
  await h.event("permission.replied", { requestID: "per_1", sessionID: "ses_a", reply: "once" })
  assert.equal(h.last("permission.replied"), undefined)
  await h.event("permission.replied", { requestID: "per_2", sessionID: "ses_a", reply: "reject" })
  assert.equal(h.last("permission.replied"), undefined)
  await h.event("permission.asked", { id: "per_3", sessionID: "ses_a", action: "shell", resources: ["c"] })
  await h.event("permission.replied", { requestID: "per_3", sessionID: "ses_a", reply: "once" })
  const replies = h.sent.filter((event) => event.hook_event_name === "permission.replied")
  assert.equal(replies.length, 1)
  assert.deepEqual(replies[0].data, { requestID: "per_3", sessionID: "ses_a", reply: "once" })
  assert.deepEqual(h.approvals.map((approval) => approval.cancelled), [true, true, true])
})

test("the card's answer goes to OpenCode, and the pane's answer withdraws the card", async () => {
  const h = harness()
  await submit(h, "ses_a")
  await h.event("permission.asked", { id: "per_1", sessionID: "ses_a", action: "shell", resources: ["a"] })
  assert.equal(h.approvals.length, 1)
  h.approvals[0].answer('{"decision":"once"}\n')
  await h.supervisor.settled()
  await new Promise((resolve) => setImmediate(resolve))
  assert.deepEqual(h.replies, [{ sessionID: "ses_a", requestID: "per_1", decision: "once" }])

  await h.event("permission.asked", { id: "per_2", sessionID: "ses_a", action: "shell", resources: ["b"] })
  await h.event("permission.replied", { requestID: "per_2", sessionID: "ses_a", reply: "reject" })
  assert.equal(h.approvals[1].cancelled, true)
  assert.equal(h.replies.length, 1)
})

test("no answer from the helper leaves the person to OpenCode's own prompt", async () => {
  const h = harness()
  await submit(h, "ses_a")
  await h.event("permission.asked", { id: "per_1", sessionID: "ses_a", action: "shell", resources: ["a"] })
  h.approvals[0].answer("")
  await new Promise((resolve) => setImmediate(resolve))
  assert.deepEqual(h.replies, [])
})

test("the end of a turn withdraws a card still up", async () => {
  const h = harness()
  await submit(h, "ses_a")
  await h.event("permission.asked", { id: "per_1", sessionID: "ses_a", action: "shell", resources: ["a"] })
  await h.event("session.execution.interrupted", { sessionID: "ses_a", reason: "user" })
  assert.equal(h.approvals[0].cancelled, true)
})

test("a manual compaction opens no turn", async () => {
  const h = harness()
  await submit(h, "ses_a")
  await h.event("session.execution.succeeded", { sessionID: "ses_a" })
  h.sent.length = 0
  await h.event("session.inbox.enqueued", {
    sessionID: "ses_a",
    inboxID: "in_c",
    item: { type: "compaction", payload: {}, delivery: "steer" },
  })
  await h.event("session.execution.started", { sessionID: "ses_a" })
  await h.event("session.compaction.started", { sessionID: "ses_a", reason: "manual" })
  await h.event("session.compaction.ended", { sessionID: "ses_a", reason: "manual", text: "long", tokens: {} })
  assert.deepEqual(h.names(), ["session.compaction.started", "session.compaction.ended"])
  h.sent.length = 0
  await h.event("session.execution.succeeded", { sessionID: "ses_a" })
  assert.deepEqual(h.names(), [])
})

test("a tool's end carries the command its start named, for the turn's checks", async () => {
  const h = harness()
  await submit(h, "ses_a")
  await h.event("session.tool.input.started", { sessionID: "ses_a", id: "t", name: "shell" })
  await h.event("session.tool.called", { sessionID: "ses_a", id: "t", input: { command: "cargo test" } })
  await h.event("session.tool.success", {
    sessionID: "ses_a",
    id: "t",
    content: [{ type: "text", text: "x".repeat(10_000) }],
    metadata: { exit: 1 },
  })
  const ended = h.last("session.tool.success")
  assert.equal(ended.data.name, "shell")
  assert.equal(ended.command, "cargo test")
  assert.equal(ended.data.content, undefined, "the model's copy of the output stays out")
  assert.equal(ended.data.metadata.exit, 1)
})

test("a running turn is closed by what the service says of it, never as a success it did not see", async () => {
  const cases = [
    [{ time: { busy: 2, idle: 1 } }, undefined],
    [{ time: { busy: 1, idle: 2 }, outcome: "succeeded" }, "session.execution.succeeded"],
    [{ time: { busy: 1, idle: 2 }, outcome: "failed" }, "session.execution.failed"],
    [{ time: { busy: 1, idle: 2 }, outcome: "interrupted" }, "session.execution.interrupted"],
    [{ time: { busy: 1, idle: 2 } }, "session.execution.interrupted"],
  ]
  for (const [info, name] of cases) {
    const h = harness()
    await submit(h, "ses_a")
    h.ctx.client.session.get = async () => info
    await h.supervisor.reconcile()
    await h.supervisor.settled()
    const lifecycle = h.sent.filter((body) => body.hook_event_name.startsWith("session.execution."))
    assert.deepEqual(lifecycle.map((body) => [body.hook_event_name, body.data.sessionID]), [
      ["session.execution.started", "ses_a"], ...(name ? [[name, "ses_a"]] : []),
    ], JSON.stringify(info))
    if (name) {
      const ended = lifecycle[1]
      assert.equal(ended.usage.isPartial, true, JSON.stringify(info))
      assert.deepEqual(h.envOf(name), {})
      if (name === "session.execution.failed") assert.deepEqual(ended.data.error, { type: "unknown", message: "" })
      if (name === "session.execution.interrupted") assert.equal(ended.data.reason, "reconciled")
      assert.equal(h.supervisor.state().turn, undefined)
      await h.supervisor.reconcile()
      await h.supervisor.settled()
      assert.equal(h.sent.filter((body) => body.hook_event_name.startsWith("session.execution.")).length, 2)
    } else {
      assert.equal(h.supervisor.state().turn.sessionID, "ses_a", "still running")
    }
  }
})

test("a report that fails does not stop the ones after it", async () => {
  const h = harness()
  const original = h.sent.push.bind(h.sent)
  let failures = 1
  h.sent.push = (item) => {
    if (failures > 0) {
      failures -= 1
      throw new Error("hook gone")
    }
    return original(item)
  }
  await h.supervisor.launch(undefined)
  await submit(h, "ses_a")
  assert.ok(h.names().includes("session.execution.started"))
})

test("a huge reply cannot sink the report that ends the turn", async () => {
  for (const text of ["y".repeat(5 * 1024 * 1024), "\0".repeat(256 * 1024)]) {
    const h = harness()
    await submit(h, "ses_a")
    await h.event("session.step.ended", { sessionID: "ses_a", tokens: { input: 7, output: 3 } })
    await h.event("session.text.ended", { sessionID: "ses_a", text })
    await h.event("session.execution.succeeded", { sessionID: "ses_a" })
    const reports = h.sent.filter((body) => body.hook_event_name === "session.execution.succeeded")
    assert.equal(reports.length, 1)
    const ended = reports[0]
    assert.equal(ended.data.sessionID, "ses_a")
    assert.equal(ended.usage.input, 7)
    assert.equal(ended.usage.output, 3)
    assert.deepEqual(h.envOf("session.execution.succeeded"), {})
    if (text.startsWith("\0")) assert.equal(ended.reply, undefined, "JSON escaping exceeds the payload budget")
    else assert.equal(ended.reply, "y".repeat(256 * 1024))
    assert.ok(Buffer.byteLength(JSON.stringify(ended)) < 1024 * 1024)
  }
})

test("bounded preserves values within its string, depth, and entry limits", () => {
  assert.equal(bounded("abc", 2), "ab")
  assert.equal(bounded("ab", 2), "ab")
  const nested = { a: { b: { c: { d: { e: { leaf: 1, f: { g: 2 } } } } } } }
  const before = JSON.stringify(nested)
  assert.deepEqual(bounded(nested), { a: { b: { c: { d: { e: { leaf: 1, f: undefined } } } } } })
  assert.equal(JSON.stringify(nested), before, "the source value remains intact")
  const values = Array.from({ length: 65 }, (_, index) => index)
  assert.deepEqual(bounded(values), Array.from({ length: 64 }, (_, index) => index))
  const entries = values.map((index) => [`key${index}`, index])
  assert.deepEqual(bounded(Object.fromEntries(entries)), Object.fromEntries(entries.slice(0, 64)))
  assert.deepEqual(bounded({ text: "long", count: 3, flag: false, absent: null }, 2), {
    text: "lo", count: 3, flag: false, absent: null,
  })
})

test("only a decision OpenCode knows is one", () => {
  assert.deepEqual(parseDecision('{"decision":"once"}'), { decision: "once" })
  assert.deepEqual(parseDecision('{"decision":"reject","message":"no"}'), { decision: "reject", message: "no" })
  assert.equal(parseDecision('{"decision":"always"}'), undefined)
  assert.equal(parseDecision(""), undefined)
  assert.equal(parseDecision("not json"), undefined)
})

test("Enter is left alone while a session runs or waits, and for a rebound key", () => {
  const layers = []
  const h = harness()
  h.ctx.keymap = { layer: (factory) => layers.push(factory()), shortcuts: () => ["return"], dispatch: () => {} }
  installGate(h.ctx, h.supervisor)
  assert.equal(layers.length, 1)
  assert.equal(layers[0].commands[0].bind, "return")
  assert.equal(layers[0].enabled(), true)
  h.running.add("ses_a")
  assert.equal(layers[0].enabled(), false, "a running session takes a steer")
  h.running.delete("ses_a")

  const waiting = harness({ waits: { ses_a: [{ id: "per_1" }] } })
  const waitingLayers = []
  waiting.ctx.keymap = { layer: (factory) => waitingLayers.push(factory()), dispatch: () => {} }
  installGate(waiting.ctx, waiting.supervisor)
  assert.equal(waitingLayers[0].enabled(), false, "Enter answers OpenCode's prompt")

  const rebound = harness()
  const reboundLayers = []
  rebound.ctx.keymap = { layer: (factory) => reboundLayers.push(factory()), shortcuts: () => ["ctrl+s"], dispatch: () => {} }
  installGate(rebound.ctx, rebound.supervisor)
  assert.equal(reboundLayers.length, 0)
})

test("Enter sends the input after the start is saved, and one at a time", async () => {
  let finishPrepare
  const prepared = new Promise((resolve) => (finishPrepare = resolve))
  const order = []
  const layers = []
  const supervisor = {
    prepare: async () => {
      order.push("prepare")
      await prepared
      order.push("saved")
    },
  }
  const h = harness()
  h.ctx.keymap = { layer: (factory) => layers.push(factory()), dispatch: (id) => order.push(id) }
  installGate(h.ctx, supervisor)
  const running = layers[0].commands[0].run()
  try {
    await layers[0].commands[0].run()
    assert.deepEqual(order, ["prepare"], "the second Enter neither prepares nor sends again")
  } finally {
    finishPrepare()
    await running
  }
  assert.deepEqual(order, ["prepare", "saved", "prompt.submit"])
})

test("the plugin does nothing outside a Weir pane or when OpenCode lacks a required API", async (t) => {
  const environment = process.env.WEIR_OPENCODE_PANE_ENV
  const keys = ["weirPaneEnvironment", SUPERVISOR_KEY, LAUNCHED_KEY]
  const previous = keys.map((key) => Object.getOwnPropertyDescriptor(globalThis, key))
  t.after(() => {
    if (environment === undefined) delete process.env.WEIR_OPENCODE_PANE_ENV
    else process.env.WEIR_OPENCODE_PANE_ENV = environment
    keys.forEach((key, index) => {
      if (previous[index]) Object.defineProperty(globalThis, key, previous[index])
      else delete globalThis[key]
    })
  })
  delete process.env.WEIR_OPENCODE_PANE_ENV
  delete globalThis.weirPaneEnvironment
  let touched = false
  const ctx = new Proxy({}, { get() { touched = true; return undefined } })
  assert.equal(await plugin.setup(ctx), undefined)
  assert.equal(touched, false)
  globalThis.weirPaneEnvironment = { WEIR_PANE_ID: "P", WEIR_OPENCODE_HOOK_DIR: "/nowhere" }
  const paths = [
    ["data", "listen"], ["data", "session", "status"], ["data", "session", "permission", "list"],
    ["data", "session", "form", "list"], ["keymap", "layer"], ["keymap", "dispatch"],
    ["ui", "router", "current"], ["client", "session", "interrupt"],
  ]
  for (const missing of paths) {
    const called = []
    const incomplete = {}
    for (const path of paths) {
      let owner = incomplete
      for (const part of path.slice(0, -1)) owner = owner[part] ??= {}
      if (path !== missing) owner[path.at(-1)] = () => called.push(path.join("."))
    }
    const sentinel = { rebind: () => called.push("rebind") }
    globalThis[SUPERVISOR_KEY] = sentinel
    delete globalThis[LAUNCHED_KEY]
    assert.equal(await plugin.setup(incomplete), undefined, missing.join("."))
    assert.deepEqual(called, [], missing.join("."))
    assert.equal(globalThis[SUPERVISOR_KEY], sentinel)
    assert.equal(globalThis[LAUNCHED_KEY], undefined)
  }
})

test("a preparation on the home screen is of the folder /cd chose, not where the interface began", async () => {
  const h = harness({ shown: null })
  h.ctx.location = { directory: "/other-repo" }
  h.ctx.data.location = { default: () => ({ directory: "/repo" }) }
  await h.supervisor.prepare()
  assert.equal(h.last("weir.prepare").cwd, "/other-repo")
})

test("switching session or changing the prompt during the wait sends nothing and drops the start", async () => {
  for (const change of ["session", "text"]) {
    let finishPrepare
    const dispatched = []
    const layers = []
    const toasts = []
    let discarded = 0
    const supervisor = {
      prepare: () => new Promise((resolve) => (finishPrepare = resolve)),
      discardPreparation: () => {
        discarded += 1
      },
    }
    const h = harness()
    h.ctx.ui.toast = { show: (options) => toasts.push(options) }
    h.ctx.renderer = { currentFocusedRenderable: { plainText: "fix it" } }
    h.ctx.keymap = { layer: (factory) => layers.push(factory()), dispatch: (id) => dispatched.push(id) }
    installGate(h.ctx, supervisor)
    const running = layers[0].commands[0].run()
    if (change === "session") h.show("ses_other")
    else h.ctx.renderer.currentFocusedRenderable.plainText = "another draft"
    finishPrepare()
    await running
    assert.deepEqual(dispatched, [], change)
    assert.equal(discarded, 1, change)
    assert.deepEqual(toasts, [{ message: notSentMessage(), variant: "warning" }], change)
    assert.equal(h.ctx.renderer.currentFocusedRenderable.plainText, change === "text" ? "another draft" : "fix it")
  }
})

test("an execution another pane began in a session this pane drove before is not this pane's", async () => {
  for (const delivery of ["steer", "queue"]) {
    const h = harness()
    await submit(h, "ses_a")
    await h.event("session.execution.succeeded", { sessionID: "ses_a" })
    h.supervisor.checkShown()
    await h.supervisor.settled()
    h.sent.length = 0
    h.envs.length = 0
    h.advance(10_000)
    if (delivery === "queue") {
      h.supervisor.onKey()
      h.advance(4_000)
    }
    await h.event("session.inbox.enqueued", {
      sessionID: "ses_a",
      inboxID: "in_b",
      item: { type: "user", payload: { text: "from pane B" }, delivery },
    })
    await h.event("session.execution.started", { sessionID: "ses_a" })
    assert.deepEqual(h.names(), [], delivery)
    assert.equal(h.supervisor.state().turns.has("ses_a"), false, delivery)
    h.running.add("ses_a")
    await h.supervisor.stopOwned()
    assert.deepEqual(h.interrupted, [], `closing this pane leaves ${delivery} work in pane B`)
  }
})

test("what the agent adds to this pane's execution carries over; once another pane went, it does not", async () => {
  const h = harness()
  await submit(h, "ses_a")
  await h.event("session.execution.succeeded", { sessionID: "ses_a" })

  const synthetic = () =>
    h.event("session.inbox.enqueued", {
      sessionID: "ses_a",
      inboxID: "in_s",
      item: { type: "synthetic", payload: { text: "a shell ended" }, delivery: "steer" },
    })
  await synthetic()
  await h.event("session.execution.started", { sessionID: "ses_a" })
  assert.equal(h.last("session.execution.started").prompt_kind, "synthetic")
  await h.event("session.inbox.delivered", { sessionID: "ses_a", inboxID: "in_s" })
  await h.event("session.execution.succeeded", { sessionID: "ses_a" })

  // Pane B's input, then an addition to its execution.
  await h.event("session.execution.started", { sessionID: "ses_a" })
  await h.event("session.execution.succeeded", { sessionID: "ses_a" })
  h.sent.length = 0
  await synthetic()
  await h.event("session.execution.started", { sessionID: "ses_a" })
  assert.deepEqual(h.names(), [])
})

test("quitting stops what this pane began; a reload of the plugin leaves it running", async () => {
  const h = harness()
  await submit(h, "ses_a")
  h.running.add("ses_a")
  let released = 0
  h.ctx.renderer = { isDestroyed: false }
  await shutDown(h.ctx, h.supervisor, () => (released += 1))
  assert.deepEqual(h.interrupted, [], "a reload")
  assert.equal(released, 1)
  h.ctx.renderer.isDestroyed = true
  await shutDown(h.ctx, h.supervisor, () => (released += 1))
  assert.deepEqual(h.interrupted, ["ses_a"], "quitting")
})

test("a resumed session reports its saved model before any step", async () => {
  const h = harness()
  h.ctx.client.session.get = async () => ({
    agent: "plan",
    model: { id: "gpt-5.5", providerID: "openrouter", variant: "high" },
    location: { directory: "/repo" },
  })
  h.ctx.data.location = {
    model: { list: () => [{ id: "gpt-5.5", providerID: "openrouter", name: "GPT-5.5" }] },
    provider: { list: () => [{ id: "openrouter", name: "OpenRouter" }] },
  }
  await h.supervisor.launch("ses_a")
  const settings = h.last("session.step.started")
  assert.deepEqual(settings.data.model, { id: "gpt-5.5", providerID: "openrouter", variant: "high" })
  assert.equal(settings.data.agent, "plan")
  assert.deepEqual(settings.model_info, { name: "GPT-5.5", provider_name: "OpenRouter" })
  assert.deepEqual(h.names(), ["weir.launch", "session.step.started"])
})

test("the pane environment file is consumed once and cached for plugin reload", (t) => {
  const previous = Object.getOwnPropertyDescriptor(globalThis, "weirPaneEnvironment")
  t.after(() => {
    if (previous) Object.defineProperty(globalThis, "weirPaneEnvironment", previous)
    else delete globalThis.weirPaneEnvironment
  })
  const directory = mkdtempSync(join(tmpdir(), "weir-pane-env-"))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  const path = join(directory, "1.env")
  writeFileSync(path, "WEIR_PANE_ID=P\0WEIR_MANY=a\nb=c\0")
  delete globalThis.weirPaneEnvironment
  assert.deepEqual(paneEnvironment(path), { WEIR_PANE_ID: "P", WEIR_MANY: "a\nb=c" })
  assert.equal(existsSync(path), false)
  assert.deepEqual(paneEnvironment(path), { WEIR_PANE_ID: "P", WEIR_MANY: "a\nb=c" })
  // An uncached process sees only the consumed file path.
  delete globalThis.weirPaneEnvironment
  assert.equal(paneEnvironment(path), undefined)
  assert.equal(paneEnvironment(""), undefined)
})

test("quitting mid-turn ends the record as stopped, past a hook that has stalled", { timeout: 5_000 }, async (t) => {
  const h = harness()
  await submit(h, "ses_a")
  let release
  const held = new Promise((resolve) => (release = resolve))
  t.after(() => release())
  let began
  const started = new Promise((resolve) => (began = resolve))
  const originalHook = h.io.hook
  h.io.hook = async (...args) => {
    if (JSON.parse(args[0]).hook_event_name === "session.step.started") {
      began()
      await held
    }
    return originalHook(...args)
  }
  await h.supervisor.onEvent({ type: "session.step.started", data: { sessionID: "ses_a", agent: "build", model: { id: "m", providerID: "p" } } })
  await started
  h.running.add("ses_a")
  h.ctx.renderer = { isDestroyed: true }
  await shutDown(h.ctx, h.supervisor, () => {})
  assert.deepEqual(h.interrupted, ["ses_a"])
  const ended = h.last("session.execution.interrupted")
  assert.equal(ended.data.reason, "quit")
  assert.equal(ended.usage.isPartial, true)
  assert.equal(h.supervisor.state().turn, undefined)
  release()
  await h.supervisor.settled()
})

test("signaled shutdown records one interrupted turn while the renderer is live", async () => {
  const h = harness()
  await submit(h, "ses_a")
  h.ctx.renderer = { isDestroyed: false }
  let releases = 0
  await shutDown(h.ctx, h.supervisor, () => (releases += 1), true)
  assert.equal(releases, 1)
  assert.equal(h.ctx.renderer.isDestroyed, false)
  const ends = h.sent.filter((body) => body.hook_event_name === "session.execution.interrupted")
  assert.equal(ends.length, 1)
  assert.equal(ends[0].data.sessionID, "ses_a")
  assert.equal(ends[0].data.reason, "quit")
  assert.equal(ends[0].usage.isPartial, true)
})

test("a turn the service ended sends no second end on quit", async () => {
  const h = harness()
  await submit(h, "ses_a")
  await h.event("session.execution.succeeded", { sessionID: "ses_a" })
  await h.supervisor.quit()
  await h.supervisor.quit()
  assert.deepEqual(h.sent.filter((body) => body.hook_event_name.startsWith("session.execution."))
    .map((body) => [body.hook_event_name, body.data.sessionID]), [
    ["session.execution.started", "ses_a"], ["session.execution.succeeded", "ses_a"],
  ])
  assert.deepEqual(h.interrupted, [])
  assert.equal(h.supervisor.state().turns.size, 0)
})

test("with a stalled hook, ownership still follows the events", { timeout: 5_000 }, async (t) => {
  const h = harness()
  let release
  const held = new Promise((resolve) => (release = resolve))
  t.after(() => release())
  let entered
  const began = new Promise((resolve) => (entered = resolve))
  const hook = h.io.hook
  h.io.hook = async (...args) => {
    if (JSON.parse(args[0]).hook_event_name === "weir.session") {
      entered()
      await held
    }
    return hook(...args)
  }
  await h.supervisor.prepare()
  await h.supervisor.onEvent({ type: "session.execution.started", data: { sessionID: "ses_a" } })
  await began
  assert.equal(h.supervisor.state().running.has("ses_a"), true)
  h.running.add("ses_a")
  const ending = h.supervisor.onEvent({ type: "session.execution.succeeded", data: { sessionID: "ses_a" } })
  assert.equal(h.supervisor.state().running.has("ses_a"), false, "ahead of the held report")
  await h.supervisor.stopOwned()
  assert.deepEqual(h.interrupted, [])
  assert.equal(h.last("session.execution.succeeded"), undefined)
  release()
  await ending
  await h.supervisor.settled()
  assert.deepEqual(h.names().filter((name) => name.startsWith("session.execution.")), [
    "session.execution.started", "session.execution.succeeded",
  ])
  assert.equal(h.last("session.execution.succeeded").data.sessionID, "ses_a")
})

test("the session's latest execution must still be the one this pane began", async () => {
  const h = harness()
  let busy = 100
  h.ctx.client.session.get = async () => ({ time: { busy } })
  await submit(h, "ses_a")
  await new Promise((resolve) => setImmediate(resolve))
  h.running.add("ses_a")
  busy = 200
  await h.supervisor.stopOwned()
  assert.deepEqual(h.interrupted, [], "a later execution, whose end never reached us")
  busy = 100
  await h.supervisor.stopOwned()
  assert.deepEqual(h.interrupted, ["ses_a"])
})

test("a later Enter during the wait replaces the earlier one", async () => {
  let finishPrepare
  let preparations = 0
  let discarded = 0
  const dispatched = []
  const layers = []
  const toasts = []
  const supervisor = {
    prepare: () => {
      preparations += 1
      return new Promise((resolve) => (finishPrepare = resolve))
    },
    discardPreparation: () => (discarded += 1),
  }
  const h = harness()
  h.ctx.ui.toast = { show: (options) => toasts.push(options) }
  h.ctx.renderer = { currentFocusedRenderable: { plainText: "first" } }
  h.ctx.keymap = {
    layer: (factory) => layers.push(factory()),
    dispatch: (id) => dispatched.push({ id, text: h.ctx.renderer.currentFocusedRenderable.plainText }),
  }
  installGate(h.ctx, supervisor)
  const running = layers[0].commands[0].run()
  try {
    assert.equal(preparations, 1)
    assert.deepEqual(dispatched, [])
    h.ctx.renderer.currentFocusedRenderable.plainText = "second"
    await layers[0].commands[0].run()
    assert.equal(preparations, 1, "the later Enter joins the preparation already held")
    assert.deepEqual(dispatched, [], "neither Enter submits before preparation finishes")
  } finally {
    finishPrepare()
    await running
  }
  assert.deepEqual(dispatched, [{ id: "prompt.submit", text: "second" }])
  assert.equal(discarded, 0)
  assert.deepEqual(toasts, [])
})

test("reloading the plugin preserves the active turn and reports the launch only once", async (t) => {
  const directory = mkdtempSync(join(tmpdir(), "weir-reload-"))
  const savedGlobals = new Map([SUPERVISOR_KEY, LAUNCHED_KEY, "weirPaneEnvironment"].map((key) =>
    [key, Object.getOwnPropertyDescriptor(globalThis, key)],
  ))
  let active
  t.after(async () => {
    try {
      if (active) {
        active.context.renderer.isDestroyed = true
        await active.close()
      }
    } finally {
      for (const [key, descriptor] of savedGlobals) {
        if (descriptor) Object.defineProperty(globalThis, key, descriptor)
        else delete globalThis[key]
      }
      rmSync(directory, { recursive: true, force: true })
    }
  })
  const log = join(directory, "reports")
  writeFileSync(join(directory, "weir-hook"), `#!/bin/sh\nbody=$(cat)\nprintf "%s\\n" "$body" >> "${log}"\n`)
  chmodSync(join(directory, "weir-hook"), 0o755)
  delete globalThis[SUPERVISOR_KEY]
  delete globalThis[LAUNCHED_KEY]
  globalThis.weirPaneEnvironment = { WEIR_PANE_ID: "P", WEIR_OPENCODE_HOOK_DIR: directory }
  const interrupted = []
  const listeners = new Set()
  const keys = new Set()
  const context = () => ({
    ui: { router: { current: () => ({ type: "session", sessionID: "ses_a" }) } },
    data: {
      listen: (handler) => {
        listeners.add(handler)
        return () => listeners.delete(handler)
      },
      session: { status: () => "running", permission: { list: () => [] }, form: { list: () => [] } },
    },
    keymap: { layer: () => {}, dispatch: () => {} },
    client: { session: { interrupt: async ({ sessionID }) => interrupted.push(sessionID) } },
    renderer: {
      isDestroyed: false,
      keyInput: { on: (_name, handler) => keys.add(handler), off: (_name, handler) => keys.delete(handler) },
    },
  })
  const deliver = (type, data) => {
    for (const handler of listeners) handler({ details: { type, data } })
  }
  const reports = async (name, count) => {
    for (let tries = 0; tries < 200; tries += 1) {
      const lines = existsSync(log) ? readFileSync(log, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line)) : []
      if (lines.filter((line) => line.hook_event_name === name).length >= count) return lines
      await new Promise((resolve) => setTimeout(resolve, 25))
    }
    assert.fail(`no ${name}`)
  }
  const first = context()
  const deactivate = await plugin.setup(first)
  active = { context: first, close: deactivate }
  await reports("weir.launch", 1)
  for (const key of keys) key()
  deliver("session.execution.started", { sessionID: "ses_a" })
  await reports("session.execution.started", 1)
  await deactivate()
  assert.deepEqual(interrupted, [], "a reload stops nothing")
  assert.equal(listeners.size, 0)
  assert.equal(keys.size, 0)

  const second = context()
  const close = await plugin.setup(second)
  active = { context: second, close }
  assert.equal(listeners.size, 1)
  assert.equal(keys.size, 1)
  deliver("session.step.ended", {
    sessionID: "ses_a",
    tokens: { input: 5, output: 1, reasoning: 0, cache: { read: 0, write: 0 } },
  })
  await new Promise((resolve) => setImmediate(resolve))
  second.renderer.isDestroyed = true
  await close()
  active = undefined
  assert.equal(listeners.size, 0)
  assert.equal(keys.size, 0)
  assert.deepEqual(interrupted, ["ses_a"], "and quitting still stops the turn it began before")
  const lines = await reports("session.execution.interrupted", 1)
  assert.equal(lines.filter((line) => line.hook_event_name === "weir.launch").length, 1)
  const ended = lines.filter((line) => line.hook_event_name === "session.execution.interrupted")
  assert.equal(ended.length, 1)
  assert.equal(ended[0].data.sessionID, "ses_a")
  assert.equal(ended[0].usage.input, 5)
})

async function compacting(h) {
  await h.event("session.inbox.enqueued", {
    sessionID: "ses_a",
    inboxID: "in_c",
    item: { type: "compaction", payload: {}, delivery: "steer" },
  })
  h.supervisor.checkShown()
  h.supervisor.onKey()
  await h.event("session.execution.started", { sessionID: "ses_a" })
  await h.event("session.compaction.started", { sessionID: "ses_a", reason: "manual" })
}

test("compaction closes on interruption, reconciliation, quit, and supersession", async () => {
  const routes = {
    esc: (h) => h.event("session.execution.interrupted", { sessionID: "ses_a", reason: "user" }),
    reconcile: async (h) => {
      h.ctx.client.session.get = async () => ({ time: { busy: 1, idle: 2 } })
      await h.supervisor.reconcile()
      await h.supervisor.settled()
    },
    quit: async (h) => {
      await h.supervisor.quit()
    },
    superseded: async (h) => {
      await h.event("session.execution.started", { sessionID: "ses_a" })
    },
  }
  for (const [route, close] of Object.entries(routes)) {
    const h = harness()
    await compacting(h)
    h.sent.length = 0
    await close(h)
    const failures = h.sent.filter((item) => item.hook_event_name === "session.compaction.failed")
    assert.equal(failures.length, 1, route)
    assert.equal(failures[0].data.sessionID, "ses_a", route)
    assert.ok(!h.sent.some((item) => item.hook_event_name.endsWith("interrupted") && item.data.sessionID === "ses_a"), route)
  }
})

test("a session the service no longer has closes the turn at once; other failures keep waiting", async () => {
  const h = harness()
  await submit(h, "ses_a")
  h.ctx.client.session.get = async () => {
    throw new Error("connection refused")
  }
  await h.supervisor.reconcile()
  await h.supervisor.settled()
  assert.equal(h.supervisor.state().turn?.sessionID, "ses_a")
  assert.equal(h.last("session.execution.interrupted"), undefined)
  h.ctx.client.session.get = async () => {
    throw Object.assign(new Error("gone"), { name: "SessionNotFoundError" })
  }
  await h.supervisor.reconcile()
  await h.supervisor.settled()
  assert.equal(h.supervisor.state().turn, undefined)
  const ends = h.sent.filter((body) => body.hook_event_name === "session.execution.interrupted")
  assert.equal(ends.length, 1)
  assert.equal(ends[0].data.sessionID, "ses_a")
  assert.equal(ends[0].data.reason, "deleted")
  assert.equal(ends[0].usage.isPartial, true)
  assert.equal(h.supervisor.state().running.size, 0)
})

test("session.deleted closes the turn short", async () => {
  const h = harness()
  await submit(h, "ses_a")
  await h.event("session.deleted", { sessionID: "ses_a" })
  const ended = h.last("session.execution.interrupted")
  assert.equal(ended.data.reason, "deleted")
  assert.equal(ended.data.sessionID, "ses_a")
  assert.equal(ended.usage.isPartial, true)
  assert.equal(h.supervisor.state().running.size, 0)
  assert.equal(h.supervisor.state().turns.size, 0)
  await h.event("session.deleted", { sessionID: "ses_a" })
  await h.supervisor.quit()
  assert.equal(h.sent.filter((body) => body.hook_event_name === "session.execution.interrupted").length, 1)
  assert.deepEqual(h.interrupted, [])
})

test("--prompt claims only the session this screen moves to, and an unrelated start leaves it armed", async () => {
  const h = harness({ shown: null, launchPrompt: true })
  await h.event("session.execution.started", { sessionID: "ses_theirs" })
  assert.equal(h.last("session.execution.started"), undefined)
  h.show("ses_mine")
  await h.event("session.execution.started", { sessionID: "ses_mine" })
  assert.equal(h.last("session.execution.started").data.sessionID, "ses_mine")
  await h.event("session.execution.succeeded", { sessionID: "ses_mine" })
  h.sent.length = 0
  h.show("ses_later")
  await h.event("session.execution.started", { sessionID: "ses_later" })
  assert.deepEqual(h.names(), [], "once")
})

test("--prompt's turn begins from the start the shim saved before OpenCode ran", async () => {
  for (const resumed of [false, true]) {
    const sessionID = resumed ? "ses_old" : "ses_mine"
    const h = harness({ shown: resumed ? sessionID : null, launchPrompt: true, launchPreparation: "gen_launch" })
    if (resumed) await h.supervisor.launch(sessionID)
    h.show(sessionID)
    await h.event("session.execution.started", { sessionID })
    const started = h.last("session.execution.started")
    assert.equal(started.data.sessionID, sessionID)
    assert.equal(started.preparation, "gen_launch")
    assert.deepEqual(h.envOf("session.execution.started"), {})
    await h.event("session.execution.succeeded", { sessionID })
    h.supervisor.checkShown()
    await h.supervisor.settled()
    h.sent.length = 0
    h.envs.length = 0
    h.supervisor.onKey()
    await h.event("session.execution.started", { sessionID })
    assert.equal(h.last("session.execution.started").data.sessionID, sessionID)
    assert.equal(h.last("session.execution.started").preparation, undefined, "an ungated next start cannot reuse the launch generation")
    assert.deepEqual(h.envOf("session.execution.started"), {})
  }
})

test("an Enter's claim ahead of --prompt drops the launch's saved start", async () => {
  const h = harness({ shown: "ses_a", launchPrompt: true, launchPreparation: "gen_launch" })
  await submit(h, "ses_a")
  assert.equal(h.last("session.execution.started").preparation, h.last("weir.prepare").preparation)
  await h.event("session.execution.succeeded", { sessionID: "ses_a" })
  h.sent.length = 0
  await h.event("session.execution.started", { sessionID: "ses_a" })
  assert.deepEqual(h.names(), [], "Enter consumed the launch claim")
  // A slash command, which no gate sees.
  h.supervisor.checkShown()
  h.supervisor.onKey()
  await h.event("session.execution.started", { sessionID: "ses_a" })
  assert.equal(h.last("session.execution.started").preparation, undefined)
})

test("a session on another run than the launch's takes no launch start", async () => {
  const h = harness({ shown: null, launchPrompt: true, launchPreparation: "gen_launch" })
  // The launch's run went to the session first on screen, so the start saved under
  // it is not that of another session the screen then moves to.
  h.show("ses_other")
  h.supervisor.checkShown()
  await h.supervisor.settled()
  h.show("ses_mine")
  await h.event("session.execution.started", { sessionID: "ses_mine" })
  const started = h.last("session.execution.started")
  assert.equal(started.data.sessionID, "ses_mine")
  assert.equal(started.preparation, undefined)
  assert.deepEqual(h.envOf("session.execution.started"), { WEIR_AGENT_RUN_ID: "RUN1" })
})

test("a start with the turn still open closes it short, whoever owns the new execution", async () => {
  // Another pane's.
  const foreign = harness()
  await submit(foreign, "ses_a")
  await foreign.event("permission.asked", { id: "per_1", sessionID: "ses_a", action: "shell", resources: ["a"] })
  foreign.sent.length = 0
  foreign.advance(10_000)
  await foreign.event("session.execution.started", { sessionID: "ses_a" })
  assert.deepEqual(foreign.names(), ["session.execution.interrupted"])
  const interrupted = foreign.last("session.execution.interrupted")
  assert.equal(interrupted.data.reason, "superseded")
  assert.equal(interrupted.data.sessionID, "ses_a")
  assert.equal(interrupted.usage.isPartial, true)
  assert.equal(foreign.approvals[0].cancelled, true)
  assert.equal(foreign.supervisor.state().turn, undefined)
  assert.equal(foreign.supervisor.state().running.size, 0)
  foreign.sent.length = 0
  await foreign.event("session.text.ended", { sessionID: "ses_a", text: "B's words" })
  await foreign.event("session.execution.succeeded", { sessionID: "ses_a" })
  assert.deepEqual(foreign.names(), [], "B's end closes nothing here")

  // This pane's own.
  const own = harness()
  await submit(own, "ses_a", "one")
  own.sent.length = 0
  await submit(own, "ses_a", "two")
  const lifecycle = () => own.sent.filter((event) => event.hook_event_name.startsWith("session.execution."))
  assert.deepEqual(lifecycle().map((event) => event.hook_event_name), [
    "session.execution.interrupted", "session.execution.started",
  ])
  assert.equal(own.last("session.execution.interrupted").data.reason, "superseded")
  assert.equal(own.last("session.execution.interrupted").usage.isPartial, true)
  assert.equal(own.last("session.execution.started").prompt, "two")
  await own.event("session.text.ended", { sessionID: "ses_a", text: "second reply" })
  await own.event("session.execution.succeeded", { sessionID: "ses_a" })
  assert.deepEqual(lifecycle().map((event) => event.hook_event_name), [
    "session.execution.interrupted", "session.execution.started", "session.execution.succeeded",
  ])
  assert.equal(own.last("session.execution.succeeded").reply, "second reply")
  await own.event("session.execution.succeeded", { sessionID: "ses_a" })
  assert.equal(lifecycle().length, 3, "a repeated terminal event creates no second end")
})

test("an execution that ended during the claim's wait leaves no entry", { timeout: 5_000 }, async (t) => {
  const h = harness({ shown: null })
  await h.supervisor.prepare()
  let release
  const held = new Promise((resolve) => (release = resolve))
  t.after(() => release())
  let entered
  const waiting = new Promise((resolve) => (entered = resolve))
  h.io.sleep = async (ms) => {
    entered()
    await held
    h.advance(ms)
  }
  const started = h.supervisor.onEvent({ type: "session.execution.started", data: { sessionID: "ses_new" } })
  await waiting
  assert.equal(h.last("session.execution.started"), undefined)
  const ended = h.supervisor.onEvent({ type: "session.execution.succeeded", data: { sessionID: "ses_new" } })
  h.show("ses_new")
  release()
  await Promise.all([started, ended])
  await h.supervisor.settled()
  assert.equal(h.supervisor.state().running.size, 0)
  assert.equal(h.supervisor.state().turns.size, 0)
  assert.deepEqual(h.sent.filter((body) => body.hook_event_name.startsWith("session.execution."))
    .map((body) => [body.hook_event_name, body.data.sessionID]), [
    ["session.execution.started", "ses_new"], ["session.execution.succeeded", "ses_new"],
  ])
})

test("quit reports the end before the service has answered", { timeout: 5_000 }, async (t) => {
  const h = harness()
  await submit(h, "ses_a")
  h.running.add("ses_a")
  let release
  const held = new Promise((resolve) => (release = resolve))
  t.after(() => release())
  let began
  const started = new Promise((resolve) => (began = resolve))
  h.ctx.client.session.interrupt = () => {
    began()
    return held
  }
  let received
  const reported = new Promise((resolve) => (received = resolve))
  const originalHook = h.io.hook
  h.io.hook = async (...args) => {
    await originalHook(...args)
    if (JSON.parse(args[0]).hook_event_name === "session.execution.interrupted") received()
  }
  const quitting = h.supervisor.quit()
  await started
  await reported
  assert.ok(h.last("session.execution.interrupted"))
  release()
  await quitting
})

test("the note about an unsent input honors the locale variables in POSIX's order", () => {
  const isJapanese = (env) => /送信/.test(notSentMessage(env))
  assert.equal(isJapanese({ LC_ALL: "ja_JP.UTF-8", LANG: "en_US" }), true)
  assert.equal(isJapanese({ LC_MESSAGES: "ja_JP.UTF-8", LANG: "en_US" }), true)
  assert.equal(isJapanese({ LC_ALL: "en_US", LC_MESSAGES: "ja_JP" }), false)
  assert.equal(isJapanese({ LANG: "ja_JP.UTF-8" }), true)
  assert.equal(isJapanese({}), false)
})

test("a shell command naming a worktree goes to the worktree hook with where it ran; others do not", async () => {
  const h = harness()
  await submit(h, "ses_a")
  const run = async (id, input, type = "session.tool.success") => {
    await h.event("session.tool.input.started", { sessionID: "ses_a", id, name: "shell" })
    await h.event("session.tool.called", { sessionID: "ses_a", id, input })
    await h.event(type, { sessionID: "ses_a", id, metadata: { exit: 0 } })
  }
  await run("t1", { command: "cargo test" })
  assert.deepEqual(h.worktreeCalls, [])
  await run("t2", { command: "git worktree add -b x ../x", workdir: "sub" })
  assert.equal(h.worktreeCalls.length, 1)
  assert.equal(h.worktreeCalls[0].hook_event_name, "session.tool.success")
  assert.equal(h.worktreeCalls[0].command, "git worktree add -b x ../x")
  assert.equal(h.worktreeCalls[0].cwd, "/repo/sub")
  assert.equal(h.worktreeCalls[0].data.metadata.exit, 0)
  // A failed tool event is excluded even with exit 0. A nonzero shell exit
  // arrives as a successful tool event and is interpreted by the Rust hook.
  await run("t3", { command: "git worktree add -b y ../y" }, "session.tool.failed")
  assert.equal(h.worktreeCalls.length, 1)
})

test("a bootstrap at work holds back no report", { timeout: 5_000 }, async (t) => {
  const h = harness()
  await submit(h, "ses_a")
  let release
  const held = new Promise((resolve) => (release = resolve))
  t.after(() => release())
  let began
  const started = new Promise((resolve) => (began = resolve))
  h.setWorktreeHook(() => {
    began()
    return held
  })
  await h.supervisor.onEvent({ type: "session.tool.input.started", data: { sessionID: "ses_a", id: "t", name: "shell" } })
  await h.supervisor.onEvent({ type: "session.tool.called", data: { sessionID: "ses_a", id: "t", input: { command: "git worktree add -b x ../x" } } })
  await h.supervisor.onEvent({ type: "session.tool.success", data: { sessionID: "ses_a", id: "t", metadata: { exit: 0 } } })
  await started
  let received
  const reported = new Promise((resolve) => (received = resolve))
  const originalHook = h.io.hook
  h.io.hook = async (...args) => {
    await originalHook(...args)
    if (JSON.parse(args[0]).hook_event_name === "session.execution.succeeded") received()
  }
  await h.supervisor.onEvent({ type: "session.execution.succeeded", data: { sessionID: "ses_a" } })
  await reported
  assert.ok(h.last("session.execution.succeeded"))
  release()
  await h.supervisor.settled()
})

test("the plugin has the shape OpenCode's loader asks for", () => {
  assert.equal(plugin.id, "weir")
  assert.equal(typeof plugin.setup, "function")
})

test("the helper override is a test's, taken only outside an app bundle", () => {
  const override = "/elsewhere/AgentIntegrationHookHelper"
  const bundle = "/Applications/Weir.app/Contents/Resources/opencode-shim"
  assert.equal(
    hookHelperPath({ WEIR_OPENCODE_HOOK_DIR: bundle, WEIR_HOOK_HELPER: override }),
    "/Applications/Weir.app/Contents/MacOS/AgentIntegrationHookHelper",
  )
  assert.equal(hookHelperPath({ WEIR_OPENCODE_HOOK_DIR: "/src/Weir/Resources/opencode-shim", WEIR_HOOK_HELPER: override }), override)
  assert.equal(
    hookHelperPath({ WEIR_OPENCODE_HOOK_DIR: "/src/Weir/Resources/opencode-shim" }),
    "/src/Weir/MacOS/AgentIntegrationHookHelper",
  )
})
