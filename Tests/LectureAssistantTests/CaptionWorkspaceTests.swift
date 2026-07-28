import Foundation
import XCTest
@testable import LectureAssistant

@MainActor
final class CaptionWorkspaceTests: XCTestCase {
    func testIndependentStatesAndPartialFinalReplacement() {
        let model = CaptionWorkspaceModel()
        let sessionID = SessionID()
        let partial = LiveTranscriptSegment(
            id: "segment-0",
            sessionID: sessionID,
            start: 1,
            end: 2,
            text: "partial",
            isFinal: false
        )
        let final = LiveTranscriptSegment(
            id: "segment-0",
            sessionID: sessionID,
            start: 1,
            end: 2,
            text: "final",
            isFinal: true
        )

        model.updateCaptureState("Recording")
        model.updateTranscriptionState("Ready")
        model.updateTranslationState("Translating")
        model.append(partial)
        model.append(final)

        XCTAssertEqual(model.captureState, "Recording")
        XCTAssertEqual(model.transcriptionState, "Ready")
        XCTAssertEqual(model.translationState, "Translating")
        XCTAssertEqual(model.segments.count, 1)
        XCTAssertEqual(model.segments[0].text, "final")
    }

    func testQuickHideDoesNotAlterPersistedTimelineModel() {
        let model = CaptionWorkspaceModel()
        let sessionID = SessionID()
        model.append(LiveTranscriptSegment(
            id: "gap-0",
            sessionID: sessionID,
            start: 4,
            end: 6,
            text: "Audio unavailable",
            isFinal: true,
            isGap: true
        ))

        model.quickHide()

        XCTAssertTrue(model.settings.isHidden)
        XCTAssertEqual(model.segments[0].start, 4)
        XCTAssertEqual(model.segments[0].end, 6)
        XCTAssertTrue(model.segments[0].isGap)
        model.showOverlay()
        XCTAssertFalse(model.settings.isHidden)
    }

    func testTranscriptEditChangesOnlySelectedSegment() {
        let model = CaptionWorkspaceModel()
        let sessionID = SessionID()
        model.append(LiveTranscriptSegment(
            id: "segment-0", sessionID: sessionID, start: 0, end: 1, text: "old", isFinal: true
        ))
        model.append(LiveTranscriptSegment(
            id: "segment-1", sessionID: sessionID, start: 1, end: 2, text: "keep", isFinal: true
        ))

        model.replaceText(segmentID: "segment-0", text: "corrected")

        XCTAssertEqual(model.segments.map(\.text), ["corrected", "keep"])
        XCTAssertTrue(model.segments[0].isFinal)
    }
    func testDisplaySettingsPersistAcrossWorkspaceModels() {
        let suiteName = "caption-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = CaptionWorkspaceModel(defaults: defaults)
        first.settings.textSize = 36
        first.settings.opacity = 0.7
        first.updateOverlayPosition(x: 210, y: 120)
        first.quickHide()

        let restored = CaptionWorkspaceModel(defaults: defaults)

        XCTAssertEqual(restored.settings.textSize, 36)
        XCTAssertEqual(restored.settings.opacity, 0.7)
        XCTAssertEqual(restored.settings.positionX, 210)
        XCTAssertEqual(restored.settings.positionY, 120)
        XCTAssertTrue(restored.settings.isHidden)
    }
}
