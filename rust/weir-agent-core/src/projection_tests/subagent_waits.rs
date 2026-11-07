//! A subagent's wait outside a turn that the person answered at the agent's
//! own prompt. Codex runs no hook when the person declines a subagent's
//! request with Esc, and a subagent declined at Claude's prompt can end
//! without another tool, so the agent's status report (OSC 7501) is what
//! says nothing waits any more.

use super::*;

/// A run whose turn ended while `caller` waits on an approval, which opened
/// at 12:03:00, as did the record's last write, resting at `rest`
/// underneath.
fn waiting(caller: Option<&str>, rest: &str) -> ProjectionInput {
    waiting_since(caller, rest, "2026-09-14T12:03:00Z", "2026-09-14T12:03:00Z")
}

/// As `waiting`, with the wait opened at `opened` and the record last
/// written at `written`.
fn waiting_since(caller: Option<&str>, rest: &str, opened: &str, written: &str) -> ProjectionInput {
    let mut input = finished_input(Vec::new());
    let caller = caller.map_or(String::new(), |caller| format!(r#","caller":{caller}"#));
    let content = record(Some(5), written, "needsInput").replace(
        r#""state":"needsInput""#,
        &format!(
            r#""state":"needsInput","detail":"Bash: touch x","tool":"Bash","waitKind":"approval","waitStartedAt":"{opened}","outsideTurnRest":"{rest}","stateEpisodeToken":"5"{caller}"#
        ),
    );
    input.records = vec![file(Some(content))];
    input
}

const SUBAGENT: Option<&str> = Some(r#"{"subagent":"a1"}"#);

fn reporting(input: ProjectionInput, state: ProgramState, at: &str) -> ProjectionInput {
    let kind = (state == ProgramState::Blocked).then_some(BlockedKind::Permission);
    super::reported_status(input, &[], "claude-code", (state, kind), at)
}

fn pass(
    previous: &ProjectionState,
    input: &ProjectionInput,
) -> (ProjectionState, Projection, Vec<Command>) {
    project_with(previous, input, &now(), &mut |_, _| false)
}

fn notifies(commands: &[Command]) -> bool {
    commands
        .iter()
        .any(|command| matches!(command.op, CommandOp::Notify(_)))
}

/// Codex reported `done` once the person declined the subagent's request
/// with Esc; Claude reports `idle`, or `working` when the subagent goes on.
/// Each says the wait is gone, and the run shows the finish the parent's
/// stop left, quietly. Before, it waited until the next prompt.
#[test]
fn a_report_after_the_wait_returns_a_subagents_wait_to_its_rest() {
    let (state, projection, _) = pass(
        &ProjectionState::default(),
        &reporting(
            waiting(SUBAGENT, "finished"),
            ProgramState::Blocked,
            "2026-09-14T12:03:05Z",
        ),
    );
    assert_eq!(projection.runtimes[0].badge.state, RunState::NeedsInput);
    for report in [
        ProgramState::Done,
        ProgramState::Idle,
        ProgramState::Working,
    ] {
        let input = reporting(
            waiting(SUBAGENT, "finished"),
            report,
            "2026-09-14T12:03:10Z",
        );
        let (_, projection, commands) = pass(&state, &input);
        let badge = &projection.runtimes[0].badge;
        assert_eq!(badge.state, RunState::Finished, "{report:?}");
        assert_eq!(badge.wait_kind, None, "{report:?}");
        assert_eq!(badge.detail, None, "{report:?}");
        assert_eq!(badge.tool, None, "{report:?}");
        assert_eq!(badge.stop_reason, None, "{report:?}");
        assert!(!notifies(&commands), "{report:?}: the person answered it");
        assert!(
            !commands
                .iter()
                .any(|command| matches!(command.op, CommandOp::EndStoppedTurn { .. })),
            "{report:?}: the record is not written"
        );
    }
}

/// A wait that came at `idle` returns there.
#[test]
fn a_subagents_wait_at_idle_returns_to_idle() {
    let input = reporting(
        waiting(SUBAGENT, "idle"),
        ProgramState::Done,
        "2026-09-14T12:03:10Z",
    );
    let (_, projection, commands) = pass(&ProjectionState::default(), &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::Idle);
    assert_eq!(badge.wait_kind, None);
    assert_eq!(badge.detail, None);
    assert!(!notifies(&commands));
}

/// A report from before the wait opened, or from the second it opened (the
/// work that asked, reported a moment before the request was drawn), is no
/// evidence, and a `blocked` one says the request is still on screen.
#[test]
fn an_older_report_or_a_block_leaves_the_wait() {
    for (report, at) in [
        (ProgramState::Done, "2026-09-14T12:02:59Z"),
        (ProgramState::Working, "2026-09-14T12:03:00Z"),
        (ProgramState::Blocked, "2026-09-14T12:03:10Z"),
    ] {
        let input = reporting(waiting(SUBAGENT, "finished"), report, at);
        let (_, projection, _) = pass(&ProjectionState::default(), &input);
        let badge = &projection.runtimes[0].badge;
        assert_eq!(badge.state, RunState::NeedsInput, "{report:?} at {at}");
        assert_eq!(badge.wait_kind, Some(weir_agent_model::WaitKind::Approval));
        assert_eq!(badge.detail.as_deref(), Some("Bash: touch x"));
    }
}

/// The agent's own wait outside a turn is left to the idle prompt, which
/// reads the agent's transcript (`lifecycle::idle_outcome`), and a wait whose
/// caller the record does not know stays as before.
#[test]
fn the_agents_own_wait_or_one_of_no_known_caller_is_left() {
    for caller in [Some(r#""agent""#), None] {
        let input = reporting(
            waiting(caller, "finished"),
            ProgramState::Done,
            "2026-09-14T12:03:10Z",
        );
        let (_, projection, _) = pass(&ProjectionState::default(), &input);
        let badge = &projection.runtimes[0].badge;
        assert_eq!(badge.state, RunState::NeedsInput, "{caller:?}");
        assert_eq!(badge.wait_kind, Some(weir_agent_model::WaitKind::Approval));
        assert_eq!(badge.detail.as_deref(), Some("Bash: touch x"));
    }
}

/// Inside the parent's turn too: Codex runs no hook when the person declines
/// the subagent's request with Esc while the parent works on, and the
/// parent's own tools leave the wait. Its `working` report then shows the run
/// at work, with neither the wait's words nor its kind; a `blocked` one
/// leaves the wait.
#[test]
fn a_report_inside_the_turn_shows_the_run_at_work() {
    let in_a_turn = || {
        let mut input = waiting(SUBAGENT, "finished");
        let content = input.records[0].content.take().expect("content").replace(
            r#""stateEpisodeToken":"5""#,
            r#""stateEpisodeToken":"5","runStartedAt":"2026-09-14T12:02:00Z""#,
        );
        input.records[0].content = Some(content);
        input
    };
    let input = reporting(in_a_turn(), ProgramState::Working, "2026-09-14T12:03:10Z");
    let (_, projection, commands) = pass(&ProjectionState::default(), &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::Running);
    assert_eq!(badge.wait_kind, None);
    assert_eq!(badge.detail, None);
    assert_eq!(badge.tool, None);
    assert_eq!(
        badge.run_started_at.as_deref(),
        Some("2026-09-14T12:02:00Z")
    );
    assert!(!notifies(&commands));
    let input = reporting(in_a_turn(), ProgramState::Blocked, "2026-09-14T12:03:10Z");
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    assert_eq!(projection.runtimes[0].badge.state, RunState::NeedsInput);
}

/// Codex reports `done` as the parent's turn ends, a moment before the
/// stop's hook writes the record. The report came after the wait opened, so
/// it still ends the wait the stop left open, though the record changed after
/// it.
#[test]
fn a_report_before_the_stops_write_still_ends_the_wait() {
    let input = reporting(
        waiting_since(
            SUBAGENT,
            "finished",
            "2026-09-14T12:03:00Z",
            "2026-09-14T12:03:02Z",
        ),
        ProgramState::Done,
        "2026-09-14T12:03:01Z",
    );
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Finished);
}

/// A wait whose caller was only inferred counts as a subagent's.
#[test]
fn a_wait_of_an_inferred_caller_is_a_subagents_here() {
    let mut input = waiting(Some(r#""agent""#), "finished");
    let content = input.records[0].content.take().expect("content").replace(
        r#""stateEpisodeToken":"5""#,
        r#""stateEpisodeToken":"5","isCallerInferred":true"#,
    );
    input.records[0].content = Some(content);
    let input = reporting(input, ProgramState::Idle, "2026-09-14T12:03:10Z");
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Finished);
}
