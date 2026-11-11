//! These tests cover a wait only the agent's own status report shows: an MCP
//! server's request for input, a question left after the turn, a sign-in.
//! No hook announces them, so the projection reads them from the report the
//! pane last made (OSC 7501) and shows the run waiting until the next one.

use super::*;
use weir_agent_model::{CommandOutcome, NotificationKind, NotifyCommand, OnMismatch};

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

fn notices(commands: &[Command]) -> Vec<&NotifyCommand> {
    commands
        .iter()
        .filter_map(|command| match &command.op {
            CommandOp::Notify(notice) => Some(notice),
            _ => None,
        })
        .collect()
}

fn assert_no_record_write(commands: &[Command]) {
    assert!(
        commands.iter().all(|command| !matches!(
            command.op,
            CommandOp::Update(_) | CommandOp::EndStoppedTurn { .. }
        )),
        "{commands:?}"
    );
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
    let delivered = notices(&commands);
    let [notice] = delivered.as_slice() else {
        panic!("expected one notice, got {delivered:?}");
    };
    assert_eq!(notice.kind, NotificationKind::NeedsInput);
    assert_eq!(notice.provider, claude());
    assert_eq!(notice.pane, PANE.parse::<Uuid>().expect("pane"));
    assert_eq!(notice.runtime_id, format!("claude:{RUN}"));
    assert_no_record_write(&commands);

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
    let (_, projection, commands) = pass(&state, &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::Running);
    assert_eq!(badge.wait_kind, None);
    assert!(!notifies(&commands));
    assert_no_record_write(&commands);
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
    let (state, projection, first) = pass(&state, &question("2026-09-14T12:03:10Z"));
    assert_eq!(
        projection.runtimes[0].badge.wait_kind,
        Some(WaitKind::Question)
    );
    let first = notices(&first);
    let [notice] = first.as_slice() else {
        panic!("expected one first notice, got {first:?}");
    };
    assert_eq!(notice.kind, NotificationKind::NeedsInput);
    let mut same_question = question("2026-09-14T12:03:10Z");
    same_question.acknowledged = vec![CommandOutcome::Notified {
        runtime_id: notice.runtime_id.clone(),
        event_token: notice.event_token.clone(),
        state: RunState::NeedsInput,
    }];
    let (state, _, commands) = pass(&state, &same_question);
    assert!(!notifies(&commands), "the delivered question still waits");

    let answered = reporting(
        working(),
        ProgramState::Working,
        None,
        "2026-09-14T12:03:20Z",
    );
    let (state, projection, commands) = pass(&state, &answered);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Running);
    assert!(!notifies(&commands));

    let (_, projection, second) = pass(&state, &question("2026-09-14T12:03:30Z"));
    assert_eq!(
        projection.runtimes[0].badge.wait_kind,
        Some(WaitKind::Question)
    );
    let second = notices(&second);
    let [next] = second.as_slice() else {
        panic!("expected one second notice, got {second:?}");
    };
    assert_eq!(next.kind, NotificationKind::NeedsInput);
    assert_eq!(next.runtime_id, notice.runtime_id);
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
    let now = at("2026-09-14T12:03:12Z");
    let (previous, pending, _) =
        project_with(&ProjectionState::default(), &input, &now, &mut |_, _| false);
    assert_eq!(pending.next_pass_in_ms, Some(3_000));
    for status in input.program_status.values_mut() {
        status.state = ProgramState::Working;
        status.kind = None;
        status.observed_at = now.wall.clone();
        status.state_since = now.wall.clone();
    }
    let (_, projection, commands) = project_with(&previous, &input, &now, &mut |_, _| false);
    assert_eq!(projection.next_pass_in_ms, None);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Running);
    assert!(!notifies(&commands));
}

#[test]
fn a_closed_panes_auth_report_asks_for_no_later_pass() {
    let mut input = settling_auth("2026-09-14T12:03:10Z");
    let now = at("2026-09-14T12:03:12Z");
    let (previous, pending, _) =
        project_with(&ProjectionState::default(), &input, &now, &mut |_, _| false);
    assert_eq!(pending.next_pass_in_ms, Some(3_000));
    assert_eq!(
        pending.runtimes[0].panes,
        [PANE.parse::<Uuid>().expect("pane")]
    );

    input.tabs.clear();
    input.program_status.clear();
    let (_, projection, commands) = project_with(&previous, &input, &now, &mut |_, _| false);
    assert_eq!(projection.next_pass_in_ms, None);
    assert!(projection.badges.is_empty());
    assert!(!notifies(&commands));
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
    assert_eq!(projection.runtimes[0].badge.state, RunState::NeedsInput);
    assert_eq!(projection.next_pass_in_ms, None);
}

/// A run of the real Antigravity adapter whose pane reports `status` at
/// 12:03:10, passed at `wall`: what its descriptor declares has to reach these
/// rules under the name it gives its agent.
fn antigravity_badge(status: (ProgramState, Option<BlockedKind>), wall: &str) -> Badge {
    let descriptor = weir_provider_antigravity::AntigravityAdapter
        .descriptor()
        .clone();
    badge_under(descriptor, "antigravity", status, wall)
}

/// `antigravity_badge` for the real Kiro adapter, whose status reports carry
/// `kiro-cli` as their app.
fn kiro_badge(status: (ProgramState, Option<BlockedKind>), wall: &str) -> Badge {
    let descriptor = weir_provider_kiro::KiroAdapter.descriptor().clone();
    badge_under(descriptor, "kiro-cli", status, wall)
}

fn badge_under(
    descriptor: weir_agent_model::ProviderDescriptor,
    app: &str,
    status: (ProgramState, Option<BlockedKind>),
    wall: &str,
) -> Badge {
    let mut input = working();
    input.records[0].provider = descriptor.id.clone();
    input.program_status.insert(
        PANE.parse().expect("pane"),
        ProgramStatus {
            app: app.to_owned(),
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

/// Kiro's permission prompts and failures reach Weir only as status reports
/// (kiro-cli 3.2.0), so its descriptor has to read both. It declares no
/// settling of `auth`, which it has not been seen to send.
#[test]
fn kiros_own_descriptor_reads_its_status_reports() {
    let wall = "2026-09-14T12:03:10Z";
    assert_eq!(
        kiro_badge((ProgramState::Blocked, Some(BlockedKind::Permission)), wall).wait_kind,
        Some(WaitKind::Approval)
    );
    assert_eq!(
        kiro_badge((ProgramState::Error, None), wall).state,
        RunState::Error
    );
}

fn reporting_codex(
    mut input: ProjectionInput,
    state: ProgramState,
    kind: Option<BlockedKind>,
    at: &str,
) -> ProjectionInput {
    let descriptor = weir_provider_codex::CodexAdapter.descriptor().clone();
    for record in &mut input.records {
        record.provider = descriptor.id.clone();
    }
    input.providers = [(descriptor.id.clone(), descriptor)].into_iter().collect();
    input.program_status.insert(
        PANE.parse().expect("pane"),
        ProgramStatus {
            app: "codex".to_owned(),
            state,
            kind,
            observed_at: at.to_owned(),
            state_since: at.to_owned(),
        },
    );
    input
}

#[test]
fn a_question_left_after_the_turn_shows_on_a_finished_run() {
    let input = finished_input(Vec::new());
    let mut input = reporting_codex(input, ProgramState::Idle, None, "2026-09-14T12:03:00Z");
    input.records[0].content = Some(record(Some(4), "2026-09-14T12:03:00Z", "finished").replace(
        r#""state":"finished""#,
        r#""state":"finished","detail":"previous event""#,
    ));
    let (state, projection, _) = pass(&ProjectionState::default(), &input);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Finished);

    let blocked = reporting_codex(
        input.clone(),
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:03:10Z",
    );
    let (state, projection, commands) = pass(&state, &blocked);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::NeedsInput);
    assert_eq!(badge.wait_kind, Some(WaitKind::Question));
    assert_eq!(badge.detail, None);
    assert_eq!(badge.stop_reason, None);
    assert_no_record_write(&commands);

    let answered = reporting_codex(input, ProgramState::Idle, None, "2026-09-14T12:03:20Z");
    let (_, projection, commands) = pass(&state, &answered);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Finished);
    assert_eq!(projection.runtimes[0].badge.wait_kind, None);
    assert!(!notifies(&commands));
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
fn a_report_is_evidence_from_the_second_the_record_changed() {
    for (at, expected) in [
        ("2026-09-14T12:02:59Z", RunState::Running),
        ("2026-09-14T12:03:00Z", RunState::NeedsInput),
    ] {
        let input = reporting(
            working(),
            ProgramState::Blocked,
            Some(BlockedKind::Question),
            at,
        );
        let (_, projection, _) = pass(&ProjectionState::default(), &input);
        assert_eq!(projection.runtimes[0].badge.state, expected, "{at}");
    }
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
        r#""state":"unknown","waitKind":"approval","lastHookEvent":"session_ended""#,
    );
    input.records = vec![file(Some(content))];
    let input = reporting(
        input,
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:03:10Z",
    );
    let (_, projection, commands) = pass(&ProjectionState::default(), &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::Unknown);
    assert_eq!(badge.wait_kind, None);
    assert!(!notifies(&commands));
}

/// Two live records name the pane: the one that changed last is the agent
/// there now, and the report is its alone.
#[test]
fn of_two_runs_in_a_pane_only_the_latest_takes_its_report() {
    const NEWER: &str = "BBBBBBBB-2222-4222-8222-BBBBBBBBBBB2";
    let mut input = working();
    input.records[0].content = Some(record(Some(99), "2026-09-14T12:01:00Z", "running"));
    let newer = record(Some(3), "2026-09-14T12:03:00Z", "running").replace(RUN, NEWER);
    input.records.push(RecordFile {
        name: NEWER.to_owned(),
        ..file(Some(newer))
    });
    let mut input = reporting(
        input,
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:03:10Z",
    );
    for _ in 0..2 {
        let (_, projection, commands) = pass(&ProjectionState::default(), &input);
        let observed: BTreeMap<_, _> = projection
            .runtimes
            .iter()
            .map(|runtime| {
                (
                    runtime.run_id.as_deref().expect("run ID"),
                    runtime.badge.state,
                )
            })
            .collect();
        assert_eq!(
            observed,
            BTreeMap::from([(RUN, RunState::Running), (NEWER, RunState::NeedsInput)])
        );
        let delivered = notices(&commands);
        let [notice] = delivered.as_slice() else {
            panic!("expected one notice, got {delivered:?}");
        };
        assert_eq!(notice.kind, NotificationKind::NeedsInput);
        assert_eq!(notice.runtime_id, format!("claude:{NEWER}"));
        input.records.reverse();
    }
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
    let mut base = working();
    let content = base.records[0].content.as_mut().expect("record");
    *content = content.replace(
        r#""state":"running""#,
        r#""state":"running","detail":"earlier event""#,
    );
    let error = reporting(
        base.clone(),
        ProgramState::Error,
        None,
        "2026-09-14T12:03:10Z",
    );

    let (_, projection, commands) = pass(&ProjectionState::default(), &error);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(
        badge.state,
        RunState::Running,
        "provider does not announce failure by report"
    );
    assert_eq!(badge.detail.as_deref(), Some("earlier event"));
    assert!(badge.run_started_at.is_some());
    assert!(!notifies(&commands));

    let (state, projection, commands) =
        pass(&ProjectionState::default(), &announcing_failure(error));
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::Error);
    assert_eq!(badge.detail, None);
    assert_eq!(badge.run_started_at, None);
    assert_eq!(badge.stop_reason, None);
    let delivered = notices(&commands);
    let [notice] = delivered.as_slice() else {
        panic!("expected one failure notice, got {delivered:?}");
    };
    assert_eq!(notice.kind, NotificationKind::Failed);
    assert_eq!(notice.runtime_id, format!("claude:{RUN}"));
    assert!(!notice.presents_banner);
    assert_no_record_write(&commands);

    let recovered = announcing_failure(reporting(
        base,
        ProgramState::Working,
        None,
        "2026-09-14T12:03:20Z",
    ));
    let (_, projection, commands) = pass(&state, &recovered);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Running);
    assert!(!notifies(&commands));
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

/// A record as a restore leaves it, as `finished_input`'s file is named.
fn restored_input(attempted: &str) -> ProjectionInput {
    let mut input = finished_input(Vec::new());
    let content = record(Some(5), "2026-09-14T12:03:00Z", "unknown").replace(
        r#""state":"unknown""#,
        &format!(r#""state":"unknown","resumeAttemptedAt":"{attempted}""#),
    );
    input.records = vec![file(Some(content))];
    input
}

/// `codex resume` runs no hook before its first prompt, yet its status report
/// says it is there: the run rests at that prompt, with no news of it, and
/// the record it read is left as it was.
#[test]
fn a_restored_run_whose_agent_reports_rests_with_no_news() {
    let input = reporting_codex(
        restored_input("2026-09-14T12:05:00Z"),
        ProgramState::Idle,
        None,
        "2026-09-14T12:05:03Z",
    );
    let (state, projection, commands) = pass(&ProjectionState::default(), &input);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Idle);
    assert_eq!(state.accepted[RUN].record.state, RunState::Unknown);
    assert!(!notifies(&commands));
    assert_no_record_write(&commands);
}

/// A resume that failed leaves the shell in front, which reports nothing.
#[test]
fn a_restored_run_with_no_report_stays_unknown() {
    let (_, projection, _) = pass(
        &ProjectionState::default(),
        &restored_input("2026-09-14T12:05:00Z"),
    );
    assert_eq!(projection.runtimes[0].badge.state, RunState::Unknown);
}

/// A report from before the restore says nothing of the resume.
#[test]
fn a_report_from_before_the_restore_is_no_evidence_of_the_resume() {
    let input = reporting(
        restored_input("2026-09-14T12:05:00Z"),
        ProgramState::Idle,
        None,
        "2026-09-14T12:04:59Z",
    );
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Unknown);
}

/// A hook that wrote the record after the restore (`SessionEnd`, say) makes
/// it newer than the mark, and a report still standing does not bring it back.
#[test]
fn a_restored_run_whose_session_ended_stays_unknown_despite_a_report() {
    let mut input = restored_input("2026-09-14T12:02:00Z");
    input.records = vec![file(Some(
        record(Some(5), "2026-09-14T12:03:00Z", "unknown").replace(
            r#""state":"unknown""#,
            r#""state":"unknown","lastHookEvent":"session_ended","resumeAttemptedAt":"2026-09-14T12:02:00Z""#,
        ),
    ))];
    let input = reporting_codex(input, ProgramState::Idle, None, "2026-09-14T12:03:10Z");
    let (_, projection, commands) = pass(&ProjectionState::default(), &input);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Unknown);
    assert!(!notifies(&commands));
    assert_no_record_write(&commands);
}

/// The record survives when the command returns to the shell before its
/// first prompt. A fresh report can attach it to the same pane again.
#[test]
fn a_restored_run_detaches_at_the_shell_and_reattaches_after_a_new_report() {
    let pane = PANE.parse::<Uuid>().expect("pane");
    let mut input = reporting_codex(
        restored_input("2026-09-14T12:05:00Z"),
        ProgramState::Idle,
        None,
        "2026-09-14T12:05:03Z",
    );
    let (state, projection, _) = pass(&ProjectionState::default(), &input);
    assert_eq!(
        projection.runtimes[0].attachment,
        AttachmentResolution::Attached
    );
    assert_eq!(projection.runtimes[0].panes, [pane]);

    input.panes_back_at_shell.insert(pane);
    input.program_status.clear();
    let (state, projection, commands) = pass(&state, &input);
    assert_eq!(
        projection.runtimes[0].attachment,
        AttachmentResolution::Detached
    );
    assert!(projection.runtimes[0].panes.is_empty());
    assert!(resume_retirement_commands(&commands).is_empty());

    let input = reporting_codex(input, ProgramState::Idle, None, "2026-09-14T12:06:00Z");
    let (_, projection, commands) = pass(&state, &input);
    let runtime = &projection.runtimes[0];
    assert_eq!(runtime.run_id.as_deref(), Some(RUN));
    assert_eq!(runtime.attachment, AttachmentResolution::Attached);
    assert_eq!(runtime.panes, [pane]);
    assert_eq!(runtime.badge.state, RunState::Idle);
    assert!(!notifies(&commands));
}

/// A tmux client returning to the shell leaves the run alive in tmux.
#[test]
fn a_restored_tmux_run_keeps_its_place_when_the_client_returns_to_the_shell() {
    let mut input = restored_input("2026-09-14T12:05:00Z");
    let content = input.records[0].content.as_mut().expect("record");
    *content = content.replace(
        r#""state":"unknown""#,
        r#""state":"unknown","isTmuxHosted":true,"tmuxSocketPath":"/tmp/socket","tmuxPaneId":"%3","tmuxServerPID":"42","tmuxServerStartedAt":"100""#,
    );
    let pane = PANE.parse::<Uuid>().expect("pane");
    input
        .presence
        .attachments
        .insert("/tmp/socket|42|100|%3".into(), vec![pane]);
    let (state, projection, _) = pass(&ProjectionState::default(), &input);
    assert_eq!(
        projection.runtimes[0].attachment,
        AttachmentResolution::Attached
    );
    assert_eq!(projection.runtimes[0].panes, [pane]);

    input.panes_back_at_shell.insert(pane);
    let (_, projection, commands) = pass(&state, &input);
    assert_eq!(
        projection.runtimes[0].attachment,
        AttachmentResolution::Attached
    );
    assert_eq!(projection.runtimes[0].panes, [pane]);
    assert!(resume_retirement_commands(&commands).is_empty());

    // A hosted run whose endpoint has yet to be recorded is still unresolved.
    let mut unresolved = restored_input("2026-09-14T12:05:00Z");
    let content = unresolved.records[0].content.as_mut().expect("record");
    *content = content.replace(
        r#""state":"unknown""#,
        r#""state":"unknown","isTmuxHosted":true"#,
    );
    unresolved.panes_back_at_shell.insert(pane);
    let (_, projection, commands) = pass(&ProjectionState::default(), &unresolved);
    assert_eq!(
        projection.runtimes[0].attachment,
        AttachmentResolution::Unresolved
    );
    assert!(resume_retirement_commands(&commands).is_empty());
}

/// Records of a resume that ended before its first prompt: the run it came
/// from, as a restore left it, and the new run its `SessionEnd` wrote.
fn resume_ended_input(ended_at: &str, ended_session: &str) -> ProjectionInput {
    const ENDED: &str = "22222222-2222-4222-8222-222222222222";
    let mut input = restored_input("2026-09-14T12:05:00Z");
    let session = r#""state":"unknown","sessionId":"s1""#;
    let restored = input.records[0]
        .content
        .clone()
        .expect("record")
        .replace(r#""state":"unknown""#, session);
    let ended = format!(
        r#"{{"schemaVersion":3,"paneId":"{PANE}","runId":"{ENDED}","revision":1,"state":"unknown","updatedAt":"{ended_at}","lastHookEvent":"session_ended","sessionId":"{ended_session}","pid":"77"}}"#
    );
    input.records = vec![
        file(Some(restored)),
        RecordFile {
            provider: claude(),
            name: ENDED.to_owned(),
            content: Some(ended),
        },
    ];
    input.pid_status.insert("77".to_owned(), PidStatus::Alive);
    input
}

/// Retirement or hint-deletion commands, including commands in a chain.
fn resume_retirement_commands(commands: &[Command]) -> Vec<&Command> {
    fn collect<'a>(commands: &'a [Command], selected: &mut Vec<&'a Command>) {
        for command in commands {
            if matches!(command.op, CommandOp::Retire)
                || matches!(command.target, Target::SessionHint { .. })
            {
                selected.push(command);
            }
            collect(&command.then, selected);
        }
    }
    let mut selected = Vec::new();
    collect(commands, &mut selected);
    selected
}

#[test]
fn a_restored_run_is_retired_only_by_a_fresh_end_of_its_own_session() {
    for (label, at, session, retires) in [
        ("matching end", "2026-09-14T12:05:30Z", "s1", true),
        ("other conversation", "2026-09-14T12:05:30Z", "s2", false),
        ("older than resume", "2026-09-14T12:04:30Z", "s1", false),
    ] {
        let (_, _, commands) = pass(
            &ProjectionState::default(),
            &resume_ended_input(at, session),
        );
        let relevant = resume_retirement_commands(&commands);
        if !retires {
            assert!(relevant.is_empty(), "{label}: {relevant:?}");
            continue;
        }
        let [hint, record] = relevant.as_slice() else {
            panic!("{label}: expected a hint and its record, got {relevant:?}");
        };
        assert_eq!(hint.op, CommandOp::Delete);
        assert_eq!(
            hint.target,
            Target::SessionHint {
                provider: claude(),
                pane: PANE.parse().expect("pane"),
            }
        );
        assert_eq!(
            hint.expect,
            Precondition::HintOwner {
                run_id: Some(RUN.into())
            }
        );
        assert_eq!(hint.on_mismatch, OnMismatch::Continue);
        assert_eq!(hint.then.as_slice(), std::slice::from_ref(*record));
        assert_eq!(record.op, CommandOp::Retire);
        assert_eq!(
            record.target,
            Target::Record {
                provider: claude(),
                storage_id: RUN.into()
            }
        );
        assert_eq!(
            record.expect,
            Precondition::RecordUnchanged {
                storage_id: RUN.into(),
                revision: Some(5),
                pid: None,
                updated_at: "2026-09-14T12:03:00Z".into(),
            }
        );
    }
}
