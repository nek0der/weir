//! These tests cover a wait only the agent's own status report shows: an MCP
//! server's request for input, a question left after the turn, a sign-in.
//! No hook announces them, so the projection reads them from the report the
//! pane last made (OSC 7501) and shows the run waiting until the next one.

use super::*;

/// A run at work inside a turn, whose record last changed at 12:03:00.
fn working() -> ProjectionInput {
    let mut input = finished_input(Vec::new());
    let content = record(Some(5), "2026-09-14T12:03:00Z", "running").replace(
        r#""state":"running""#,
        r#""state":"running","tool":"mcp__docs__search","runStartedAt":"2026-09-14T12:02:00Z","stateEpisodeToken":"5""#,
    );
    input.records = vec![file(Some(content))];
    input
}

/// `input` with the pane last reporting `state` and `kind` at `at`.
fn reporting(
    input: ProjectionInput,
    state: ProgramState,
    kind: Option<BlockedKind>,
    at: &str,
) -> ProjectionInput {
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

#[test]
fn a_permission_report_is_a_wait_for_a_provider_that_announces_it_no_other_way() {
    let mut input = reporting(
        working(),
        ProgramState::Blocked,
        Some(BlockedKind::Permission),
        "2026-09-14T12:03:10Z",
    );
    for descriptor in input.providers.values_mut() {
        descriptor
            .capabilities
            .insert(Capability::ProgramStatusAnnouncesPermission);
    }
    let (state, projection, commands) = pass(&ProjectionState::default(), &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::NeedsInput);
    assert_eq!(badge.wait_kind, Some(WaitKind::Approval));
    assert!(notifies(&commands), "a new wait is news");

    // The person allowed it; the agent reports its work again.
    let mut input = reporting(
        working(),
        ProgramState::Working,
        None,
        "2026-09-14T12:03:20Z",
    );
    for descriptor in input.providers.values_mut() {
        descriptor
            .capabilities
            .insert(Capability::ProgramStatusAnnouncesPermission);
    }
    let (_, projection, _) = pass(&state, &input);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Running);
}

#[test]
fn a_question_report_shows_the_run_waiting_and_announces_it() {
    let (state, projection, _) = pass(&ProjectionState::default(), &working());
    assert_eq!(projection.runtimes[0].badge.state, RunState::Running);

    // An MCP server asked for input: the agent reports a block on a question.
    let input = reporting(
        working(),
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:03:10Z",
    );
    let (state, projection, commands) = pass(&state, &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::NeedsInput);
    assert_eq!(badge.wait_kind, Some(WaitKind::Question));
    assert_eq!(badge.detail, None, "the report carries no words Weir reads");
    assert_eq!(badge.tool, None);
    assert!(notifies(&commands), "a new wait is news");

    // The person answered; the agent reports its work again.
    let input = reporting(
        working(),
        ProgramState::Working,
        None,
        "2026-09-14T12:03:20Z",
    );
    let (_, projection, commands) = pass(&state, &input);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Running);
    assert!(!notifies(&commands));
}

/// A second request in the same turn writes no record, so it waits in the
/// episode of the first; it is still a new wait, and announced as one.
#[test]
fn a_second_question_in_the_same_turn_is_announced_again() {
    let question = |at| {
        reporting(
            working(),
            ProgramState::Blocked,
            Some(BlockedKind::Question),
            at,
        )
    };
    let (state, _, _) = pass(&ProjectionState::default(), &working());
    let (state, _, first) = pass(&state, &question("2026-09-14T12:03:10Z"));
    let answered = reporting(
        working(),
        ProgramState::Working,
        None,
        "2026-09-14T12:03:20Z",
    );
    let (state, _, _) = pass(&state, &answered);
    let (_, projection, second) = pass(&state, &question("2026-09-14T12:03:30Z"));
    assert_eq!(projection.runtimes[0].badge.state, RunState::NeedsInput);
    assert!(notifies(&first));
    assert!(notifies(&second), "the second wait is news too");
}

#[test]
fn an_auth_report_shows_the_run_waiting_on_a_sign_in() {
    let input = reporting(
        working(),
        ProgramState::Blocked,
        Some(BlockedKind::Auth),
        "2026-09-14T12:03:10Z",
    );
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::NeedsInput);
    assert_eq!(badge.wait_kind, Some(WaitKind::SignIn));
}

/// `input` with its providers declaring that an `auth` report settles, and
/// the pane reporting `auth` since `since`.
fn settling_auth(since: &str) -> ProjectionInput {
    let mut input = reporting(
        working(),
        ProgramState::Blocked,
        Some(BlockedKind::Auth),
        "2026-09-14T12:03:10Z",
    );
    for descriptor in input.providers.values_mut() {
        descriptor
            .capabilities
            .insert(Capability::ProgramStatusAuthSettles);
    }
    for status in input.program_status.values_mut() {
        status.state_since = since.to_owned();
    }
    input
}

fn at(wall: &str) -> Instants {
    Instants {
        wall: wall.to_owned(),
        ..now()
    }
}

#[test]
fn an_auth_report_that_settles_is_no_wait_and_no_news_until_it_has_stood() {
    let input = settling_auth("2026-09-14T12:03:10Z");
    let (state, projection, commands) = project_with(
        &ProjectionState::default(),
        &input,
        &at("2026-09-14T12:03:12Z"),
        &mut |_, _| false,
    );
    assert_eq!(projection.runtimes[0].badge.state, RunState::Running);
    assert_eq!(projection.runtimes[0].badge.wait_kind, None);
    assert!(!notifies(&commands), "the agent is only starting");
    assert_eq!(
        projection.next_pass_in_ms,
        Some(3_000),
        "nothing else asks for the pass that shows it"
    );

    // Nothing more came: it is a sign-in the person has to make.
    let (_, projection, commands) =
        project_with(&state, &input, &at("2026-09-14T12:03:15Z"), &mut |_, _| {
            false
        });
    assert_eq!(projection.runtimes[0].badge.state, RunState::NeedsInput);
    assert_eq!(
        projection.runtimes[0].badge.wait_kind,
        Some(WaitKind::SignIn)
    );
    assert!(notifies(&commands), "a wait that stands is news");
    assert_eq!(projection.next_pass_in_ms, None);
}

#[test]
fn a_repeated_auth_report_settles_from_its_first() {
    // `settling_auth` reports at 12:03:10, the last of the repeats.
    let input = settling_auth("2026-09-14T12:03:04Z");
    let (_, projection, _) = project_with(
        &ProjectionState::default(),
        &input,
        &at("2026-09-14T12:03:10Z"),
        &mut |_, _| false,
    );
    assert_eq!(
        projection.runtimes[0].badge.wait_kind,
        Some(WaitKind::SignIn)
    );
}

#[test]
fn a_report_after_the_auth_asks_for_no_later_pass() {
    let mut input = settling_auth("2026-09-14T12:03:10Z");
    for status in input.program_status.values_mut() {
        status.state = ProgramState::Working;
        status.kind = None;
    }
    let (_, projection, _) = project_with(
        &ProjectionState::default(),
        &input,
        &at("2026-09-14T12:03:12Z"),
        &mut |_, _| false,
    );
    assert_eq!(projection.next_pass_in_ms, None);
}

#[test]
fn a_closed_panes_auth_report_asks_for_no_later_pass() {
    let mut input = settling_auth("2026-09-14T12:03:10Z");
    input.program_status.clear();
    let (_, projection, _) = project_with(
        &ProjectionState::default(),
        &input,
        &at("2026-09-14T12:03:12Z"),
        &mut |_, _| false,
    );
    assert_eq!(projection.next_pass_in_ms, None);
}

#[test]
fn an_auth_report_of_a_provider_that_does_not_settle_is_a_wait_at_once() {
    let mut input = settling_auth("2026-09-14T12:03:10Z");
    for descriptor in input.providers.values_mut() {
        descriptor
            .capabilities
            .remove(&Capability::ProgramStatusAuthSettles);
    }
    let (_, projection, _) = project_with(
        &ProjectionState::default(),
        &input,
        &at("2026-09-14T12:03:10Z"),
        &mut |_, _| false,
    );
    assert_eq!(
        projection.runtimes[0].badge.wait_kind,
        Some(WaitKind::SignIn)
    );
    assert_eq!(projection.next_pass_in_ms, None);
}

/// A run of the real Antigravity adapter whose pane reports `status` at
/// 12:03:10, passed at `wall`: what its descriptor declares has to reach these
/// rules under the name it gives its agent.
fn antigravity_badge(status: (ProgramState, Option<BlockedKind>), wall: &str) -> Badge {
    let descriptor = weir_provider_antigravity::AntigravityAdapter
        .descriptor()
        .clone();
    let mut input = working();
    input.records[0].provider = descriptor.id.clone();
    input.program_status.insert(
        PANE.parse().expect("pane"),
        ProgramStatus {
            app: descriptor.program_status_app.clone().expect("app"),
            state: status.0,
            kind: status.1,
            observed_at: "2026-09-14T12:03:10Z".to_owned(),
            state_since: "2026-09-14T12:03:10Z".to_owned(),
        },
    );
    input.providers = [(descriptor.id.clone(), descriptor)].into_iter().collect();
    let (_, projection, _) = project_with(
        &ProjectionState::default(),
        &input,
        &at(wall),
        &mut |_, _| false,
    );
    projection.runtimes[0].badge.clone()
}

#[test]
fn antigravitys_own_descriptor_reads_its_status_reports() {
    let wall = "2026-09-14T12:03:10Z";
    let blocked = |kind| (ProgramState::Blocked, Some(kind));
    assert_eq!(
        antigravity_badge(blocked(BlockedKind::Permission), wall).wait_kind,
        Some(WaitKind::Approval)
    );
    assert_eq!(
        antigravity_badge((ProgramState::Error, None), wall).state,
        RunState::Error
    );
    assert_eq!(
        antigravity_badge(blocked(BlockedKind::Auth), wall).wait_kind,
        None,
        "not yet: it sends one at every start"
    );
    assert_eq!(
        antigravity_badge(blocked(BlockedKind::Auth), "2026-09-14T12:03:15Z").wait_kind,
        Some(WaitKind::SignIn)
    );
}

#[test]
fn a_question_left_after_the_turn_shows_on_a_finished_run() {
    // Codex blocks on an async question only once its turn is over.
    let input = reporting(
        finished_input(Vec::new()),
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:03:10Z",
    );
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::NeedsInput);
    assert_eq!(badge.wait_kind, Some(WaitKind::Question));
    assert_eq!(badge.stop_reason, None);
}

#[test]
fn a_block_without_a_question_or_a_sign_in_changes_nothing() {
    // A permission request comes with its own hook, and a block with no kind
    // is a dialog of the agent's own.
    for kind in [Some(BlockedKind::Permission), None] {
        let input = reporting(
            working(),
            ProgramState::Blocked,
            kind,
            "2026-09-14T12:03:10Z",
        );
        let (_, projection, _) = pass(&ProjectionState::default(), &input);
        assert_eq!(
            projection.runtimes[0].badge.state,
            RunState::Running,
            "{kind:?}"
        );
    }
}

#[test]
fn a_report_from_before_the_record_changed_is_no_evidence() {
    let input = reporting(
        working(),
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:02:59Z",
    );
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Running);
}

#[test]
fn a_hook_question_keeps_its_own_words() {
    let mut input = finished_input(Vec::new());
    let content = record(Some(5), "2026-09-14T12:03:00Z", "needsInput").replace(
        r#""state":"needsInput""#,
        r#""state":"needsInput","waitKind":"question","tool":"AskUserQuestion","detail":"Which color?""#,
    );
    input.records = vec![file(Some(content))];
    let input = reporting(
        input,
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:03:10Z",
    );
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.wait_kind, Some(WaitKind::Question));
    assert_eq!(badge.detail.as_deref(), Some("Which color?"));
}

/// An approval for the record, as its hook wrote it at 12:03:00.
fn approval() -> ProjectionInput {
    let mut input = finished_input(Vec::new());
    let content = record(Some(5), "2026-09-14T12:03:00Z", "needsInput").replace(
        r#""state":"needsInput""#,
        r#""state":"needsInput","waitKind":"approval","tool":"mcp__docs__search","detail":"mcp__docs__search""#,
    );
    input.records = vec![file(Some(content))];
    input
}

/// While the approval is up, the agent's report of it changes nothing: the
/// hook's wait names the tool.
#[test]
fn an_approval_keeps_its_words_while_the_agent_reports_it() {
    let input = reporting(
        approval(),
        ProgramState::Blocked,
        Some(BlockedKind::Permission),
        "2026-09-14T12:03:00Z",
    );
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.wait_kind, Some(WaitKind::Approval));
    assert_eq!(badge.detail.as_deref(), Some("mcp__docs__search"));
}

/// No hook says an approval was answered. The MCP tool it allowed then asks
/// for input, and the agent reports a question: that is the wait now.
#[test]
fn a_question_reported_after_an_approval_is_the_wait_now() {
    let input = reporting(
        approval(),
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:03:20Z",
    );
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::NeedsInput);
    assert_eq!(badge.wait_kind, Some(WaitKind::Question));
    assert_eq!(badge.detail, None);
    assert_eq!(badge.tool, None);
}

#[test]
fn a_report_from_another_program_in_the_pane_is_not_the_agent_s() {
    let input = super::reported_status(
        working(),
        &[],
        "some-other-tool",
        (ProgramState::Blocked, Some(BlockedKind::Question)),
        "2026-09-14T12:03:10Z",
    );
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Running);
}

/// A run killed with its pane still open, whose record a resume still
/// claims, is not the agent that reports in the pane now: the new agent's
/// wait is not announced a second time under the dead run.
#[test]
fn a_dead_run_still_claimed_by_a_resume_takes_no_report_from_its_pane() {
    let mut input = working();
    let content = input.records[0]
        .content
        .clone()
        .expect("record")
        .replace(r#""state":"running""#, r#""state":"running","pid":"4242""#);
    input.records = vec![file(Some(content))];
    input.pid_status = [("4242".to_owned(), PidStatus::Dead)].into();
    input.resume_intents = vec![weir_agent_model::ResumeIntent {
        run_id: RUN.to_owned(),
        pane_id: PANE.parse().expect("pane"),
        session_id: "session".to_owned(),
        owner_run_id: None,
        pid: "4242".to_owned(),
        created_at: "2026-10-12T00:00:30Z".to_owned(),
    }];
    let input = reporting(
        input,
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:03:10Z",
    );
    let (_, projection, commands) = pass(&ProjectionState::default(), &input);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Running);
    assert!(!notifies(&commands));
}

/// A run whose session ended stays on record (its last wait still named) but
/// is not the agent in the pane any more: the new agent's question is not
/// its wait.
#[test]
fn a_run_whose_session_ended_takes_no_report_from_its_pane() {
    let mut input = finished_input(Vec::new());
    let content = record(Some(5), "2026-09-14T12:03:00Z", "unknown").replace(
        r#""state":"unknown""#,
        r#""state":"unknown","waitKind":"approval""#,
    );
    input.records = vec![file(Some(content))];
    let input = reporting(
        input,
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:03:10Z",
    );
    let (_, projection, commands) = pass(&ProjectionState::default(), &input);
    assert_ne!(projection.runtimes[0].badge.state, RunState::NeedsInput);
    assert!(!notifies(&commands));
}

/// Two live records name the pane: the one that changed last is the agent
/// there now, and the report is its alone.
#[test]
fn of_two_runs_in_a_pane_only_the_latest_takes_its_report() {
    let mut input = working();
    let older = record(Some(3), "2026-09-14T12:01:00Z", "running")
        .replace(RUN, "BBBBBBBB-2222-4222-8222-BBBBBBBBBBB2");
    input.records.push(RecordFile {
        name: "BBBBBBBB-2222-4222-8222-BBBBBBBBBBB2".to_owned(),
        ..file(Some(older))
    });
    let input = reporting(
        input,
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:03:10Z",
    );
    let (_, projection, commands) = pass(&ProjectionState::default(), &input);
    let waiting: Vec<_> = projection
        .runtimes
        .iter()
        .filter(|runtime| runtime.badge.state == RunState::NeedsInput)
        .map(|runtime| runtime.run_id.clone())
        .collect();
    assert_eq!(waiting, [Some(RUN.to_owned())]);
    assert_eq!(
        commands
            .iter()
            .filter(|command| matches!(command.op, CommandOp::Notify(_)))
            .count(),
        1
    );
}

/// `input` with its providers declaring that a report of `error` is a failure.
fn announcing_failure(mut input: ProjectionInput) -> ProjectionInput {
    for descriptor in input.providers.values_mut() {
        descriptor
            .capabilities
            .insert(Capability::ProgramStatusAnnouncesFailure);
    }
    input
}

#[test]
fn an_error_report_is_a_failure_for_a_provider_that_announces_it_no_other_way() {
    let input = announcing_failure(reporting(
        working(),
        ProgramState::Error,
        None,
        "2026-09-14T12:03:10Z",
    ));
    let (state, projection, commands) = pass(&ProjectionState::default(), &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::Error);
    assert_eq!(badge.detail, None);
    assert_eq!(badge.stop_reason, None);
    assert!(notifies(&commands), "a new failure is news");

    // The person tried again; the agent reports its work.
    let input = announcing_failure(reporting(
        working(),
        ProgramState::Working,
        None,
        "2026-09-14T12:03:20Z",
    ));
    let (_, projection, _) = pass(&state, &input);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Running);
}

#[test]
fn an_error_report_changes_nothing_without_the_capability() {
    let input = reporting(working(), ProgramState::Error, None, "2026-09-14T12:03:10Z");
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Running);
}

#[test]
fn an_error_report_leaves_the_words_of_a_failure_a_hook_announced() {
    let mut input = finished_input(Vec::new());
    let content = record(Some(5), "2026-09-14T12:03:00Z", "error").replace(
        r#""state":"error""#,
        r#""state":"error","detail":"quota exhausted""#,
    );
    input.records = vec![file(Some(content))];
    let input = announcing_failure(reporting(
        input,
        ProgramState::Error,
        None,
        "2026-09-14T12:03:10Z",
    ));
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::Error);
    assert_eq!(badge.detail.as_deref(), Some("quota exhausted"));
}
