// AutomationDefaults.swift
// Weir — a channel run's user defaults start empty when its home starts over.

#if DEBUG && WEIR_AUTOMATION

    import Foundation
    import OSLog

    private let log = Logger.weir("automation")

    /// A channel run's bundle identifier is its home's
    /// (`automation_bundle_id` in `scripts/weir-automation.py`), so its user
    /// defaults are a domain of its own rather than the person's. macOS keeps
    /// that domain under the account's `~/Library/Preferences`, not in the
    /// home, so it outlives the home: a home removed and made again at the same
    /// path would start with the defaults of the one before. The run's data
    /// folder therefore keeps a mark, and a run that finds none empties the
    /// domain first, as its data folder starts empty.
    @MainActor
    enum AutomationDefaults {
        static let markName = "automation-defaults"

        /// Empties this channel run's domain when its home is fresh. Called
        /// first at launch, before anything reads the defaults. Any other run
        /// is left alone, so the domain emptied is never the person's.
        static func startOverIfTheHomeIsFresh(environment: [String: String] = ProcessInfo.processInfo.environment) {
            guard AutomationChannel.isAutomationRun(environment: environment) else { return }
            startOver(dataFolder: WeirPaths.applicationSupportDirectory(), bundleID: WeirPaths.bundleID, defaults: .standard)
        }

        /// Empties the domain `bundleID` of `defaults` when `dataFolder` holds
        /// no mark yet, then marks the folder. Returns whether it emptied it.
        @discardableResult
        static func startOver(dataFolder: URL, bundleID: String, defaults: UserDefaults) -> Bool {
            let mark = dataFolder.appendingPathComponent(markName, isDirectory: false)
            guard !FileManager.default.fileExists(atPath: mark.path) else { return false }
            defaults.removePersistentDomain(forName: bundleID)
            if defaults.persistentDomain(forName: bundleID)?.isEmpty == false {
                log.error("automation defaults not emptied for a fresh home")
            }
            SecureFileWrite.ensureUserOnlyDirectory(dataFolder)
            do {
                try SecureFileWrite.writeAtomic(Data(bundleID.utf8), to: mark)
            } catch {
                // Unmarked, the next run in this home empties the domain again,
                // losing what this run sets; the run itself still starts clean.
                log.error("automation defaults mark not written: \(String(describing: error), privacy: .private)")
            }
            return true
        }
    }

#endif
