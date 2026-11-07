//! What a run record keeps from each event: the conversation, prompts and
//! titles, waits, the cache window and usage limit, and the record's
//! revision and text bounds.

use super::*;

#[test]
fn a_session_holds_a_conversation_once_prompted_or_resumed() {
    let start = |source: Option<SessionSource>| AgentEvent::SessionStarted {
        compact: source == Some(SessionSource::Compact),
        source,
        session_id: Some("session-1".into()),
        session_title: None,
        cwd: None,
    };
    let run = |prev: Option<&RunRecord>, event: &AgentEvent| {
        apply(prev, event, &context(), &claude(), NOW)
            .run
            .expect("record")
    };

    // Started anew, nothing said yet: no transcript to resume.
    let fresh = run(None, &start(Some(SessionSource::Startup)));
    assert_eq!(fresh.has_prompt, Some(false));
    assert_eq!(
        run(None, &start(Some(SessionSource::Clear))).has_prompt,
        Some(false)
    );

    // A prompt gives it one, and a compaction keeps it.
    let prompted = run(Some(&fresh), &prompt("hello"));
    assert_eq!(prompted.has_prompt, Some(true));
    for source in [SessionSource::Startup, SessionSource::Clear] {
        let restarted = run(Some(&prompted), &start(Some(source)));
        assert_eq!(restarted.has_prompt, Some(false), "{source:?}");
    }
    let compacted = run(Some(&prompted), &start(Some(SessionSource::Compact)));
    assert_eq!(compacted.has_prompt, Some(true));

    // A resume or a fork picked an existing conversation up, said or not
    // since: Weir typing `codex resume` at launch and the person
    // quitting before a word is still a conversation to keep.
    for source in [SessionSource::Resume, SessionSource::Fork] {
        assert_eq!(run(None, &start(Some(source))).has_prompt, Some(true));
        assert_eq!(
            run(Some(&fresh), &start(Some(source))).has_prompt,
            Some(true)
        );
    }

    // A start that does not say where it came from says nothing.
    assert_eq!(run(None, &start(None)).has_prompt, None);
    assert_eq!(run(Some(&fresh), &start(None)).has_prompt, None);
}

#[test]
fn session_start_resets_the_run_and_remembers_the_session() {
    let writes = apply(None, &started(Some("Formal")), &context(), &claude(), NOW);
    let record = writes.run.expect("record");
    assert_eq!(record.schema_version, 3);
    assert_eq!(record.state, RunState::Idle);
    assert_eq!(record.revision, Some(1));
    assert_eq!(record.state_episode_token.as_deref(), Some("1"));
    assert_eq!(record.session_started_at.as_deref(), Some(NOW));
    assert_eq!(record.run_started_at, None);
    assert_eq!(record.session_id.as_deref(), Some("session-1"));
    assert_eq!(record.provider_session_title.as_deref(), Some("Formal"));
    assert_eq!(record.pid.as_deref(), Some("4242"));
    assert_eq!(record.run_id.as_deref(), Some(context().run_id.as_str()));
    assert_eq!(record.last_hook_event.as_deref(), Some("session_started"));
    assert_eq!(
        writes.side,
        vec![SideWrite::SessionHint {
            session_id: "session-1".into(),
            cwd: Some("/repo".into()),
            owner_run_id: None,
        }]
    );
    assert_eq!(writes.snapshot, None);

    let (active, _, _) = run(
        &claude(),
        &[started(Some("Old title")), prompt("previous turn")],
    );
    assert_eq!(active.state, RunState::Running);
    assert_eq!(active.run_started_at.as_deref(), Some(NOW));
    let writes = apply(
        Some(&active),
        &started(Some("Formal")),
        &context(),
        &claude(),
        LATER,
    );
    let reset = writes.run.expect("record");
    assert_eq!(reset.state, RunState::Idle);
    assert_eq!(reset.run_started_at, None);
    assert_eq!(reset.first_prompt, None);
    assert_eq!(reset.last_prompt, None);
    assert_eq!(reset.session_started_at.as_deref(), Some(LATER));
    assert_eq!(reset.provider_session_title.as_deref(), Some("Formal"));
    assert_eq!(reset.session_id.as_deref(), Some("session-1"));
    assert_eq!(reset.revision, Some(3));
    assert_eq!(writes.snapshot, None);
}

#[test]
fn a_wait_records_its_kind_and_the_tool_it_waits_to_use() {
    let tool = AgentEvent::ToolStarted {
        tool: "Write".into(),
        detail: Some("Write: /repo/notes.txt".into()),
        caller: Caller::Agent,
    };
    let approval = AgentEvent::ApprovalRequested {
        detail: Some("Claude needs your permission to use Write".into()),
        caller: Caller::Agent,
    };
    let (waiting, _, _) = run(
        &claude(),
        &[started(None), prompt("go"), tool, approval.clone()],
    );
    assert_eq!(waiting.state, RunState::NeedsInput);
    assert_eq!(waiting.wait_kind, Some(WaitKind::Approval));
    assert_eq!(waiting.tool.as_deref(), Some("Write"));
    assert_eq!(waiting.detail.as_deref(), Some("Write: /repo/notes.txt"));
    assert_eq!(waiting.caller, Some(Caller::Agent));
    assert_eq!(waiting.wait_started_at.as_deref(), Some(NOW));

    let answered = apply(
        Some(&waiting),
        &AgentEvent::ToolFinished {
            tool: Some("Write".into()),
            caller: Caller::Agent,
        },
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(answered.state, RunState::Running);
    assert_eq!(answered.wait_kind, None);
    assert_eq!(answered.tool, None);
    assert_eq!(answered.caller, None);
    assert_eq!(answered.wait_started_at, None);
    assert_eq!(answered.detail, None);

    // With no preceding tool, the provider's message is used, even after an error.
    let (running, _, _) = run(&claude(), &[started(None), prompt("go")]);
    let failed = apply(
        Some(&running),
        &AgentEvent::Failed {
            error: "rate_limit".into(),
            usage_limit: None,
            kind: None,
        },
        &context(),
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    assert_eq!(failed.detail.as_deref(), Some("rate_limit"));
    for (previous, label) in [(&running, "no tool yet"), (&failed, "prior error")] {
        let requested = apply(Some(previous), &approval, &context(), &claude(), LATER)
            .run
            .expect("record");
        assert_eq!(requested.wait_kind, Some(WaitKind::Approval), "{label}");
        assert_eq!(requested.tool, None, "{label}");
        assert_eq!(
            requested.detail.as_deref(),
            Some("Claude needs your permission to use Write"),
            "{label}"
        );
    }

    // A question is one whatever its words look like.
    let (record, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("go"),
            AgentEvent::WaitingForInput {
                detail: Some("Read: which file first?".into()),
                caller: Caller::Agent,
            },
        ],
    );
    assert_eq!(record.wait_kind, Some(WaitKind::Question));
    assert_eq!(record.tool, None);
    let encoded: serde_json::Value =
        serde_json::from_slice(&record.encode().expect("encodes")).expect("json");
    assert_eq!(encoded["waitKind"], "question");
}

#[test]
fn a_permission_prompt_after_a_question_leaves_the_question_waiting() {
    let question = AgentEvent::WaitingForInput {
        detail: Some("Which color?".into()),
        caller: Caller::Agent,
    };
    let (waiting, _, _) = run(&claude(), &[started(None), prompt("go"), question]);
    let payload = weir_agent_model::RawHookInput {
        bytes: br#"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use AskUserQuestion"}"#,
        transcript: None,
    };
    let events = weir_provider_claude::ClaudeAdapter
        .normalize(payload, &weir_agent_model::HookContext::fixture())
        .expect("normalize");
    let [permission] = events.as_slice() else {
        panic!("expected one permission event, got {events:?}");
    };
    assert!(matches!(
        permission,
        AgentEvent::ApprovalRequested {
            caller: Caller::Unnamed,
            ..
        }
    ));

    let named = AgentEvent::ApprovalRequested {
        detail: Some("Claude needs your permission to use AskUserQuestion".into()),
        caller: Caller::Agent,
    };
    // A record from before waitKind and caller metadata says which wait it
    // is by its last event.
    let older = RunRecord {
        wait_kind: None,
        caller: None,
        is_caller_inferred: None,
        ..waiting.clone()
    };
    for (label, previous, permission, caller, inferred) in [
        ("named caller", &waiting, &named, Some(Caller::Agent), None),
        (
            "unnamed caller",
            &waiting,
            permission,
            Some(Caller::Agent),
            Some(true),
        ),
        ("legacy wait", &older, permission, None, None),
    ] {
        let record = apply(Some(previous), permission, &context(), &claude(), LATER)
            .run
            .expect("record");
        assert_eq!(record.state, RunState::NeedsInput);
        assert_eq!(record.wait_kind, Some(WaitKind::Question));
        assert_eq!(record.detail.as_deref(), Some("Which color?"));
        assert_eq!(record.tool, None);
        assert_eq!(record.wait_started_at.as_deref(), Some(NOW));
        assert_eq!(record.state_episode_token, previous.state_episode_token);
        assert_eq!(record.caller, caller);
        assert_eq!(record.is_caller_inferred, inferred, "{label}");
    }
}

#[test]
fn a_turn_keeps_its_latest_transcript_path_until_it_ends() {
    let named = ApplyContext {
        transcript_path: Some("/t/session.jsonl".into()),
        ..context()
    };
    let (session, _, _) = run(&claude(), &[started(None)]);
    let asked = apply(Some(&session), &prompt("go"), &named, &claude(), NOW)
        .run
        .expect("record");
    // Esc or Ctrl+C at work sends no hook, so the record names the turn's
    // transcript from its prompt on.
    assert_eq!(asked.state, RunState::Running);
    assert_eq!(asked.transcript_path.as_deref(), Some("/t/session.jsonl"));
    let wait_path = ApplyContext {
        transcript_path: Some("/t/question.jsonl".into()),
        ..context()
    };
    let waiting = apply(
        Some(&asked),
        &AgentEvent::WaitingForInput {
            detail: Some("Which color?".into()),
            caller: Caller::Agent,
        },
        &wait_path,
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    assert_eq!(
        waiting.transcript_path.as_deref(),
        Some("/t/question.jsonl")
    );

    // The permission prompt after the question names no path of its own;
    // the wait keeps the question's.
    let prompt_shown = apply(
        Some(&waiting),
        &AgentEvent::ApprovalRequested {
            detail: None,
            caller: Caller::Agent,
        },
        &context(),
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    assert_eq!(
        prompt_shown.transcript_path.as_deref(),
        Some("/t/question.jsonl")
    );

    // The answer moves the run on in the same turn, which keeps the path,
    // and the turn's end lets it go.
    let answered = apply(
        Some(&prompt_shown),
        &AgentEvent::ToolFinished {
            tool: Some("AskUserQuestion".into()),
            caller: Caller::Agent,
        },
        &context(),
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    assert_eq!(answered.state, RunState::Running);
    assert_eq!(
        answered.transcript_path.as_deref(),
        Some("/t/question.jsonl")
    );
    let ended = apply(
        Some(&answered),
        &AgentEvent::TurnFinished {
            continues_after_stop_hook: false,
            titles: None,
            cache: None,
            reply: None,
            background_work: None,
        },
        &context(),
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    assert_eq!(ended.state, RunState::Finished);
    assert_eq!(ended.transcript_path, None);

    // A path no record text could hold is not cut down to another file's.
    let long = ApplyContext {
        transcript_path: Some(format!("/{}.jsonl", "a".repeat(MAX_RECORD_TEXT_BYTES))),
        ..context()
    };
    let record = apply(
        Some(&asked),
        &AgentEvent::WaitingForInput {
            detail: None,
            caller: Caller::Agent,
        },
        &long,
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    assert_eq!(record.transcript_path, None);
}

#[test]
fn a_turn_carries_prompts_and_ends_without_erasing_them() {
    let (record, sides, snapshots) = run(
        &claude(),
        &[
            started(None),
            prompt("first"),
            AgentEvent::ToolStarted {
                tool: "Bash".into(),
                detail: Some("Bash: ls".into()),
                caller: Caller::Agent,
            },
            AgentEvent::ApprovalRequested {
                detail: Some("Claude needs your permission".into()),
                caller: Caller::Agent,
            },
        ],
    );
    assert_eq!(record.state, RunState::NeedsInput);
    assert_eq!(record.detail.as_deref(), Some("Bash: ls"));
    assert_eq!(record.run_started_at.as_deref(), Some(NOW));
    assert_eq!(record.first_prompt.as_deref(), Some("first"));
    assert_eq!(record.last_prompt.as_deref(), Some("first"));
    assert_eq!(record.revision, Some(4));
    assert_eq!(sides.len(), 1);
    assert_eq!(
        snapshots,
        vec![TurnSnapshotOp::Capture {
            cwd: Some("/repo".into()),
        }]
    );

    let finished = apply(
        Some(&record),
        &AgentEvent::TurnFinished {
            continues_after_stop_hook: false,
            titles: None,
            cache: None,
            reply: None,
            background_work: None,
        },
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(finished.state, RunState::Finished);
    assert_eq!(finished.run_started_at, None);
    assert_eq!(finished.detail, None);
    assert_eq!(finished.last_prompt.as_deref(), Some("first"));
    assert_eq!(finished.updated_at, LATER);

    let second = apply(
        Some(&finished),
        &prompt("second"),
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(second.first_prompt.as_deref(), Some("first"));
    assert_eq!(second.last_prompt.as_deref(), Some("second"));

    let failed = apply(
        Some(&second),
        &AgentEvent::Failed {
            error: "server_error".into(),
            usage_limit: None,
            kind: None,
        },
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(failed.state, RunState::Error);
    assert_eq!(failed.detail.as_deref(), Some("server_error"));
    assert_eq!(failed.run_started_at, None);
    // Unified reset rule: an error keeps what the notification body needs.
    assert_eq!(failed.last_prompt.as_deref(), Some("second"));
    assert_eq!(failed.session_started_at.as_deref(), Some(NOW));
}

fn window(observed_at: &str) -> weir_agent_model::CacheWindow {
    weir_agent_model::CacheWindow {
        observed_at: observed_at.to_owned(),
        ttl_seconds: 3600,
        rewrite_tokens: Some(573_000),
        precision: weir_agent_model::CachePrecision::Estimated,
    }
}

fn finished_with(observed_at: &str) -> AgentEvent {
    AgentEvent::TurnFinished {
        continues_after_stop_hook: false,
        titles: None,
        cache: Some(window(observed_at)),
        reply: None,
        background_work: None,
    }
}

#[test]
fn a_finished_turn_records_its_cache_window_and_quiet_events_keep_it() {
    let (record, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("first"),
            finished_with(NOW),
            // A waiting-for-input event neither starts nor ends work, so
            // the window still describes the cache.
            AgentEvent::WaitingForInput {
                detail: None,
                caller: Caller::Agent,
            },
        ],
    );
    assert_eq!(record.state, RunState::NeedsInput);
    assert_eq!(record.wait_kind, Some(WaitKind::Question));
    assert_eq!(record.cache_window, Some(window(NOW)));
    let encoded: serde_json::Value =
        serde_json::from_slice(&record.encode().expect("encodes")).expect("json");
    assert_eq!(
        encoded["cacheWindow"],
        serde_json::json!({
            "observedAt": "2026-09-14T00:00:00Z",
            "ttlSeconds": 3600, "rewriteTokens": 573_000, "precision": "estimated",
        })
    );

    // The next turn's window replaces it, and a turn that could not read
    // one leaves the cache unknown rather than reusing the old numbers.
    let (record, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("first"),
            finished_with(NOW),
            prompt("second"),
            finished_with(LATER),
        ],
    );
    assert_eq!(record.cache_window, Some(window(LATER)));
    let (record, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("first"),
            finished_with(NOW),
            AgentEvent::TurnFinished {
                continues_after_stop_hook: false,
                titles: None,
                cache: None,
                reply: None,
                background_work: None,
            },
        ],
    );
    assert_eq!(record.cache_window, None);
}

#[test]
fn a_failure_sets_the_usage_limit_and_the_next_failure_replaces_it() {
    let limited = |resets_at: &str, window: &str| AgentEvent::Failed {
        error: "rate_limit".into(),
        usage_limit: Some(weir_agent_model::UsageLimit {
            resets_at: Some(resets_at.into()),
            window: Some(window.into()),
            ..weir_agent_model::UsageLimit::default()
        }),
        kind: None,
    };
    let (record, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("go"),
            limited("2026-09-14T15:00:00Z", "five_hour"),
        ],
    );
    assert_eq!(record.state, RunState::Error);
    let first: serde_json::Value =
        serde_json::from_slice(&record.encode().expect("encodes")).expect("json");
    assert_eq!(
        first["usageLimit"],
        serde_json::json!({
            "resetsAt": "2026-09-14T15:00:00Z", "window": "five_hour",
        })
    );

    let replaced = apply(
        Some(&record),
        &limited("2026-09-17T10:00:00Z", "seven_day"),
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(replaced.state, RunState::Error);
    let second: serde_json::Value =
        serde_json::from_slice(&replaced.encode().expect("encodes")).expect("json");
    assert_eq!(
        second["usageLimit"],
        serde_json::json!({
            "resetsAt": "2026-09-17T10:00:00Z", "window": "seven_day",
        })
    );

    let other = AgentEvent::Failed {
        error: "server_error".into(),
        usage_limit: None,
        kind: None,
    };
    let failed = apply(Some(&replaced), &other, &context(), &claude(), LATER)
        .run
        .expect("record");
    assert_eq!(failed.usage_limit, None);
}

#[test]
fn a_cache_window_clears_on_turn_boundaries_and_when_outside_work_ends() {
    let (finished, _, _) = run(&claude(), &[started(None), prompt("p"), finished_with(NOW)]);
    assert!(finished.cache_window.is_some());
    let clearing = [
        prompt("next"),
        started(None),
        AgentEvent::SessionStarted {
            compact: true,
            source: Some(SessionSource::Compact),
            session_id: Some("session-1".into()),
            session_title: None,
            cwd: None,
        },
        AgentEvent::SessionEnded {
            reason: Some("exit".into()),
            session_id: Some("session-1".into()),
        },
        AgentEvent::Compacting,
        AgentEvent::CompactionFinished,
        AgentEvent::Failed {
            error: "server_error".into(),
            usage_limit: None,
            kind: None,
        },
        AgentEvent::Interrupted,
    ];
    for event in &clearing {
        let next = apply(Some(&finished), event, &context(), &claude(), LATER)
            .run
            .expect("record");
        assert_eq!(next.cache_window, None, "{event:?} must clear the window");
        assert_eq!(next.revision, finished.revision.map(|it| it + 1));
    }

    let idle = AgentEvent::AwaitingPrompt {
        awaited_call_ended: false,
    };
    assert_eq!(
        apply(Some(&finished), &idle, &context(), &claude(), LATER),
        RecordWrites::default()
    );
    let working = apply(
        Some(&finished),
        &AgentEvent::ToolFinished {
            tool: Some("Bash".into()),
            caller: Caller::Agent,
        },
        &context(),
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    assert_eq!(working.state, RunState::Running);
    assert_eq!(working.run_started_at, None);
    assert_eq!(working.cache_window, Some(window(NOW)));
    let settled = apply(Some(&working), &idle, &context(), &claude(), LATER)
        .run
        .expect("record");
    assert_eq!(settled.state, RunState::Finished);
    assert_eq!(settled.cache_window, None);
    assert_eq!(settled.revision, working.revision.map(|it| it + 1));
}

#[test]
fn session_end_keeps_prompts_drops_the_hint_and_removes_the_snapshot() {
    let (mut record, _, _) = run(&claude(), &[started(None), prompt("first"), prompt("last")]);
    record.turn_base_tree = Some("abc".into());
    record.turn_root = Some("/repo".into());
    record.worktree_root = Some("/worktree".into());
    let writes = apply(
        Some(&record),
        &AgentEvent::SessionEnded {
            reason: Some("prompt_input_exit".into()),
            session_id: Some("session-1".into()),
        },
        &context(),
        &claude(),
        LATER,
    );
    let ended = writes.run.expect("record");
    assert_eq!(ended.state, RunState::Unknown);
    assert_eq!(ended.first_prompt.as_deref(), Some("first"));
    assert_eq!(ended.last_prompt.as_deref(), Some("last"));
    assert_eq!(ended.session_started_at.as_deref(), Some(NOW));
    assert_eq!(ended.run_started_at, None);
    assert_eq!(ended.turn_base_tree, None);
    assert_eq!(ended.turn_root, None);
    assert_eq!(ended.worktree_root, None);
    assert_eq!(
        writes.snapshot,
        Some(TurnSnapshotOp::Remove {
            cwd: Some("/repo".into()),
        })
    );
    assert_eq!(
        writes.side,
        vec![SideWrite::DeleteSessionHint {
            session_id: "session-1".into()
        }]
    );

    let writes = apply(
        Some(&record),
        &AgentEvent::SessionEnded {
            reason: Some("exit".into()),
            session_id: None,
        },
        &context(),
        &ProviderDescriptor::fixture("claude", [Capability::Resume]),
        LATER,
    );
    assert_eq!(writes.snapshot, None);
    let ended = writes.run.expect("record");
    assert_eq!(ended.state, RunState::Unknown);
    assert_eq!(ended.turn_root, None);
    assert_eq!(ended.worktree_root, None);

    // A signal keeps the hint for auto-resume.
    let writes = apply(
        Some(&record),
        &AgentEvent::SessionEnded {
            reason: Some("other".into()),
            session_id: Some("session-1".into()),
        },
        &context(),
        &claude(),
        LATER,
    );
    assert!(writes.side.is_empty());

    // Codex never drops the hint because `/quit` reports `other`.
    let writes = apply(
        Some(&record),
        &AgentEvent::SessionEnded {
            reason: Some("exit".into()),
            session_id: Some("session-1".into()),
        },
        &context(),
        &codex(),
        LATER,
    );
    assert!(writes.side.is_empty());
}

#[test]
fn compaction_keeps_the_opening_prompt_and_generated_title() {
    let (record, _, _) = run(
        &claude(),
        &[
            started(Some("Formal")),
            AgentEvent::PromptSubmitted {
                prompt: "first".into(),
                kind: None,
                titles: Some(Titles {
                    session_title: None,
                    generated_title: Some("Generated".into()),
                }),
                cwd: None,
            },
            AgentEvent::Compacting,
        ],
    );
    assert_eq!(record.state, RunState::Compacting);
    assert_eq!(record.run_started_at.as_deref(), Some(NOW));

    let restarted = apply(
        Some(&record),
        &AgentEvent::SessionStarted {
            compact: true,
            source: Some(SessionSource::Compact),
            session_id: Some("session-1".into()),
            session_title: None,
            cwd: None,
        },
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    // The compaction came mid-turn, so the turn goes on.
    assert_eq!(restarted.state, RunState::Running);
    assert_eq!(restarted.run_started_at.as_deref(), Some(NOW));
    assert_eq!(restarted.first_prompt.as_deref(), Some("first"));
    assert_eq!(restarted.last_prompt, None);
    assert_eq!(restarted.provider_session_title.as_deref(), Some("Formal"));
    assert_eq!(
        restarted.provider_generated_title.as_deref(),
        Some("Generated")
    );
    assert_eq!(restarted.session_started_at.as_deref(), Some(LATER));

    let fresh = apply(
        Some(&restarted),
        &started(None),
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(fresh.first_prompt, None);
    assert_eq!(fresh.provider_generated_title, None);
    assert_eq!(fresh.provider_session_title, None);
}

#[test]
fn codex_compaction_and_interrupt_return_to_a_settled_state() {
    let (record, _, _) = run(
        &codex(),
        &[
            started(None),
            prompt("first"),
            AgentEvent::Compacting,
            AgentEvent::CompactionFinished,
        ],
    );
    assert_eq!(record.state, RunState::Running);
    let interrupted = apply(
        Some(&record),
        &AgentEvent::Interrupted,
        &context(),
        &codex(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(interrupted.state, RunState::Finished);
    assert_eq!(interrupted.run_started_at, None);
    assert_eq!(interrupted.first_prompt.as_deref(), Some("first"));
}

#[test]
fn episode_token_survives_repeated_states_and_changes_with_the_state() {
    let question = AgentEvent::WaitingForInput {
        detail: Some("Which color?".into()),
        caller: Caller::Agent,
    };
    let (first, _, _) = run(
        &claude(),
        &[started(None), prompt("first"), question.clone()],
    );
    assert_eq!(first.state, RunState::NeedsInput);
    assert_eq!(first.revision, Some(3));
    assert_eq!(first.state_episode_token.as_deref(), Some("3"));

    let repeated = apply(Some(&first), &question, &context(), &claude(), LATER)
        .run
        .expect("record");
    assert_eq!(repeated.state, RunState::NeedsInput);
    assert_eq!(repeated.revision, Some(4));
    assert_eq!(repeated.state_episode_token, first.state_episode_token);

    let finished = apply(
        Some(&repeated),
        &finished_with(LATER),
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(finished.state, RunState::Finished);
    assert_eq!(finished.revision, Some(5));
    assert_eq!(finished.state_episode_token.as_deref(), Some("5"));
}

#[test]
fn tmux_hosting_marks_the_record_and_withholds_the_hint() {
    let context = ApplyContext {
        tmux: Some(TmuxEndpoint {
            socket_path: "/tmp/tmux-501/weir".into(),
            pane: "%3".into(),
            server_pid: 777,
            server_started_at: Some(1_700_000_000),
        }),
        is_tmux_hosted: true,
        pid: None,
        ..self::context()
    };
    let writes = apply(None, &started(None), &context, &claude(), NOW);
    let record = writes.run.expect("record");
    assert_eq!(record.is_tmux_hosted, Some(true));
    assert_eq!(
        record.tmux_socket_path.as_deref(),
        Some("/tmp/tmux-501/weir")
    );
    assert_eq!(record.tmux_pane_id.as_deref(), Some("%3"));
    assert_eq!(record.tmux_server_pid.as_deref(), Some("777"));
    assert_eq!(record.tmux_server_started_at.as_deref(), Some("1700000000"));
    assert_eq!(record.pid, None);
    assert!(writes.side.is_empty());
}

#[test]
fn side_only_events_write_no_record() {
    let cwd = AgentEvent::CwdChanged {
        new_cwd: "/repo/.git".into(),
        old_cwd: Some("/repo".into()),
    };
    let writes = apply(None, &cwd, &context(), &claude(), NOW);
    assert_eq!(writes.run, None);
    assert_eq!(
        writes.side,
        vec![SideWrite::CwdEvent {
            new_cwd: "/repo/.git".into(),
            old_cwd: Some("/repo".into()),
        }]
    );
    assert_eq!(
        apply(None, &cwd, &context(), &codex(), NOW),
        RecordWrites::default()
    );
    let extension = AgentEvent::Extension {
        name: "Notification".into(),
        payload: serde_json::json!({}),
    };
    assert_eq!(
        apply(None, &extension, &context(), &claude(), NOW),
        RecordWrites::default()
    );

    let (active, _, _) = run(&claude(), &[started(None), prompt("go")]);
    let worktree = AgentEvent::WorktreeCreated {
        repo_root: "/repo".into(),
        worktree_path: "/repo-fork".into(),
        branch: "fork".into(),
    };
    let writes = apply(Some(&active), &worktree, &context(), &claude(), LATER);
    assert_eq!(writes.run, None);
    assert_eq!(writes.snapshot, None);
    assert_eq!(
        writes.side,
        [SideWrite::WorktreeEvent {
            repo_root: "/repo".into(),
            worktree_path: "/repo-fork".into(),
            branch: "fork".into(),
        }]
    );
}

#[test]
fn titles_are_sanitized_and_absent_observations_keep_the_previous_value() {
    let (record, _, _) = run(
        &claude(),
        &[
            started(Some("  Safe\u{202e}\n\t title\u{200b}  ")),
            AgentEvent::TurnFinished {
                continues_after_stop_hook: false,
                titles: None,
                cache: None,
                reply: None,
                background_work: None,
            },
            AgentEvent::TurnFinished {
                continues_after_stop_hook: false,
                titles: Some(Titles {
                    session_title: None,
                    generated_title: Some("Gen\u{7}erated".into()),
                }),
                cache: None,
                reply: None,
                background_work: None,
            },
        ],
    );
    assert_eq!(record.provider_session_title.as_deref(), Some("Safe title"));
    assert_eq!(
        record.provider_generated_title.as_deref(),
        Some("Generated")
    );
    let unobserved = apply(
        Some(&record),
        &finished_with(LATER),
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(
        unobserved.provider_session_title.as_deref(),
        Some("Safe title")
    );
    assert_eq!(
        unobserved.provider_generated_title.as_deref(),
        Some("Generated")
    );
}

#[test]
fn prompts_keep_line_breaks_but_are_bounded_and_cleaned() {
    let prefix = "line one\nline two";
    let padding = "x".repeat(MAX_RECORD_TEXT_BYTES - prefix.len() - 1);
    let long = format!("line one\nline\u{202e} two{padding}😀rest");
    let writes = apply(None, &prompt(&long), &context(), &claude(), NOW);
    let record = writes.run.expect("record");
    assert_eq!(record.last_prompt, Some(format!("{prefix}{padding}")));
    assert_eq!(sanitize_text("\u{1F600}\u{9f}ok"), "\u{1F600}ok");
}

#[test]
fn detail_belongs_to_one_event_only() {
    let (failed, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("first"),
            AgentEvent::Failed {
                error: "server_error".into(),
                usage_limit: None,
                kind: None,
            },
        ],
    );
    assert_eq!(failed.detail.as_deref(), Some("server_error"));
    let prompted = apply(
        Some(&failed),
        &prompt("second"),
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(prompted.state, RunState::Running);
    assert_eq!(
        prompted.detail, None,
        "a new prompt does not show the previous error"
    );

    let compacting = apply(
        Some(&failed),
        &AgentEvent::Compacting,
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(compacting.state, RunState::Compacting);
    assert_eq!(
        compacting.detail, None,
        "compaction also clears a prior detail"
    );
}

#[test]
fn hostile_session_ids_never_become_hints() {
    for (case, session_id) in ["bad\"id", "bad\\id", ""].into_iter().enumerate() {
        let event = AgentEvent::SessionStarted {
            compact: false,
            source: Some(SessionSource::Startup),
            session_id: Some(session_id.into()),
            session_title: None,
            cwd: None,
        };
        let writes = apply(None, &event, &context(), &claude(), NOW);
        assert!(writes.side.is_empty(), "case {case}");
        assert_eq!(
            writes.run.expect("record").session_id.as_deref(),
            Some(session_id)
        );
    }
}

#[test]
fn version_two_records_are_continued_with_a_higher_revision() {
    let previous = RunRecord::decode(
        br#"{"schemaVersion":2,"paneId":"P","state":"running","detail":"","runStartedAt":"2026-09-13T00:00:00Z","updatedAt":"2026-09-13T00:00:00Z","lastHookEvent":"UserPromptSubmit","lastPrompt":"old","firstPrompt":"old","revision":7,"stateEpisodeToken":"6","runId":"R","legacyField":1}"#,
    )
    .expect("decodes");
    let writes = apply(
        Some(&previous),
        &AgentEvent::TurnFinished {
            continues_after_stop_hook: false,
            titles: None,
            cache: None,
            reply: None,
            background_work: None,
        },
        &context(),
        &claude(),
        NOW,
    );
    let record = writes.run.expect("record");
    assert_eq!(record.revision, Some(8));
    assert_eq!(record.state_episode_token.as_deref(), Some("8"));
    assert_eq!(record.first_prompt.as_deref(), Some("old"));
    assert_eq!(record.schema_version, 3);
    assert_eq!(record.extra.get("legacyField"), Some(&serde_json::json!(1)));
    assert_eq!(record.run_id.as_deref(), Some(context().run_id.as_str()));
    let encoded: serde_json::Value =
        serde_json::from_slice(&record.encode().expect("encode")).expect("json");
    assert_eq!(encoded["schemaVersion"], 3);
    assert_eq!(encoded["legacyField"], 1);
}

#[test]
fn version_two_text_is_cleaned_and_bounded_when_the_writer_changes() {
    let oversized_prompt = format!("old\u{202e}{}", "x".repeat(MAX_RECORD_TEXT_BYTES));
    let oversized_detail = format!("command\u{202e}{}", "y".repeat(MAX_RECORD_TEXT_BYTES));
    let previous = serde_json::json!({
        "schemaVersion": 2,
        "paneId": "P",
        "state": "running",
        "detail": oversized_detail,
        "runStartedAt": "2026-09-13T00:00:00Z",
        "updatedAt": "2026-09-13T00:00:00Z",
        "lastHookEvent": "PreToolUse",
        "lastPrompt": oversized_prompt,
        "firstPrompt": "opening\u{202e} prompt",
        "providerSessionTitle": "Title\nline\u{202e}",
        "providerGeneratedTitle": "Generated\u{7} title",
        "revision": 7,
        "runId": "R"
    });
    let previous =
        RunRecord::decode(&serde_json::to_vec(&previous).expect("encodes")).expect("decodes");
    let record = apply(
        Some(&previous),
        &AgentEvent::ApprovalRequested {
            detail: Some("generic approval".into()),
            caller: Caller::Agent,
        },
        &context(),
        &claude(),
        NOW,
    )
    .run
    .expect("record");

    let last_prompt = record.last_prompt.expect("last prompt");
    assert_eq!(
        last_prompt,
        format!("old{}", "x".repeat(MAX_RECORD_TEXT_BYTES - 3))
    );
    let detail = record.detail.expect("detail");
    assert_eq!(
        detail,
        format!("command{}", "y".repeat(MAX_RECORD_TEXT_BYTES - 7))
    );
    assert_eq!(record.first_prompt.as_deref(), Some("opening prompt"));
    assert_eq!(record.provider_session_title.as_deref(), Some("Title line"));
    assert_eq!(
        record.provider_generated_title.as_deref(),
        Some("Generated title")
    );
}

#[test]
fn a_first_prompt_the_harness_wrote_gives_way_to_the_persons() {
    let notification = "<task-notification>\n<task-id>b1</task-id>";
    let first = apply(None, &prompt(notification), &context(), &claude(), NOW)
        .run
        .expect("record");
    assert_eq!(first.first_prompt.as_deref(), Some(notification));
    let second = apply(
        Some(&first),
        &prompt("fix the login"),
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(second.first_prompt.as_deref(), Some("fix the login"));
    // Once the person's words name it, a later prompt does not.
    let third = apply(
        Some(&second),
        &prompt(notification),
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(third.first_prompt.as_deref(), Some("fix the login"));
    assert_eq!(third.last_prompt.as_deref(), Some(notification));
}

#[test]
fn a_stopped_turn_ends_in_the_episode_the_person_stopped_and_keeps_the_rest() {
    let named = ApplyContext {
        transcript_path: Some("/t/session.jsonl".into()),
        ..context()
    };
    let (asked, _, _) = run(&claude(), &[started(None), prompt("go")]);
    let waiting = apply(
        Some(&asked),
        &AgentEvent::WaitingForInput {
            detail: Some("Which color?".into()),
            caller: Caller::Agent,
        },
        &named,
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    let mut waiting = waiting;
    assert_eq!(waiting.wait_started_at.as_deref(), Some(NOW));
    assert_eq!(waiting.caller, Some(Caller::Agent));
    waiting.tool = Some("AskUserQuestion".into());
    waiting.is_caller_inferred = Some(true);
    waiting.cache_window = Some(window(NOW));
    waiting
        .extra
        .insert("futureMetadata".into(), serde_json::json!({"kept": true}));
    let ended = end_stopped_turn(&waiting, LATER).expect("a wait inside a turn ends");
    assert_eq!(ended.state, RunState::Finished);
    assert_eq!(ended.run_started_at, None);
    assert_eq!(ended.wait_kind, None);
    assert_eq!(ended.wait_started_at, None, "the wait's time goes with it");
    assert_eq!(ended.caller, None);
    assert_eq!(ended.is_caller_inferred, None);
    assert_eq!(ended.tool, None);
    assert_eq!(ended.detail, None);
    assert_eq!(ended.transcript_path, None);
    assert_eq!(ended.cache_window, None);
    assert_eq!(ended.updated_at, LATER);
    assert_eq!(
        ended.revision,
        waiting.revision.map(|revision| revision + 1)
    );
    // The badge already showed this finish in the wait's episode.
    assert_eq!(ended.state_episode_token, waiting.state_episode_token);
    // No hook call is behind the write, so who the run is stays as it was.
    assert_eq!(ended.pid, waiting.pid);
    assert_eq!(ended.run_id, waiting.run_id);
    assert_eq!(ended.pane_id, waiting.pane_id);
    assert_eq!(ended.session_id, waiting.session_id);
    assert_eq!(ended.last_prompt, waiting.last_prompt);
    assert_eq!(ended.extra, waiting.extra);

    assert_eq!(ended.last_hook_event.as_deref(), Some("wait_declined"));

    // Work in a turn ends the same way, when the person stopped it with Esc
    // or Ctrl+C.
    assert_eq!(asked.state, RunState::Running);
    let compacting = apply(
        Some(&asked),
        &AgentEvent::Compacting,
        &context(),
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    assert_eq!(compacting.state, RunState::Compacting);
    for active in [&asked, &compacting] {
        let interrupted = end_stopped_turn(active, LATER).expect("work inside a turn ends");
        assert_eq!(interrupted.state, RunState::Finished, "{:?}", active.state);
        assert_eq!(interrupted.run_started_at, None);
        assert_eq!(interrupted.tool, None);
        assert_eq!(interrupted.state_episode_token, active.state_episode_token);
        assert_eq!(interrupted.last_hook_event.as_deref(), Some("interrupted"));
    }

    // Only work or a wait inside a turn ends this way, since the projection
    // reads no other as stopped.
    assert_eq!(end_stopped_turn(&ended, LATER), None);
    let outside = RunRecord {
        run_started_at: None,
        ..waiting
    };
    assert_eq!(end_stopped_turn(&outside, LATER), None);
}
