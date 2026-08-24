import Foundation
import XCTest
@testable import quill

final class CallPresenceDetectorTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    func testMeetStartsOnlyAfterAllSignalsRemainStable() {
        var machine = CallPresenceStateMachine(startDelay: 2, endDelay: 4)
        let strongMeet = snapshot(meet: (true, true, true))

        XCTAssertNil(machine.update(strongMeet, at: origin))
        XCTAssertNil(machine.update(strongMeet, at: origin.addingTimeInterval(1.9)))
        XCTAssertEqual(
            machine.update(strongMeet, at: origin.addingTimeInterval(2)),
            .started(.googleMeet)
        )
        XCTAssertEqual(machine.activePlatform, .googleMeet)
    }

    func testBrowserAudioWithoutMeetWindowNeverStarts() {
        var machine = CallPresenceStateMachine(startDelay: 2, endDelay: 4)
        let ordinaryBrowserAudio = snapshot(meet: (true, true, false))

        XCTAssertNil(machine.update(ordinaryBrowserAudio, at: origin))
        XCTAssertNil(machine.update(
            ordinaryBrowserAudio,
            at: origin.addingTimeInterval(10)
        ))
        XCTAssertNil(machine.activePlatform)
    }

    func testActiveMeetSurvivesBackgroundTabWhileAudioStreamsRemain() {
        var machine = activeMeetMachine()
        let hiddenMeet = snapshot(meet: (true, true, false))

        XCTAssertNil(machine.update(hiddenMeet, at: origin.addingTimeInterval(3)))
        XCTAssertNil(machine.update(hiddenMeet, at: origin.addingTimeInterval(30)))
        XCTAssertEqual(machine.activePlatform, .googleMeet)
    }

    func testMeetEndsQuicklyWithoutUsingSilenceEnergy() {
        var machine = activeMeetMachine()

        XCTAssertNil(machine.update(.empty, at: origin.addingTimeInterval(3)))
        XCTAssertNil(machine.update(.empty, at: origin.addingTimeInterval(6.9)))
        XCTAssertEqual(
            machine.update(.empty, at: origin.addingTimeInterval(7)),
            .ended(.googleMeet)
        )
        XCTAssertNil(machine.activePlatform)
    }

    func testBriefAudioRouteInterruptionDoesNotEndCall() {
        var machine = activeMeetMachine()

        XCTAssertNil(machine.update(.empty, at: origin.addingTimeInterval(3)))
        XCTAssertNil(machine.update(
            snapshot(meet: (true, true, false)),
            at: origin.addingTimeInterval(5)
        ))
        XCTAssertNil(machine.update(.empty, at: origin.addingTimeInterval(8)))
        XCTAssertNil(machine.update(.empty, at: origin.addingTimeInterval(11)))
        XCTAssertEqual(machine.activePlatform, .googleMeet)
    }

    func testZoomUsesTheSameDebouncedLifecycle() {
        var machine = CallPresenceStateMachine(startDelay: 1, endDelay: 2)
        let zoom = snapshot(zoom: (true, true, true))

        XCTAssertNil(machine.update(zoom, at: origin))
        XCTAssertEqual(
            machine.update(zoom, at: origin.addingTimeInterval(1)),
            .started(.zoom)
        )
        XCTAssertNil(machine.update(.empty, at: origin.addingTimeInterval(2)))
        XCTAssertEqual(
            machine.update(.empty, at: origin.addingTimeInterval(4)),
            .ended(.zoom)
        )
    }

    func testLostStartSignalsResetTheCandidateDelay() {
        var machine = CallPresenceStateMachine(startDelay: 2, endDelay: 4)
        let meet = snapshot(meet: (true, true, true))

        XCTAssertNil(machine.update(meet, at: origin))
        XCTAssertNil(machine.update(.empty, at: origin.addingTimeInterval(1)))
        XCTAssertNil(machine.update(meet, at: origin.addingTimeInterval(2)))
        XCTAssertNil(machine.update(meet, at: origin.addingTimeInterval(3.9)))
        XCTAssertEqual(
            machine.update(meet, at: origin.addingTimeInterval(4)),
            .started(.googleMeet)
        )
    }

    func testSwitchingStartCandidateRestartsDelayForNewPlatform() {
        var machine = CallPresenceStateMachine(startDelay: 2, endDelay: 4)
        let meet = snapshot(meet: (true, true, true))
        let zoom = snapshot(zoom: (true, true, true))

        XCTAssertNil(machine.update(meet, at: origin))
        XCTAssertNil(machine.update(zoom, at: origin.addingTimeInterval(1)))
        XCTAssertNil(machine.update(zoom, at: origin.addingTimeInterval(2.9)))
        XCTAssertEqual(
            machine.update(zoom, at: origin.addingTimeInterval(3)),
            .started(.zoom)
        )
    }

    func testEndedCallCanBeFollowedByASeparatelyDebouncedNewPlatform() {
        var machine = activeMeetMachine()
        let zoom = snapshot(zoom: (true, true, true))

        XCTAssertNil(machine.update(zoom, at: origin.addingTimeInterval(3)))
        XCTAssertEqual(
            machine.update(zoom, at: origin.addingTimeInterval(7)),
            .ended(.googleMeet)
        )
        XCTAssertNil(machine.update(zoom, at: origin.addingTimeInterval(7.1)))
        XCTAssertNil(machine.update(zoom, at: origin.addingTimeInterval(9)))
        XCTAssertEqual(
            machine.update(zoom, at: origin.addingTimeInterval(9.2)),
            .started(.zoom)
        )
    }

    func testMeetWindowTitleMatchingIsConservativeAndHandlesZenTitle() {
        XCTAssertTrue(NativeCallObservation.isMeetWindowTitle("Meet\u{00a0}– Dan and Albert"))
        XCTAssertTrue(NativeCallObservation.isMeetWindowTitle("Google Meet"))
        XCTAssertTrue(NativeCallObservation.isMeetWindowTitle("abc-defg-hij – Google Meet"))
        XCTAssertFalse(NativeCallObservation.isMeetWindowTitle("Meeting notes"))
        XCTAssertFalse(NativeCallObservation.isMeetWindowTitle("How to meet deadlines"))
    }

    private func activeMeetMachine() -> CallPresenceStateMachine {
        var machine = CallPresenceStateMachine(startDelay: 2, endDelay: 4)
        let strongMeet = snapshot(meet: (true, true, true))
        XCTAssertNil(machine.update(strongMeet, at: origin))
        XCTAssertEqual(
            machine.update(strongMeet, at: origin.addingTimeInterval(2)),
            .started(.googleMeet)
        )
        return machine
    }

    private func snapshot(
        meet: (Bool, Bool, Bool) = (false, false, false),
        zoom: (Bool, Bool, Bool) = (false, false, false)
    ) -> CallPresenceSnapshot {
        CallPresenceSnapshot(
            googleMeet: .init(
                inputActive: meet.0,
                outputActive: meet.1,
                windowVisible: meet.2
            ),
            zoom: .init(
                inputActive: zoom.0,
                outputActive: zoom.1,
                windowVisible: zoom.2
            )
        )
    }
}
