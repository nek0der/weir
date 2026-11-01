//! Several sessions of one process in one pane, each with its own run: what the
//! projection keeps of a session the pane does not show, and what it no longer calls
//! seen.

use super::*;
use weir_agent_model::RunState;

const SHOWN: &str = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1";
const BEHIND: &str = "BBBBBBBB-1111-4111-8111-BBBBBBBBBBB2";
const OTHER_PANE: &str = "22222222-2222-4222-8222-222222222222";

fn pane() -> Uuid {
    PANE.parse().expect("pane")
}

fn sibling(run: &str, state: &str, updated_at: &str, extra: &str) -> RecordFile {
    RecordFile {
        provider: claude(),
        name: run.to_owned(),
        content: Some(format!(
            r#"{{"schemaVersion":3,"paneId":"{PANE}","runId":"{run}","revision":3,"pid":"4242",
               "state":"{state}","updatedAt":"{updated_at}","paneFamilyRunId":"{SHOWN}"{extra}}}"#
        )),
    }
}

/// The launch's run, on screen, and a session in a tab behind it.
fn siblings(shown: &str, behind: &str) -> ProjectionInput {
    let mut input = finished_input(Vec::new());
    input.records = vec![
        sibling(
            SHOWN,
            shown,
            "2026-10-12T00:00:50Z",
            &format!(r#","paneShownRunId":"{SHOWN}","sessionId":"ses_a""#),
        ),
        sibling(
            BEHIND,
            behind,
            "2026-10-12T00:00:10Z",
            r#","sessionId":"ses_b""#,
        ),
    ];
    input.pid_status = [("4242".to_owned(), PidStatus::Alive)]
        .into_iter()
        .collect();
    input
}

fn project(input: &ProjectionInput) -> (Projection, Vec<Command>) {
    let (_, projection, commands) =
        project_with(&ProjectionState::default(), input, &now(), &mut |_, _| {
            false
        });
    (projection, commands)
}

fn runtime<'a>(projection: &'a Projection, run: &str) -> &'a RuntimePresentation {
    projection
        .runtimes
        .iter()
        .find(|runtime| runtime.run_id.as_deref() == Some(run))
        .expect("the run has a runtime")
}

fn badge(projection: &Projection) -> &Badge {
    &projection.badges[&pane()][&claude()]
}

fn viewed(commands: &[Command]) -> Vec<&str> {
    commands
        .iter()
        .filter_map(|command| match &command.op {
            CommandOp::MarkViewed { runtime_id, .. } => Some(runtime_id.as_str()),
            _ => None,
        })
        .collect()
}

#[test]
fn a_wait_behind_a_shown_session_at_work_takes_the_panes_badge() {
    let (projection, _) = project(&siblings("running", "needsInput"));
    assert_eq!(
        runtime(&projection, BEHIND).badge.state,
        RunState::NeedsInput
    );
    assert_eq!(runtime(&projection, SHOWN).badge.state, RunState::Running);
    assert_eq!(badge(&projection).state, RunState::NeedsInput);
}

#[test]
fn a_failure_behind_a_wait_loses_the_badge_and_keeps_its_runtime() {
    let (projection, _) = project(&siblings("needsInput", "error"));
    assert_eq!(badge(&projection).state, RunState::NeedsInput);
    assert_eq!(runtime(&projection, BEHIND).badge.state, RunState::Error);
}

#[test]
fn the_shown_fact_says_which_run_is_behind_in_the_pane() {
    let (projection, _) = project(&siblings("idle", "finished"));
    let (shown, behind) = (runtime(&projection, SHOWN), runtime(&projection, BEHIND));
    assert!(shown.panes_behind_shown_tab.is_empty());
    assert_eq!(behind.panes_behind_shown_tab, vec![pane()]);
}

#[test]
fn a_sibling_not_reported_yet_is_behind_and_a_closed_shown_run_shows_nothing() {
    let mut input = siblings("idle", "idle");
    // The fact names a run with no record yet, or one whose tab closed.
    input.records[0] = sibling(
        SHOWN,
        "idle",
        "2026-10-12T00:00:50Z",
        r#","paneShownRunId":"CCCCCCCC-1111-4111-8111-CCCCCCCCCCC3""#,
    );
    let (projection, _) = project(&input);
    assert_eq!(
        runtime(&projection, SHOWN).panes_behind_shown_tab,
        vec![pane()]
    );
    assert_eq!(
        runtime(&projection, BEHIND).panes_behind_shown_tab,
        vec![pane()]
    );
}

#[test]
fn the_launchs_run_in_another_pane_says_nothing_here() {
    let mut input = siblings("idle", "finished");
    input.records[0].content = input.records[0]
        .content
        .as_ref()
        .map(|content| content.replace(PANE, OTHER_PANE));
    let (projection, _) = project(&input);
    assert!(
        runtime(&projection, BEHIND)
            .panes_behind_shown_tab
            .is_empty()
    );
}

#[test]
fn a_run_no_family_names_is_never_behind() {
    let (projection, _) = project(&finished_input(Vec::new()));
    assert!(runtime(&projection, RUN).panes_behind_shown_tab.is_empty());
}

#[test]
fn a_finish_behind_the_shown_tab_is_not_seen_with_its_pane_in_sight() {
    let mut input = siblings("finished", "finished");
    input.seen_panes = vec![pane()];
    let (projection, commands) = project(&input);
    let viewed = viewed(&commands);
    assert_eq!(viewed, vec![runtime(&projection, SHOWN).id.as_str()]);
}

#[test]
fn a_banner_from_behind_the_shown_tab_is_not_suppressed_by_the_pane() {
    let previous = {
        let (state, _, _) = project_with(
            &ProjectionState::default(),
            &siblings("running", "running"),
            &now(),
            &mut |_, _| false,
        );
        state
    };
    let mut notify_input = siblings("running", "needsInput");
    notify_input.seen_panes = vec![pane()];
    notify_input.records[1].content = notify_input.records[1]
        .content
        .as_ref()
        .map(|content| content.replace(r#""revision":3"#, r#""revision":4"#));
    let (_, _, commands) = project_with(&previous, &notify_input, &now(), &mut |_, _| false);
    let notice = commands
        .iter()
        .find_map(|command| match &command.op {
            CommandOp::Notify(notify) => Some(notify),
            _ => None,
        })
        .expect("the wait is announced");
    assert!(notice.runtime_id.contains(BEHIND));
    assert!(!notice.suppress_when_pane_focused);
}

#[test]
fn a_dead_process_retires_every_sibling_and_says_both_at_work_stopped() {
    let mut input = siblings("running", "needsInput");
    input.pid_status = [("4242".to_owned(), PidStatus::Dead)].into_iter().collect();
    let (projection, commands) = project(&input);
    let retired = commands
        .iter()
        .flat_map(|command| std::iter::once(command).chain(command.then.iter()))
        .filter(|command| matches!(command.op, CommandOp::Retire))
        .count();
    assert_eq!(retired, 2, "{commands:?}");
    assert_ne!(runtime(&projection, SHOWN).badge.state, RunState::Running);
    assert_ne!(
        runtime(&projection, BEHIND).badge.state,
        RunState::NeedsInput
    );
}

#[test]
fn the_home_screen_keeps_the_header_but_nothing_is_in_front() {
    let mut input = siblings("finished", "finished");
    input.records[0] = sibling(
        SHOWN,
        "finished",
        "2026-10-12T00:00:50Z",
        &format!(r#","paneShownRunId":"{SHOWN}","paneShowsHome":true"#),
    );
    input.seen_panes = vec![pane()];
    let (projection, commands) = project(&input);
    let shown = runtime(&projection, SHOWN);
    assert!(shown.panes_behind_shown_tab.is_empty(), "the header's");
    assert_eq!(shown.panes_not_in_front, vec![pane()]);
    assert!(viewed(&commands).is_empty());
}

/// A request to bring a session forward is named for the process, by its launch's run:
/// two `OpenCode` processes started from one pane under tmux each read their own.
#[test]
fn the_channel_is_named_for_the_process_not_the_pane() {
    let (projection, _) = project(&siblings("idle", "idle"));
    let channel = Some(SHOWN.parse::<Uuid>().expect("run"));
    assert_eq!(runtime(&projection, BEHIND).tab_channel, channel);
    assert_eq!(runtime(&projection, SHOWN).tab_channel, channel);
    let (projection, _) = project(&finished_input(Vec::new()));
    assert_eq!(runtime(&projection, RUN).tab_channel, None);
}

/// A process found dead is a stop the list keeps, not announced as a failure, for
/// siblings as for any run: no burst of notices however many tabs it had. Only what
/// was at work shows as stopped.
#[test]
fn a_dead_process_announces_nothing_and_stops_only_what_was_at_work() {
    let notices = |commands: &[Command]| {
        commands
            .iter()
            .filter(|command| matches!(command.op, CommandOp::Notify(_)))
            .count()
    };
    let (state, _, _) = project_with(
        &ProjectionState::default(),
        &siblings("running", "idle"),
        &now(),
        &mut |_, _| false,
    );
    let mut dead = siblings("running", "idle");
    dead.pid_status = [("4242".to_owned(), PidStatus::Dead)].into_iter().collect();
    let (state, projection, first) = project_with(&state, &dead, &now(), &mut |_, _| false);
    assert_eq!(notices(&first), 0, "{first:?}");
    assert_eq!(runtime(&projection, SHOWN).badge.state, RunState::Error);
    assert_eq!(runtime(&projection, BEHIND).badge.state, RunState::Idle);
    let (_, _, second) = project_with(&state, &dead, &now(), &mut |_, _| false);
    assert_eq!(notices(&second), 0, "{second:?}");
}

/// A run restored at launch from an earlier process (its own family, its last fact
/// of what was on screen) beside the tabs of the process that resumed it: it rests
/// once the agent reports, and has no say in which of the new family's tabs is in front.
#[test]
fn a_restored_run_from_an_earlier_process_stays_out_of_the_new_familys_tabs() {
    const RESTORED: &str = "CCCCCCCC-1111-4111-8111-CCCCCCCCCCC3";
    const OLD: &str = "DDDDDDDD-1111-4111-8111-DDDDDDDDDDD4";
    let mut input = siblings("idle", "idle");
    input.records.push(RecordFile {
        provider: claude(),
        name: RESTORED.to_owned(),
        content: Some(format!(
            r#"{{"schemaVersion":3,"paneId":"{PANE}","runId":"{RESTORED}","revision":3,
               "state":"unknown","updatedAt":"2026-10-12T00:00:05Z","sessionId":"ses_a",
               "resumeAttemptedAt":"2026-10-12T00:00:05Z","paneFamilyRunId":"{OLD}",
               "paneShownRunId":"{OLD}"}}"#
        )),
    });
    let input = reported_status(
        input,
        &[],
        "claude-code",
        (ProgramState::Idle, None),
        "2026-10-12T00:00:30Z",
    );
    let (projection, _) = project(&input);
    let restored = runtime(&projection, RESTORED);
    assert_eq!(restored.badge.state, RunState::Idle);
    // Its family's launch run is gone, so nothing says it is behind.
    assert!(restored.panes_behind_shown_tab.is_empty());
    assert!(
        runtime(&projection, SHOWN)
            .panes_behind_shown_tab
            .is_empty()
    );
    assert_eq!(
        runtime(&projection, BEHIND).panes_behind_shown_tab,
        vec![pane()]
    );
}
