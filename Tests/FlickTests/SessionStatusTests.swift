import XCTest
@testable import InboxCore

final class SessionStatusTests: XCTestCase {
    private func request(_ type: RequestType,
                         title: String = "Bash",
                         session: String = "s1") -> InboxRequest {
        InboxRequest(agent: .claude,
                     sessionID: session,
                     project: "flick",
                     cwd: "/tmp",
                     type: type,
                     title: title,
                     message: "echo hi")
    }

    // MARK: - Transitions

    func testApprovalTheUserMustAnswerIsWaiting() {
        let status = SessionStatus.transition(for: request(.approval), awaitingUser: true)
        XCTAssertEqual(status?.activity, .waiting)
        XCTAssertEqual(status?.label, "Waiting for approval")
    }

    /// The regression this guards: a session-wide allow (or a terminal-only
    /// setting) answers an approval without the user ever seeing it. Reporting
    /// that as "Waiting" would show a session as blocked while it runs happily.
    func testApprovalAnsweredWithoutTheUserKeepsWorking() {
        let status = SessionStatus.transition(for: request(.approval), awaitingUser: false)
        XCTAssertEqual(status?.activity, .working)
    }

    func testQuestionKeepsTheAdaptersOwnHeadline() {
        let status = SessionStatus.transition(for: request(.question, title: "Waiting for permission"),
                                              awaitingUser: true)
        XCTAssertEqual(status?.activity, .waiting)
        XCTAssertEqual(status?.label, "Waiting for permission")
    }

    func testQuestionWithNoHeadlineFallsBackToAGenericWait() {
        let status = SessionStatus.transition(for: request(.question, title: "   "),
                                              awaitingUser: true)
        XCTAssertEqual(status?.label, "Waiting for you")
    }

    func testFinishedAndSessionEndAreBothFinished() {
        XCTAssertEqual(SessionStatus.transition(for: request(.finished), awaitingUser: false)?.activity,
                       .finished)
        XCTAssertEqual(SessionStatus.transition(for: request(.sessionEnd), awaitingUser: false)?.activity,
                       .finished)
    }

    func testSessionStartIsWorking() {
        XCTAssertEqual(SessionStatus.transition(for: request(.sessionStart), awaitingUser: false)?.activity,
                       .working)
    }

    func testErrorIsItsOwnState() {
        let status = SessionStatus.transition(for: request(.error), awaitingUser: false)
        XCTAssertEqual(status?.activity, .error)
        XCTAssertEqual(status?.label, "Error")
    }

    func testAnythingStoppedForTheUserSaysSo() {
        XCTAssertTrue(SessionActivity.waiting.needsUser)
        XCTAssertTrue(SessionActivity.error.needsUser)
        XCTAssertFalse(SessionActivity.working.needsUser)
        XCTAssertFalse(SessionActivity.finished.needsUser)
    }

    /// The dashboard sorts on this, so the states that want the user have to
    /// come out ahead of the ones that do not.
    func testSortPriorityPutsStoppedSessionsFirst() {
        let order: [SessionActivity] = [.waiting, .error, .working, .finished]
        XCTAssertEqual(order.sorted { $0.sortPriority < $1.sortPriority }, order)
        for stopped in [SessionActivity.waiting, .error] {
            for running in [SessionActivity.working, .finished] {
                XCTAssertLessThan(stopped.sortPriority, running.sortPriority,
                                  "\(stopped) must sort above \(running)")
            }
        }
    }

    // MARK: - The clock

    /// The regression this guards: repeat events of the same kind must not
    /// restart `since`. A duration that resets to zero every few seconds is
    /// worse than showing no duration at all.
    func testAnIdenticalStatusDoesNotRestartTheClock() {
        let first = SessionStatus(.waiting, detail: "Waiting for approval")
        let second = SessionStatus(.waiting, detail: "Waiting for approval")
        XCTAssertTrue(first.supersedes(second))
    }

    func testARealChangeDoesRestartTheClock() {
        let waiting = SessionStatus(.waiting, detail: "Waiting for approval")
        XCTAssertFalse(waiting.supersedes(SessionStatus(.working)))
        XCTAssertFalse(waiting.supersedes(SessionStatus(.waiting, detail: "Waiting for you")))
    }

    func testDurationCountsFromTheTransition() {
        let now = Date()
        let status = SessionStatus(.working, since: now.addingTimeInterval(-90))
        XCTAssertEqual(status.duration(asOf: now), 90, accuracy: 0.001)
    }

    /// A clock skew backwards must read as 0s, never as a negative duration.
    func testDurationNeverGoesNegative() {
        let now = Date()
        let status = SessionStatus(.working, since: now.addingTimeInterval(30))
        XCTAssertEqual(status.duration(asOf: now), 0, accuracy: 0.001)
    }

    // MARK: - Labels

    func testDurationLabels() {
        XCTAssertEqual(DurationLabel.compact(0), "0s")
        XCTAssertEqual(DurationLabel.compact(38), "38s")
        XCTAssertEqual(DurationLabel.compact(59), "59s")
        XCTAssertEqual(DurationLabel.compact(60), "1m 0s")
        XCTAssertEqual(DurationLabel.compact(252), "4m 12s")
        XCTAssertEqual(DurationLabel.compact(3599), "59m 59s")
        // Seconds are dropped past the hour so the label stops changing width.
        XCTAssertEqual(DurationLabel.compact(3600), "1h 0m")
        XCTAssertEqual(DurationLabel.compact(3840), "1h 4m")
        XCTAssertEqual(DurationLabel.compact(-5), "0s")
    }

    func testStatusFallsBackToTheActivityLabel() {
        XCTAssertEqual(SessionStatus(.working).label, "Working")
        XCTAssertEqual(SessionStatus(.finished).label, "Finished")
        XCTAssertEqual(SessionStatus(.waiting).label, "Waiting")
        XCTAssertEqual(SessionStatus(.error).label, "Error")
    }
}
