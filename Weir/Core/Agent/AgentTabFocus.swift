// AgentTabFocus.swift
// Weir — asking a pane's agent to bring one of its sessions forward, and what it shows.

import Foundation
import os
import WeirDomain

/// The one way Weir reaches into an agent that shows several sessions in a pane
/// (OpenCode's tabs): no key can name a session, so a file its plugin looks for says
/// which. A request carries a session's ID, when it was asked, and a nonce if an answer
/// is wanted, and nothing else. The plugin obeys only for a session of its own pane, and
/// ignores one older than a few seconds, so a late one cannot pull the person away
/// from where they went since.
///
/// Files are named for the process, by its launch's run, which is the name its plugin
/// knows: several processes can run from one pane under tmux, and each takes only its own
/// (`AgentRuntimePresentation.tabChannel`).
enum AgentTabFocus {
    private static let log = Logger(subsystem: "com.nekoder.weir", category: "agent.tab-focus")

    /// What the plugin read of the screen as it answered: the session in front, nil for
    /// none (its home screen).
    private struct Answer: Decodable {
        let nonce: String
        let sessionId: String?
        let rootSessionId: String?
    }

    /// Where a request goes, beside the provider directories the plugin knows its own
    /// place among (`focusRequestPath` in the plugin).
    static func requestURL(channel: UUID, under root: URL = WeirPaths.applicationSupportDirectory()) -> URL {
        root.appendingPathComponent("tab-focus", isDirectory: true)
            .appendingPathComponent("\(channel.uuidString.uppercased()).json")
    }

    /// One file for each request, so two at once cannot take each other's answer.
    private static func answerURL(nonce: String, channel: UUID, under root: URL) -> URL {
        let request = requestURL(channel: channel, under: root)
        return request.deletingLastPathComponent().appendingPathComponent("\(request.lastPathComponent).\(nonce).answer")
    }

    /// Asks the pane to show `runtime`'s session. Nothing to name, or nothing written,
    /// leaves the pane as it is, and whoever needs the session on screen finds that out.
    static func request(_ runtime: AgentRuntimePresentation, under root: URL = WeirPaths.applicationSupportDirectory()) {
        guard let channel = runtime.tabChannel, let sessionID = runtime.sessionID else { return }
        write(sessionID: sessionID, nonce: nil, channel: channel, root: root)
    }

    /// Asks the pane what it shows, bringing `sessionID` forward first if one is named,
    /// and waits for the answer. True when the session is in front as of a read the
    /// plugin made just now: `sessionID`, or with none named, any session but a
    /// subagent's view, whose prompt is not that of the session it belongs to.
    static func confirm(
        sessionID: String?,
        channel: UUID,
        limit: Duration,
        under root: URL = WeirPaths.applicationSupportDirectory()
    ) async -> Bool {
        let nonce = UUID().uuidString
        let answerURL = answerURL(nonce: nonce, channel: channel, under: root)
        defer { try? FileManager.default.removeItem(at: answerURL) }
        guard write(sessionID: sessionID, nonce: nonce, channel: channel, root: root) else { return false }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while clock.now < deadline, !Task.isCancelled {
            if let data = try? Data(contentsOf: answerURL),
               let answer = try? JSONDecoder().decode(Answer.self, from: data),
               answer.nonce == nonce
            {
                if let sessionID {
                    return sessionID == answer.sessionId
                }
                return answer.sessionId != nil && answer.sessionId == answer.rootSessionId
            }
            // Short, as the paste follows this read: what it found ages as this sleeps.
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Requests and answers nobody took: a request is ignored past a few seconds, and an
    /// answer whose asker gave up has nobody to read it, as do the files of a process
    /// that has ended or of an earlier build that named them by pane.
    private static func sweepStale(in directory: URL, now: Date = Date()) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".json") || name.hasSuffix(".answer") {
            let url = directory.appendingPathComponent(name)
            let written = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            if let written, now.timeIntervalSince(written) > 30 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    @discardableResult
    private static func write(sessionID: String?, nonce: String?, channel: UUID, root: URL) -> Bool {
        var body: [String: Any] = ["at": Int(Date().timeIntervalSince1970 * 1000)]
        body["sessionId"] = sessionID
        body["nonce"] = nonce
        let url = requestURL(channel: channel, under: root)
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            sweepStale(in: url.deletingLastPathComponent())
            try SecureFileWrite.writeAtomic(data, to: url)
            return true
        } catch {
            log.error("focus request not written: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}
