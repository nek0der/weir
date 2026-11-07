use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;

use weir_agent_model::{ApprovalQuestion, ProviderId};

macro_rules! identifier {
    ($name:ident) => {
        #[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
        pub struct $name(Uuid);

        impl $name {
            #[must_use]
            pub const fn new(value: Uuid) -> Self {
                Self(value)
            }

            #[must_use]
            pub const fn value(self) -> Uuid {
                self.0
            }
        }
    };
}

identifier!(RunId);
identifier!(RequestId);
identifier!(ServiceEpoch);

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Principal {
    Requester { run_id: RunId },
    Controller,
    Diagnostic,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct ApprovalKey {
    pub run_id: RunId,
    pub request_id: RequestId,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalRequest {
    pub key: ApprovalKey,
    pub provider: ProviderId,
    pub session_id: Option<String>,
    pub operation_id: Option<String>,
    pub tool_name: String,
    pub summary: Option<String>,
    /// Canonical JSON owned by the protocol adapter.
    pub input_json: String,
    pub timeout_ms: u64,
    /// Questions the provider wants answered instead of a permission; empty
    /// for an ordinary tool approval.
    pub questions: Vec<ApprovalQuestion>,
    /// The agent run whose hook asked, for correlation only; `None` outside
    /// a Weir run. Never part of the key or of authorization.
    pub agent_run_id: Option<Uuid>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ApprovalDecision {
    AllowOnce,
    Deny { message: Option<String> },
    Delegate,
    Answer { answers: BTreeMap<String, String> },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ApprovalState {
    Pending,
    Resolved(ApprovalDecision),
    Canceled,
    Expired,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalSnapshot {
    pub request: ApprovalRequest,
    pub state: ApprovalState,
    pub created_at_ms: u64,
    pub deadline_ms: u64,
    pub sequence: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BrokerError {
    Unauthorized,
    InvalidTimeout,
    CapacityExceeded,
    NotFound,
    RequestConflict,
    AlreadyTerminal,
    ClockOverflow,
    SequenceOverflow,
}

pub struct ApprovalBroker {
    epoch: ServiceEpoch,
    maximum_records: usize,
    sequence: u64,
    records: BTreeMap<ApprovalKey, ApprovalSnapshot>,
    /// Terminal records their requester has received (a `get` or `wait` that
    /// returned them) or withdrawn. Only these may be evicted to make room:
    /// evicting one the requester has not read yet would turn its result into
    /// `not_found` while its hook still waits.
    consumed: BTreeSet<ApprovalKey>,
    /// The requester runs that have a session open (`open_requester`), and
    /// whether each was withdrawn (`cancel_run`). The host can deliver a
    /// submit sent just before a connection went after that connection's
    /// withdrawal, and `submit` refuses it here, under the same lock as the
    /// withdrawal. A run is kept only while a session of it is open, since
    /// only an open session can still submit, so these never outnumber the
    /// sessions.
    requester_runs: BTreeMap<RunId, RequesterRun>,
}

/// A requester run with a session open (`ApprovalBroker::requester_runs`).
#[derive(Clone, Copy, Debug, Default)]
struct RequesterRun {
    open_sessions: usize,
    is_withdrawn: bool,
}

impl ApprovalBroker {
    #[must_use]
    pub fn new(epoch: ServiceEpoch, maximum_records: usize) -> Self {
        Self {
            epoch,
            maximum_records,
            sequence: 0,
            records: BTreeMap::new(),
            consumed: BTreeSet::new(),
            requester_runs: BTreeMap::new(),
        }
    }

    #[must_use]
    pub const fn epoch(&self) -> ServiceEpoch {
        self.epoch
    }

    #[must_use]
    pub const fn sequence(&self) -> u64 {
        self.sequence
    }

    /// Registers a request for the authenticated run.
    ///
    /// # Errors
    ///
    /// Returns an authorization, validation, capacity, conflict, or counter
    /// error without changing an existing request. A run already withdrawn
    /// (`cancel_run`) is no longer authorized to ask.
    pub fn submit(
        &mut self,
        principal: &Principal,
        request: ApprovalRequest,
        now_ms: u64,
    ) -> Result<ApprovalSnapshot, BrokerError> {
        self.expire(now_ms)?;
        if !matches!(principal, Principal::Requester { run_id } if *run_id == request.key.run_id)
            || self
                .requester_runs
                .get(&request.key.run_id)
                .is_some_and(|run| run.is_withdrawn)
        {
            return Err(BrokerError::Unauthorized);
        }
        if request.timeout_ms == 0 {
            return Err(BrokerError::InvalidTimeout);
        }
        if let Some(existing) = self.records.get(&request.key) {
            return if existing.request == request {
                Ok(existing.clone())
            } else {
                Err(BrokerError::RequestConflict)
            };
        }
        if self.records.len() >= self.maximum_records {
            self.evict_one(now_ms);
        }
        if self.records.len() >= self.maximum_records {
            return Err(BrokerError::CapacityExceeded);
        }
        let deadline_ms = now_ms
            .checked_add(request.timeout_ms)
            .ok_or(BrokerError::ClockOverflow)?;
        let sequence = self.next_sequence()?;
        let snapshot = ApprovalSnapshot {
            request,
            state: ApprovalState::Pending,
            created_at_ms: now_ms,
            deadline_ms,
            sequence,
        };
        self.records.insert(snapshot.request.key, snapshot.clone());
        Ok(snapshot)
    }

    /// Returns one request visible to the principal, expiring it first when due.
    ///
    /// A requester reading its own terminal record consumes it, which makes
    /// the record evictable. A controller's read does not: the app looks a
    /// record up to learn how it ended, and that must not take the result
    /// away from the hook still waiting for it.
    ///
    /// # Errors
    ///
    /// Returns an authorization, missing-request, or counter error.
    pub fn get(
        &mut self,
        principal: &Principal,
        key: ApprovalKey,
        now_ms: u64,
    ) -> Result<ApprovalSnapshot, BrokerError> {
        self.expire(now_ms)?;
        Self::authorize_read(principal, key)?;
        let record = self
            .records
            .get(&key)
            .cloned()
            .ok_or(BrokerError::NotFound)?;
        if matches!(principal, Principal::Requester { .. })
            && record.state != ApprovalState::Pending
        {
            self.consumed.insert(key);
        }
        Ok(record)
    }

    /// Applies the first controller decision to a pending request.
    ///
    /// # Errors
    ///
    /// Returns an authorization, missing-request, terminal-state, or counter
    /// error. Repeating the same accepted decision is idempotent.
    pub fn resolve(
        &mut self,
        principal: &Principal,
        key: ApprovalKey,
        decision: ApprovalDecision,
        now_ms: u64,
    ) -> Result<ApprovalSnapshot, BrokerError> {
        self.expire(now_ms)?;
        if !matches!(principal, Principal::Controller) {
            return Err(BrokerError::Unauthorized);
        }
        if let Some(existing) = self.records.get(&key) {
            if existing.state == ApprovalState::Resolved(decision.clone()) {
                return Ok(existing.clone());
            }
            if existing.state != ApprovalState::Pending {
                return Err(BrokerError::AlreadyTerminal);
            }
        } else {
            return Err(BrokerError::NotFound);
        }
        let sequence = self.next_sequence()?;
        let record = self.records.get_mut(&key).ok_or(BrokerError::NotFound)?;
        record.state = ApprovalState::Resolved(decision);
        record.sequence = sequence;
        Ok(record.clone())
    }

    /// Cancels a pending request owned by the requester.
    ///
    /// # Errors
    ///
    /// Returns an authorization, missing-request, terminal-state, or counter
    /// error.
    pub fn cancel(
        &mut self,
        principal: &Principal,
        key: ApprovalKey,
        now_ms: u64,
    ) -> Result<ApprovalSnapshot, BrokerError> {
        self.expire(now_ms)?;
        if !matches!(principal, Principal::Requester { run_id } if *run_id == key.run_id) {
            return Err(BrokerError::Unauthorized);
        }
        let state = self
            .records
            .get(&key)
            .map(|record| record.state.clone())
            .ok_or(BrokerError::NotFound)?;
        if state == ApprovalState::Canceled {
            return self.records.get(&key).cloned().ok_or(BrokerError::NotFound);
        }
        if state != ApprovalState::Pending {
            return Err(BrokerError::AlreadyTerminal);
        }
        let sequence = self.next_sequence()?;
        let record = self.records.get_mut(&key).ok_or(BrokerError::NotFound)?;
        record.state = ApprovalState::Canceled;
        record.sequence = sequence;
        let canceled = record.clone();
        // The requester withdrew it, so nobody is left waiting for it.
        self.consumed.insert(key);
        Ok(canceled)
    }

    /// Withdraws every pending request of the requester's run, for when its
    /// host connection is gone: the hook that asked has stopped (the agent
    /// interrupted the tool, or its person answered in the TUI's own
    /// dialog), so nobody would ever read a decision. Without this the
    /// request stays pending until its deadline and keeps offering a card
    /// for an answer that can no longer arrive. While a session of the run
    /// is still open, the run is remembered as withdrawn, so a submit of it
    /// that arrives later is refused (`requester_runs`).
    ///
    /// # Errors
    ///
    /// Returns an authorization error for a controller, or a counter error.
    pub fn cancel_run(
        &mut self,
        principal: &Principal,
        now_ms: u64,
    ) -> Result<Vec<ApprovalSnapshot>, BrokerError> {
        let Principal::Requester { run_id } = principal else {
            return Err(BrokerError::Unauthorized);
        };
        // Marked first, so an error below cannot leave the run open to a
        // late submit: the connection is gone whether or not its requests
        // could be canceled.
        if let Some(run) = self.requester_runs.get_mut(run_id) {
            run.is_withdrawn = true;
        }
        self.expire(now_ms)?;
        let keys: Vec<ApprovalKey> = self
            .records
            .iter()
            .filter(|(key, record)| key.run_id == *run_id && record.state == ApprovalState::Pending)
            .map(|(key, _)| *key)
            .collect();
        let mut canceled = Vec::with_capacity(keys.len());
        for key in keys {
            canceled.push(self.cancel(principal, key, now_ms)?);
        }
        Ok(canceled)
    }

    /// Notes a session opened for the requester run `run_id`, so a
    /// withdrawal of the run holds for as long as the session can submit.
    pub fn open_requester(&mut self, run_id: RunId) {
        self.requester_runs.entry(run_id).or_default().open_sessions += 1;
    }

    /// Notes a session of `run_id` closed. The run is forgotten with its
    /// last session: nothing is left that could submit for it.
    pub fn close_requester(&mut self, run_id: RunId) {
        if let Some(run) = self.requester_runs.get_mut(&run_id) {
            run.open_sessions = run.open_sessions.saturating_sub(1);
            if run.open_sessions == 0 {
                self.requester_runs.remove(&run_id);
            }
        }
    }

    /// Returns a controller-only consistent snapshot after applying expiry.
    ///
    /// # Errors
    ///
    /// Returns an authorization or counter error.
    pub fn snapshot(
        &mut self,
        principal: &Principal,
        now_ms: u64,
    ) -> Result<Vec<ApprovalSnapshot>, BrokerError> {
        self.expire(now_ms)?;
        if !matches!(principal, Principal::Controller) {
            return Err(BrokerError::Unauthorized);
        }
        Ok(self.records.values().cloned().collect())
    }

    /// Expires every pending request whose deadline has passed.
    ///
    /// # Errors
    ///
    /// Returns a counter error if the projection sequence is exhausted.
    pub fn expire(&mut self, now_ms: u64) -> Result<Vec<ApprovalSnapshot>, BrokerError> {
        let keys = self
            .records
            .iter()
            .filter(|(_, record)| {
                record.state == ApprovalState::Pending && now_ms >= record.deadline_ms
            })
            .map(|(key, _)| *key)
            .collect::<Vec<_>>();
        let expired_count = u64::try_from(keys.len()).map_err(|_| BrokerError::SequenceOverflow)?;
        self.sequence
            .checked_add(expired_count)
            .ok_or(BrokerError::SequenceOverflow)?;
        let mut expired = Vec::with_capacity(keys.len());
        for key in keys {
            // The aggregate check above proves every increment in this loop is
            // safe, so expiry cannot leave a partially updated batch.
            self.sequence += 1;
            if let Some(record) = self.records.get_mut(&key) {
                record.state = ApprovalState::Expired;
                record.sequence = self.sequence;
                expired.push(record.clone());
            }
        }
        Ok(expired)
    }

    /// How many records could not be evicted to make room right now: the
    /// pending ones and the terminal ones still owed to their requester. A
    /// full broker whose records are all evictable still accepts requests,
    /// so this, not the record count, is what a capacity warning compares.
    ///
    /// # Errors
    ///
    /// Returns a counter error from applying expiry first.
    pub fn unevictable_count(&mut self, now_ms: u64) -> Result<usize, BrokerError> {
        self.expire(now_ms)?;
        Ok(self
            .records
            .iter()
            .filter(|(key, record)| !self.is_evictable(**key, record, now_ms))
            .count())
    }

    /// Whether a record may give up its slot: a terminal record its
    /// requester has consumed, or one left unconsumed for twice its request's
    /// lifetime, after which the requester cannot still be waiting. Pending
    /// records never may.
    fn is_evictable(&self, key: ApprovalKey, record: &ApprovalSnapshot, now_ms: u64) -> bool {
        record.state != ApprovalState::Pending
            && (self.consumed.contains(&key)
                || now_ms
                    >= record
                        .created_at_ms
                        .saturating_add(record.request.timeout_ms.saturating_mul(2)))
    }

    /// Frees one slot for a new request: the evictable record that became
    /// terminal first.
    fn evict_one(&mut self, now_ms: u64) {
        let evictable = self
            .records
            .iter()
            .filter(|(key, record)| self.is_evictable(**key, record, now_ms))
            .min_by_key(|(_, record)| record.sequence)
            .map(|(key, _)| *key);
        if let Some(key) = evictable {
            self.records.remove(&key);
            self.consumed.remove(&key);
        }
    }

    fn authorize_read(principal: &Principal, key: ApprovalKey) -> Result<(), BrokerError> {
        match principal {
            Principal::Requester { run_id } if *run_id == key.run_id => Ok(()),
            Principal::Controller => Ok(()),
            Principal::Requester { .. } | Principal::Diagnostic => Err(BrokerError::Unauthorized),
        }
    }

    fn next_sequence(&mut self) -> Result<u64, BrokerError> {
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or(BrokerError::SequenceOverflow)?;
        Ok(self.sequence)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(value: u128) -> Uuid {
        Uuid::from_u128(value)
    }

    fn request(run: u128, request: u128) -> ApprovalRequest {
        ApprovalRequest {
            key: ApprovalKey {
                run_id: RunId::new(id(run)),
                request_id: RequestId::new(id(request)),
            },
            provider: ProviderId::new("claude").expect("provider id"),
            session_id: Some("session".into()),
            operation_id: None,
            tool_name: "Bash".into(),
            summary: Some("Run tests".into()),
            input_json: r#"{"command":"make test"}"#.into(),
            timeout_ms: 1_000,
            questions: Vec::new(),
            agent_run_id: None,
        }
    }

    fn broker() -> ApprovalBroker {
        ApprovalBroker::new(ServiceEpoch::new(id(99)), 8)
    }

    #[test]
    fn requester_cannot_resolve_its_own_request() {
        let mut broker = broker();
        let request = request(1, 2);
        let principal = Principal::Requester {
            run_id: request.key.run_id,
        };
        let original = broker.submit(&principal, request.clone(), 0).unwrap();
        let sequence = broker.sequence();

        assert_eq!(
            broker.resolve(&principal, request.key, ApprovalDecision::AllowOnce, 1),
            Err(BrokerError::Unauthorized)
        );
        assert_eq!(
            broker.get(&Principal::Controller, request.key, 1),
            Ok(original)
        );
        assert_eq!(broker.sequence(), sequence);
    }

    #[test]
    fn requester_cannot_read_or_cancel_another_run() {
        let mut broker = broker();
        let request = request(1, 2);
        let original = broker
            .submit(
                &Principal::Requester {
                    run_id: request.key.run_id,
                },
                request.clone(),
                0,
            )
            .unwrap();
        let sequence = broker.sequence();
        let other = Principal::Requester {
            run_id: RunId::new(id(3)),
        };

        assert_eq!(
            broker.get(&other, request.key, 1),
            Err(BrokerError::Unauthorized)
        );
        assert_eq!(
            broker.cancel(&other, request.key, 1),
            Err(BrokerError::Unauthorized)
        );
        assert_eq!(
            broker.get(&Principal::Controller, request.key, 1),
            Ok(original)
        );
        assert_eq!(broker.sequence(), sequence);
    }

    #[test]
    fn identical_submit_and_resolution_are_idempotent() {
        let mut broker = broker();
        let request = request(1, 2);
        let requester = Principal::Requester {
            run_id: request.key.run_id,
        };
        let first = broker.submit(&requester, request.clone(), 0).unwrap();
        assert_eq!(first.request, request);
        assert_eq!(first.state, ApprovalState::Pending);
        assert_eq!(first.created_at_ms, 0);
        assert_eq!(first.deadline_ms, 1_000);
        let submitted_sequence = broker.sequence();
        let second = broker.submit(&requester, request.clone(), 10).unwrap();
        assert_eq!(first, second);
        assert_eq!(broker.sequence(), submitted_sequence);

        let first = broker
            .resolve(
                &Principal::Controller,
                request.key,
                ApprovalDecision::AllowOnce,
                20,
            )
            .unwrap();
        assert_eq!(
            first.state,
            ApprovalState::Resolved(ApprovalDecision::AllowOnce)
        );
        let resolved_sequence = broker.sequence();
        let second = broker
            .resolve(
                &Principal::Controller,
                request.key,
                ApprovalDecision::AllowOnce,
                30,
            )
            .unwrap();
        assert_eq!(first, second);
        assert_eq!(broker.sequence(), resolved_sequence);
        assert_eq!(
            broker.resolve(
                &Principal::Controller,
                request.key,
                ApprovalDecision::Deny { message: None },
                40
            ),
            Err(BrokerError::AlreadyTerminal)
        );
        assert_eq!(
            broker.get(&Principal::Controller, request.key, 40),
            Ok(first)
        );
        assert_eq!(broker.sequence(), resolved_sequence);
    }

    #[test]
    fn a_resubmit_with_changed_content_conflicts_without_mutating_the_request() {
        let unnamed = request(1, 2);
        let named = ApprovalRequest {
            agent_run_id: Some(id(7)),
            ..unnamed.clone()
        };
        for (field, original, changed) in [
            (
                "agent run changed",
                &named,
                ApprovalRequest {
                    agent_run_id: Some(id(8)),
                    ..named.clone()
                },
            ),
            ("agent run removed", &named, unnamed.clone()),
            (
                "tool changed",
                &unnamed,
                ApprovalRequest {
                    tool_name: "Write".into(),
                    ..unnamed.clone()
                },
            ),
        ] {
            let mut broker = broker();
            let requester = requester_of(original);
            let snapshot = broker.submit(&requester, original.clone(), 0).unwrap();
            let sequence = broker.sequence();
            assert_eq!(
                broker.submit(&requester, changed, 1),
                Err(BrokerError::RequestConflict),
                "{field}"
            );
            assert_eq!(
                broker.get(&Principal::Controller, original.key, 1),
                Ok(snapshot.clone()),
                "{field}"
            );
            assert_eq!(broker.sequence(), sequence, "{field}");
            assert_eq!(
                broker.submit(&requester, original.clone(), 1),
                Ok(snapshot),
                "{field}"
            );
            assert_eq!(broker.sequence(), sequence, "{field}");
        }
    }

    #[test]
    fn an_allow_is_accepted_before_the_deadline_and_rejected_at_it() {
        let mut broker = broker();
        let timely = request(1, 2);
        let due = request(1, 3);
        let requester = requester_of(&timely);
        for item in [&timely, &due] {
            let submitted = broker.submit(&requester, item.clone(), 0).unwrap();
            assert_eq!(submitted.deadline_ms, 1_000);
        }
        assert_eq!(
            broker
                .resolve(
                    &Principal::Controller,
                    timely.key,
                    ApprovalDecision::AllowOnce,
                    999
                )
                .unwrap()
                .state,
            ApprovalState::Resolved(ApprovalDecision::AllowOnce)
        );
        assert_eq!(
            broker.resolve(
                &Principal::Controller,
                due.key,
                ApprovalDecision::AllowOnce,
                1_000
            ),
            Err(BrokerError::AlreadyTerminal)
        );
        assert_eq!(
            broker.get(&requester, due.key, 1_000).unwrap().state,
            ApprovalState::Expired
        );
        assert_eq!(
            broker.get(&requester, timely.key, 1_000).unwrap().state,
            ApprovalState::Resolved(ApprovalDecision::AllowOnce)
        );
    }

    #[test]
    fn cancellation_wins_over_delayed_resolution() {
        let mut broker = broker();
        let request = request(1, 2);
        let requester = Principal::Requester {
            run_id: request.key.run_id,
        };
        broker.submit(&requester, request.clone(), 0).unwrap();
        let canceled = broker.cancel(&requester, request.key, 10).unwrap();
        assert_eq!(canceled.state, ApprovalState::Canceled);
        let sequence = broker.sequence();

        assert_eq!(
            broker.resolve(
                &Principal::Controller,
                request.key,
                ApprovalDecision::AllowOnce,
                11
            ),
            Err(BrokerError::AlreadyTerminal)
        );
        assert_eq!(
            broker.get(&Principal::Controller, request.key, 11),
            Ok(canceled)
        );
        assert_eq!(broker.sequence(), sequence);
    }

    #[test]
    fn cancel_run_withdraws_only_that_runs_pending_requests() {
        let mut broker = broker();
        let first = request(1, 2);
        let second = request(1, 4);
        let answered = request(1, 3);
        let other_run = request(4, 5);
        let requester = requester_of(&first);
        for item in [&first, &second, &answered, &other_run] {
            broker.submit(&requester_of(item), item.clone(), 0).unwrap();
        }
        let allowed = broker
            .resolve(
                &Principal::Controller,
                answered.key,
                ApprovalDecision::AllowOnce,
                1,
            )
            .unwrap();
        let original_other = broker
            .get(&Principal::Controller, other_run.key, 1)
            .unwrap();
        assert_eq!(
            allowed.state,
            ApprovalState::Resolved(ApprovalDecision::AllowOnce)
        );
        assert_eq!(original_other.state, ApprovalState::Pending);

        let sequence = broker.sequence();
        assert_eq!(
            broker.cancel_run(&Principal::Controller, 2),
            Err(BrokerError::Unauthorized)
        );
        assert_eq!(broker.sequence(), sequence);
        for key in [first.key, second.key, other_run.key] {
            assert_eq!(
                broker.get(&Principal::Controller, key, 2).unwrap().state,
                ApprovalState::Pending
            );
        }

        let canceled = broker.cancel_run(&requester, 3).unwrap();
        assert_eq!(canceled.len(), 2);
        assert_eq!(
            canceled
                .iter()
                .map(|record| record.request.key)
                .collect::<BTreeSet<_>>(),
            BTreeSet::from([first.key, second.key])
        );
        for key in [first.key, second.key] {
            assert_eq!(
                broker.get(&requester, key, 4).unwrap().state,
                ApprovalState::Canceled
            );
        }
        assert_eq!(
            broker.get(&Principal::Controller, answered.key, 4),
            Ok(allowed)
        );
        assert_eq!(
            broker.get(&Principal::Controller, other_run.key, 4),
            Ok(original_other)
        );
    }

    /// The host runs a requester's submit on a thread of its own, so the
    /// connection's withdrawal can reach the broker first. A submit that
    /// lands after it must not leave a request nobody waits for.
    #[test]
    fn a_submit_after_its_run_was_withdrawn_is_refused() {
        let mut broker = broker();
        let late = request(1, 2);
        let other_run = request(3, 4);
        let requester = requester_of(&late);
        broker.open_requester(late.key.run_id);
        broker.open_requester(other_run.key.run_id);

        assert_eq!(broker.cancel_run(&requester, 0).unwrap(), Vec::new());

        assert_eq!(
            broker.submit(&requester, late.clone(), 1),
            Err(BrokerError::Unauthorized)
        );
        assert_eq!(
            broker.get(&Principal::Controller, late.key, 2),
            Err(BrokerError::NotFound)
        );
        broker
            .submit(&requester_of(&other_run), other_run, 3)
            .unwrap();
    }

    /// A withdrawal that fails part way, here on an exhausted sequence,
    /// still leaves its run withdrawn: the connection is gone either way.
    #[test]
    fn a_withdrawal_that_fails_still_refuses_a_late_submit() {
        let mut broker = broker();
        let due = request(1, 2);
        let late = request(1, 3);
        let requester = requester_of(&due);
        broker.open_requester(due.key.run_id);
        broker.submit(&requester, due, 0).unwrap();
        broker.sequence = u64::MAX;

        assert_eq!(
            broker.cancel_run(&requester, 2_000),
            Err(BrokerError::SequenceOverflow)
        );

        broker.sequence = 0;
        assert_eq!(
            broker.submit(&requester, late, 2_001),
            Err(BrokerError::Unauthorized)
        );
    }

    /// A withdrawn run is remembered while any session of it is open, and
    /// forgotten with the last one, so the broker holds no more of them
    /// than there are sessions.
    #[test]
    fn a_withdrawn_run_is_forgotten_with_its_last_session() {
        let mut broker = broker();
        let late = request(1, 2);
        let requester = requester_of(&late);
        broker.open_requester(late.key.run_id);
        broker.open_requester(late.key.run_id);
        broker.cancel_run(&requester, 0).unwrap();

        broker.close_requester(late.key.run_id);
        assert_eq!(
            broker.submit(&requester, late.clone(), 1),
            Err(BrokerError::Unauthorized)
        );

        broker.close_requester(late.key.run_id);
        assert!(broker.requester_runs.is_empty());
    }

    fn small_broker() -> ApprovalBroker {
        ApprovalBroker::new(ServiceEpoch::new(id(99)), 2)
    }

    fn requester_of(request: &ApprovalRequest) -> Principal {
        Principal::Requester {
            run_id: request.key.run_id,
        }
    }

    #[test]
    fn capacity_evicts_consumed_terminal_records_first() {
        let mut broker = small_broker();
        let consumed = request(1, 2);
        let waiting = request(1, 3);
        broker
            .submit(&requester_of(&consumed), consumed.clone(), 0)
            .unwrap();
        broker
            .submit(&requester_of(&waiting), waiting.clone(), 0)
            .unwrap();
        for key in [consumed.key, waiting.key] {
            broker
                .resolve(&Principal::Controller, key, ApprovalDecision::AllowOnce, 1)
                .unwrap();
        }
        broker
            .get(&requester_of(&consumed), consumed.key, 2)
            .unwrap();

        let newcomer = request(1, 4);
        broker
            .submit(&requester_of(&newcomer), newcomer, 3)
            .unwrap();

        assert_eq!(
            broker.get(&Principal::Controller, consumed.key, 4),
            Err(BrokerError::NotFound)
        );
        assert!(broker.get(&Principal::Controller, waiting.key, 4).is_ok());
    }

    #[test]
    fn capacity_never_evicts_pending_or_unconsumed() {
        let mut broker = small_broker();
        let pending = request(1, 2);
        let unread = request(1, 3);
        let pending_snapshot = broker
            .submit(&requester_of(&pending), pending.clone(), 0)
            .unwrap();
        broker
            .submit(&requester_of(&unread), unread.clone(), 0)
            .unwrap();
        let unread_snapshot = broker
            .resolve(
                &Principal::Controller,
                unread.key,
                ApprovalDecision::Deny { message: None },
                1,
            )
            .unwrap();
        // The app reading how it ended does not consume it.
        assert_eq!(
            broker.get(&Principal::Controller, unread.key, 2),
            Ok(unread_snapshot.clone())
        );
        let sequence = broker.sequence();

        let newcomer = request(1, 4);
        assert_eq!(
            broker.submit(&requester_of(&newcomer), newcomer.clone(), 3),
            Err(BrokerError::CapacityExceeded)
        );
        assert_eq!(
            broker.get(&Principal::Controller, pending.key, 3),
            Ok(pending_snapshot)
        );
        assert_eq!(
            broker.get(&Principal::Controller, unread.key, 3),
            Ok(unread_snapshot)
        );
        assert_eq!(
            broker.get(&Principal::Controller, newcomer.key, 3),
            Err(BrokerError::NotFound)
        );
        assert_eq!(broker.sequence(), sequence);
    }

    #[test]
    fn an_unread_result_survives_capacity_pressure() {
        let mut broker = small_broker();
        let answered = request(1, 2);
        broker
            .submit(&requester_of(&answered), answered.clone(), 0)
            .unwrap();
        broker
            .resolve(
                &Principal::Controller,
                answered.key,
                ApprovalDecision::AllowOnce,
                1,
            )
            .unwrap();
        let other = request(1, 3);
        broker
            .submit(&requester_of(&other), other.clone(), 1)
            .unwrap();
        broker.cancel(&requester_of(&other), other.key, 2).unwrap();
        // The slot freed for this one is the withdrawn request's, not the
        // answer the requester has yet to read.
        let newcomer = request(1, 4);
        let accepted = broker
            .submit(&requester_of(&newcomer), newcomer.clone(), 3)
            .unwrap();
        assert_eq!(accepted.request, newcomer);
        assert_eq!(accepted.state, ApprovalState::Pending);
        assert_eq!(
            broker.get(&Principal::Controller, newcomer.key, 3),
            Ok(accepted)
        );
        assert_eq!(
            broker.get(&Principal::Controller, other.key, 3),
            Err(BrokerError::NotFound)
        );

        let result = broker
            .get(&requester_of(&answered), answered.key, 999)
            .unwrap();
        assert_eq!(
            result.state,
            ApprovalState::Resolved(ApprovalDecision::AllowOnce)
        );
    }

    #[test]
    fn unconsumed_terminal_becomes_evictable_at_twice_its_timeout() {
        let mut broker = small_broker();
        let mut live = request(1, 2);
        live.timeout_ms = 10_000;
        let abandoned = request(1, 3);
        let live_snapshot = broker
            .submit(&requester_of(&live), live.clone(), 0)
            .unwrap();
        broker
            .submit(&requester_of(&abandoned), abandoned.clone(), 0)
            .unwrap();
        let abandoned_snapshot = broker
            .resolve(
                &Principal::Controller,
                abandoned.key,
                ApprovalDecision::AllowOnce,
                1,
            )
            .unwrap();

        // `abandoned` was never read; its lifetime is 1,000 ms.
        let early = request(1, 5);
        assert_eq!(
            broker.submit(&requester_of(&early), early.clone(), 1_999),
            Err(BrokerError::CapacityExceeded)
        );
        assert_eq!(
            broker.get(&Principal::Controller, abandoned.key, 2_000),
            Ok(abandoned_snapshot)
        );
        broker
            .submit(&requester_of(&early), early.clone(), 2_000)
            .unwrap();
        assert_eq!(
            broker.get(&Principal::Controller, abandoned.key, 2_001),
            Err(BrokerError::NotFound)
        );
        assert_eq!(
            broker.get(&Principal::Controller, live.key, 2_001),
            Ok(live_snapshot)
        );
        assert_eq!(
            broker
                .get(&Principal::Controller, early.key, 2_001)
                .unwrap()
                .state,
            ApprovalState::Pending
        );
    }

    #[test]
    fn eviction_takes_the_record_that_ended_first() {
        let mut broker = ApprovalBroker::new(ServiceEpoch::new(id(99)), 3);
        let first = request(1, 2);
        let second = request(1, 3);
        let live = request(1, 4);
        for request in [&first, &second, &live] {
            broker
                .submit(&requester_of(request), request.clone(), 0)
                .unwrap();
        }
        // `second` ends first, so it goes first even though it was submitted
        // after `first`.
        broker
            .resolve(
                &Principal::Controller,
                second.key,
                ApprovalDecision::AllowOnce,
                1,
            )
            .unwrap();
        broker
            .resolve(
                &Principal::Controller,
                first.key,
                ApprovalDecision::AllowOnce,
                2,
            )
            .unwrap();
        broker.get(&requester_of(&first), first.key, 3).unwrap();
        broker.get(&requester_of(&second), second.key, 3).unwrap();

        let newcomer = request(1, 5);
        broker
            .submit(&requester_of(&newcomer), newcomer, 4)
            .unwrap();

        assert_eq!(
            broker.get(&Principal::Controller, second.key, 5),
            Err(BrokerError::NotFound)
        );
        assert!(broker.get(&Principal::Controller, first.key, 5).is_ok());
    }

    #[test]
    fn reading_a_pending_request_does_not_consume_it() {
        let mut broker = small_broker();
        let read_early = request(1, 2);
        let other = request(1, 3);
        broker
            .submit(&requester_of(&read_early), read_early.clone(), 0)
            .unwrap();
        broker
            .submit(&requester_of(&other), other.clone(), 0)
            .unwrap();
        broker
            .get(&requester_of(&read_early), read_early.key, 1)
            .unwrap();
        broker
            .resolve(
                &Principal::Controller,
                read_early.key,
                ApprovalDecision::AllowOnce,
                2,
            )
            .unwrap();

        let newcomer = request(1, 4);
        assert_eq!(
            broker.submit(&requester_of(&newcomer), newcomer, 3),
            Err(BrokerError::CapacityExceeded)
        );
        assert_eq!(broker.unevictable_count(3), Ok(2));
    }

    #[test]
    fn unevictable_count_excludes_consumed_results() {
        let mut broker = small_broker();
        let consumed = request(1, 2);
        let pending = request(1, 3);
        broker
            .submit(&requester_of(&consumed), consumed.clone(), 0)
            .unwrap();
        broker.submit(&requester_of(&pending), pending, 0).unwrap();
        broker
            .resolve(
                &Principal::Controller,
                consumed.key,
                ApprovalDecision::AllowOnce,
                1,
            )
            .unwrap();
        assert_eq!(broker.unevictable_count(2), Ok(2));

        broker
            .get(&requester_of(&consumed), consumed.key, 2)
            .unwrap();
        assert_eq!(broker.unevictable_count(3), Ok(1));
    }
}
