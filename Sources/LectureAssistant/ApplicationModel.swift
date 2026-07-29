import Foundation
import SwiftUI

@MainActor
public final class ApplicationModel: ObservableObject {
    @Published public private(set) var activeSession: LectureSession?
    @Published public private(set) var restoredSession: LectureSession?
    @Published public private(set) var capturePreflight: CapturePreflightResult?
    @Published public private(set) var recordingIndicator: RecordingIndicatorSnapshot

    private let services: ApplicationServices
    private let defaults: UserDefaults
    private let policyStore: RecordingPolicyStore
    private let startGate: RecordingStartGate
    private let sessionKey = "lecture-assistant.active-session"
    private let indicatorStore: RecordingIndicatorStore
    private let preflightService: CapturePreflightService?
    private let storageRootURL: URL?
    private let transcriptionModelReady: @MainActor @Sendable () -> Bool

    public init(
        services: ApplicationServices = .unavailable,
        defaults: UserDefaults = .standard,
        policyStore: RecordingPolicyStore? = nil,
        startGate: RecordingStartGate = RecordingStartGate(),
        indicatorStore: RecordingIndicatorStore? = nil,
        preflightService: CapturePreflightService? = nil,
        storageRootURL: URL? = nil,
        transcriptionModelReady: @escaping @MainActor @Sendable () -> Bool = { false }
    ) {
        self.services = services
        self.defaults = defaults
        self.policyStore = policyStore ?? RecordingPolicyStore(defaults: defaults)
        self.startGate = startGate
        self.indicatorStore = indicatorStore ?? RecordingIndicatorStore(defaults: defaults)
        self.preflightService = preflightService
        self.storageRootURL = storageRootURL
        self.transcriptionModelReady = transcriptionModelReady
        recordingIndicator = self.indicatorStore.snapshot
        restoreSession()
    }

    public func prepareSession(title: String, courseID: CourseID? = nil) {
        let session = LectureSession(courseID: courseID, title: title)
        activeSession = session
        persist(session)
    }

    public func refreshCapturePreflight(requestPermission: Bool = false) async {
        guard let preflightService, let storageRootURL else { return }
        if requestPermission {
            _ = await SystemMicrophoneAuthorizationProvider().requestAccess()
        }
        do {
            capturePreflight = try preflightService.evaluate(
                selectedDeviceID: capturePreflight?.selectedDevice?.id,
                storageRootURL: storageRootURL,
                transcriptionModelReady: transcriptionModelReady()
            )
        } catch {
            capturePreflight = CapturePreflightResult(
                authorization: SystemMicrophoneAuthorizationProvider().status(),
                devices: [],
                selectedDevice: nil,
                issues: [.selectedDeviceUnavailable]
            )
        }
    }

    public var isRecordingPolicyAcknowledged: Bool {
        policyStore.isCurrentPolicyAcknowledged()
    }

    public var canStartRecording: Bool {
        activeSession?.state == .prepared
            && isRecordingPolicyAcknowledged
            && capturePreflight?.isReady == true
    }

    public func acknowledgeRecordingPolicy() throws {
        try policyStore.acknowledgeCurrentPolicy()
        objectWillChange.send()
    }

    public func updateCapturePreflight(_ result: CapturePreflightResult) {
        capturePreflight = result
    }

    public func startRecording() async throws {
        guard var session = activeSession, session.state == .prepared else { return }
        if preflightService != nil {
            await refreshCapturePreflight()
        }
        guard let capturePreflight else {
            throw RecordingStartGateError.preflightNotReady([])
        }
        try startGate.validate(
            policyAcknowledged: policyStore.isCurrentPolicyAcknowledged(),
            preflight: capturePreflight
        )
        guard let selectedDevice = capturePreflight.selectedDevice else {
            throw RecordingStartGateError.preflightNotReady([.selectedDeviceUnavailable])
        }
        try await services.capture.prepare(
            LectureCapturePreparation(session: session, deviceID: selectedDevice.id)
        )
        try await services.capture.start()
        indicatorStore.begin(sessionID: session.id)
        recordingIndicator = indicatorStore.snapshot
        session.state = .recording
        session.updatedAt = LectureTimestamp()
        activeSession = session
        persist(session)
    }

    public func pauseRecording() async throws {
        guard var session = activeSession, session.state == .recording else { return }
        try await services.capture.pause()
        session.state = .paused
        session.updatedAt = LectureTimestamp()
        activeSession = session
        indicatorStore.pause()
        recordingIndicator = indicatorStore.snapshot
    }

    public func resumeRecording() async throws {
        guard var session = activeSession, session.state == .paused else { return }
        try await services.capture.resume()
        session.state = .recording
        session.updatedAt = LectureTimestamp()
        activeSession = session
        persist(session)
        indicatorStore.resume()
        recordingIndicator = indicatorStore.snapshot
    }

    public func stopRecording() async throws {
        guard var session = activeSession,
              session.state == .recording || session.state == .paused else { return }
        indicatorStore.stopping()
        recordingIndicator = indicatorStore.snapshot
        try await services.capture.stop()
        session.state = .completed
        session.updatedAt = LectureTimestamp()
        activeSession = session
        persist(session)
        indicatorStore.completed()
        recordingIndicator = indicatorStore.snapshot
    }
    private func restoreSession() {
        guard let data = defaults.data(forKey: sessionKey),
              let session = try? JSONDecoder().decode(LectureSession.self, from: data) else { return }
        restoredSession = session.state == .recording || session.state == .paused
            ? LectureSession(
                id: session.id,
                courseID: session.courseID,
                title: session.title,
                state: .interrupted,
                createdAt: session.createdAt,
                updatedAt: LectureTimestamp()
            )
            : session
        activeSession = restoredSession
        if activeSession?.state == .interrupted && recordingIndicator.state.isMicrophoneOwned {
            indicatorStore.hide()
            recordingIndicator = indicatorStore.snapshot
        }
        activeSession = restoredSession
    }

    private func persist(_ session: LectureSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: sessionKey)
    }
}
