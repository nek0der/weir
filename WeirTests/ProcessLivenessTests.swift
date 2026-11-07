// ProcessLivenessTests.swift
// Weir — a killed process not yet reaped counts as gone, alone and as its group's last member.

import Darwin
import Foundation
import Testing
@testable import Weir

struct ProcessLivenessTests {
    /// `kill(pid, 0)` still answers for the zombie; the process table says
    /// it has exited.
    @Test func aKilledProcess_notYetReaped_isNotLive_norIsItsGroup() throws {
        // Reaped only at the end: the test looks at the zombie.
        let pid = try spawnProcessGroup(["/bin/sleep", "30"])
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        try #require(ProcessLiveness.isLive(pid))
        try #require(ProcessLiveness.hasLiveMembers(group: pid))
        try #require(kill(pid, SIGKILL) == 0)

        // Observe exit independently, leaving the child waitable for the assertions.
        var exit = siginfo_t()
        let result = waitid(P_PID, id_t(pid), &exit, WEXITED | WNOWAIT)
        try #require(result == 0)
        try #require(exit.si_pid == pid && exit.si_code == CLD_KILLED && exit.si_status == SIGKILL)

        #expect(kill(pid, 0) == 0, "not reaped: the zombie is still in the table")
        #expect(!ProcessLiveness.isLive(pid))
        #expect(!ProcessLiveness.hasLiveMembers(group: pid))
    }

    @Test(arguments: [Int32(0), -1])
    func nonpositiveIdentifier_isNotLive(_ pid: Int32) {
        #expect(!ProcessLiveness.isLive(pid))
        #expect(!ProcessLiveness.hasLiveMembers(group: pid))
    }
}
