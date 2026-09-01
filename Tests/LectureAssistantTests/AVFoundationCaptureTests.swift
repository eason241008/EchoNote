import XCTest
@testable import LectureAssistant

final class AVFoundationCaptureTests: XCTestCase {
    func testMicrophoneTapLeavesFormatNegotiationToAudioEngine() {
        XCTAssertNil(AVFoundationLectureCaptureService.inputTapFormat)
    }

    func testFailedSelectedRouteFallsBackToCurrentDefaultInputFirst() {
        let devices = [
            AudioInputDevice(id: 119, name: "AirPods Pro", isDefault: false),
            AudioInputDevice(id: 86, name: "Virtual Audio", isDefault: false),
            AudioInputDevice(id: 81, name: "MacBook Microphone", isDefault: true),
        ]

        let fallbackIDs = AVFoundationLectureCaptureService.fallbackDeviceIDs(
            requestedDeviceID: 119,
            devices: devices
        )

        XCTAssertEqual(fallbackIDs, [81, 86])
    }

    func testTransientRouteFailureRetriesBeforeFallingBack() {
        let devices = [
            AudioInputDevice(id: 119, name: "AirPods Pro", isDefault: false),
            AudioInputDevice(id: 81, name: "MacBook Microphone", isDefault: true),
        ]

        XCTAssertEqual(
            AVFoundationLectureCaptureService.startAttemptDeviceIDs(
                requestedDeviceID: 119,
                devices: devices
            ),
            [119, 119, 81, 81]
        )
    }
}
