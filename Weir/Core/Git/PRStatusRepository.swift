// PRStatusRepository.swift
// Weir — what one repository's configuration says about where each branch's pull request lives.
//
// The batched lookup asks the forge about every row of a repository at
// once, so it can no longer let `gh pr view` work out each row's head
// branch. We work it out the way `gh pr view` does (gh 2.103, read with
// `GH_DEBUG=api`): the branch `@{push}` names, else the remote that
// `branch.<name>.pushRemote`, `remote.pushDefault`, or `branch.<name>.remote`
// names with the local branch's name, or the upstream's name when
// `push.default` is `upstream` or `tracking`; and a branch that merges
// `refs/pull/<n>/head` (what `gh pr checkout` sets up for a fork it has no
// remote for) is request `n`. A head pushed to another owner's repository
// is that owner's fork, and only a request from that owner matches it.
//
// Worktrees share their repository's configuration and refs, so one
// `git config` and one `git for-each-ref` cover every row of a project,
// where `gh pr view` ran seven Git commands per row.

import Foundation

/// What a branch's pull request is asked for by: the branch the request's
/// head is, with the owner whose repository holds it, or the request's
/// number when the branch's upstream names one.
enum PRHeadSelector: Hashable, Sendable {
    /// `owner` is `nil` when no remote names one; any owner then matches.
    case branch(name: String, owner: String?)
    case number(Int)
}

/// The part of a repository's configuration and refs that decides each
/// branch's `PRHeadSelector`.
struct PRStatusRepository: Equatable, Sendable {
    /// Remote name to URL.
    var remotes: [String: String] = [:]
    /// Remote name to what `gh repo set-default` wrote for it.
    var resolvedRemotes: [String: String] = [:]
    /// Local branch name to its `branch.<name>.*` settings.
    var branches: [String: BranchSettings] = [:]
    /// `push.default`.
    var pushDefault: String?
    /// `remote.pushDefault`.
    var remotePushDefault: String?
    /// Local branch name to where `@{push}` resolves, for the branches
    /// where it does.
    var pushes: [String: Push] = [:]

    struct BranchSettings: Equatable, Sendable {
        var remote: String?
        var merge: String?
        var pushRemote: String?
    }

    /// `@{push}` of a branch: the remote, and the remote-tracking ref
    /// (`refs/remotes/<remote>/<branch>`).
    struct Push: Equatable, Sendable {
        var remote: String
        var trackingRef: String
    }

    /// The keys `parse` reads, for `git config --get-regexp`. Git lowercases
    /// the section and the key, and keeps a branch's name as it is.
    static let configPattern = #"^(remote\..*\.(url|gh-resolved)|remote\.pushdefault|push\.default|branch\..*\.(remote|merge|pushremote))$"#

    /// The repository a project's requests are asked for, as `gh` picks it
    /// (go-gh and gh's `factory/default.go`): the remote `gh repo
    /// set-default` marked (`remote.<name>.gh-resolved` is `base`, or names
    /// `owner/repo` on that remote's host), the first of them in `gh`'s
    /// order of remotes, else the first remote in that order. Without
    /// this, a fork cloned as `origin` with the parent set as the default
    /// would be asked about, which has none of the requests `gh pr view`
    /// showed, and `refs/pull/<n>/head` would name another repository's `n`.
    /// GitLab's lookup takes the first remote in that order, as before.
    func baseRepository(forge: ForgeKind) -> BaseRepository? {
        let ranked = ForgeResolver.remotesByPriority(remotes)
        if forge == .gitHub {
            for remote in ranked {
                guard let resolved = resolvedRemotes[remote.name], !resolved.isEmpty else { continue }
                if resolved == "base" {
                    return BaseRepository(remote: remote)
                }
                let parts = resolved.split(separator: "/")
                if parts.count == 2 {
                    return BaseRepository(host: remote.host, path: resolved)
                }
            }
        }
        return ranked.first.flatMap(BaseRepository.init(remote:))
    }

    /// The host and the path (`owner/repo` on GitHub, the project's full
    /// path on GitLab) the queries name.
    struct BaseRepository: Equatable {
        let host: String
        let path: String

        init(host: String, path: String) {
            self.host = host
            self.path = path
        }

        init?(remote: ForgeRemote) {
            guard let repository = ForgeResolver.repository(fromRemoteURL: remote.url),
                  let slash = repository.firstIndex(of: "/")
            else { return nil }
            self.init(host: remote.host, path: String(repository[repository.index(after: slash)...]))
        }

        /// `acme` of `acme/app`.
        var owner: String? {
            path.split(separator: "/").first.map(String.init)
        }
    }

    /// The `git config` arguments that read what `parse` takes.
    static let configArguments = ["config", "--get-regexp", configPattern]

    /// The `git for-each-ref` arguments that read `@{push}` of `branches`.
    /// A pattern also matches the refs below it (`a` matches `a/b`), which
    /// `parse` drops; a branch name cannot hold the characters a pattern
    /// would read as a glob.
    static func pushArguments(branches: [String]) -> [String] {
        ["for-each-ref", "--format=%(refname)%09%(push:remotename)%09%(push)"] + branches.map { "refs/heads/\($0)" }
    }

    /// Reads `git config --get-regexp` output (`key value` lines) and
    /// `git for-each-ref` output in `pushArguments`' format.
    static func parse(config: String, pushes: String, branches wanted: Set<String>) -> PRStatusRepository {
        var repository = PRStatusRepository()
        for line in config.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            repository.apply(key: key, value: value)
        }
        for line in pushes.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, fields[0].hasPrefix("refs/heads/") else { continue }
            let branch = String(fields[0].dropFirst("refs/heads/".count))
            guard wanted.contains(branch), !fields[1].isEmpty, !fields[2].isEmpty else { continue }
            repository.pushes[branch] = Push(remote: fields[1], trackingRef: fields[2])
        }
        return repository
    }

    private mutating func apply(key: String, value: String) {
        switch key {
        case "push.default":
            pushDefault = value
        case "remote.pushdefault":
            remotePushDefault = value
        default:
            if key.hasPrefix("remote."), key.hasSuffix(".url") {
                let name = String(key.dropFirst("remote.".count).dropLast(".url".count))
                if !name.isEmpty {
                    remotes[name] = value
                }
                return
            }
            if key.hasPrefix("remote."), key.hasSuffix(".gh-resolved") {
                let name = String(key.dropFirst("remote.".count).dropLast(".gh-resolved".count))
                if !name.isEmpty {
                    resolvedRemotes[name] = value
                }
                return
            }
            guard key.hasPrefix("branch.") else { return }
            let rest = key.dropFirst("branch.".count)
            for (suffix, path) in [
                (".remote", \BranchSettings.remote),
                (".merge", \BranchSettings.merge),
                (".pushremote", \BranchSettings.pushRemote)
            ]
                where rest.hasSuffix(suffix)
            {
                let branch = String(rest.dropLast(suffix.count))
                guard !branch.isEmpty else { return }
                branches[branch, default: BranchSettings()][keyPath: path] = value
                return
            }
        }
    }

    /// How the request of local branch `branch` is asked for, against a
    /// base repository owned by `baseOwner`.
    func selector(for branch: String, baseOwner: String?) -> PRHeadSelector {
        let settings = branches[branch] ?? BranchSettings()
        if let merge = settings.merge, let number = Self.pullRequestNumber(mergeRef: merge) {
            return .number(number)
        }
        var name = branch
        var headRemote: String?
        if let push = pushes[branch], push.trackingRef.hasPrefix("refs/remotes/\(push.remote)/") {
            name = String(push.trackingRef.dropFirst("refs/remotes/\(push.remote)/".count))
            headRemote = push.remote
        } else {
            headRemote = settings.pushRemote ?? remotePushDefault ?? settings.remote
            if ["upstream", "tracking"].contains(pushDefault), let merge = settings.merge, merge.hasPrefix("refs/heads/") {
                name = String(merge.dropFirst("refs/heads/".count))
            }
        }
        // A remote may be named by its URL rather than by a name.
        let headURL = headRemote.flatMap { remotes[$0] ?? $0 }
        let owner = headURL.flatMap(Self.owner(fromRemoteURL:)) ?? baseOwner
        return .branch(name: name, owner: owner)
    }

    /// `selector(for:baseOwner:)` as `forge` can ask it. GitLab's lookup
    /// tells forks apart by no owner, as `glab mr view` does not, and has no
    /// form of GitHub's request refs, so a branch merging one is asked for
    /// by its own name.
    func selector(for branch: String, baseOwner: String?, forge: ForgeKind) -> PRHeadSelector {
        let selector = selector(for: branch, baseOwner: baseOwner)
        guard forge == .gitLab else { return selector }
        return switch selector {
        case let .branch(name, _): .branch(name: name, owner: nil)
        case .number: .branch(name: branch, owner: nil)
        }
    }

    /// `n` of `refs/pull/<n>/head`.
    static func pullRequestNumber(mergeRef: String) -> Int? {
        let parts = mergeRef.split(separator: "/")
        guard parts.count == 4, parts[0] == "refs", parts[1] == "pull", parts[3] == "head" else { return nil }
        return Int(parts[2])
    }

    /// The owner a remote URL names: `acme` of `github.com/acme/app`.
    static func owner(fromRemoteURL url: String) -> String? {
        ForgeResolver.repository(fromRemoteURL: url)
            .map { $0.split(separator: "/") }
            .flatMap { $0.count >= 3 ? String($0[1]) : nil }
    }
}
