// Weir's OpenCode plugin. OpenCode's sessions run on a background service that
// many terminals share, so the only place that knows which pane a session
// belongs to is the terminal interface inside the pane. Weir places this file in
// OpenCode's plugin folder, where every OpenCode reads it, so outside a Weir pane
// it does nothing at all.
//
// It holds no rules of the run's state: it carries what happened to `weir-hook`,
// which runs in this pane's environment, and the Rust adapter says what it means.
// What it does decide is what only the pane can know: whether this pane sent the
// input a session is running on, and what one execution added up to.
//
// Nothing here may reach OpenCode as an exception. A broken Weir leaves a plain
// OpenCode, unwatched.

import { spawn } from "node:child_process"
import { randomUUID } from "node:crypto"
import { readFileSync, renameSync, rmSync, writeFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"

// How long Enter waits for the start of a turn to be saved, before the input is
// sent anyway and the turn goes without a start.
export const PREPARE_LIMIT_MS = 10_000
// A preparation an input never followed (an empty line, a `!` command) is
// dropped after this, so a later turn no input of ours began does not take it.
export const PREPARATION_LIFETIME_MS = 15_000
// How long the serial queue waits for one hook. Claude's and Codex's hooks get the
// same; a hook that hangs must not hold the reports after it forever.
export const HOOK_LIMIT_MS = 600_000
// How often a running turn is checked against the service, for an end whose event
// never reached us (a lost connection).
export const RECONCILE_INTERVAL_MS = 30_000
// How recently a key press counts as this pane having sent an input that did not
// come through the Enter gate (a rebound submit key).
export const KEY_PRESS_WINDOW_MS = 3_000
// How long a new session gets to show in this pane after its first events.
export const ROUTE_WAIT_MS = 500
// How often the screen is read for the session it shows. Moving between tabs sends no
// event. A read costs a signal's value; only a change costs a hook.
export const SHOWN_POLL_MS = 500
// How often a request of Weir's to bring a session forward is looked for, which a
// paste waits on.
export const FOCUS_POLL_MS = 100
// A request older than this is ignored: the person has moved on, and being pulled back
// to another tab would be worse than the request going unanswered.
export const FOCUS_REQUEST_LIMIT_MS = 3_000
// How long the answer to a request waits for the tab it asked for to come forward.
export const FOCUS_ANSWER_LIMIT_MS = 1_000
const FOCUS_ANSWER_CHECK_MS = 10
// How long what is on screen waits before it is said again, when it could not be
// written, doubling up to the limit. Nothing else would say it.
export const SHOWN_RETRY_MS = 100
export const SHOWN_RETRY_LIMIT_MS = 5_000
// What the hook exits with when it could not write what is on screen, and it is
// worth saying again (`HookOutcome::NotRecorded`). Any other status will not change.
export const NOT_RECORDED_EXIT = 75
// How many times one fact is said. With the hook's own 2 s wait on the lock, this
// is about a minute, far past any hook holding a record or a launch's report landing. What
// holds it longer is broken, and spawning for the life of the process would not mend
// it; the next change of screen says it afresh.
export const SHOWN_TRIES = 10
// The hook's input limit is a mebibyte (`MAX_HOOK_INPUT_BYTES`); a payload over it
// is dropped whole, which would leave a turn running forever.
const REPLY_LIMIT = 256 * 1024
const PROMPT_LIMIT = 64 * 1024
const TEXT_LIMIT = 8 * 1024
const PAYLOAD_LIMIT = 900 * 1024
// Where what the pane knows lives across a reload. A new number starts it afresh, for
// a change to the supervisor that the one still in memory could not serve.
export const SUPERVISOR_KEY = Symbol.for("weir.opencode.supervisor.v1")
export const LAUNCHED_KEY = Symbol.for("weir.opencode.launched")
// How long closing the interface waits for the service to take the stop.
export const STOP_LIMIT_MS = 2_000
// The adapter's request times out at 570 s, and the helper gives up its last wait by
// 580 s. A helper still here 10 s past that is stuck, and goes.
const APPROVAL_LIMIT_MS = 590_000

const FORWARDED_EVENTS = new Set([
  "session.tool.called",
  "session.tool.success",
  "session.tool.failed",
  "session.retry.scheduled",
])

/** Strings cut to `limit`, nested values kept to a few levels, so one huge tool input cannot sink a report. */
export function bounded(value, limit = TEXT_LIMIT, depth = 0) {
  if (typeof value === "string") return value.length > limit ? value.slice(0, limit) : value
  if (value === null || typeof value !== "object") return value
  if (depth >= 6) return undefined
  if (Array.isArray(value)) return value.slice(0, 64).map((item) => bounded(item, limit, depth + 1))
  const copy = {}
  for (const key of Object.keys(value).slice(0, 64)) copy[key] = bounded(value[key], limit, depth + 1)
  return copy
}

/**
 * Whether `title` is a session's own name, not what OpenCode stands in for one until it
 * names the session: nothing, or "New session - <time>" (`SessionTitleFallback` in its
 * `util` package at v2.2.5). The stand-in names no conversation, so it would only push
 * aside the folder name the pane shows meanwhile.
 */
export function isSessionTitle(title) {
  return (
    typeof title === "string" &&
    title.length > 0 &&
    !/^(New session|Child session) - \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(title)
  )
}

/** What the client throws for a thing the service does not have: its declared error, named by its tag. */
function isNotFound(error) {
  return /NotFound/.test(error?.name ?? "") || /NotFound/.test(error?._tag ?? "")
}

function sessionShown(ctx) {
  const route = ctx.ui.router.current()
  return route?.type === "session" ? route.sessionID : undefined
}

/** Whether the prompt on screen is what Enter would send: focus sits in a text field with words in it. */
function promptHasWords(ctx) {
  // The interface tells the prompt from a dialog's filter by the editor in focus: a
  // textarea that is not a one-line input (`keymap.tsx` at v2.2.5). A dialog and the
  // command menu also take their keys in a mode of their own, where this layer, in the
  // base mode, is off.
  const editor = ctx.renderer?.currentFocusedEditor
  if (editor && (editor.constructor?.name === "InputRenderable" || editor.singleLine === true)) return false
  const focused = ctx.renderer?.currentFocusedRenderable
  // A build that does not say what has focus goes through the gate, as an empty
  // line costs only a snapshot.
  if (focused === undefined) return true
  if (typeof focused?.plainText !== "string") return false
  return focused.plainText.trim().length > 0
}

function promptText(ctx) {
  return ctx.renderer?.currentFocusedRenderable?.plainText
}

function hasWaits(ctx, sessionID) {
  if (!sessionID) return false
  const family = ctx.data.session.family?.(sessionID) ?? [sessionID]
  return family.some(
    (id) => ctx.data.session.permission.list(id)?.length > 0 || ctx.data.session.form.list(id)?.length > 0,
  )
}

/**
 * What this pane knows of the sessions it drives. `io` is everything that reaches
 * outside (the hook, the approval helper, timers), so the tests run it on a
 * recorded stream of events.
 */
export function createSupervisor(initialContext, io) {
  // The interface of the plugin's current generation (`rebind`).
  let ctx = initialContext
  // The root sessions running an execution this pane began, each with when the
  // service says it began (`time.busy`, filled in shortly after). Ownership is the
  // execution's, not the session's: another pane may send the next input to the same
  // session, and that one is not ours to record or to stop. One this pane left for
  // another session stays here, as it stops with the pane. It changes as events
  // arrive, never behind a report, which may be waiting on a slow hook.
  const running = new Map()
  // The sessions whose last execution seen was this pane's, for what continues it
  // with no input of anyone's at a pane (`isContinuation`).
  const lastOwned = new Set()
  // How many ends each session has had by the time they arrive.
  const endsSeen = new Map()
  const parents = new Map()
  const toolNames = new Map()
  const toolCommands = new Map()
  const titles = new Map()
  const inboxes = new Map()
  const approvals = new Map()
  // The open turn of each root session, each session's run, and which sessions have
  // told the runtime they exist. A session's run is its own from the first time this
  // pane has to do with it to the end of the process, through a closed tab and its
  // reopening.
  const turns = new Map()
  const runs = new Map()
  const reported = new Set()
  const launchRun = io.launchRun?.()
  const autoAccepts = io.autoAccepts?.() === true
  let isLaunchRunTaken = false
  // The run an input on the home screen saved its start under, until its session comes.
  let homeRun
  let preparation
  let lastKeyAt = -Infinity
  const lastSettings = new Map()
  // The session the last read of the screen found (`checkShown`), and what that was
  // at the last key. A tab switch is a key too, so what a key "was looking at" has to
  // be from before it, and a read can only be late, never early.
  let lastShown
  let shownAtLastKey
  const bornAt = new Map()
  const tabsSeen = new Set()
  // `--prompt` makes the interface send its input with no key at all, on the home
  // screen or the session it resumes. The session the screen shows is its own, once.
  let isLaunchPromptDue = io.launchPrompt?.() === true
  // The start the shim saved for that input before OpenCode ran, under the launch's
  // run: no gate sees it, and the interface sends it before any wait here could hold
  // it. Only the launch's first claimed turn may take it, and only on that run. It has
  // no lifetime here, as Enter's does: the interface may hold the input behind a dialog
  // of its own first, and the runtime refuses a start older than ten minutes.
  let launchPreparation = isLaunchPromptDue ? io.launchPreparation?.() || undefined : undefined
  // What happened is judged in `queue`, which waits on no hook; what it means to
  // report goes on to `reports`, one hook at a time.
  let queue = Promise.resolve()
  let reports = Promise.resolve()
  let worktrees = Promise.resolve()
  // The latest of what is on screen not written yet, and the one delivery of it.
  let shownFact
  let shownDelivery = Promise.resolve()
  let isDeliveringShown = false
  let isHomeReported = false
  // What could not be written by the end of its tries, said again on a later check.
  let shownUnwritten
  let focusAnswer
  let isQuitting = false
  let quitting

  const enqueue = (work) => {
    queue = queue.then(work).catch((error) => io.log?.(`event failed: ${error}`))
    return queue
  }

  const rootOf = (sessionID) => {
    let id = sessionID
    for (let hops = 0; parents.has(id) && hops < 16; hops += 1) id = parents.get(id)
    if (id !== sessionID) return id
    return ctx.data.session.root?.(sessionID) ?? sessionID
  }

  /** A run no session has yet: the launch's while it is free, else a new one. Taken at once, with no wait to race. */
  const nextRun = () => {
    if (launchRun && !isLaunchRunTaken) {
      isLaunchRunTaken = true
      return launchRun
    }
    return io.newRun?.() ?? randomUUID().toUpperCase()
  }

  /** The run of `sessionID`, given `prepared` if it is new and its input saved a start under that one. */
  const takeRun = (sessionID, prepared) => {
    const known = runs.get(sessionID)
    if (known) return known
    const run = prepared ?? nextRun()
    if (run === homeRun) homeRun = undefined
    runs.set(sessionID, run)
    return run
  }

  /** What a hook of `run` adds to the pane's environment. The launch's own run needs nothing. */
  const runEnvironment = (run) => (!run || run === launchRun ? {} : { WEIR_AGENT_RUN_ID: run })

  const environmentOf = (sessionID) => runEnvironment(sessionID ? runs.get(rootOf(sessionID)) : undefined)

  /** Whether `sessionID` is what the input on the home screen made. */
  const isHomeInputFor = (sessionID) =>
    preparation?.expected === true &&
    !preparation.session &&
    (!runs.has(sessionID) || runs.get(sessionID) === preparation.run)

  const send = (name, data, extra = {}, envelope = {}) => {
    const runEnv = environmentOf(data?.sessionID)
    const { after: _after, ...fields } = envelope
    let body = JSON.stringify({ hook_event_name: name, ...fields, data, ...extra })
    if (Buffer.byteLength(body) > PAYLOAD_LIMIT) {
      // A terminal report must arrive even if it says less.
      const { reply: _reply, ...rest } = extra
      body = JSON.stringify({ hook_event_name: name, ...fields, data: { sessionID: data?.sessionID }, ...rest })
    }
    // Past any report still waiting: the process is about to go.
    if (isQuitting) {
      // Its own start may still be waiting in the queue this passes, and an end that
      // lands first would leave the run's record at work.
      const after = envelope.after
      return after ? after.then(() => io.hook(body, HOOK_LIMIT_MS, runEnv)) : io.hook(body, HOOK_LIMIT_MS, runEnv)
    }
    reports = reports.then(() => io.hook(body, HOOK_LIMIT_MS, runEnv)).catch((error) => io.log?.(`report failed: ${error}`))
    return undefined
  }

  /**
   * Tells the runtime of a session, once, in the reports' own order: what asks for it
   * first, the screen or its start, puts this ahead of anything else about the session.
   * Done with no wait, as a start that came after it would otherwise land before it
   * and be reset to rest.
   */
  const reportSession = (sessionID, directory, source) => {
    if (reported.has(sessionID)) return
    reported.add(sessionID)
    send("weir.session", { sessionID }, { cwd: directory, source, pane_family: launchRun, auto_accept: autoAccepts })
    reportShownAfterStart()
  }

  const directoryOf = (event) =>
    event?.location?.directory ?? ctx.data.session.get?.(event?.data?.sessionID)?.location?.directory ?? io.cwd()

  const newTurn = (sessionID, generation, directory) => ({
    sessionID,
    generation,
    directory,
    usage: { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0 },
    reply: undefined,
    isPartial: false,
    isCompactionOnly: false,
    isCompacting: false,
    waits: new Set(),
  })

  const addTokens = (turn, tokens) => {
    if (!tokens) return
    turn.usage.input += tokens.input ?? 0
    turn.usage.output += tokens.output ?? 0
    turn.usage.reasoning += tokens.reasoning ?? 0
    turn.usage.cacheRead += tokens.cache?.read ?? 0
    turn.usage.cacheWrite += tokens.cache?.write ?? 0
  }

  /** Ends the turn with `name`, carrying what it added up to; `data` is what the event says. */
  const endTurn = (ended, name, data, envelope = {}, extra = {}) => {
    if (!ended) return Promise.resolve()
    if (turns.get(ended.sessionID) === ended) turns.delete(ended.sessionID)
    for (const [id, approval] of [...approvals]) {
      if (approval.root === ended.sessionID) cancelApproval(id)
    }
    // No turn to end, but a compaction stopped midway says so in no event of its own
    // (Esc publishes no `session.compaction.failed`), and the run would stay at it.
    if (ended.isCompactionOnly) {
      if (!ended.isCompacting) return Promise.resolve()
      return (
        send("session.compaction.failed", { sessionID: ended.sessionID, reason: data?.reason }, {}, { after: ended.startReported }) ??
        Promise.resolve()
      )
    }
    const known = titles.get(ended.sessionID) ?? ctx.data.session.get?.(ended.sessionID)?.title
    const title = isSessionTitle(known) ? known : undefined
    return send(
      name,
      { ...data, sessionID: ended.sessionID },
      {
        cwd: ended.directory,
        usage: { ...ended.usage, isPartial: ended.isPartial || extra.isPartial === true },
        ...(ended.reply === undefined ? {} : { reply: ended.reply }),
        ...(title ? { title } : {}),
      },
      { ...envelope, after: ended.startReported },
    )
  }

  const takeInbox = (sessionID) => {
    const items = inboxes.get(sessionID) ?? []
    const person = items.find((item) => item.type === "user")
    const synthetic = items.find((item) => item.type === "synthetic")
    return {
      prompt: person?.text ?? synthetic?.text ?? "",
      kind: person ? "user" : synthetic ? "synthetic" : "none",
      isCompactionOnly: !person && !synthetic && items.some((item) => item.type === "compaction"),
    }
  }

  /** Waits for the screen to show `sessionID`, which moves around the time its first events arrive. */
  const isShownSoon = async (sessionID) => {
    const deadline = io.now() + ROUTE_WAIT_MS
    while (sessionShown(ctx) !== sessionID && io.now() < deadline) await io.sleep(25)
    return sessionShown(ctx) === sessionID
  }

  /** Whether the execution of `sessionID` that just started came from this pane. */
  const claims = async (sessionID) => {
    const isClaimed =
      // First: what a session of this pane goes on with is its own, whatever input
      // waits for a session of its own on the home screen.
      isContinuation(sessionID) ||
      // An input on the home screen makes a session; another pane's new session stays
      // off this screen.
      (isHomeInputFor(sessionID)
        ? await isShownSoon(sessionID)
        : (preparation?.expected && preparation.session === sessionID) ||
          (isLaunchPromptDue && (await isShownSoon(sessionID))) ||
          hasFreshKeyPress(sessionID))
    if (isClaimed) isLaunchPromptDue = false
    return isClaimed
  }

  // What this pane's execution left to go on with: what the agent or the service adds
  // by itself. An input sent while a session works, queued or not, joins the execution
  // that is running (OpenCode 2.2.5 starts none for it), so it is that execution's
  // owner's, whichever pane sent it. A person's input that starts an execution of its
  // own at rest is whoever sent it, which no event says, so it is not carried over.
  const isContinuation = (sessionID) =>
    (inboxes.get(sessionID) ?? []).some(
      (item) => lastOwned.has(sessionID) && (item.type === "synthetic" || item.type === "compaction"),
    )

  // No gate saw this input (a slash command, a rebound submit key), but the person
  // is at this pane, looking at the session: since before the key, as the key that
  // moved to a tab says nothing of what another pane then starts in it. A session the
  // key made cannot have been there before it.
  const hasFreshKeyPress = (sessionID) =>
    sessionShown(ctx) === sessionID &&
    io.now() - lastKeyAt <= KEY_PRESS_WINDOW_MS &&
    (shownAtLastKey === sessionID || (shownAtLastKey === undefined && (bornAt.get(sessionID) ?? -Infinity) >= lastKeyAt))

  const onStarted = async (event, endsBefore) => {
    const sessionID = event.data.sessionID
    if (parents.has(sessionID) || rootOf(sessionID) !== sessionID) return
    // A start with the turn still open means its end never reached us. Whoever owns
    // the new execution, the old turn is over, and what follows is not its.
    if (turns.has(sessionID)) {
      running.delete(sessionID)
      await endTurn(turns.get(sessionID), "session.execution.interrupted", { reason: "superseded" }, {}, { isPartial: true })
    }
    if (!(await claims(sessionID))) {
      lastOwned.delete(sessionID)
      return
    }
    const isInput = preparation?.expected === true && (preparation.session === sessionID || isHomeInputFor(sessionID))
    const run = takeRun(sessionID, isInput ? preparation.run : undefined)
    const generation = isInput
      ? preparation.generation
      : run === launchRun
        ? launchPreparation
        : undefined
    if (isInput) preparation = undefined
    launchPreparation = undefined
    lastOwned.add(sessionID)
    // An end that arrived during the claim's wait was this execution's.
    if ((endsSeen.get(sessionID) ?? 0) === endsBefore) {
      const execution = { busy: undefined }
      running.set(sessionID, execution)
      Promise.resolve()
        .then(() => ctx.client.session.get({ sessionID }))
        .then((info) => {
          if (running.get(sessionID) === execution) execution.busy = info?.time?.busy
        })
        .catch(() => {})
    }
    const directory = directoryOf(event)
    reportSession(sessionID, directory, ctx.data.session.message?.list?.(sessionID)?.length > 1 ? "resume" : "startup")
    const { prompt, kind, isCompactionOnly } = takeInbox(sessionID)
    const turn = newTurn(sessionID, generation, directory)
    turns.set(sessionID, turn)
    turn.isCompactionOnly = isCompactionOnly
    // A compaction's turn reports no start of its own: its end follows the session's.
    turn.startReported = reports
    if (isCompactionOnly) return
    await send(
      "session.execution.started",
      event.data,
      {
        cwd: directory,
        prompt: bounded(prompt, PROMPT_LIMIT),
        prompt_kind: kind,
        // Absent for a turn no gate saw: the runtime then records it has no start
        // rather than taking one after the agent may have begun.
        ...(generation ? { preparation: generation } : {}),
      },
      envelopeOf(event),
    )
    turn.startReported = reports
  }

  const onSettings = async (event) => {
    const { model, agent } = event.data
    const location = event.location ?? ctx.data.location?.default?.()
    const modelInfo = ctx.data.location?.model
      ?.list?.(location)
      ?.find((item) => item.id === model?.id && (item.providerID ?? model?.providerID) === model?.providerID)
    const provider = ctx.data.location?.provider?.list?.(location)?.find((item) => item.id === model?.providerID)
    // With the names: a report made before the lists were read is made again.
    const key = JSON.stringify([model?.providerID, model?.id, model?.variant, agent, modelInfo?.name, provider?.name])
    if (key === lastSettings.get(event.data.sessionID)) return
    lastSettings.set(event.data.sessionID, key)
    await send(
      event.type,
      { sessionID: event.data.sessionID, agent, model },
      { model_info: { name: modelInfo?.name, provider_name: provider?.name } },
      envelopeOf(event),
    )
  }

  const startApproval = (event) => {
    // An OpenCode without this leaves every approval to its own prompt.
    if (!io.approval || !ctx.client.permission?.reply) return
    const { id: requestID, sessionID } = event.data
    // Whole, never cut: Allow answers the request itself, so a card must show all it
    // allows. One too large for the helper is left to OpenCode's own prompt.
    const body = JSON.stringify({
      hook_event_name: event.type,
      cwd: directoryOf(event),
      tool: toolOf(event.data),
      data: event.data,
    })
    if (Buffer.byteLength(body) > PAYLOAD_LIMIT) return
    const running = io.approval(body, APPROVAL_LIMIT_MS, environmentOf(sessionID))
    running.root = rootOf(sessionID)
    approvals.set(requestID, running)
    running.result
      .then(async (output) => {
        if (approvals.get(requestID) !== running) return
        approvals.delete(requestID)
        const decision = parseDecision(output)
        if (!decision) return
        await ctx.client.permission.reply({ sessionID, requestID, ...decision })
      })
      .catch((error) => io.log?.(`approval failed: ${error}`))
  }

  const cancelApproval = (requestID) => {
    const running = approvals.get(requestID)
    approvals.delete(requestID)
    running?.cancel()
  }

  const toolOf = (data) => {
    const source = data.source?.id
    return (source && toolNames.get(source)) ?? data.action
  }

  /** What one event of a session this pane's turn is about means here. */
  const onTurnEvent = async (event, root, turn) => {
    const { type, data } = event
    const isRoot = data.sessionID === root
    switch (type) {
      case "session.step.started":
        // A subagent's model is not the session's.
        if (isRoot) await onSettings(event)
        return
      case "session.step.ended":
      case "session.step.failed":
        addTokens(turn, data.tokens)
        return
      case "session.text.ended":
        if (isRoot && data.text) turn.reply = bounded(data.text, REPLY_LIMIT)
        return
      case "session.tool.input.started":
        toolNames.set(data.id, data.name)
        return
      case "session.moved":
        turn.isPartial = true
        return
      case "permission.asked":
        turn.waits.add(data.id)
        toolNames.set(data.id, toolOf(data))
        await send(type, bounded(data), { tool: toolOf(data) }, envelopeOf(event))
        startApproval(event)
        return
      case "permission.replied":
        turn.waits.delete(data.requestID)
        cancelApproval(data.requestID)
        // A refusal says nothing of what comes next: the agent may go on or stop,
        // and the event that ends the execution says so.
        if (turn.waits.size === 0 && data.reply !== "reject") {
          await send(type, data, { tool: toolNames.get(data.requestID) }, envelopeOf(event))
        }
        return
      case "form.created":
        turn.waits.add(data.id)
        await send(type, bounded(data), {}, envelopeOf(event))
        return
      case "form.replied":
      case "form.cancelled":
        turn.waits.delete(data.id)
        if (turn.waits.size === 0) await send(type, { id: data.id, sessionID: data.sessionID }, {}, envelopeOf(event))
        return
      case "session.compaction.started":
        turn.isCompacting = true
        if (isRoot) await send(type, forwardedData(event), {}, envelopeOf(event))
        return
      case "session.compaction.ended":
      case "session.compaction.failed":
        turn.isCompacting = false
        addTokens(turn, data.tokens)
        if (isRoot) await send(type, { sessionID: data.sessionID, reason: data.reason }, {}, envelopeOf(event))
        return
      default:
        // A subagent's tools are the work of the agent's own tool that started it.
        if (isRoot && FORWARDED_EVENTS.has(type)) {
          const extra = toolExtra(event, turn)
          await send(type, forwardedData(event), extra, envelopeOf(event))
          if (type === "session.tool.success" && /\bworktree\b/.test(extra.command ?? "")) {
            finishWorktree(JSON.stringify({ hook_event_name: type, data: forwardedData(event), ...extra }))
          }
        }
    }
  }

  /**
   * The project's setup for a worktree the command may have made, which the runtime
   * judges. Apart from the reports: a bootstrap can take minutes, and the turn's
   * reports should not wait for it.
   */
  const finishWorktree = (body) => {
    if (!io.worktreeHook) return
    const runEnv = environmentOf(JSON.parse(body).data?.sessionID)
    worktrees = worktrees.then(() => io.worktreeHook(body, HOOK_LIMIT_MS, runEnv)).catch((error) => io.log?.(`worktree: ${error}`))
  }

  /** A tool's end says only its id, and the check it may be needs its command and where it ran. */
  const toolExtra = (event, turn) => {
    if (event.type === "session.tool.called" && typeof event.data.input?.command === "string") {
      const workdir = event.data.input.workdir
      toolCommands.set(event.data.id, {
        command: bounded(event.data.input.command),
        // What the runtime may prove a worktree's making from is the whole command.
        command_complete: event.data.input.command.length <= TEXT_LIMIT,
        cwd: typeof workdir === "string" ? resolve(turn.directory, workdir) : turn.directory,
      })
    }
    if (event.type !== "session.tool.success" && event.type !== "session.tool.failed") return {}
    const tool = toolCommands.get(event.data.id)
    toolCommands.delete(event.data.id)
    return tool ?? {}
  }

  const forwardedData = (event) => {
    const data = { ...bounded(event.data) }
    delete data.native
    if (data.id && !data.name) data.name = toolNames.get(data.id)
    // The model's copy of a tool's output can be megabytes; the exit status is in
    // the metadata.
    delete data.content
    return data
  }

  const handle = async (raw, endsBefore) => {
    // The one event whose fields sit a level down.
    const event = raw.type === "form.created" ? { ...raw, data: raw.data?.form } : raw
    const { type, data } = event
    if (!data || typeof type !== "string") return
    if (type === "session.created") {
      if (data.parentID) parents.set(data.sessionID, data.parentID)
      bornAt.set(data.sessionID, io.now())
      if (isSessionTitle(data.title)) titles.set(data.sessionID, data.title)
      return
    }
    if (type === "session.renamed") {
      if (!isSessionTitle(data.title)) return
      titles.set(data.sessionID, data.title)
      if (reported.has(data.sessionID)) await send("weir.title", { sessionID: data.sessionID }, { title: data.title })
      return
    }
    if (type === "session.inbox.enqueued") {
      const items = inboxes.get(data.sessionID) ?? []
      items.push({
        id: data.inboxID,
        type: data.item?.type,
        text: data.item?.payload?.text,
      })
      inboxes.set(data.sessionID, items)
      return
    }
    if (type === "session.inbox.delivered" || type === "session.inbox.cancelled") {
      const items = inboxes.get(data.sessionID)?.filter((item) => item.id !== data.inboxID)
      if (items) inboxes.set(data.sessionID, items)
      return
    }
    if (type === "session.execution.started") {
      await onStarted(event, endsBefore)
      return
    }
    if (!data.sessionID) return
    const root = rootOf(data.sessionID)
    const turn = turns.get(root)
    if (!turn) return
    if (data.sessionID === root) {
      if (type === "session.execution.succeeded" || type === "session.execution.failed") {
        await endTurn(turn, type, bounded(data), envelopeOf(event))
        return
      }
      if (type === "session.execution.interrupted") {
        await endTurn(turn, type, data, envelopeOf(event))
        return
      }
      if (type === "session.deleted") {
        await endTurn(turn, "session.execution.interrupted", { reason: "deleted" }, envelopeOf(event), { isPartial: true })
        return
      }
    }
    await onTurnEvent(event, root, turn)
  }

  /**
   * Checks the running turn against the service, for an end whose event never
   * came. A session at rest with no outcome is not a success: it closes short, as
   * stopped. So does one the service says is gone; any other failure to read says
   * nothing, and the next check tries again.
   */
  const reconcile = async () => {
    if (shownUnwritten && !shownFact) sayShownBody(shownUnwritten)
    await Promise.allSettled([...turns.values()].map(reconcileTurn))
  }

  const reconcileTurn = async (checked) => {
    const sessionID = checked.sessionID
    let info
    try {
      info = await ctx.client.session.get({ sessionID })
    } catch (error) {
      if (!isNotFound(error)) return
      await enqueue(async () => {
        if (turns.get(sessionID) !== checked) return
        running.delete(sessionID)
        await endTurn(checked, "session.execution.interrupted", { reason: "deleted" }, {}, { isPartial: true })
      })
      return
    }
    if (!info?.time) return
    const busy = info.time.busy ?? 0
    const idle = info.time.idle ?? 0
    if (idle < busy || idle === 0) return
    await enqueue(async () => {
      // What was read says nothing of a turn that began since.
      if (turns.get(sessionID) !== checked) return
      running.delete(sessionID)
      switch (info.outcome) {
        case "succeeded":
          await endTurn(checked, "session.execution.succeeded", {}, {}, { isPartial: true })
          return
        case "failed":
          await endTurn(
            checked,
            "session.execution.failed",
            { error: { type: "unknown", message: "" } },
            {},
            { isPartial: true },
          )
          return
        default:
          await endTurn(checked, "session.execution.interrupted", { reason: "reconciled" }, {}, { isPartial: true })
      }
    })
  }

  /**
   * Stops each execution this pane began that still runs: closing a pane, or
   * quitting its interface, stops its agent. Settles when the service has answered.
   * The service can stop only a session, whatever runs in it, so the session must
   * still be in the execution this pane began: `time.busy` says when its latest began.
   */
  const stopOwned = () =>
    Promise.allSettled(
      [...running].map(async ([sessionID, execution]) => {
        if (ctx.data.session.status(sessionID) !== "running") return
        const info = await Promise.resolve()
          .then(() => ctx.client.session.get({ sessionID }))
          .catch(() => undefined)
        if (execution.busy !== undefined && info?.time?.busy !== undefined && info.time.busy !== execution.busy) return
        if (running.get(sessionID) !== execution) return
        await ctx.client.session.interrupt({ sessionID })
      }),
    )

  /**
   * The interface is going, by the person's doing: stops what this pane began and
   * ends the turn's record as stopped, so the pane shows no crash. The report goes at
   * once, whatever the service is doing, and past any waiting on a slow hook; a hook
   * still at work when the process goes finishes alone.
   */
  const quit = () => {
    if (!quitting) {
      isQuitting = true
      quitting = Promise.allSettled([
        stopOwned(),
        ...[...turns.values()].map((turn) =>
          endTurn(turn, "session.execution.interrupted", { reason: "quit" }, {}, { isPartial: true }),
        ),
      ])
    }
    return quitting
  }

  /**
   * Asks the runtime to save the start of a turn, for Enter. Returns once it has
   * or the limit passed, never throwing: the input goes either way.
   */
  const prepare = async () => {
    const sessionID = sessionShown(ctx)
    // Before any wait, so the read of the screen and the start that may come during it
    // find the same run. A new session has no id yet: its run is named here and given
    // to it when it comes.
    const root = sessionID && rootOf(sessionID)
    if (!root) homeRun ??= nextRun()
    const run = root ? takeRun(root) : homeRun
    const generation = randomUUID()
    // Where the input will run. On the home screen that is the folder `/cd` chose,
    // where the new session is made, which may not be the one the interface began in.
    const directory = sessionID
      ? (ctx.data.session.get?.(sessionID)?.location?.directory ?? io.cwd())
      : (ctx.location?.directory ?? ctx.data.location?.default?.()?.directory ?? io.cwd())
    const saved = await io.prepare(
      JSON.stringify({ hook_event_name: "weir.prepare", preparation: generation, cwd: directory, data: {} }),
      PREPARE_LIMIT_MS,
      runEnvironment(run),
    )
    const entry = { generation: saved ? generation : undefined, session: sessionID, expected: true, run }
    preparation = entry
    io.setTimer(() => {
      if (preparation === entry) discardPreparation()
    }, PREPARATION_LIFETIME_MS)
  }

  /** Forgets the start saved for an input that will not go after all. */
  const discardPreparation = () => {
    preparation = undefined
    // No session came for the run it named. The launch's run goes back, or the next
    // session would take another, leaving the launch's with none, as a tab that is not.
    if (homeRun === launchRun) isLaunchRunTaken = false
    homeRun = undefined
  }

  /**
   * What a session already has, for a run that has seen none of it happen: its name and
   * its settings. A session resumed, reopened in a tab, or brought in from OpenCode's own
   * list was named before this run began, so no `session.renamed` comes for it.
   */
  const reportSavedSettings = async (sessionID) => {
    try {
      const info = await ctx.client.session.get({ sessionID })
      if (isSessionTitle(info?.title) && titles.get(sessionID) !== info.title) {
        titles.set(sessionID, info.title)
        await send("weir.title", { sessionID }, { title: info.title })
      }
      if (!info?.model) return
      await Promise.allSettled([
        ctx.data.location?.model?.sync?.(info.location),
        ctx.data.location?.provider?.sync?.(info.location),
      ])
      await onSettings({
        type: "session.step.started",
        location: info.location,
        data: { sessionID, agent: info.agent, model: info.model },
      })
    } catch (error) {
      io.log?.(`settings not read: ${error}`)
    }
  }

  /**
   * Delivers the latest of what is on screen, on the launch's run. Past the reports,
   * which can wait on a snapshot for seconds with the person already looking elsewhere,
   * and one at a time, so they land in order. Only the latest is worth writing, and
   * it is said until it is written: a busy record, or none yet because the launch's own
   * report has not landed, is reported by the hook, and nothing else would say it again.
   */
  const deliverShown = async () => {
    let wait = SHOWN_RETRY_MS
    let tries = 0
    while (shownFact && !isQuitting) {
      const fact = shownFact
      let status
      try {
        status = await io.hook(fact, HOOK_LIMIT_MS, {})
      } catch (error) {
        io.log?.(`report failed: ${error}`)
      }
      tries += 1
      if (shownFact !== fact) {
        wait = SHOWN_RETRY_MS
        tries = 0
        continue
      }
      if (status !== NOT_RECORDED_EXIT || tries >= SHOWN_TRIES) {
        // Out of tries, it is said again as the turns are checked, until written.
        shownUnwritten = status === NOT_RECORDED_EXIT ? fact : undefined
        shownFact = undefined
        break
      }
      await io.sleep(wait)
      wait = Math.min(wait * 2, SHOWN_RETRY_LIMIT_MS)
    }
    isDeliveringShown = false
  }

  const sayShownBody = (body) => {
    shownUnwritten = undefined
    shownFact = body
    if (isDeliveringShown) return
    isDeliveringShown = true
    shownDelivery = deliverShown()
  }

  const sayShown = (fact) => sayShownBody(JSON.stringify(fact))

  const reportShown = () => {
    if (!lastShown) return
    const sessionID = lastShown
    sayShown({
      hook_event_name: "weir.shown",
      data: { sessionID },
      shown_run: runs.get(sessionID),
      shown_home: false,
      cwd: directoryOf({ data: { sessionID } }),
    })
  }

  // A sibling's start, which waits in the reports, takes the pane's resume hint with
  // it when it lands. Saying what is on screen after it gives the hint back.
  const reportShownAfterStart = () => {
    reports = reports.then(() => reportShown()).catch((error) => io.log?.(`report failed: ${error}`))
  }

  const answerFocus = () => {
    if (!focusAnswer) return
    // The route itself, not its root: viewing a subagent, a paste would go to that view.
    const current = sessionShown(ctx)
    const isWanted = !focusAnswer.session || current === focusAnswer.session
    if (!isWanted && io.now() < focusAnswer.deadline) {
      io.setTimer(answerFocus, FOCUS_ANSWER_CHECK_MS)
      return
    }
    // The route read just now, however long the wait: what a paste goes by.
    io.answerFocus?.({
      nonce: focusAnswer.nonce,
      sessionId: current ?? null,
      // Apart: a subagent's view takes no paste meant for its session.
      rootSessionId: current ? rootOf(current) : null,
    })
    focusAnswer = undefined
  }

  /**
   * Takes a request of Weir's to bring a session forward, if it is a session of this
   * pane and not an old one, opening a tab closed since. One with a nonce is answered
   * with what the screen shows at that moment.
   */
  const checkFocus = () => {
    const request = io.takeFocusRequest?.()
    if (!request || io.now() - request.at > FOCUS_REQUEST_LIMIT_MS) return
    const isOurs = request.sessionId && runs.has(request.sessionId)
    if (isOurs) ctx.ui.tabs?.focus?.(request.sessionId)
    if (request.nonce) {
      focusAnswer = {
        nonce: request.nonce,
        session: request.sessionId,
        // One this pane cannot bring forward is answered at once.
        deadline: request.sessionId && !isOurs ? 0 : io.now() + FOCUS_ANSWER_LIMIT_MS,
      }
      answerFocus()
    }
  }

  /**
   * Reads the screen, which says nothing by event. A session seen first here gets its
   * run, so the header names what is on screen. A tab gone with its turn over ends its
   * run; closing a tab does not stop its execution, so a running one ends first, and
   * one left holding a question stays a wait, which going to it opens again.
   */
  const checkShown = () => {
    const tabs = ctx.ui.tabs?.list?.()
    if (tabs) {
      const open = new Set(tabs.map((tab) => tab.sessionID))
      for (const id of open) tabsSeen.add(id)
      for (const id of [...tabsSeen]) {
        if (open.has(id) || turns.has(id)) continue
        tabsSeen.delete(id)
        if (!reported.delete(id)) continue
        if (lastShown === id) lastShown = undefined
        enqueue(() => send("weir.closed", { sessionID: id }))
      }
    }
    const shown = sessionShown(ctx)
    // The home screen shows no session, and coming back to the last one says so again.
    if (!shown) {
      lastShown = undefined
      if (!isHomeReported) {
        isHomeReported = true
        sayShown({ hook_event_name: "weir.shown", data: {}, shown_home: true })
      }
      return undefined
    }
    isHomeReported = false
    const root = rootOf(shown)
    if (root === lastShown) return undefined
    lastShown = root
    takeRun(root, isHomeInputFor(root) ? preparation.run : undefined)
    reportShown()
    if (reported.has(root)) return undefined
    reportSession(
      root,
      directoryOf({ data: { sessionID: root } }),
      ctx.data.session.message?.list?.(root)?.length > 0 ? "resume" : "startup",
    )
    return enqueue(() => reportSavedSettings(root))
  }

  return {
    onEvent: (event) => {
      const sessionID = event?.data?.sessionID
      if (
        sessionID &&
        (event.type === "session.execution.succeeded" ||
          event.type === "session.execution.failed" ||
          event.type === "session.execution.interrupted" ||
          event.type === "session.deleted")
      ) {
        running.delete(sessionID)
        endsSeen.set(sessionID, (endsSeen.get(sessionID) ?? 0) + 1)
      }
      const endsBefore = endsSeen.get(sessionID) ?? 0
      return enqueue(() => handle(event, endsBefore))
    },
    rebind: (next) => {
      ctx = next
    },
    onKey: () => {
      lastKeyAt = io.now()
      shownAtLastKey = lastShown
    },
    prepare,
    discardPreparation,
    reconcile,
    checkShown,
    checkFocus,
    stopOwned,
    quit,
    launch: async (session) => {
      // The run rests with the session it resumes, so its first input names no
      // new one.
      if (session) {
        takeRun(session)
        reported.add(session)
      }
      await enqueue(() =>
        send("weir.launch", { sessionID: session }, { cwd: io.cwd(), pane_family: launchRun, auto_accept: autoAccepts }),
      )
      if (session) await reportSavedSettings(session)
    },
    state: () => ({ running, turn: [...turns.values()].at(-1), turns, runs, preparation }),
    settled: () =>
      queue
        .then(() => reports)
        .then(() => shownDelivery)
        .then(() => worktrees),
  }
}

function envelopeOf(event) {
  return { event_id: event.id, created: event.created, seq: event.durable?.seq }
}

/** The helper's answer: nothing means the person answers at OpenCode's own prompt. */
export function parseDecision(output) {
  const text = output?.trim()
  if (!text) return undefined
  try {
    const { decision, message } = JSON.parse(text)
    if (decision !== "once" && decision !== "reject") return undefined
    return message ? { decision, message } : { decision }
  } catch {
    return undefined
  }
}

/** Runs one child with `body` on stdin, killed at `limit`; resolves with its output and whether it finished. */
function runChild(command, args, body, limit, env) {
  const child = spawn(command, args, { stdio: ["pipe", "pipe", "ignore"], env })
  let output = ""
  const result = new Promise((resolve) => {
    const timer = setTimeout(() => child.kill("SIGKILL"), limit)
    child.stdout.on("data", (chunk) => {
      output += chunk
    })
    child.on("error", () => {
      clearTimeout(timer)
      resolve({ output: "", isFinished: false })
    })
    child.on("close", (code) => {
      clearTimeout(timer)
      resolve({ output, isFinished: code === 0, code })
    })
  })
  child.stdin.on("error", () => {})
  child.stdin.end(body)
  return { child, result }
}

/**
 * What the shim kept of the pane's environment for this launch, in `NAME=value`
 * entries each ended by a NUL. OpenCode hands the interface's environment to every
 * session it shows (`Env.session`, then `session.environment`), and a session's
 * commands run with it, so the variables cannot be in ours: a `claude` the agent
 * ran would report as this pane's. Taken once, so a nested OpenCode, which inherits
 * the file's name, finds nothing and stays unwatched. A plugin reloaded in this
 * process finds it kept here.
 */
export function paneEnvironment(path = process.env.WEIR_OPENCODE_PANE_ENV) {
  if (globalThis.weirPaneEnvironment) return globalThis.weirPaneEnvironment
  if (!path) return undefined
  let text
  try {
    text = readFileSync(path, "utf8")
    rmSync(path, { force: true })
  } catch {
    return undefined
  }
  const environment = {}
  for (const entry of text.split("\0")) {
    const separator = entry.indexOf("=")
    if (separator > 0) environment[entry.slice(0, separator)] = entry.slice(separator + 1)
  }
  globalThis.weirPaneEnvironment = environment
  return environment
}

/**
 * Where Weir asks this process to bring a session forward: beside the session records,
 * one file for each process, named by its launch's run. Not by the pane, which several
 * OpenCodes started under tmux share. It can only ever name a session.
 */
export function focusRequestPath(pane) {
  const run = pane.WEIR_AGENT_RUN_ID?.toUpperCase()
  if (!pane.WEIR_OPENCODE_SESSIONS_DIR || !/^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/.test(run ?? "")) {
    return undefined
  }
  return join(dirname(pane.WEIR_OPENCODE_SESSIONS_DIR), "tab-focus", `${run}.json`)
}

/**
 * Takes the request at `path`, so it is obeyed once: by renaming it, so what is read is
 * what is removed, and one Weir writes meanwhile stays for the next look. A session's id,
 * a nonce, and when it was asked are all it can say; anything else is no request.
 */
export function takeFocusRequest(path) {
  if (!path) return undefined
  const taken = `${path}.taken.${process.pid}`
  try {
    renameSync(path, taken)
  } catch {
    return undefined
  }
  try {
    const text = readFileSync(taken, "utf8")
    const { sessionId, nonce, at } = text.length <= 1024 ? JSON.parse(text) : {}
    if (typeof at !== "number") return undefined
    if (sessionId !== undefined && !(typeof sessionId === "string" && /^ses_[A-Za-z0-9]+$/.test(sessionId))) return undefined
    if (nonce !== undefined && !(typeof nonce === "string" && /^[A-Za-z0-9-]{1,64}$/.test(nonce))) return undefined
    return { sessionId, nonce, at }
  } catch {
    return undefined
  } finally {
    rmSync(taken, { force: true })
  }
}

/**
 * The answer to a request, beside it, written whole: Weir reads it as soon as it is
 * there. A file for each nonce, so one request's cleanup cannot take another's answer.
 */
export function writeFocusAnswer(path, answer) {
  if (!path) return
  const temporary = `${path}.${process.pid}.tmp`
  try {
    writeFileSync(temporary, JSON.stringify(answer), { mode: 0o600 })
    renameSync(temporary, `${path}.${answer.nonce}.answer`)
  } catch {
    rmSync(temporary, { force: true })
  }
}

/**
 * What a hook is told of the time it has: a little less than the wait for it, so it
 * stops the git it runs, which a kill of the hook does not reach, and reaps it before
 * it is killed.
 */
export function hookTimeLimit(limit) {
  return String(Math.max(1_000, limit - Math.min(2_000, Math.floor(limit / 5))))
}

/**
 * Whether the interface was started with `--auto`: a yargs boolean at v2.2.5 (its
 * `run` and TUI commands), so `--auto`, `--auto=true`, and `--auto true` turn it on and
 * `--no-auto` or `--auto=false` keep it off. It has no alias.
 */
export function autoAcceptsFrom(argv) {
  let isOn = false
  argv.forEach((word, index) => {
    if (word === "--auto") isOn = argv[index + 1] !== "false"
    else if (word === "--auto=true") isOn = true
    else if (word === "--auto=false" || word === "--no-auto") isOn = false
  })
  return isOn
}

/**
 * The Hook Helper beside the shim folder. `WEIR_HOOK_HELPER` is a test's, taken only
 * outside an app bundle, as the shell wrappers take it: a bundle's helper is the signed
 * one beside it, and nothing in the pane's environment chooses another.
 */
export function hookHelperPath(pane) {
  const hookDirectory = pane.WEIR_OPENCODE_HOOK_DIR
  const bundled = join(dirname(dirname(hookDirectory)), "MacOS", "AgentIntegrationHookHelper")
  if (/\.app\/Contents\/Resources\//.test(hookDirectory)) return bundled
  return pane.WEIR_HOOK_HELPER ?? bundled
}

function realIO(pane) {
  const hookDirectory = pane.WEIR_OPENCODE_HOOK_DIR
  const env = { ...process.env, ...pane }
  const hook = join(hookDirectory, "weir-hook")
  const helper = hookHelperPath(pane)
  const runHook = (args, body, limit, runEnv) =>
    runChild("/bin/sh", [hook, ...args], body, limit, { ...env, ...runEnv, WEIR_HOOK_TIME_LIMIT_MS: hookTimeLimit(limit) })
      .result
  return {
    now: () => Date.now(),
    // Not what keeps the process: a wait here must not hold up its going.
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms).unref?.()),
    setTimer: (work, ms) => setTimeout(work, ms).unref?.(),
    cwd: () => process.cwd(),
    launchPrompt: () => pane.WEIR_OPENCODE_LAUNCH_PROMPT === "1",
    launchPreparation: () => pane.WEIR_OPENCODE_LAUNCH_PREPARATION,
    launchRun: () => pane.WEIR_AGENT_RUN_ID,
    // `--auto` approves whatever a permission does not deny (`usePermission` in its
    // interface at v2.2.5). `session.permissions` in a config file does the same, and
    // a plugin can read no config, so that one goes unsaid.
    autoAccepts: () => autoAcceptsFrom(process.argv),
    takeFocusRequest: () => takeFocusRequest(focusRequestPath(pane)),
    answerFocus: (answer) => writeFocusAnswer(focusRequestPath(pane), answer),
    log: () => {},
    hook: async (body, limit, runEnv) => (await runHook([], body, limit, runEnv)).code,
    worktreeHook: async (body, limit, runEnv) => {
      await runHook(["worktree"], body, limit, runEnv)
    },
    prepare: async (body, limit, runEnv) => (await runHook([], body, limit, runEnv)).isFinished,
    approval: (body, limit, runEnv) => {
      const { child, result } = runChild(helper, ["permission-request", "opencode"], body, limit, { ...env, ...runEnv })
      return {
        result: result.then(({ output, isFinished }) => (isFinished ? output : "")),
        // The helper withdraws its request on this, then ends.
        cancel: () => child.kill("SIGTERM"),
      }
    },
  }
}

/**
 * The plugin's end: stops the agent only when the interface itself is going. A
 * signal's teardown runs this before the renderer goes, so it is said apart.
 */
export async function shutDown(ctx, supervisor, release, wasSignaled = false) {
  release()
  if (!wasSignaled && !ctx.renderer?.isDestroyed) return
  await Promise.race([supervisor.quit(), new Promise((resolve) => setTimeout(resolve, STOP_LIMIT_MS))])
}

/**
 * The only words the plugin shows itself. They live here rather than in
 * `Localizable.xcstrings`, which it cannot read: it runs inside OpenCode, outside the
 * app's bundle. The language comes from the locale variables, in POSIX's order.
 */
export function notSentMessage(env = process.env) {
  return /^ja/i.test(env.LC_ALL || env.LC_MESSAGES || env.LANG || "")
    ? "送信していません。開始点を保存している間に入力か画面が変わりました。もう一度 Enter を押してください。"
    : "Not sent: the prompt or session changed while Weir saved the turn’s start. Press Enter again."
}

export function installGate(ctx, supervisor) {
  // The person's key for sending, when they kept the default. With another one,
  // turns go without a saved start rather than Enter being taken from them.
  const shortcuts = ctx.keymap.shortcuts?.("input.submit")
  if (shortcuts && !shortcuts.some((key) => /^(return|enter)$/i.test(key))) return
  // What the latest Enter of the wait in progress asked to send.
  let waiting
  ctx.keymap.layer(() => ({
    priority: 1000,
    enabled: () => {
      const sessionID = sessionShown(ctx)
      if (sessionID && ctx.data.session.status(sessionID) === "running") return false
      return !hasWaits(ctx, sessionID) && promptHasWords(ctx)
    },
    commands: [
      {
        id: "weir.submit",
        title: "Weir: save the start of a turn, then send",
        bind: "return",
        run: async (_input, event) => {
          event?.preventDefault?.()
          event?.stopPropagation?.()
          // One wait at a time; a later Enter during it replaces the text to send.
          // `prompt.submit` sends whatever the prompt on screen holds when it runs,
          // so if that is not what the latest Enter saw, or the screen is on another
          // session, nothing goes and the prompt stays as it is.
          if (waiting) {
            waiting.text = promptText(ctx)
            return
          }
          const session = sessionShown(ctx)
          waiting = { text: promptText(ctx) }
          try {
            await supervisor.prepare()
          } catch {
            // The input still goes.
          }
          const { text } = waiting
          waiting = undefined
          if (sessionShown(ctx) !== session || promptText(ctx) !== text) {
            supervisor.discardPreparation?.()
            ctx.ui.toast?.show?.({ message: notSentMessage(), variant: "warning" })
            return
          }
          ctx.keymap.dispatch("prompt.submit")
        },
      },
    ],
  }))
}

export default {
  id: "weir",
  setup: async (ctx) => {
    const pane = paneEnvironment()
    if (!pane?.WEIR_PANE_ID || !pane.WEIR_OPENCODE_HOOK_DIR) return
    // Each of these holds up part of the run's record, and a record with a part
    // missing would say something false. An OpenCode that lacks one goes unwatched.
    const canSupervise =
      ctx?.data?.listen &&
      ctx?.data?.session?.status &&
      ctx?.data?.session?.permission?.list &&
      ctx?.data?.session?.form?.list &&
      ctx?.keymap?.layer &&
      ctx?.keymap?.dispatch &&
      ctx?.ui?.router?.current &&
      ctx?.client?.session?.interrupt
    if (!canSupervise) return
    try {
      // OpenCode reloads a changed plugin in place while the agent works, so what this
      // pane knows outlives each generation, and so does the one report of its launch.
      let supervisor = globalThis[SUPERVISOR_KEY]
      if (supervisor) {
        supervisor.rebind(ctx)
      } else {
        supervisor = createSupervisor(ctx, realIO(pane))
        globalThis[SUPERVISOR_KEY] = supervisor
        if (!globalThis[LAUNCHED_KEY]) {
          globalThis[LAUNCHED_KEY] = true
          supervisor.launch(pane.WEIR_OPENCODE_LAUNCH_SESSION || undefined)
        }
      }
      const stopListening = ctx.data.listen(({ details }) => supervisor.onEvent(details))
      const onKey = () => supervisor.onKey()
      ctx.renderer?.keyInput?.on?.("keypress", onKey)
      installGate(ctx, supervisor)
      const reconciling = setInterval(() => supervisor.reconcile().catch(() => {}), RECONCILE_INTERVAL_MS)
      reconciling.unref?.()
      // At once, as a key press means nothing without what the screen showed before it.
      supervisor.checkShown()
      const watchingFocus = setInterval(() => {
        try {
          supervisor.checkFocus()
        } catch {
          // The next look tries again.
        }
      }, FOCUS_POLL_MS)
      watchingFocus.unref?.()
      const watchingShown = setInterval(() => {
        try {
          supervisor.checkShown()
        } catch {
          // The next read tries again.
        }
      }, SHOWN_POLL_MS)
      watchingShown.unref?.()
      let wasSignaled = false
      const onSignal = () => {
        wasSignaled = true
        void supervisor.quit()
      }
      for (const signal of ["SIGHUP", "SIGTERM"]) process.on(signal, onSignal)
      // OpenCode awaits this before it exits, so Ctrl+C and `/exit` stop the agent as
      // closing the pane does. It also runs when OpenCode reloads a changed plugin,
      // where the interface goes on and so does the agent; only quitting has destroyed
      // the renderer by now, or follows a signal.
      return () =>
        shutDown(
          ctx,
          supervisor,
          () => {
            stopListening?.()
            ctx.renderer?.keyInput?.off?.("keypress", onKey)
            clearInterval(reconciling)
            clearInterval(watchingShown)
            clearInterval(watchingFocus)
            for (const signal of ["SIGHUP", "SIGTERM"]) process.off(signal, onSignal)
          },
          wasSignaled,
        )
    } catch {
      // A plain OpenCode, unwatched.
    }
  },
}
