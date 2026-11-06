// AgentIntegrationServiceRegistrar.swift
// Weir — reconciles the bundled approval service without needless restarts.

import DiskArbitration
import Foundation
import OSLog
import ServiceManagement

enum AgentIntegrationRegistrationStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown
}

enum AgentIntegrationRegistrationAction: Equatable, Sendable {
    case register
    case keep
    case replace
    case retry
    case awaitApproval
    case failUnknown
}

enum RunningServiceArtifactObservation: Equatable, Sendable {
    case notApplicable
    case response(AgentIntegrationServiceArtifact?)
    case unavailable
}

enum AgentIntegrationRegistrationDecision {
    static func action(
        status: AgentIntegrationRegistrationStatus,
        bundledArtifact: AgentIntegrationServiceArtifact,
        runningArtifact: RunningServiceArtifactObservation,
        marker: AgentIntegrationRegistrationMarker?
    ) -> AgentIntegrationRegistrationAction {
        switch status {
        case .notRegistered, .notFound:
            // Background Task Management reports `.notFound` for a label it has
            // no record of, which is the state of every machine before the
            // first registration; `.notRegistered` only appears once a record
            // exists, such as after an unregister. The caller has already
            // validated the bundled service and property list, so a missing
            // record is a reason to register, and `register()` reports any
            // real failure itself.
            return .register
        case .enabled:
            guard marker?.artifact == bundledArtifact,
                  marker?.phase == .ready || marker?.phase == .registered
            else { return .replace }
            guard case let .response(runningArtifact) = runningArtifact else {
                return .retry
            }
            return runningArtifact == bundledArtifact ? .keep : .replace
        case .requiresApproval:
            return .awaitApproval
        case .unknown:
            return .failUnknown
        }
    }
}

/// What the registrar does about a registered service that does not
/// answer while the marker says it is current: ADR 0007.
///
/// A service that is restarting, after a crash or a wake from sleep, answers
/// again within seconds, and replacing it would drop its pending requests.
/// One that never answers, because it dies as it starts or its registered
/// bundle is gone, cannot be fixed by asking again. So the registrar asks
/// again on a backoff, replaces the service once when it has stayed
/// unreachable for `replacementDelay`, and after that waits for the person:
/// the next activation or Retry observes once more without a timer. The
/// window runs on a clock, not a count, so activating the app often cannot
/// bring the replacement forward, and the clock stops while the Mac sleeps,
/// so a wake cannot use up the minute.
struct AgentIntegrationUnreachableServicePolicy: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        case retry(after: Duration)
        case replace
        case wait
    }

    static let retryDelays: [Duration] = [2, 4, 8, 16, 32].map { .seconds($0) }
    static let replacementDelay: Duration = .seconds(60)

    private var firstUnreachableAt: SuspendingClock.Instant?
    private var retriesScheduled = 0
    private(set) var hasReplaced = false

    /// The step for one more unreachable observation at `now`.
    /// `isRetryPending` is whether a timer is already set, which the
    /// observation then leaves alone.
    mutating func step(at now: SuspendingClock.Instant, isRetryPending: Bool) -> Step {
        let first = firstUnreachableAt ?? now
        firstUnreachableAt = first
        guard !hasReplaced else { return .wait }
        if first.duration(to: now) >= Self.replacementDelay {
            hasReplaced = true
            return .replace
        }
        guard !isRetryPending, retriesScheduled < Self.retryDelays.count else { return .wait }
        defer { retriesScheduled += 1 }
        return .retry(after: Self.retryDelays[retriesScheduled])
    }

    /// The service answered, or the person asked to try again.
    mutating func reset() {
        self = Self()
    }
}

/// Where the running app is, as far as registering its service goes.
enum AgentIntegrationBundleLocation: Equatable, Sendable {
    case installed
    /// On a mounted disk image, which goes away when it is ejected.
    case diskImage
    /// Under App Translocation: a read-only mount of a randomized path that
    /// macOS makes for a quarantined app opened where it was downloaded.
    case translocated

    /// The volume's DiskArbitration device model is "Disk Image" for a
    /// mounted image. A translocated app runs from a read-only mount whose
    /// own path has an `AppTranslocation` component. Neither test refuses a
    /// read-only or external disk the app is installed on, or a path that
    /// merely contains the word.
    init(volumeDeviceModel: String?, isVolumeReadOnly: Bool, volumePath: String) {
        if volumeDeviceModel == "Disk Image" {
            self = .diskImage
        } else if isVolumeReadOnly, volumePath != "/",
                  URL(fileURLWithPath: volumePath).pathComponents.contains("AppTranslocation")
        {
            self = .translocated
        } else {
            self = .installed
        }
    }

    /// Reads where `bundleURL` is from its volume. A volume the system
    /// cannot describe counts as installed, as before this check existed.
    init(of bundleURL: URL) {
        guard let values = try? bundleURL.resourceValues(forKeys: [.volumeURLKey, .volumeIsReadOnlyKey]),
              let volume = values.volume
        else {
            self = .installed
            return
        }
        var deviceModel: String?
        if let session = DASessionCreate(kCFAllocatorDefault),
           let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL),
           let description = DADiskCopyDescription(disk) as? [String: Any]
        {
            deviceModel = description[kDADiskDescriptionDeviceModelKey as String] as? String
        }
        self.init(
            volumeDeviceModel: deviceModel?.trimmingCharacters(in: .whitespaces),
            isVolumeReadOnly: values.volumeIsReadOnly ?? false,
            volumePath: volume.path
        )
    }
}

/// How a failed `SMAppService.register()` is answered. `SMAppService.h`
/// documents `kSMErrorAlreadyRegistered` for a service already registered
/// and `kSMErrorLaunchDeniedByUser` for one the person has not allowed.
enum AgentIntegrationRegistrationFailure: Equatable, Sendable {
    /// Nothing failed: verify the registration as after a success.
    case alreadyRegistered
    /// Registered, but off in Login Items until the person allows it.
    case deniedByUser
    /// The property list or the executable it names is not in the bundle.
    case missingFromBundle
    case other

    init(_ error: any Error) {
        let error = error as NSError
        guard error.domain == SMAppServiceErrorDomain else {
            self = .other
            return
        }
        switch error.code {
        case Int(kSMErrorAlreadyRegistered): self = .alreadyRegistered
        case Int(kSMErrorLaunchDeniedByUser): self = .deniedByUser
        case Int(kSMErrorJobPlistNotFound), Int(kSMErrorToolNotValid): self = .missingFromBundle
        default: self = .other
        }
    }
}

/// What the registrar asks of macOS and of the app's bundle. Injected so a
/// test can run the whole reconciliation, timers included, without
/// registering anything; `live(appBundleURL:)` is the app's.
struct AgentIntegrationServiceEnvironment {
    /// The bundled artifact after its signatures are checked, and where the
    /// bundle is. Blocks on code signing and hashing.
    var inspectBundle: @Sendable () async throws -> (artifact: AgentIntegrationServiceArtifact, location: AgentIntegrationBundleLocation)
    var status: @MainActor () -> AgentIntegrationRegistrationStatus
    var register: @MainActor () throws -> Void
    /// Returns once the system's completion handler has run.
    var unregister: @MainActor () async throws -> Void
    /// The artifact the running service reports, after authenticating it.
    var runningArtifact: @Sendable () async throws -> AgentIntegrationServiceArtifact?
    var now: @Sendable () -> SuspendingClock.Instant
    var sleep: @Sendable (Duration) async throws -> Void
    /// Whether this environment registers with the system, which the test
    /// host's own registrar must never do.
    var registersWithSystem: Bool
}

struct AgentIntegrationRegistrationMarker: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    enum Phase: String, Codable, Sendable {
        case replacing
        case registered
        case ready
    }

    let schemaVersion: Int
    let phase: Phase
    let artifact: AgentIntegrationServiceArtifact
    let appVersion: String

    init(
        schemaVersion: Int = Self.schemaVersion,
        phase: Phase,
        artifact: AgentIntegrationServiceArtifact,
        appVersion: String
    ) {
        self.schemaVersion = schemaVersion
        self.phase = phase
        self.artifact = artifact
        self.appVersion = appVersion
    }
}

struct AgentIntegrationRegistrationMarkerStore: Sendable {
    let fileURL: URL

    func load() -> AgentIntegrationRegistrationMarker? {
        guard let data = try? Data(contentsOf: fileURL),
              let marker = try? JSONDecoder().decode(AgentIntegrationRegistrationMarker.self, from: data),
              marker.schemaVersion == AgentIntegrationRegistrationMarker.schemaVersion
        else { return nil }
        return marker
    }

    func write(_ marker: AgentIntegrationRegistrationMarker) throws {
        SecureFileWrite.ensureUserOnlyDirectory(fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try SecureFileWrite.writeAtomic(encoder.encode(marker), to: fileURL)
    }
}

struct AgentIntegrationServiceIssue: Identifiable, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case requiresApproval
        case serviceNotFound
        case reconciliationFailed
        /// Weir runs from its disk image or from a translocated copy, a
        /// place that is gone once the image is ejected or the app is
        /// moved. A service registered from there would stop starting.
        case temporaryLocation
    }

    let reason: Reason
    let diagnostic: String?

    var id: Reason {
        reason
    }

    /// The issue a failed reconciliation reports, or `nil` when there is
    /// nothing the user can act on. An ad hoc-signed build has no Team ID
    /// for the service to authenticate its peers with, and retrying cannot
    /// change the running app's signature, so it stays unavailable without
    /// an alert; the agents keep their native permission prompts.
    static func forReconciliationFailure(_ error: any Error) -> Self? {
        if case AgentIntegrationError.adHocSigningUnsupported = error {
            return nil
        }
        return Self(reason: .reconciliationFailed, diagnostic: String(describing: error))
    }

    var title: LocalizedStringResource {
        "Native Approvals Unavailable"
    }

    var detail: LocalizedStringResource {
        switch reason {
        case .requiresApproval:
            "Enable Weir in System Settings → General → Login Items & Extensions, then return to Weir."
        case .serviceNotFound:
            "The bundled approval service couldn’t be found. Reinstall Weir and try again."
        case .reconciliationFailed:
            "Weir couldn’t start its approval service. Claude and Codex will use their own permission prompts."
        case .temporaryLocation:
            "Weir is running from a disk image or a temporary copy. Move it to the Applications folder, then open it again."
        }
    }
}

struct AgentIntegrationIssuePresentation: Equatable, Sendable {
    private(set) var issue: AgentIntegrationServiceIssue?
    private var dismissedReason: AgentIntegrationServiceIssue.Reason?

    mutating func present(_ issue: AgentIntegrationServiceIssue) {
        guard dismissedReason != issue.reason else { return }
        dismissedReason = nil
        self.issue = issue
    }

    mutating func dismiss() {
        guard let issue else { return }
        dismissedReason = issue.reason
        self.issue = nil
    }

    mutating func reset() {
        dismissedReason = nil
        issue = nil
    }
}

@MainActor
@Observable
final class AgentIntegrationServiceRegistrar {
    private static let log = Logger.weir("agent.integration-service")
    private static let controlEnvironmentKey = "WEIR_AGENT_SERVICE_CONTROL"

    private(set) var isReady = false
    private var issuePresentation = AgentIntegrationIssuePresentation()

    var issue: AgentIntegrationServiceIssue? {
        issuePresentation.issue
    }

    private let environment: AgentIntegrationServiceEnvironment
    private let markerStore: AgentIntegrationRegistrationMarkerStore
    private let appVersion: String
    private var reconcileTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var unreachablePolicy = AgentIntegrationUnreachableServicePolicy()
    /// Set by Retry while a reconcile runs: that one is not the person's
    /// fresh start, so another follows it.
    private var isRetryRequested = false
    /// Set once recurring reconciles are scheduled; a demo run and a test
    /// never get there.
    private var isFollowingActivation = false
    private var readinessChanged: ((Bool) -> Void)?
    /// Set once the running app turns out to be ad hoc-signed. Its signature
    /// cannot change while it runs, so later activations skip reconciling.
    private var isSigningUnsupported = false

    init(
        appBundleURL: URL = Bundle.main.bundleURL,
        applicationSupportDirectory: URL = WeirPaths.applicationSupportDirectory(),
        appVersion: String? = nil,
        environment: AgentIntegrationServiceEnvironment? = nil
    ) {
        self.environment = environment ?? .live(appBundleURL: appBundleURL)
        markerStore = AgentIntegrationRegistrationMarkerStore(
            fileURL: applicationSupportDirectory
                .appendingPathComponent("agent-integration", isDirectory: true)
                .appendingPathComponent("service-registration.json")
        )
        self.appVersion = appVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? "unknown"
    }

    func start(readinessChanged: @escaping (Bool) -> Void) {
        guard !(WeirPaths.isRunningInTests && environment.registersWithSystem) else { return }
        // A demo run, such as `make screenshot`, shares its bundle identifier
        // and LaunchAgent label with the Weir the user already runs.
        // `SMAppService` keeps one registration per user, so reconciling here
        // would replace that app's service with this build's. The demo leaves
        // the agents on their native prompts instead.
        guard !DemoFixture.isDemoActive else {
            Self.log.notice("Native approvals are off: demo mode")
            return
        }
        #if DEBUG && WEIR_AUTOMATION
            // A run the verification channel drives shares the bundle
            // identifier too, with only its data moved aside, so it leaves the
            // registration alone for the same reason the demo does. Decided as
            // the channel decides whether to start: a run it refuses is an
            // ordinary run on the person's data, and keeps its approvals.
            guard !AutomationChannel.isAutomationRun(environment: ProcessInfo.processInfo.environment) else {
                Self.log.notice("Native approvals are off: automation run")
                return
            }
        #endif
        self.readinessChanged = readinessChanged

        #if DEBUG
            if let command = ProcessInfo.processInfo.environment[Self.controlEnvironmentKey] {
                runDevelopmentCommand(command)
                return
            }
        #endif

        isFollowingActivation = true
        reconcile()
    }

    /// Called every time the app gains focus (`AppVisibilityObserver`).
    func appDidBecomeActive() {
        guard isFollowingActivation else { return }
        reconcile()
    }

    /// The person's Retry: a fresh start, with the unreachable service's
    /// budget restored. When a reconcile is already running, the fresh one
    /// follows it rather than being dropped.
    func retry() {
        issuePresentation.reset()
        retryTask?.cancel()
        retryTask = nil
        isRetryRequested = true
        reconcile()
    }

    func dismissIssue() {
        issuePresentation.dismiss()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    #if DEBUG
        /// Waits until no reconcile runs and no retry is scheduled, so a test
        /// can read the outcome of a whole sequence rather than wait a while.
        func waitUntilIdle() async {
            while let task = reconcileTask ?? retryTask {
                await task.value
            }
        }

        /// Waits until no reconcile runs, leaving a scheduled retry waiting,
        /// so a test whose retry delays never pass can read what one
        /// activation decided before the next arrives: an activation while a
        /// reconcile runs is dropped, and the reconcile goes on after its
        /// observation ends.
        func waitUntilReconciled() async {
            while let task = reconcileTask {
                await task.value
            }
        }
    #endif

    private func reconcile(forceReplacement: Bool = false) {
        guard reconcileTask == nil, !isSigningUnsupported else { return }
        if isRetryRequested {
            isRetryRequested = false
            unreachablePolicy.reset()
        }
        reconcileTask = Task { [weak self] in
            guard let self else { return }
            defer {
                reconcileTask = nil
                if isRetryRequested {
                    reconcile()
                }
            }
            do {
                let bundle = try await environment.inspectBundle()
                let status = environment.status()
                var observation = RunningServiceArtifactObservation.notApplicable
                var observationDiagnostic: String?
                if status == .enabled {
                    do {
                        observation = try await .response(environment.runningArtifact())
                    } catch {
                        observation = .unavailable
                        observationDiagnostic = String(describing: error)
                    }
                }
                let action = forceReplacement && status == .enabled
                    ? AgentIntegrationRegistrationAction.replace
                    : AgentIntegrationRegistrationDecision.action(
                        status: status,
                        bundledArtifact: bundle.artifact,
                        runningArtifact: observation,
                        marker: markerStore.load()
                    )
                try await apply(
                    action,
                    artifact: bundle.artifact,
                    location: bundle.location,
                    diagnostic: observationDiagnostic
                )
            } catch {
                guard let issue = AgentIntegrationServiceIssue.forReconciliationFailure(error) else {
                    Self.log.notice("Native approvals are off: this build is ad hoc-signed")
                    isSigningUnsupported = true
                    return
                }
                Self.log.error("Service reconciliation failed: \(String(describing: error), privacy: .private)")
                setUnavailable(issue.reason, diagnostic: issue.diagnostic)
            }
        }
    }

    private func apply(
        _ action: AgentIntegrationRegistrationAction,
        artifact: AgentIntegrationServiceArtifact,
        location: AgentIntegrationBundleLocation,
        diagnostic: String?
    ) async throws {
        // Only a registration records where the app is; keeping a service
        // that an installed copy registered is fine from anywhere.
        if action == .register || action == .replace, location != .installed {
            Self.log.notice("Not registering the service from \(String(describing: location), privacy: .public)")
            setUnavailable(.temporaryLocation)
            return
        }
        switch action {
        case .register:
            try writeMarker(phase: .replacing, artifact: artifact)
            guard try register(artifact) else { return }
            try await verifyRegisteredService(artifact: artifact)
        case .keep:
            try writeMarker(phase: .ready, artifact: artifact)
            setReady()
        case .replace:
            // A timer set before the replacement would observe again after
            // it, and a failed replacement must wait for the person.
            retryTask?.cancel()
            retryTask = nil
            try writeMarker(phase: .replacing, artifact: artifact)
            let slowOperationNotice = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.setUnavailable(
                    .reconciliationFailed,
                    diagnostic: "Service removal is taking longer than expected."
                )
            }
            defer { slowOperationNotice.cancel() }
            try await environment.unregister()
            guard try register(artifact) else { return }
            try await verifyRegisteredService(artifact: artifact)
        case .retry:
            let step = unreachablePolicy.step(at: environment.now(), isRetryPending: retryTask != nil)
            // Once a replacement was refused for where the app runs, no
            // registration from here can repair the service, so later
            // observations keep saying so instead of offering a Retry that
            // cannot help. A service that answers again still clears it.
            let reason: AgentIntegrationServiceIssue.Reason =
                location != .installed && unreachablePolicy.hasReplaced
                    ? .temporaryLocation
                    : .reconciliationFailed
            switch step {
            case let .retry(delay):
                setUnavailable(reason, diagnostic: diagnostic)
                scheduleRetry(after: delay)
            case .wait:
                setUnavailable(reason, diagnostic: diagnostic)
            case .replace:
                Self.log.notice("Replacing the service, which has not answered for a minute")
                try await apply(.replace, artifact: artifact, location: location, diagnostic: diagnostic)
            }
        case .awaitApproval:
            setUnavailable(.requiresApproval)
        case .failUnknown:
            throw AgentIntegrationError.invalidResponse
        }
    }

    /// Registers the bundled service. Returns whether the registration
    /// stands, so verification follows; a failure the person can act on is
    /// reported here, and any other is thrown.
    private func register(_ artifact: AgentIntegrationServiceArtifact) throws -> Bool {
        do {
            try environment.register()
        } catch {
            var failure = AgentIntegrationRegistrationFailure(error)
            // Not every refusal carries the documented code; the status says
            // the same thing when the person has turned the service off.
            if failure == .other, environment.status() == .requiresApproval {
                failure = .deniedByUser
            }
            let kind = String(describing: failure)
            Self.log.notice(
                "Registering the service failed (\(kind, privacy: .public)): \(String(describing: error), privacy: .private)"
            )
            switch failure {
            case .alreadyRegistered:
                break
            case .deniedByUser:
                // The registration exists, off in Login Items; once allowed,
                // the marker lets it be kept rather than replaced again.
                try writeMarker(phase: .registered, artifact: artifact)
                setUnavailable(.requiresApproval)
                return false
            case .missingFromBundle:
                setUnavailable(.serviceNotFound)
                return false
            case .other:
                throw error
            }
        }
        try writeMarker(phase: .registered, artifact: artifact)
        return true
    }

    private func verifyRegisteredService(artifact: AgentIntegrationServiceArtifact) async throws {
        switch environment.status() {
        case .enabled:
            guard try await environment.runningArtifact() == artifact else {
                throw AgentIntegrationError.invalidResponse
            }
            try writeMarker(phase: .ready, artifact: artifact)
            setReady()
        case .requiresApproval:
            setUnavailable(.requiresApproval)
        case .notFound:
            setUnavailable(.serviceNotFound)
        case .notRegistered, .unknown:
            throw AgentIntegrationError.invalidResponse
        }
    }

    private func scheduleRetry(after delay: Duration) {
        guard retryTask == nil else { return }
        let sleep = environment.sleep
        retryTask = Task { [weak self] in
            try? await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            retryTask = nil
            reconcile()
        }
    }

    private func writeMarker(
        phase: AgentIntegrationRegistrationMarker.Phase,
        artifact: AgentIntegrationServiceArtifact
    ) throws {
        try markerStore.write(AgentIntegrationRegistrationMarker(
            phase: phase,
            artifact: artifact,
            appVersion: appVersion
        ))
    }

    private func setReady() {
        retryTask?.cancel()
        retryTask = nil
        unreachablePolicy.reset()
        issuePresentation.reset()
        guard !isReady else { return }
        isReady = true
        readinessChanged?(true)
        Self.log.notice("Agent Integration Service is ready")
    }

    private func setUnavailable(
        _ reason: AgentIntegrationServiceIssue.Reason,
        diagnostic: String? = nil
    ) {
        issuePresentation.present(AgentIntegrationServiceIssue(
            reason: reason,
            diagnostic: diagnostic
        ))
        guard isReady else { return }
        isReady = false
        readinessChanged?(false)
    }

    #if DEBUG
        private func runDevelopmentCommand(_ command: String) {
            switch command {
            case "register":
                reconcile()
            case "refresh":
                reconcile(forceReplacement: true)
            case "unregister":
                reconcileTask = Task {
                    defer { reconcileTask = nil }
                    do {
                        try await environment.unregister()
                        setUnavailable(.reconciliationFailed, diagnostic: "unregistered by development control")
                    } catch {
                        setUnavailable(.reconciliationFailed, diagnostic: String(describing: error))
                    }
                }
            case "status":
                Self.log.notice("Agent Integration Service status: \(String(describing: self.environment.status()), privacy: .public)")
            default:
                setUnavailable(
                    .reconciliationFailed,
                    diagnostic: "WEIR_AGENT_SERVICE_CONTROL must be register, refresh, unregister, or status."
                )
            }
        }
    #endif
}

extension AgentIntegrationServiceEnvironment {
    /// The app's environment: the bundled LaunchAgent through `SMAppService`,
    /// its signatures through Security, and the running service through XPC.
    /// Every call that blocks runs through `OffPoolWork`.
    static func live(appBundleURL: URL) -> Self {
        Self(
            inspectBundle: {
                try await OffPoolWork.run {
                    let executableDirectory = AgentIntegrationConfiguration.executableDirectory(inApp: appBundleURL)
                    try AgentIntegrationSigning.validateStaticCode(
                        at: executableDirectory.appendingPathComponent(AgentIntegrationConfiguration.serviceExecutableName),
                        identifier: AgentIntegrationConfiguration.serviceIdentifier
                    )
                    try AgentIntegrationSigning.validateStaticCode(
                        at: executableDirectory.appendingPathComponent(AgentIntegrationConfiguration.hookHelperExecutableName),
                        identifier: AgentIntegrationConfiguration.hookHelperIdentifier
                    )
                    return try (
                        AgentIntegrationServiceArtifact.bundled(in: appBundleURL),
                        AgentIntegrationBundleLocation(of: appBundleURL)
                    )
                }
            },
            status: { registrationStatus(service().status) },
            register: { try service().register() },
            unregister: { try await unregister(service()) },
            runningArtifact: { try await runningServiceArtifact() },
            now: { SuspendingClock.now },
            sleep: { try await Task.sleep(for: $0, clock: .suspending) },
            registersWithSystem: true
        )
    }

    @MainActor private static func service() -> SMAppService {
        SMAppService.agent(plistName: AgentIntegrationConfiguration.plistName)
    }

    @MainActor private static func registrationStatus(_ status: SMAppService.Status) -> AgentIntegrationRegistrationStatus {
        switch status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    @MainActor private static func unregister(_ service: SMAppService) async throws {
        guard service.status != .notRegistered else { return }
        let _: Void = try await withCheckedThrowingContinuation { continuation in
            service.unregister { error in
                if let error {
                    continuation.resume(
                        throwing: AgentIntegrationError.requestFailed(error.localizedDescription)
                    )
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Asks the running service three times, a little apart, since it may
    /// still be starting.
    private static func runningServiceArtifact() async throws -> AgentIntegrationServiceArtifact? {
        do {
            return try await queryRunningServiceArtifact()
        } catch {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
        }
        do {
            return try await queryRunningServiceArtifact()
        } catch {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(400))
        }
        return try await queryRunningServiceArtifact()
    }

    private static func queryRunningServiceArtifact() async throws -> AgentIntegrationServiceArtifact? {
        try await OffPoolWork.run {
            let client = try AgentIntegrationXPCClient(role: .controller)
            let bootstrap = try client.openSession()
            guard bootstrap.role == .controller else {
                throw AgentIntegrationError.invalidResponse
            }
            return bootstrap.serviceArtifact
        }
    }
}
