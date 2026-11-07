// AgentIntegrationServiceRegistrarTests.swift
// Weir — registration decisions, crash-recovery markers, and recovery from a service that does not answer.

import Foundation
import Observation
import ServiceManagement
import Testing
@testable import Weir

@Suite("Agent integration service registration")
struct AgentIntegrationServiceRegistrarTests {
    private let current = AgentIntegrationServiceArtifact(
        serviceExecutableSHA256: "service-current",
        launchAgentPropertyListSHA256: "plist-current"
    )
    private let previous = AgentIntegrationServiceArtifact(
        serviceExecutableSHA256: "service-previous",
        launchAgentPropertyListSHA256: "plist-previous"
    )

    @Test("maps every service status to a fail-closed action")
    func decision_allStatuses() {
        #expect(action(.notRegistered, running: nil) == .register)
        #expect(action(.enabled, running: current) == .keep)
        #expect(action(.enabled, running: previous) == .replace)
        #expect(action(.enabled, running: nil) == .replace)
        #expect(action(.enabled, running: current, registered: previous) == .replace)
        let beforeRegistration = AgentIntegrationRegistrationMarker(
            phase: .replacing,
            artifact: current,
            appVersion: "2"
        )
        #expect(AgentIntegrationRegistrationDecision.action(
            status: .enabled,
            bundledArtifact: current,
            runningArtifact: .response(current),
            marker: beforeRegistration
        ) == .replace)
        let afterRegistration = AgentIntegrationRegistrationMarker(
            phase: .registered,
            artifact: current,
            appVersion: "2"
        )
        #expect(AgentIntegrationRegistrationDecision.action(
            status: .enabled,
            bundledArtifact: current,
            runningArtifact: .response(current),
            marker: afterRegistration
        ) == .keep)
        #expect(AgentIntegrationRegistrationDecision.action(
            status: .enabled,
            bundledArtifact: current,
            runningArtifact: .unavailable,
            marker: afterRegistration
        ) == .retry)
        #expect(AgentIntegrationRegistrationDecision.action(
            status: .enabled,
            bundledArtifact: current,
            runningArtifact: .unavailable,
            marker: beforeRegistration
        ) == .replace)
        let previousMarker = AgentIntegrationRegistrationMarker(
            phase: .ready,
            artifact: previous,
            appVersion: "1"
        )
        #expect(AgentIntegrationRegistrationDecision.action(
            status: .enabled,
            bundledArtifact: current,
            runningArtifact: .unavailable,
            marker: previousMarker
        ) == .replace)
        for observation in [RunningServiceArtifactObservation.response(current), .unavailable] {
            #expect(AgentIntegrationRegistrationDecision.action(
                status: .enabled,
                bundledArtifact: current,
                runningArtifact: observation,
                marker: nil
            ) == .replace)
        }
        #expect(action(.requiresApproval, running: nil) == .awaitApproval)
        #expect(action(.unknown, running: nil) == .failUnknown)

        // A stale marker cannot change the system's report that there is no registration.
        for marker in [nil, previousMarker] {
            #expect(AgentIntegrationRegistrationDecision.action(
                status: .notFound,
                bundledArtifact: current,
                runningArtifact: .notApplicable,
                marker: marker
            ) == .register)
        }
    }

    @Test("fingerprints both executable and launch agent property list")
    func artifact_changeInEitherInputChangesIdentity() throws {
        try withTempDir { dir in
            let contents = dir.appendingPathComponent("Contents", isDirectory: true)
            let executables = contents.appendingPathComponent("MacOS", isDirectory: true)
            let launchAgents = contents
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
            let executable = executables.appendingPathComponent("AgentIntegrationService")
            let propertyList = launchAgents.appendingPathComponent(AgentIntegrationConfiguration.plistName)
            try Data("service-a".utf8).write(to: executable)
            try Data("plist-a".utf8).write(to: propertyList)
            let first = try AgentIntegrationServiceArtifact.bundled(in: dir)

            try Data("service-b".utf8).write(to: executable)
            let executableChanged = try AgentIntegrationServiceArtifact.bundled(in: dir)
            #expect(executableChanged != first)

            try Data("service-a".utf8).write(to: executable)
            try Data("plist-b".utf8).write(to: propertyList)
            let propertyListChanged = try AgentIntegrationServiceArtifact.bundled(in: dir)
            #expect(propertyListChanged != first)
        }
    }

    @Test("persists each registration phase and rejects unreadable markers")
    func marker_roundTripsAndRejectsCorruption() throws {
        try withTempDir { dir in
            let store = AgentIntegrationRegistrationMarkerStore(
                fileURL: dir.appendingPathComponent("nested/service-registration.json")
            )
            let replacing = AgentIntegrationRegistrationMarker(
                phase: .replacing,
                artifact: current,
                appVersion: "2"
            )
            try store.write(replacing)
            #expect(store.load() == replacing)

            let registered = AgentIntegrationRegistrationMarker(
                phase: .registered,
                artifact: current,
                appVersion: "2"
            )
            try store.write(registered)
            #expect(store.load() == registered)

            let ready = AgentIntegrationRegistrationMarker(
                phase: .ready,
                artifact: current,
                appVersion: "2"
            )
            try store.write(ready)
            #expect(store.load() == ready)
            let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)

            let unknown = AgentIntegrationRegistrationMarker(
                schemaVersion: 2, phase: .ready, artifact: current, appVersion: "2"
            )
            try JSONEncoder().encode(unknown).write(to: store.fileURL, options: .atomic)
            #expect(store.load() == nil, "a decodable marker from another schema is not evidence")
            try Data("invalid".utf8).write(to: store.fileURL, options: .atomic)
            #expect(store.load() == nil)
        }
    }

    @Test("helper-side identity matches only its containing app artifact")
    func artifact_matchUsesContainingAppBundle() throws {
        try withTempDir { dir in
            let app = dir.appendingPathComponent("Weir.app", isDirectory: true)
            let executableDirectory = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
            let launchAgentDirectory = app
                .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            try FileManager.default.createDirectory(
                at: executableDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: launchAgentDirectory,
                withIntermediateDirectories: true
            )
            try Data("service".utf8).write(
                to: executableDirectory.appendingPathComponent("AgentIntegrationService")
            )
            try Data("plist".utf8).write(
                to: launchAgentDirectory.appendingPathComponent(
                    AgentIntegrationConfiguration.plistName
                )
            )
            let helper = executableDirectory.appendingPathComponent("AgentIntegrationHookHelper")
            let artifact = try AgentIntegrationServiceArtifact.bundled(in: app)

            #expect(try AgentIntegrationServiceArtifact.matchesBundle(
                artifact,
                containing: helper
            ))
            #expect(try !AgentIntegrationServiceArtifact.matchesBundle(
                previous,
                containing: helper
            ))
            #expect(try !AgentIntegrationServiceArtifact.matchesBundle(
                nil,
                containing: helper
            ))
        }
    }

    @Test("decodes an older bootstrap without artifact identity")
    func bootstrap_oldServiceOmitsArtifact() throws {
        let data = Data(#"{"role":"controller","serviceProcessID":42}"#.utf8)
        let bootstrap = try JSONDecoder().decode(AgentIntegrationSessionBootstrap.self, from: data)
        #expect(bootstrap.role == .controller)
        #expect(bootstrap.serviceProcessID == 42)
        #expect(bootstrap.serviceArtifact == nil)
    }

    @Test("keeps a dismissed issue hidden until retry, recovery, or a different failure")
    func issuePresentation_dismissesOnlyTheCurrentReason() {
        var presentation = AgentIntegrationIssuePresentation()
        let reconciliation = AgentIntegrationServiceIssue(
            reason: .reconciliationFailed,
            diagnostic: "first failure"
        )

        presentation.present(reconciliation)
        #expect(presentation.issue == reconciliation)

        presentation.dismiss()
        presentation.present(AgentIntegrationServiceIssue(
            reason: .reconciliationFailed,
            diagnostic: "automatic retry failed"
        ))
        #expect(presentation.issue == nil)

        let approval = AgentIntegrationServiceIssue(
            reason: .requiresApproval,
            diagnostic: nil
        )
        presentation.present(approval)
        #expect(presentation.issue == approval)

        presentation.dismiss()
        presentation.reset()
        presentation.present(reconciliation)
        #expect(presentation.issue == reconciliation)
    }

    @Test("reports no issue for an ad hoc-signed build, since retrying cannot fix it")
    func reconciliationFailure_adHocSigningIsQuiet() {
        #expect(AgentIntegrationServiceIssue.forReconciliationFailure(
            AgentIntegrationError.adHocSigningUnsupported
        ) == nil)

        let issue = AgentIntegrationServiceIssue.forReconciliationFailure(
            AgentIntegrationError.invalidResponse
        )
        #expect(issue?.reason == .reconciliationFailed)
        #expect(issue?.diagnostic == String(describing: AgentIntegrationError.invalidResponse))
    }

    private func action(
        _ status: AgentIntegrationRegistrationStatus,
        running: AgentIntegrationServiceArtifact?,
        registered: AgentIntegrationServiceArtifact? = nil
    ) -> AgentIntegrationRegistrationAction {
        let marker = (registered ?? (status == .enabled ? current : nil)).map {
            AgentIntegrationRegistrationMarker(phase: .ready, artifact: $0, appVersion: "2")
        }
        return AgentIntegrationRegistrationDecision.action(
            status: status,
            bundledArtifact: current,
            runningArtifact: status == .enabled ? .response(running) : .notApplicable,
            marker: marker
        )
    }
}

@MainActor
@Suite("Agent integration service recovery")
struct AgentIntegrationServiceRecoveryTests {
    private let current = AgentIntegrationServiceArtifact(
        serviceExecutableSHA256: "service-current",
        launchAgentPropertyListSHA256: "plist-current"
    )

    @Test func unreachablePolicy_backsOffThenReplacesOnceThenWaits() {
        let start = SuspendingClock.now
        var policy = AgentIntegrationUnreachableServicePolicy()
        var elapsed = Duration.zero
        var steps: [AgentIntegrationUnreachableServicePolicy.Step] = []
        for _ in 0..<7 {
            let step = policy.step(at: start + elapsed, isRetryPending: false)
            steps.append(step)
            if case let .retry(delay) = step {
                elapsed += delay
            }
        }
        #expect(steps == [
            .retry(after: .seconds(2)), .retry(after: .seconds(4)), .retry(after: .seconds(8)),
            .retry(after: .seconds(16)), .retry(after: .seconds(32)), .replace, .wait
        ])
    }

    @Test func unreachablePolicy_observationsCloseTogether_doNotBringTheReplacementForward() {
        let start = SuspendingClock.now
        var policy = AgentIntegrationUnreachableServicePolicy()
        #expect(policy.step(at: start, isRetryPending: false) == .retry(after: .seconds(2)))
        for second in 1...59 {
            #expect(policy.step(at: start + .seconds(second), isRetryPending: true) == .wait)
        }
        #expect(policy.step(at: start + .seconds(60), isRetryPending: true) == .replace)
    }

    @Test func unreachablePolicy_afterAnEarlyReplacement_setsNoMoreTimers() {
        let start = SuspendingClock.now
        var policy = AgentIntegrationUnreachableServicePolicy()
        #expect(policy.step(at: start, isRetryPending: false) == .retry(after: .seconds(2)))
        #expect(policy.step(at: start + .seconds(60), isRetryPending: false) == .replace)
        #expect(policy.step(at: start + .seconds(61), isRetryPending: false) == .wait)
    }

    @Test func unreachablePolicy_reset_restoresTheReplacement() {
        let start = SuspendingClock.now
        var policy = AgentIntegrationUnreachableServicePolicy()
        _ = policy.step(at: start, isRetryPending: false)
        #expect(policy.step(at: start + .seconds(60), isRetryPending: false) == .replace)
        policy.reset()
        #expect(policy.step(at: start + .seconds(61), isRetryPending: false) == .retry(after: .seconds(2)))
        #expect(policy.step(at: start + .seconds(121), isRetryPending: false) == .replace)
    }

    @Test func registrationFailure_readsTheDocumentedCodes() {
        func failure(_ code: Int32, domain: String = SMAppServiceErrorDomain) -> AgentIntegrationRegistrationFailure {
            AgentIntegrationRegistrationFailure(NSError(domain: domain, code: Int(code)))
        }
        #expect(failure(Int32(kSMErrorAlreadyRegistered)) == .alreadyRegistered)
        #expect(failure(Int32(kSMErrorLaunchDeniedByUser)) == .deniedByUser)
        #expect(failure(Int32(kSMErrorJobPlistNotFound)) == .missingFromBundle)
        #expect(failure(Int32(kSMErrorToolNotValid)) == .missingFromBundle)
        #expect(failure(Int32(kSMErrorInvalidSignature)) == .other)
        #expect(failure(Int32(kSMErrorLaunchDeniedByUser), domain: NSPOSIXErrorDomain) == .other)
    }

    @Test func bundleLocation_refusesOnlyADiskImageOrATranslocatedCopy() throws {
        #expect(AgentIntegrationBundleLocation(volumeDeviceModel: "Disk Image", isVolumeReadOnly: true, volumePath: "/Volumes/Weir") ==
            .diskImage)
        #expect(AgentIntegrationBundleLocation(
            volumeDeviceModel: nil,
            isVolumeReadOnly: true,
            volumePath: "/private/var/folders/xy/abc/T/AppTranslocation/6E3B4C1A-0000-4000-8000-000000000000"
        ) == .translocated)
        // An external disk Weir is installed on, read-only or not.
        #expect(AgentIntegrationBundleLocation(volumeDeviceModel: "Portable SSD", isVolumeReadOnly: true, volumePath: "/Volumes/Archive") ==
            .installed)
        // A writable folder that only happens to carry the name.
        #expect(AgentIntegrationBundleLocation(
            volumeDeviceModel: nil,
            isVolumeReadOnly: false,
            volumePath: "/Users/someone/AppTranslocation"
        ) == .installed)
        try withTempDir { directory in
            #expect(AgentIntegrationBundleLocation(of: directory) == .installed)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func reconcile_unreachableService_retriesWithBackoffThenReplacesOnce() async throws {
        try await withTempDir { directory in
            let system = FakeServiceSystem(artifact: current)
            try writeMarker(.ready, in: directory)
            let registrar = system.registrar(directory: directory)
            registrar.start { _ in }
            await registrar.waitUntilIdle()

            #expect(system.sleeps == [2, 4, 8, 16, 32].map { .seconds($0) })
            #expect(system.registrationCalls == [.unregister, .register])
            #expect(marker(in: directory)?.phase == .registered, "the replacement did not answer")
            #expect(registrar.issue?.reason == .reconciliationFailed)
            let observed = system.observationCount

            // After the one replacement, an activation observes once more
            // and schedules nothing.
            registrar.appDidBecomeActive()
            await registrar.waitUntilIdle()
            #expect(system.observationCount == observed + 1)
            #expect(system.sleeps.count == 5)
            #expect(system.registrationCalls == [.unregister, .register])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func reconcile_serviceAnswersAgain_keepsItAndForgetsTheFailures() async throws {
        try await withTempDir { directory in
            let system = FakeServiceSystem(artifact: current)
            defer { system.releaseSleeps() }
            system.answersAfterSleeps = 2
            try writeMarker(.ready, in: directory)
            let registrar = system.registrar(directory: directory)
            var readiness: [Bool] = []
            registrar.start { readiness.append($0) }
            await registrar.waitUntilIdle()

            #expect(system.sleeps == [.seconds(2), .seconds(4)])
            #expect(system.unregisterCount == 0)
            #expect(registrar.isReady)
            #expect(readiness == [true])
            #expect(registrar.issue == nil)
            #expect(system.registerCount == 0)

            system.answersAfterSleeps = Int.max
            system.holdsSleeps = true
            registrar.appDidBecomeActive()
            await registrar.waitUntilReconciled()
            await untilObserved { system.sleeps.count == 3 }
            try #require(system.sleeps == [.seconds(2), .seconds(4), .seconds(2)])
            #expect(!registrar.isReady)
            #expect(readiness == [true, false])

            system.advance(by: .seconds(59))
            registrar.appDidBecomeActive()
            await registrar.waitUntilReconciled()
            #expect(system.registrationCalls.isEmpty)

            system.advance(by: .seconds(1))
            registrar.appDidBecomeActive()
            await registrar.waitUntilReconciled()
            #expect(system.registrationCalls == [.unregister, .register])
            system.releaseSleeps()
            await untilObserved { !system.heldSleepCancellations.isEmpty }
            #expect(system.heldSleepCancellations == [true])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func reconcile_activationsCloseTogether_doNotReplaceEarly() async throws {
        try await withTempDir { directory in
            let system = FakeServiceSystem(artifact: current)
            defer { system.releaseSleeps() }
            system.holdsSleeps = true
            try writeMarker(.ready, in: directory)
            let registrar = system.registrar(directory: directory)
            registrar.start { _ in }
            await untilObserved { system.sleeps.count == 1 }
            try #require(system.sleeps.count == 1)
            await registrar.waitUntilReconciled()
            for activation in 1...10 {
                system.advance(by: .seconds(1))
                registrar.appDidBecomeActive()
                await registrar.waitUntilReconciled()
                #expect(system.observationCount == activation + 1)
            }
            #expect(system.observationCount == 11)
            #expect(system.unregisterCount == 0)
            #expect(system.sleeps.count == 1)
            system.releaseSleeps()
            await registrar.waitUntilIdle()
        }
    }

    /// A timer set before the replacement must not run it again after it
    /// failed: only the person brings the next attempt.
    @Test(.timeLimit(.minutes(1)))
    func replace_failed_isNotRetriedByATimerSetBeforeIt() async throws {
        try await withTempDir { directory in
            let system = FakeServiceSystem(artifact: current)
            defer { system.releaseSleeps() }
            system.holdsSleeps = true
            system.unregisterError = AgentIntegrationError.requestFailed("unregister failed")
            try writeMarker(.ready, in: directory)
            let registrar = system.registrar(directory: directory)
            registrar.start { _ in }
            await untilObserved { system.sleeps.count == 1 }
            try #require(system.sleeps.count == 1)
            await registrar.waitUntilReconciled()

            system.advance(by: .seconds(60))
            registrar.appDidBecomeActive()
            await registrar.waitUntilReconciled()
            #expect(system.unregisterCount == 1)
            #expect(marker(in: directory)?.phase == .replacing)

            system.releaseSleeps()
            await untilObserved { !system.heldSleepCancellations.isEmpty }
            try #require(system.heldSleepCancellations == [true])
            #expect(system.unregisterCount == 1)
            #expect(registrar.issue?.reason == .reconciliationFailed)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func retry_whileAReconcileRuns_runsAnotherAfterIt() async throws {
        try await withTempDir { directory in
            let system = FakeServiceSystem(artifact: current)
            let observation = Gate<Void>()
            system.observationGate = observation
            defer { observation.open() }
            try writeMarker(.ready, in: directory)
            let registrar = system.registrar(directory: directory)
            registrar.start { _ in }
            try await observation.waitUntilRequested(timeout: .seconds(5))
            try #require(system.observationEvents == [.started(1)])
            registrar.retry()
            #expect(system.observationEvents == [.started(1)])

            system.answersAfterSleeps = 0
            observation.open()
            await registrar.waitUntilIdle()

            #expect(system.observationEvents == [.started(1), .finished(1), .started(2), .finished(2)])
            #expect(system.observationCount == 2)
            #expect(registrar.isReady)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func register_deniedByUser_asksForLoginItemsAndKeepsTheRegistration() async throws {
        try await withTempDir { directory in
            let system = FakeServiceSystem(artifact: current)
            system.status = .notRegistered
            system.registerError = NSError(domain: SMAppServiceErrorDomain, code: Int(kSMErrorLaunchDeniedByUser))
            let registrar = system.registrar(directory: directory)
            registrar.start { _ in }
            await registrar.waitUntilIdle()
            #expect(registrar.issue?.reason == .requiresApproval)
            #expect(marker(in: directory)?.phase == .registered)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func register_fromADiskImage_isRefusedButAHealthyServiceIsKept() async throws {
        try await withTempDir { directory in
            let system = FakeServiceSystem(artifact: current)
            system.location = .diskImage
            system.status = .notRegistered
            let registrar = system.registrar(directory: directory)
            registrar.start { _ in }
            await registrar.waitUntilIdle()
            #expect(registrar.issue?.reason == .temporaryLocation)
            #expect(system.registerCount == 0)
            #expect(marker(in: directory) == nil)

            system.status = .enabled
            system.answersAfterSleeps = 0
            try writeMarker(.ready, in: directory)
            registrar.appDidBecomeActive()
            await registrar.waitUntilIdle()
            #expect(registrar.isReady)
            #expect(registrar.issue == nil)
            #expect(system.registrationCalls.isEmpty)
            #expect(marker(in: directory) == AgentIntegrationRegistrationMarker(phase: .ready, artifact: current, appVersion: "2"))
        }
    }

    /// A replacement refused on a disk image leaves the service registered
    /// and the marker current, so a later activation observes it again and
    /// finds it still unreachable. The issue must stay the disk image's,
    /// whose alert has no Retry, rather than turn back into the generic one.
    @Test(.timeLimit(.minutes(1)))
    func reconcile_fromADiskImage_afterTheRefusedReplacement_staysATemporaryLocation() async throws {
        try await withTempDir { directory in
            let system = FakeServiceSystem(artifact: current)
            system.location = .diskImage
            try writeMarker(.ready, in: directory)
            let registrar = system.registrar(directory: directory)
            registrar.start { _ in }
            await registrar.waitUntilIdle()
            #expect(registrar.issue?.reason == .temporaryLocation)
            #expect(system.unregisterCount == 0)

            registrar.appDidBecomeActive()
            await registrar.waitUntilIdle()
            #expect(registrar.issue?.reason == .temporaryLocation)
            #expect(system.unregisterCount == 0)
            #expect(system.registerCount == 0)
        }
    }

    private func writeMarker(_ phase: AgentIntegrationRegistrationMarker.Phase, in directory: URL) throws {
        try store(in: directory).write(AgentIntegrationRegistrationMarker(phase: phase, artifact: current, appVersion: "2"))
    }

    private func marker(in directory: URL) -> AgentIntegrationRegistrationMarker? {
        store(in: directory).load()
    }

    private func store(in directory: URL) -> AgentIntegrationRegistrationMarkerStore {
        AgentIntegrationRegistrationMarkerStore(fileURL: directory
            .appendingPathComponent("agent-integration", isDirectory: true)
            .appendingPathComponent("service-registration.json"))
    }
}

/// A stand-in for `SMAppService`, the bundle, the running service, and the
/// clock. The service does not answer until `answersAfterSleeps` retry
/// delays have passed (never, by default). A sleep passes at once and moves
/// the clock on, unless `holdsSleeps` keeps it waiting. Observable, so a
/// test waits for a held sleep or observation to begin without a deadline
/// a loaded machine can pass.
@MainActor
@Observable
private final class FakeServiceSystem {
    let artifact: AgentIntegrationServiceArtifact
    var location = AgentIntegrationBundleLocation.installed
    var status = AgentIntegrationRegistrationStatus.enabled
    var registerError: (any Error)?
    var answersAfterSleeps = Int.max
    var holdsSleeps = false
    var observationGate: Gate<Void>?
    enum RegistrationCall {
        case register, unregister
    }

    enum ObservationEvent: Equatable {
        case started(Int)
        case finished(Int)
    }

    private(set) var registrationCalls: [RegistrationCall] = []
    var registerCount: Int {
        registrationCalls.count { $0 == .register }
    }

    var unregisterCount: Int {
        registrationCalls.count { $0 == .unregister }
    }

    private(set) var observationCount = 0
    private(set) var observationEvents: [ObservationEvent] = []
    private(set) var sleeps: [Duration] = []
    private(set) var heldSleepCancellations: [Bool] = []
    private var elapsed = Duration.zero
    private let start = SuspendingClock.now
    private var heldSleeps: [CheckedContinuation<Void, Never>] = []
    var unregisterError: (any Error)?

    init(artifact: AgentIntegrationServiceArtifact) {
        self.artifact = artifact
    }

    func advance(by duration: Duration) {
        elapsed += duration
    }

    /// Lets every held sleep pass, without moving the clock.
    func releaseSleeps() {
        holdsSleeps = false
        heldSleeps.forEach { $0.resume() }
        heldSleeps = []
    }

    func registrar(directory: URL) -> AgentIntegrationServiceRegistrar {
        AgentIntegrationServiceRegistrar(
            applicationSupportDirectory: directory,
            appVersion: "2",
            environment: AgentIntegrationServiceEnvironment(
                inspectBundle: { [self] in await (artifact, location) },
                status: { [self] in status },
                register: { [self] in
                    registrationCalls.append(.register)
                    if let registerError {
                        throw registerError
                    }
                    status = .enabled
                },
                unregister: { [self] in
                    registrationCalls.append(.unregister)
                    if let unregisterError {
                        throw unregisterError
                    }
                },
                runningArtifact: { [self] in try await observe() },
                now: { [self] in MainActor.assumeIsolated { start + elapsed } },
                sleep: { [self] duration in await sleep(duration) },
                registersWithSystem: false
            )
        )
    }

    private func observe() async throws -> AgentIntegrationServiceArtifact? {
        observationCount += 1
        let number = observationCount
        observationEvents.append(.started(number))
        defer { observationEvents.append(.finished(number)) }
        await observationGate?.wait()
        guard sleeps.count >= answersAfterSleeps else { throw AgentIntegrationError.timeout }
        return artifact
    }

    private func sleep(_ duration: Duration) async {
        sleeps.append(duration)
        if holdsSleeps {
            await withCheckedContinuation { heldSleeps.append($0) }
            heldSleepCancellations.append(Task.isCancelled)
            return
        }
        elapsed += duration
    }
}
