import XCTest
@testable import LectureAssistant

final class AVFoundationCaptureTests: XCTestCase {
    func testMicrophoneTapLeavesFormatNegotiationToAudioEngine() {
        XCTAssertNil(AVFoundationLectureCaptureService.inputTapFormat)
    }
}
