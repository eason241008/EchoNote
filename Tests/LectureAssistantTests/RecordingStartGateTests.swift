import Foundation
import XCTest
@testable import LectureAssistant

private actor RecordingGateCaptureSpy: LectureCaptureService {
    private var preparedSessionIDs: [SessionID] = []
    private var startCount = 0

    func prepare(_ preparation: LectureCapturePreparation) async throws {
        preparedSessionIDs.append(preparation.session.id)
    }

    func start() async throws {
        startCount += 1
    }

    func pause() async throws {}
    func resume() async throws {}
    func stop() async throws {}

    func invocations() -> (preparedSessionIDs: [SessionID], startCount: Int) {
        (preparedSessionIDs, startCount)
    }
}

private struct RecordingGateAuthorizationProvider: MicrophoneAuthorizationProviding {
    func status() -> MicrophoneAuthorization { .authorized }
    func requestAccess() async -> Bool { true }
}

private struct RecordingGateDeviceProvider: AudioInputDeviceProviding {
    func inputDevices() throws -> [AudioInputDevice] {
        [AudioInputDevice(id: 1, name: "Test Input", isDefault: true)]
    }
}

private final class RecordingGateModelReadiness: @unchecked Sendable {
    var isReady = false
}

final class RecordingStartGateTests: XCTestCase {
    @MainActor
    func testPolicyAcknowledgementIsRequiredBeforeCaptureCalls() async throws {
        let fixture = makeFixture()
        fixture.model.prepareSession(title: "Policy lecture")
        fixture.model.updateCapturePreflight(readyPreflight())

        do {
            try await fixture.model.startRecording()
            XCTFail("Expected policy acknowledgement requirement")
        } catch {
            XCTAssertEqual(error as? RecordingStartGateError, .policyAcknowledgementRequired)
        }
        let invocations = await fixture.capture.invocations()
        XCTAssertEqual(invocations.preparedSessionIDs, [])
        XCTAssertEqual(invocations.startCount, 0)
        XCTAssertEqual(fixture.model.activeSession?.state, .prepared)
    }

    @MainActor
    func testFailedPreflightCannotStartCaptureAfterPolicyAcceptance() async throws {
        let fixture = makeFixture()
        fixture.model.prepareSession(title: "Preflight lecture")
        try fixture.model.acknowledgeRecordingPolicy()
        fixture.model.updateCapturePreflight(
            CapturePreflightResult(
                authorization: .denied,
                devices: [],
                selectedDevice: nil,
                issues: [.microphonePermissionDenied, .selectedDeviceUnavailable]
            )
        )

        do {
            try await fixture.model.startRecording()
            XCTFail("Expected failed preflight")
        } catch {
            XCTAssertEqual(
                error as? RecordingStartGateError,
                .preflightNotReady([.microphonePermissionDenied, .selectedDeviceUnavailable])
            )
        }
        let invocations = await fixture.capture.invocations()
        XCTAssertEqual(invocations.preparedSessionIDs, [])
        XCTAssertEqual(invocations.startCount, 0)
        XCTAssertEqual(fixture.model.activeSession?.state, .prepared)
    }

    @MainActor
    func testExplicitStartTransitionsPreparedSessionOnlyAfterAllGatesPass() async throws {
        let fixture = makeFixture()
        fixture.model.prepareSession(title: "Ready lecture")
        let sessionID = try XCTUnwrap(fixture.model.activeSession?.id)
        try fixture.model.acknowledgeRecordingPolicy()
        fixture.model.updateCapturePreflight(readyPreflight())

        XCTAssertTrue(fixture.model.canStartRecording)
        try await fixture.model.startRecording()

        let invocations = await fixture.capture.invocations()
        XCTAssertEqual(invocations.preparedSessionIDs, [sessionID])
        XCTAssertEqual(invocations.startCount, 1)
        XCTAssertEqual(fixture.model.activeSession?.state, .recording)
        XCTAssertFalse(fixture.model.canStartRecording)
    }

    @MainActor
    func testStartRefreshesStalePreflightAfterModelBecomesReady() async throws {
        let defaultsName = UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        let capture = RecordingGateCaptureSpy()
        let readiness = RecordingGateModelReadiness()
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let model = ApplicationModel(
            services: ApplicationServices(
                scheduling: EmptyCourseSchedulingService(),
                capture: capture,
                transcription: EmptyTranscriptionService(),
                translation: EmptyTranslationService(),
                studyNotes: EmptyStudyNotesService(),
                library: EmptyLectureLibraryService(),
                export: EmptyLectureExportService()
            ),
            defaults: defaults,
            preflightService: CapturePreflightService(
                authorizationProvider: RecordingGateAuthorizationProvider(),
                deviceProvider: RecordingGateDeviceProvider()
            ),
            storageRootURL: storageRoot,
            transcriptionModelReady: { readiness.isReady }
        )
        model.prepareSession(title: "Fresh model lecture")
        try model.acknowledgeRecordingPolicy()
        await model.refreshCapturePreflight()
        XCTAssertEqual(model.capturePreflight?.issues, [.transcriptionModelUnavailable])

        readiness.isReady = true
        try await model.startRecording()

        XCTAssertEqual(model.activeSession?.state, .recording)
        let invocations = await capture.invocations()
        XCTAssertEqual(invocations.startCount, 1)
    }

    @MainActor
    func testAcknowledgementPersistsAcrossApplicationModels() throws {
        let defaultsName = #function
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        let first = ApplicationModel(defaults: defaults)
        try first.acknowledgeRecordingPolicy()

        let restored = ApplicationModel(defaults: defaults)

        XCTAssertTrue(restored.isRecordingPolicyAcknowledged)
    }

    @MainActor
    private func makeFixture() -> (
        model: ApplicationModel,
        capture: RecordingGateCaptureSpy
    ) {
        let defaultsName = UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        let capture = RecordingGateCaptureSpy()
        let services = ApplicationServices(
            scheduling: EmptyCourseSchedulingService(),
            capture: capture,
            transcription: EmptyTranscriptionService(),
            translation: EmptyTranslationService(),
            studyNotes: EmptyStudyNotesService(),
            library: EmptyLectureLibraryService(),
            export: EmptyLectureExportService()
        )
        return (ApplicationModel(services: services, defaults: defaults), capture)
    }

    private func readyPreflight() -> CapturePreflightResult {
        let device = AudioInputDevice(id: 1, name: "Test Input", isDefault: true)
        return CapturePreflightResult(
            authorization: .authorized,
            devices: [device],
            selectedDevice: device,
            issues: []
        )
    }
}
