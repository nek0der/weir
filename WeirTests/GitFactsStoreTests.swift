// GitFactsStoreTests.swift
// Weir — when the session folders' Git facts are read, and what a reading Git did not answer keeps.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct GitFactsStoreTests {
    private nonisolated static let facts = GitFactsFixture.make(commits: nil, unpushed: nil, uncommitted: 1, base: nil)

    @Test func aReadingOfAll_keepsWhatItRead_andForgetsFoldersNoLongerListed() async {
        let store = GitFactsStore(fetch: { _ in .facts(Self.facts) })
        let project = ContainerID.project(UUID())
        let gone = ContainerID.project(UUID())
        await store.refresh([.init(container: project, workingDirectory: URL(fileURLWithPath: "/a"))], isAll: true)
        await store.refresh(gone, at: URL(fileURLWithPath: "/b"))
        #expect(store.facts(for: gone) == Self.facts)

        await store.refresh([.init(container: project, workingDirectory: URL(fileURLWithPath: "/a"))], isAll: true)
        #expect(store.facts(for: project) == Self.facts)
        #expect(store.facts(for: gone) == nil)
    }

    @Test func inactiveLaunchDefersTheReadUntilActivation() async throws {
        let reads = Recorded<[URL]>([])
        let readsByFolder = Recorded<[URL: Int]>([:])
        let store = GitFactsStore(fetch: { folder in
            reads.update { $0.append(folder) }
            readsByFolder.update { $0[folder, default: 0] += 1 }
            let branch = readsByFolder.value[folder] == 1 ? "first" : "second"
            return .facts(GitFactsFixture.make(branch: branch, commits: nil, unpushed: nil, base: nil))
        })
        let (session, project) = WorkspaceSessionFixture.withProject()
        let other = session.addOrActivateProject(
            rootURL: WorkspaceSessionFixture.projectRootURL("other-facts"),
            suggestedName: "other"
        )
        let front = Recorded(false)
        store.start(session: session) { front.value }
        // Observe the launch window. The periodic clock's first tick is later.
        await pollUntil(timeout: .milliseconds(200)) { !reads.value.isEmpty }
        #expect(reads.value.isEmpty)
        #expect(store.facts.isEmpty)

        front.value = true
        store.appActivityChanged(isActive: true)
        await pollUntil {
            store.facts(for: .project(project.id))?.branch == "first" && store.facts(for: .project(other.id))?.branch == "first"
        }
        try #require(reads.value.count == 2)
        #expect(Set(reads.value) == [project.rootURL, other.rootURL])
        #expect(store.facts(for: .project(project.id))?.branch == "first")
        #expect(store.facts(for: .project(other.id))?.branch == "first")

        front.value = false
        store.appActivityChanged(isActive: false)
        front.value = true
        store.appActivityChanged(isActive: true)
        await pollUntil {
            store.facts(for: .project(project.id))?.branch == "second" && store.facts(for: .project(other.id))?.branch == "second"
        }
        #expect(store.facts(for: .project(project.id))?.branch == "second")
        #expect(store.facts(for: .project(other.id))?.branch == "second")
        #expect(readsByFolder.value == [project.rootURL: 2, other.rootURL: 2])
    }

    /// Launch in front triggers a read. The next same-state report is no
    /// new activation during the window observed here.
    @Test func activeLaunchReadsWithoutAnActivityNotification() async throws {
        let reads = Recorded<[URL]>([])
        let store = GitFactsStore(fetch: { folder in
            reads.update { $0.append(folder) }
            return .facts(Self.facts)
        })
        let (session, project) = WorkspaceSessionFixture.withProject()
        let other = session.addOrActivateProject(
            rootURL: WorkspaceSessionFixture.projectRootURL("other-facts"),
            suggestedName: "other"
        )
        store.start(session: session) { true }
        await pollUntil { store.facts.count == 2 }
        try #require(store.facts == [.project(project.id): Self.facts, .project(other.id): Self.facts])
        #expect(reads.value.count == 2)
        #expect(Set(reads.value) == [project.rootURL, other.rootURL])

        store.appActivityChanged(isActive: true)
        await pollUntil(timeout: .milliseconds(200)) { reads.value.count > 2 }
        #expect(reads.value.count == 2)
    }

    @Test func aReadingAfterThePersonsRead_waitsForIt() async throws {
        let gate = Gate<Void>()
        let log = Recorded<[String]>([])
        let store = GitFactsStore(fetch: { folder in
            await gate.pass(folder.lastPathComponent, loggingTo: log)
            return .facts(Self.facts)
        })
        let container = ContainerID.project(UUID())
        async let asked = store.read(container, at: URL(fileURLWithPath: "/asked"))
        defer { gate.open() }
        try await gate.waitUntilRequested()
        // The MainActor task reaches refresh's registration before returning at its await.
        let clock = Task.immediate { await store.refresh(container, at: URL(fileURLWithPath: "/clock")) }
        #expect(log.value == ["start asked"])
        gate.open()
        #expect(await asked == .facts(Self.facts))
        await clock.value
        #expect(log.value == ["start asked", "end asked", "start clock", "end clock"])
    }

    @Test func aReadingAskedForByThePerson_ignoresTheWait_andSaysWhatGitAnswered() async {
        let answers = Answers([.unanswered, .facts(Self.facts)])
        let store = GitFactsStore(fetch: { _ in await answers.next() })
        let container = ContainerID.project(UUID())
        let folder = URL(fileURLWithPath: "/a")
        await store.refresh(container, at: folder)
        // The clock would wait now; the person's move does not.
        #expect(await store.read(container, at: folder) == .facts(Self.facts))
        #expect(store.facts(for: container) == Self.facts)
    }

    @Test func readingsOfAll_askedForWhileOneRuns_runOnceAfterIt() async throws {
        let gate = Gate<Void>()
        let log = Recorded<[String]>([])
        let store = GitFactsStore(fetch: { folder in
            await gate.pass(folder.path, loggingTo: log)
            return .facts(Self.facts)
        })
        let (session, project) = WorkspaceSessionFixture.withProject()
        let front = Recorded(false)
        store.start(session: session) { front.value }
        front.value = true
        let target = PRStatusSyncer.Target(container: .project(project.id), workingDirectory: project.rootURL)
        async let first: Void = store.refresh([target], isAll: true, first: [target.container])
        defer { gate.open() }
        try await gate.waitUntilRequested()
        let added = session.addOrActivateProject(
            rootURL: WorkspaceSessionFixture.projectRootURL("new-facts"),
            suggestedName: "new"
        )

        await store.refresh([target], isAll: true)
        await store.refresh([target], isAll: true)
        #expect(log.value == ["start \(project.rootURL.path)"])
        gate.open()
        await first

        let entries = log.value
        #expect(entries.count == 6)
        #expect(Array(entries.prefix(2)) == ["start \(project.rootURL.path)", "end \(project.rootURL.path)"])
        #expect(Set(entries.dropFirst(2)) == [
            "start \(project.rootURL.path)", "end \(project.rootURL.path)",
            "start \(added.rootURL.path)", "end \(added.rootURL.path)"
        ])
        #expect(store.facts == [.project(project.id): Self.facts, .project(added.id): Self.facts])
    }

    @Test func aReadingGitLeavesUnanswered_keepsTheFactsBefore_andWaitsLongerEachTime() async {
        let answers = Answers([.facts(Self.facts), .unanswered, .unanswered, .notWorkTree])
        var clock = ContinuousClock.now
        let store = GitFactsStore(fetch: { _ in await answers.next() }, now: { clock })
        let container = ContainerID.project(UUID())
        let folder = URL(fileURLWithPath: "/a")

        await store.refresh(container, at: folder)
        await store.refresh(container, at: folder)
        // Unanswered is not "no facts".
        #expect(store.facts(for: container) == Self.facts)
        // Within the wait the folder is not asked again.
        clock += .seconds(29)
        await store.refresh(container, at: folder)
        #expect(await answers.taken == 2)

        clock += .seconds(1)
        await store.refresh(container, at: folder)
        #expect(await answers.taken == 3)
        // The second in a row waits twice as long.
        clock += .seconds(59)
        await store.refresh(container, at: folder)
        #expect(await answers.taken == 3)
        clock += .seconds(1)
        await store.refresh(container, at: folder)
        // Not a work tree is an answer: the facts go.
        #expect(await answers.taken == 4)
        #expect(store.facts(for: container) == nil)
    }

    @Test func aReadingQueuedBehindOneGitLeftUnanswered_waitsToo() async throws {
        let gate = Gate<Void>()
        let log = Recorded<[String]>([])
        let store = GitFactsStore(fetch: { folder in
            await gate.pass(folder.lastPathComponent, loggingTo: log)
            return .unanswered
        })
        let container = ContainerID.project(UUID())
        async let first: Void = store.refresh(container, at: URL(fileURLWithPath: "/first"))
        defer { gate.open() }
        try await gate.waitUntilRequested()
        let second = Task.immediate { await store.refresh(container, at: URL(fileURLWithPath: "/second")) }
        #expect(log.value == ["start first"])
        gate.open()
        await first
        await second.value
        #expect(log.value == ["start first", "end first"])
    }

    @Test func aReadingOfAll_stopsWhenWeirGoesToTheBack() async {
        let front = Recorded(false)
        let reads = Recorded<[URL]>([])
        let store = GitFactsStore(fetch: { folder in
            reads.update { $0.append(folder) }
            front.value = false
            return .facts(Self.facts)
        })
        let (session, project) = WorkspaceSessionFixture.withProject()
        store.start(session: session) { front.value }
        let known = ContainerID.project(UUID())
        await store.refresh(known, at: URL(fileURLWithPath: "/known"))
        front.value = true
        let targets = [
            PRStatusSyncer.Target(container: .project(project.id), workingDirectory: project.rootURL),
            PRStatusSyncer.Target(container: .project(UUID()), workingDirectory: URL(fileURLWithPath: "/later"))
        ]
        await store.refresh(targets, isAll: true, first: [.project(project.id)])
        // The first folder read sends Weir to the back: the second is not
        // read, and the folder no longer listed goes.
        #expect(store.facts(for: .project(project.id)) == Self.facts)
        #expect(store.facts(for: targets[1].container) == nil)
        #expect(store.facts(for: known) == nil)
        #expect(reads.value == [URL(fileURLWithPath: "/known"), project.rootURL])
    }

    @Test func aReadVisitsPreferredContainersBeforeOtherTargets() async {
        let order = Recorded<[String]>([])
        let store = GitFactsStore(fetch: { folder in
            order.update { $0.append(folder.lastPathComponent) }
            return .facts(Self.facts)
        })
        let targets = ["other", "front-a", "later", "front-b"].map {
            PRStatusSyncer.Target(container: .project(UUID()), workingDirectory: URL(fileURLWithPath: "/\($0)"))
        }

        await store.refresh(targets, isAll: true, first: [targets[1].container, targets[3].container])

        #expect(order.value.count == 4)
        #expect(Set(order.value.prefix(2)) == ["front-a", "front-b"])
        #expect(Set(order.value.suffix(2)) == ["other", "later"])
    }

    @Test func aContainersReadsAreSerializedAndTheLaterReadingWins() async throws {
        let gate = Gate<Void>()
        let log = Recorded<[String]>([])
        let store = GitFactsStore(fetch: { folder in
            await gate.pass(folder.lastPathComponent, loggingTo: log)
            return .facts(GitFactsFixture.make(branch: folder.lastPathComponent, commits: nil, unpushed: nil, base: nil))
        })
        let container = ContainerID.project(UUID())
        async let first: Void = store.refresh(container, at: URL(fileURLWithPath: "/first"))
        defer { gate.open() }
        try await gate.waitUntilRequested()
        let second = Task.immediate { await store.refresh(container, at: URL(fileURLWithPath: "/second")) }
        #expect(log.value == ["start first"])
        gate.open()
        await first
        await second.value
        #expect(log.value == ["start first", "end first", "start second", "end second"])
        #expect(store.facts(for: container)?.branch == "second")
    }
}

extension GitFactsStoreTests {
    /// One of the other worktrees is read at most every five minutes, unless
    /// a window shows it; the rows around it are read every time.
    @Test func anOtherWorktree_isReadAtMostEveryFiveMinutes_unlessAWindowShowsIt() async {
        let reads = Recorded<[URL]>([])
        var clock = ContinuousClock.now
        let store = GitFactsStore(fetch: { folder in
            reads.update { $0.append(folder) }
            return .facts(Self.facts)
        }, now: { clock })
        let row = URL(fileURLWithPath: "/row")
        let other = URL(fileURLWithPath: "/other")
        let otherID = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        let targets: [PRStatusSyncer.Target] = [
            .init(container: .project(UUID()), workingDirectory: row),
            .init(container: otherID, workingDirectory: other, isOccasional: true)
        ]

        await store.refresh(targets, isAll: true)
        clock += .seconds(299)
        await store.refresh(targets, isAll: true)
        #expect(reads.value == [row, other, row])
        // Not read, it is not forgotten either.
        #expect(store.facts(for: otherID) == Self.facts)

        clock += .seconds(1)
        await store.refresh(targets, isAll: true)
        #expect(reads.value == [row, other, row, row, other])

        // Shown in a window, it is read as the row it is.
        await store.refresh(targets, isAll: true, first: [otherID])
        #expect(reads.value.suffix(2) == [other, row])
    }
}

/// Gives the answers in order, counting those taken.
private actor Answers {
    private var answers: [GitFactsRead]
    private(set) var taken = 0

    init(_ answers: [GitFactsRead]) {
        self.answers = answers
    }

    func next() -> GitFactsRead {
        taken += 1
        return answers.isEmpty ? .unanswered : answers.removeFirst()
    }
}
