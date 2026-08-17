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
    func testTranslationPlaceholderReflectsProviderAvailability() {
        let model = CaptionWorkspaceModel()
        XCTAssertEqual(model.translationPlaceholder, "未配置中文翻译")
        model.setTranslationAvailable(true)
        XCTAssertEqual(model.translationPlaceholder, "等待翻译…")
    }

    func testDisplaySettingsPersistAcrossWorkspaceModels() {
        let suiteName = "caption-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = CaptionWorkspaceModel(defaults: defaults)
        first.settings.textSize = 36
        first.settings.opacity = 0.7
        first.settings.presentationMode = .dynamicIsland
        first.updateOverlayPosition(x: 210, y: 120)
        first.quickHide()

        let restored = CaptionWorkspaceModel(defaults: defaults)

        XCTAssertEqual(restored.settings.textSize, 36)
        XCTAssertEqual(restored.settings.opacity, 0.7)
        XCTAssertEqual(restored.settings.presentationMode, .dynamicIsland)
        XCTAssertEqual(restored.settings.positionX, 210)
        XCTAssertEqual(restored.settings.positionY, 120)
        XCTAssertTrue(restored.settings.isHidden)
    }

    func testRecentSegmentsKeepsThreeRecordsInsteadOfOnlyLatest() {
        let model = CaptionWorkspaceModel()
        let sessionID = SessionID()
        for index in 0..<5 {
            model.append(LiveTranscriptSegment(
                id: "segment-\(index)",
                sessionID: sessionID,
                start: Double(index),
                end: Double(index + 1),
                text: "line \(index)",
                isFinal: true
            ))
        }

        XCTAssertEqual(model.recentSegments().map(\.text), ["line 2", "line 3", "line 4"])
    }

    func testLegacyDisplaySettingsDecodeWithoutPresentationMode() throws {
        let data = Data(
            #"{"languageVisibility":"englishOnly","textSize":38,"opacity":0.8,"positionX":21,"positionY":22,"isHidden":false}"#.utf8
        )

        let settings = try JSONDecoder().decode(CaptionDisplaySettings.self, from: data)

        XCTAssertEqual(settings.presentationMode, .floatingWindow)
        XCTAssertEqual(settings.languageVisibility, .englishOnly)
        XCTAssertEqual(settings.textSize, 38)
        XCTAssertEqual(settings.positionX, 21)
    }
}
