#![cfg(unix)]

use serde_json::{Value, json};
use std::os::unix::net::UnixStream;
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};
use uuid::Uuid;
use weir_agent_core::ProviderId;
use weir_agent_core::{Principal, RunId};
use weir_agent_protocol::{
    ApprovalDecisionWire, ApprovalKeyWire, ApprovalRequestWire, ApprovalService, ApprovalStateWire,
    ErrorCode, MAXIMUM_DECISION_BYTES, MAXIMUM_RECORDS, MAXIMUM_REQUEST_BYTES,
    MAXIMUM_RESPONSE_BYTES, PROTOCOL_VERSION, RequestBody, ResponseBody, WireRequest, WireResponse,
    read_frame, write_frame,
};

fn start_connection(
    service: Arc<ApprovalService>,
    principal: Principal,
) -> (UnixStream, thread::JoinHandle<()>) {
    let (client, mut server) = UnixStream::pair().unwrap();
    // A stalled peer must fail a test rather than leave its socket read blocked.
    let timeout = Some(Duration::from_secs(10));
    client.set_read_timeout(timeout).unwrap();
    client.set_write_timeout(timeout).unwrap();
    server.set_write_timeout(timeout).unwrap();
    let task = thread::spawn(move || {
        service.serve_connection(&mut server, &principal).unwrap();
    });
    (client, task)
}

fn exchange(stream: &mut UnixStream, request: &WireRequest) -> WireResponse {
    write_frame(stream, request, MAXIMUM_REQUEST_BYTES).unwrap();
    read_frame(stream, MAXIMUM_RESPONSE_BYTES).unwrap().unwrap()
}

fn hello(stream: &mut UnixStream) -> Uuid {
    let response = exchange(
        stream,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: None,
            body: RequestBody::Hello {
                client_version: "test".into(),
            },
        },
    );
    assert!(matches!(response.body, ResponseBody::HelloResult { .. }));
    response.service_epoch
}

fn approval(run_id: Uuid, request_id: Uuid) -> ApprovalRequestWire {
    ApprovalRequestWire {
        run_id,
        request_id,
        provider: ProviderId::new("claude").expect("provider id"),
        session_id: Some("session".into()),
        operation_id: None,
        tool_name: "Bash".into(),
        summary: Some("Run tests".into()),
        input: json!({"command": "make test"}),
        timeout_ms: 5_000,
        questions: Vec::new(),
        agent_run_id: None,
    }
}

#[test]
fn requester_receives_controller_answer_over_real_streams() {
    let service = Arc::new(ApprovalService::new(8));
    let run_id = Uuid::new_v4();
    let request_id = Uuid::new_v4();
    let (mut requester, requester_task) = start_connection(
        Arc::clone(&service),
        Principal::Requester {
            run_id: RunId::new(run_id),
        },
    );
    let (mut controller, controller_task) =
        start_connection(Arc::clone(&service), Principal::Controller);
    let requester_epoch = hello(&mut requester);
    let controller_epoch = hello(&mut controller);
    assert_eq!(requester_epoch, controller_epoch);

    let mut request = approval(run_id, request_id);
    request.tool_name = "AskUserQuestion".into();
    request.input = json!({});
    let questions = json!([{
        "header": "Colors",
        "prompt": "Which color?",
        "options": [
            {"label": "Red", "description": "Warm"},
            {"label": "Blue", "description": "Cool"}
        ],
        "multi_select": true
    }]);
    request.questions = serde_json::from_value(questions.clone()).unwrap();
    let submit = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(requester_epoch),
            body: RequestBody::ApprovalSubmit(request),
        },
    );
    assert!(matches!(submit.body, ResponseBody::ApprovalResult(_)));

    let get = exchange(
        &mut controller,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(controller_epoch),
            body: RequestBody::ApprovalGet(ApprovalKeyWire { run_id, request_id }),
        },
    );
    let ResponseBody::ApprovalResult(pending) = get.body else {
        panic!("expected approval result");
    };
    assert!(matches!(pending.state, ApprovalStateWire::Pending));
    assert_eq!(pending.request.run_id, run_id);
    assert_eq!(pending.request.request_id, request_id);
    assert_eq!(
        serde_json::to_value(&pending.request.questions).unwrap(),
        questions
    );

    let decision = json!({"decision": "answer", "answers": {"Which color?": "Red"}});
    let resolve_decision: ApprovalDecisionWire = serde_json::from_value(decision.clone()).unwrap();
    let resolver = thread::spawn(move || {
        let response = exchange(
            &mut controller,
            &WireRequest {
                version: PROTOCOL_VERSION,
                message_id: Uuid::new_v4(),
                service_epoch: Some(controller_epoch),
                body: RequestBody::ApprovalResolve {
                    key: ApprovalKeyWire { run_id, request_id },
                    decision: resolve_decision,
                },
            },
        );
        assert!(matches!(response.body, ResponseBody::ApprovalResult(_)));
        drop(controller);
    });

    let response = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(requester_epoch),
            body: RequestBody::ApprovalWait {
                key: ApprovalKeyWire { run_id, request_id },
                maximum_wait_ms: 5_000,
            },
        },
    );
    let ResponseBody::ApprovalResult(snapshot) = response.body else {
        panic!("expected approval result");
    };
    let snapshot = serde_json::to_value(&snapshot).unwrap();
    assert_eq!(snapshot["state"]["status"], "resolved");
    assert_eq!(snapshot["state"]["result"], decision);
    assert_eq!(snapshot["request"]["questions"], questions);

    drop(requester);
    resolver.join().unwrap();
    requester_task.join().unwrap();
    controller_task.join().unwrap();
}

#[test]
fn controller_subscription_observes_a_concurrent_submit() {
    let service = Arc::new(ApprovalService::new(8));
    let run_id = Uuid::new_v4();
    let request_id = Uuid::new_v4();
    let (mut requester, requester_task) = start_connection(
        Arc::clone(&service),
        Principal::Requester {
            run_id: RunId::new(run_id),
        },
    );
    let (mut controller, controller_task) =
        start_connection(Arc::clone(&service), Principal::Controller);
    let requester_epoch = hello(&mut requester);
    let controller_epoch = hello(&mut controller);
    assert_eq!(requester_epoch, controller_epoch);

    // The subscription is on the wire before the submit goes out. Whether
    // the service is already waiting on it by then is not something it
    // shows, so the assertions hold either way: a subscription that starts
    // after the submit reads the same snapshot at once. This checks snapshot
    // delivery, not the condition variable wakeup itself.
    let (sent, subscription_sent) = mpsc::channel();
    let subscriber = thread::spawn(move || {
        write_frame(
            &mut controller,
            &WireRequest {
                version: PROTOCOL_VERSION,
                message_id: Uuid::new_v4(),
                service_epoch: Some(controller_epoch),
                body: RequestBody::ApprovalSubscribe {
                    after_sequence: 0,
                    maximum_wait_ms: 5_000,
                },
            },
            MAXIMUM_REQUEST_BYTES,
        )
        .unwrap();
        sent.send(()).unwrap();
        let response: WireResponse = read_frame(&mut controller, MAXIMUM_RESPONSE_BYTES)
            .unwrap()
            .unwrap();
        let ResponseBody::ApprovalSnapshotResult {
            sequence,
            requests,
            now_ms,
            ..
        } = response.body
        else {
            panic!("expected approval snapshot result");
        };
        assert_eq!(sequence, 1);
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].request_id, request_id);
        let now_ms = now_ms.expect("subscription carries the service clock");
        assert!(requests[0].deadline_ms > now_ms);
        drop(controller);
    });

    subscription_sent
        .recv_timeout(Duration::from_secs(5))
        .expect("the subscription is sent");
    let submit = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(requester_epoch),
            body: RequestBody::ApprovalSubmit(approval(run_id, request_id)),
        },
    );
    assert!(matches!(submit.body, ResponseBody::ApprovalResult(_)));

    drop(requester);
    subscriber.join().unwrap();
    requester_task.join().unwrap();
    controller_task.join().unwrap();
}

#[test]
fn stream_session_rejects_self_approval_and_stale_epoch() {
    let service = Arc::new(ApprovalService::new(8));
    let run_id = Uuid::new_v4();
    let request_id = Uuid::new_v4();
    let (mut requester, requester_task) = start_connection(
        Arc::clone(&service),
        Principal::Requester {
            run_id: RunId::new(run_id),
        },
    );
    let (mut controller, controller_task) = start_connection(service, Principal::Controller);
    let epoch = hello(&mut requester);
    assert_eq!(hello(&mut controller), epoch);
    let submit = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalSubmit(approval(run_id, request_id)),
        },
    );
    let ResponseBody::ApprovalResult(original) = submit.body else {
        panic!("expected pending submission");
    };
    assert!(matches!(original.state, ApprovalStateWire::Pending));

    let self_approval = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalResolve {
                key: ApprovalKeyWire { run_id, request_id },
                decision: ApprovalDecisionWire::AllowOnce,
            },
        },
    );
    assert!(matches!(
        self_approval.body,
        ResponseBody::Error {
            code: ErrorCode::Unauthorized,
            ..
        }
    ));

    let stale_epoch = Uuid::new_v4();
    let stale_get = exchange(
        &mut requester,
        &request(
            stale_epoch,
            RequestBody::ApprovalGet(ApprovalKeyWire { run_id, request_id }),
        ),
    );
    assert!(matches!(
        stale_get.body,
        ResponseBody::Error {
            code: ErrorCode::EpochMismatch,
            ..
        }
    ));
    let stale = exchange(
        &mut controller,
        &request(
            stale_epoch,
            RequestBody::ApprovalResolve {
                key: ApprovalKeyWire { run_id, request_id },
                decision: ApprovalDecisionWire::AllowOnce,
            },
        ),
    );
    assert!(matches!(
        stale.body,
        ResponseBody::Error {
            code: ErrorCode::EpochMismatch,
            ..
        }
    ));

    let current = exchange(
        &mut controller,
        &request(
            epoch,
            RequestBody::ApprovalGet(ApprovalKeyWire { run_id, request_id }),
        ),
    );
    let ResponseBody::ApprovalResult(mut current) = current.body else {
        panic!("expected original request after rejected resolutions");
    };
    assert!(current.now_ms.take().is_some());
    assert_eq!(
        serde_json::to_value(current).unwrap(),
        serde_json::to_value(original).unwrap()
    );

    drop(requester);
    drop(controller);
    requester_task.join().unwrap();
    controller_task.join().unwrap();
}

#[test]
fn wait_returns_pending_at_the_callers_deadline_without_changing_the_request() {
    const CALLER_WAIT_MS: u64 = 30;
    let service = Arc::new(ApprovalService::new(8));
    let run_id = Uuid::new_v4();
    let request_id = Uuid::new_v4();
    let (mut requester, requester_task) = start_connection(
        Arc::clone(&service),
        Principal::Requester {
            run_id: RunId::new(run_id),
        },
    );
    let (mut controller, controller_task) =
        start_connection(Arc::clone(&service), Principal::Controller);
    let epoch = hello(&mut requester);
    assert_eq!(hello(&mut controller), epoch);

    let submit = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalSubmit(approval(run_id, request_id)),
        },
    );
    let ResponseBody::ApprovalResult(pending) = submit.body else {
        panic!("expected pending submission");
    };
    assert!(matches!(pending.state, ApprovalStateWire::Pending));

    let started = Instant::now();
    let wait = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalWait {
                key: ApprovalKeyWire { run_id, request_id },
                maximum_wait_ms: CALLER_WAIT_MS,
            },
        },
    );
    let elapsed = started.elapsed();
    assert!(
        elapsed >= Duration::from_millis(CALLER_WAIT_MS),
        "wait returned early: {elapsed:?}"
    );
    // Allow scheduling latency while distinguishing the caller's deadline
    // from the request's five-second deadline.
    assert!(
        elapsed < Duration::from_secs(2),
        "wait returned late: {elapsed:?}"
    );
    let ResponseBody::ApprovalResult(snapshot) = wait.body else {
        panic!("expected approval result");
    };
    assert_eq!(
        serde_json::to_value(snapshot).unwrap(),
        serde_json::to_value(pending).unwrap()
    );

    let resolved = exchange(
        &mut controller,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalResolve {
                key: ApprovalKeyWire { run_id, request_id },
                decision: ApprovalDecisionWire::AllowOnce,
            },
        },
    );
    let ResponseBody::ApprovalResult(resolved) = resolved.body else {
        panic!("controller could not resolve after the caller deadline");
    };
    assert_eq!(resolved.request.run_id, run_id);
    assert_eq!(resolved.request.request_id, request_id);
    assert!(matches!(
        resolved.state,
        ApprovalStateWire::Resolved {
            result: ApprovalDecisionWire::AllowOnce
        }
    ));

    drop(requester);
    drop(controller);
    requester_task.join().unwrap();
    controller_task.join().unwrap();
}

#[test]
fn oversized_denial_is_rejected_without_resolving_the_request() {
    let service = Arc::new(ApprovalService::new(8));
    let run_id = Uuid::new_v4();
    let request_id = Uuid::new_v4();
    let (mut requester, requester_task) = start_connection(
        Arc::clone(&service),
        Principal::Requester {
            run_id: RunId::new(run_id),
        },
    );
    let (mut controller, controller_task) =
        start_connection(Arc::clone(&service), Principal::Controller);
    let epoch = hello(&mut requester);
    assert_eq!(hello(&mut controller), epoch);
    let submit = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalSubmit(approval(run_id, request_id)),
        },
    );
    assert!(matches!(submit.body, ResponseBody::ApprovalResult(_)));

    let denied = exchange(
        &mut controller,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalResolve {
                key: ApprovalKeyWire { run_id, request_id },
                decision: ApprovalDecisionWire::Deny {
                    message: Some("x".repeat(MAXIMUM_DECISION_BYTES)),
                },
            },
        },
    );
    assert!(matches!(
        denied.body,
        ResponseBody::Error {
            code: ErrorCode::InvalidRequest,
            ..
        }
    ));

    let current = exchange(
        &mut requester,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalGet(ApprovalKeyWire { run_id, request_id }),
        },
    );
    let ResponseBody::ApprovalResult(snapshot) = current.body else {
        panic!("expected approval result");
    };
    assert!(matches!(snapshot.state, ApprovalStateWire::Pending));

    drop(requester);
    drop(controller);
    requester_task.join().unwrap();
    controller_task.join().unwrap();
}

#[test]
fn bounded_snapshot_remains_response_safe_at_capacity() {
    let service = Arc::new(ApprovalService::new(usize::MAX));
    let run_id = Uuid::new_v4();
    let (mut requester, requester_task) = start_connection(
        Arc::clone(&service),
        Principal::Requester {
            run_id: RunId::new(run_id),
        },
    );
    let (mut controller, controller_task) =
        start_connection(Arc::clone(&service), Principal::Controller);
    let epoch = hello(&mut requester);
    assert_eq!(hello(&mut controller), epoch);

    for _ in 0..MAXIMUM_RECORDS {
        let request_id = Uuid::new_v4();
        let mut request = approval(run_id, request_id);
        request.input = json!({"command": "x".repeat(40 * 1024)});
        let response = exchange(
            &mut requester,
            &WireRequest {
                version: PROTOCOL_VERSION,
                message_id: Uuid::new_v4(),
                service_epoch: Some(epoch),
                body: RequestBody::ApprovalSubmit(request),
            },
        );
        assert!(matches!(response.body, ResponseBody::ApprovalResult(_)));
    }

    let snapshot = exchange(
        &mut controller,
        &WireRequest {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            service_epoch: Some(epoch),
            body: RequestBody::ApprovalSnapshot,
        },
    );
    let encoded = serde_json::to_vec(&snapshot).unwrap();
    assert!(encoded.len() <= MAXIMUM_RESPONSE_BYTES);
    let ResponseBody::ApprovalSnapshotResult { requests, .. } = snapshot.body else {
        panic!("expected approval snapshot");
    };
    assert_eq!(requests.len(), MAXIMUM_RECORDS);

    drop(requester);
    drop(controller);
    requester_task.join().unwrap();
    controller_task.join().unwrap();
}

fn request(epoch: Uuid, body: RequestBody) -> WireRequest {
    WireRequest {
        version: PROTOCOL_VERSION,
        message_id: Uuid::new_v4(),
        service_epoch: Some(epoch),
        body,
    }
}

#[test]
fn only_controller_responses_carry_the_service_clock() {
    let service = Arc::new(ApprovalService::new(8));
    let run_id = Uuid::new_v4();
    let request_id = Uuid::new_v4();
    let (mut requester, requester_task) = start_connection(
        Arc::clone(&service),
        Principal::Requester {
            run_id: RunId::new(run_id),
        },
    );
    let (mut controller, controller_task) =
        start_connection(Arc::clone(&service), Principal::Controller);
    let epoch = hello(&mut requester);
    assert_eq!(hello(&mut controller), epoch);
    let key = ApprovalKeyWire { run_id, request_id };
    let submitted = exchange(
        &mut requester,
        &request(
            epoch,
            RequestBody::ApprovalSubmit(approval(run_id, request_id)),
        ),
    );
    let ResponseBody::ApprovalResult(submitted) = submitted.body else {
        panic!("expected approval result");
    };
    assert_eq!(submitted.now_ms, None);
    assert!(matches!(submitted.state, ApprovalStateWire::Pending));

    let snapshot = exchange(
        &mut controller,
        &request(epoch, RequestBody::ApprovalSnapshot),
    );
    let ResponseBody::ApprovalSnapshotResult {
        requests, now_ms, ..
    } = snapshot.body
    else {
        panic!("expected approval snapshot");
    };
    let now_ms = now_ms.expect("a controller snapshot carries the service clock");
    let [indexed] = requests.as_slice() else {
        panic!("expected exactly the submitted request");
    };
    assert_eq!(indexed.request_id, request_id);
    assert_eq!(indexed.deadline_ms, submitted.deadline_ms);
    assert!(indexed.deadline_ms > now_ms);

    let controller_get = exchange(
        &mut controller,
        &request(epoch, RequestBody::ApprovalGet(key.clone())),
    );
    let ResponseBody::ApprovalResult(controller_get) = controller_get.body else {
        panic!("expected approval result");
    };
    let controller_now = controller_get
        .now_ms
        .expect("controller get carries the service clock");
    assert!(controller_now >= now_ms);
    assert_eq!(controller_get.deadline_ms, submitted.deadline_ms);
    assert_eq!(controller_get.request.request_id, request_id);
    assert!(matches!(controller_get.state, ApprovalStateWire::Pending));

    // Inspect the bytes the service sent. Re-encoding a decoded Option
    // would erase a null field and could make the same assertion pass.
    let get = request(epoch, RequestBody::ApprovalGet(key));
    write_frame(&mut requester, &get, MAXIMUM_REQUEST_BYTES).unwrap();
    let raw: Value = read_frame(&mut requester, MAXIMUM_RESPONSE_BYTES)
        .unwrap()
        .unwrap();
    assert_eq!(raw["type"], "approval.result");
    assert_eq!(raw["in_reply_to"], json!(get.message_id));
    assert_eq!(raw["body"]["state"]["status"], "pending");
    assert_eq!(raw["body"]["request"]["run_id"], json!(run_id));
    assert_eq!(raw["body"]["request"]["request_id"], json!(request_id));
    assert!(raw["body"].get("now_ms").is_none());

    drop(requester);
    drop(controller);
    requester_task.join().unwrap();
    controller_task.join().unwrap();
}

#[test]
fn a_requesters_wait_consumes_its_result_and_a_controller_get_does_not() {
    let service = Arc::new(ApprovalService::new(2));
    let run_id = Uuid::new_v4();
    let (mut requester, requester_task) = start_connection(
        Arc::clone(&service),
        Principal::Requester {
            run_id: RunId::new(run_id),
        },
    );
    let (mut controller, controller_task) =
        start_connection(Arc::clone(&service), Principal::Controller);
    let epoch = hello(&mut requester);
    assert_eq!(hello(&mut controller), epoch);
    let mut ask = |body| exchange(&mut requester, &request(epoch, body));
    let mut control = |body| exchange(&mut controller, &request(epoch, body));
    let answered = Uuid::new_v4();
    let agent_run_id = Uuid::from_u128(0xabcd);
    for request_id in [answered, Uuid::new_v4()] {
        let mut approval = approval(run_id, request_id);
        approval.agent_run_id = Some(agent_run_id);
        let submitted = ask(RequestBody::ApprovalSubmit(approval));
        assert!(matches!(submitted.body, ResponseBody::ApprovalResult(_)));
    }
    let key = ApprovalKeyWire {
        run_id,
        request_id: answered,
    };
    let assert_allowed = |response: WireResponse| {
        let ResponseBody::ApprovalResult(result) = response.body else {
            panic!("expected approval result, got {:?}", response.body);
        };
        assert_eq!(result.request.run_id, run_id);
        assert_eq!(result.request.request_id, answered);
        assert!(matches!(
            result.state,
            ApprovalStateWire::Resolved {
                result: ApprovalDecisionWire::AllowOnce
            }
        ));
        result
    };
    assert_allowed(control(RequestBody::ApprovalResolve {
        key: key.clone(),
        decision: ApprovalDecisionWire::AllowOnce,
    }));

    // The app looking up how it ended keeps the result for the hook.
    assert_allowed(control(RequestBody::ApprovalGet(key.clone())));
    let newcomer = Uuid::new_v4();
    assert!(matches!(
        ask(RequestBody::ApprovalSubmit(approval(run_id, newcomer))).body,
        ResponseBody::Error {
            code: ErrorCode::CapacityExceeded,
            ..
        }
    ));
    let ResponseBody::ApprovalSnapshotResult {
        unevictable_records,
        ..
    } = control(RequestBody::ApprovalSnapshot).body
    else {
        panic!("expected approval snapshot");
    };
    assert_eq!(unevictable_records, Some(2));

    // The hook's wait returns the result and frees its slot.
    let waited = ask(RequestBody::ApprovalWait {
        key: key.clone(),
        maximum_wait_ms: 1_000,
    });
    assert_eq!(
        assert_allowed(waited).request.agent_run_id,
        Some(agent_run_id)
    );
    let ResponseBody::ApprovalResult(admitted) =
        ask(RequestBody::ApprovalSubmit(approval(run_id, newcomer))).body
    else {
        panic!("expected admission after requester consumption");
    };
    assert_eq!(admitted.request.request_id, newcomer);
    assert!(matches!(admitted.state, ApprovalStateWire::Pending));
    assert!(matches!(
        control(RequestBody::ApprovalGet(key)).body,
        ResponseBody::Error {
            code: ErrorCode::NotFound,
            ..
        }
    ));

    drop(requester);
    drop(controller);
    requester_task.join().unwrap();
    controller_task.join().unwrap();
}
