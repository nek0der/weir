// AutomationRunFolder.swift
// Weir — the folder one run of the verification channel listens in.

#if DEBUG && WEIR_AUTOMATION

    import Darwin
    import Foundation
    import Security

    /// `<base>/<short run ID>/`, mode 0700, holding the socket (`s`), the token
    /// (`token`, 0600), and `info.json` (0600). One folder per run, so two
    /// Debug runs never share a socket or overwrite each other's token, which
    /// they would in the `Weir Dev` data folder every Debug run shares.
    ///
    /// The base defaults to `$TMPDIR/wa`: a Unix socket path is limited to 104
    /// bytes, and `$TMPDIR` (about 49) plus a short name leaves room, where an
    /// Application Support path would not.
    struct AutomationRunFolder {
        struct Info: Codable, Equatable {
            let run: String
            let pid: Int32
            let socket: String
            let `protocol`: String
            /// What the launcher passed in `WEIR_AUTOMATION_NONCE`, so it can
            /// tell its own run from one that another caller started at the
            /// same moment from the same build.
            var nonce: String?
        }

        let base: URL
        let runID: UUID
        let pid: Int32
        let nonce: String?

        init(
            base: URL = FileManager.default.temporaryDirectory.appendingPathComponent("wa", isDirectory: true),
            runID: UUID = UUID(),
            pid: Int32 = getpid(),
            nonce: String? = ProcessInfo.processInfo.environment["WEIR_AUTOMATION_NONCE"]
        ) {
            self.base = base
            self.runID = runID
            self.pid = pid
            self.nonce = nonce
        }

        /// The first eight hex digits of the run ID: short for the socket path,
        /// and unique enough among the runs of one person at one time. The
        /// whole ID is in `info.json`.
        var shortID: String {
            String(runID.uuidString.lowercased().prefix(8))
        }

        var folder: URL {
            base.appendingPathComponent(shortID, isDirectory: true)
        }

        var socketURL: URL {
            folder.appendingPathComponent("s")
        }

        var tokenURL: URL {
            folder.appendingPathComponent("token")
        }

        var infoURL: URL {
            folder.appendingPathComponent("info.json")
        }

        /// Makes the folder and writes the token and `info.json`. Returns the
        /// token. Fails when the base is not ours alone: a folder another user
        /// made could be watched.
        func create() throws -> String {
            let fm = FileManager.default
            try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Self.requireOwnedPrivateDirectory(base)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do {
                let token = try Self.makeToken()
                try SecureFileWrite.writeAtomic(Data(token.utf8), to: tokenURL)
                let info = Info(
                    run: runID.uuidString,
                    pid: pid,
                    socket: socketURL.path,
                    protocol: AutomationProtocol.marker,
                    nonce: nonce
                )
                try SecureFileWrite.writeAtomic(JSONEncoder().encode(info), to: infoURL)
                return token
            } catch {
                // A folder with no info would never be judged stale, so a
                // half-made one goes now.
                try? fm.removeItem(at: folder)
                throw error
            }
        }

        /// Removes the folder, but only while `info.json` still names this
        /// process: a folder a later run took over is that run's.
        func remove() {
            guard let info = Self.readInfo(at: infoURL), info.pid == pid else { return }
            try? FileManager.default.removeItem(at: folder)
        }

        /// Removes the folders under `base` whose process is gone, which a run
        /// that crashed or was killed leaves behind.
        static func removeStale(in base: URL, isAlive: (Int32) -> Bool = Self.isProcessAlive) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return }
            for entry in entries {
                let info = readInfo(at: entry.appendingPathComponent("info.json"))
                // A folder with no readable info is one a run was still making,
                // or not ours to judge; it is left.
                guard let info, !isAlive(info.pid) else { continue }
                try? fm.removeItem(at: entry)
            }
        }

        static func readInfo(at url: URL) -> Info? {
            // A missing or torn file reads as no info; the callers then leave
            // the folder alone.
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Info.self, from: data)
        }

        static func isProcessAlive(_ pid: Int32) -> Bool {
            kill(pid, 0) == 0 || errno == EPERM
        }

        private static func makeToken() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            return bytes.hexString
        }

        private static func requireOwnedPrivateDirectory(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
            let isPrivate = (info.st_mode & 0o077) == 0
            guard isDirectory, info.st_uid == getuid(), isPrivate else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EACCES),
                    userInfo: [NSLocalizedDescriptionKey: "\(url.path) is not a private folder of this user"]
                )
            }
        }
    }

#endif
