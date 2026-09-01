import Foundation
import SwiftUI

@MainActor
public final class ApplicationModel: ObservableObject {
    @Published public private(set) var activeSession: LectureSession?
    @Published public private(set) var restoredSession: LectureSession?
    @Published public private(set) var capturePreflight: CapturePreflightResult?
    @Published public private(set) var recordingIndicator: RecordingIndicatorSnapshot
    @Published public private(set) var automaticStopAt: Date?
    @Published public private(set) var automaticStopFailureMessage: String?

    private let services: ApplicationServices
    private let defaults: UserDefaults
    private let policyStore: RecordingPolicyStore
    private let startGate: RecordingStartGate
    private let sessionKey = "lecture-assistant.active-session"
    private let indicatorStore: RecordingIndicatorStore
    private let preflightService: CapturePreflightService?
    private let storageRootURL: URL?
    private let timetable: TimetableStore
    private let transcriptionModelReady: @MainActor @Sendable () -> Bool
    private let automaticStopGracePeriod: TimeInterval
    private var automaticStopTask: Task<Void, Never>?

    public init(
        services: ApplicationServices = .unavailable,
        defaults: UserDefaults = .standard,
        policyStore: RecordingPolicyStore? = nil,
        startGate: RecordingStartGate = RecordingStartGate(),
        indicatorStore: RecordingIndicatorStore? = nil,
        preflightService: CapturePreflightService? = nil,
        storageRootURL: URL? = nil,
        timetable: TimetableStore? = nil,
        automaticStopGracePeriod: TimeInterval = 5 * 60,
        transcriptionModelReady: @escaping @MainActor @Sendable () -> Bool = { false }
    ) {
        self.services = services
        self.defaults = defaults
        self.policyStore = policyStore ?? RecordingPolicyStore(defaults: defaults)
        self.startGate = startGate
        self.indicatorStore = indicatorStore ?? RecordingIndicatorStore(defaults: defaults)
        self.preflightService = preflightService
        self.storageRootURL = storageRootURL
        self.timetable = timetable ?? TimetableStore(defaults: defaults)
        self.automaticStopGracePeriod = automaticStopGracePeriod
        self.transcriptionModelReady = transcriptionModelReady
        recordingIndicator = self.indicatorStore.snapshot
        restoreSession()
    }

    public func prepareSession(
        title: String,
        courseID: CourseID? = nil,
        scheduledEventID: String? = nil,
        scheduledEndAt: Date? = nil
    ) {
        cancelAutomaticStop()
        let session = LectureSession(
            courseID: courseID,
            title: title,
            scheduledEventID: scheduledEventID,
            scheduledEndAt: scheduledEndAt.map(LectureTimestamp.init)
        )
        activeSession = session
        persist(session)
    }

    public func prepareSession(for context: TimetableRecordingContext) {
        prepareSession(
            title: context.title,
            scheduledEventID: timetable.recordingEventIdentifier(for: context.event),
            scheduledEndAt: context.event.endsAt
        )
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
        scheduleAutomaticStop(for: session)
    }

    public func pauseRecording() async throws {
        guard var session = activeSession, session.state == .recording else { return }
        try await services.capture.pause()
        session.state = .paused
        session.updatedAt = LectureTimestamp()
        activeSession = session
        indicatorStore.pause()
        recordingIndicator = indicatorStore.snapshot
        persist(session)
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
        cancelAutomaticStop()
        try await performStopRecording()
    }

    private func performStopRecording() async throws {
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

    private func scheduleAutomaticStop(for session: LectureSession) {
        cancelAutomaticStop()
        guard let scheduledEndAt = session.scheduledEndAt?.date else { return }
        let nextContext = session.scheduledEventID.flatMap {
            timetable.followingRecordingContext(
                after: $0,
                maximumGap: automaticStopGracePeriod
            )
        }
        let deadline = session.scheduledEventID.flatMap {
            timetable.automaticStopDeadline(
                after: $0,
                maximumGap: automaticStopGracePeriod
            )
        } ?? scheduledEndAt.addingTimeInterval(automaticStopGracePeriod)
        let actionDate = nextContext?.event.startsAt ?? deadline
        automaticStopAt = deadline
        automaticStopFailureMessage = nil
        let delay = max(0, actionDate.timeIntervalSinceNow)
        let expectedSessionID = session.id
        automaticStopTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.automaticStopTask = nil
            do {
                guard let activeSession = self.activeSession,
                      activeSession.id == expectedSessionID,
                      activeSession.state == .recording || activeSession.state == .paused
                else { return }
                if let nextContext {
                    try await self.performAutomaticRollover(
                        from: activeSession,
                        to: nextContext
                    )
                } else {
                    try await self.performStopRecording()
                    self.automaticStopAt = nil
                }
            } catch {
                self.automaticStopFailureMessage = "课后自动结束失败：\(error.localizedDescription)"
            }
        }
    }

    private func cancelAutomaticStop() {
        automaticStopTask?.cancel()
        automaticStopTask = nil
        automaticStopAt = nil
    }

    private func performAutomaticRollover(
        from currentSession: LectureSession,
        to nextContext: TimetableRecordingContext
    ) async throws {
        let nextState = currentSession.state
        var nextSession = LectureSession(
            courseID: nil,
            title: nextContext.title,
            scheduledEventID: timetable.recordingEventIdentifier(for: nextContext.event),
            scheduledEndAt: LectureTimestamp(nextContext.event.endsAt),
            state: nextState
        )
        nextSession.updatedAt = LectureTimestamp()
        try await services.capture.rollover(to: nextSession)
        activeSession = nextSession
        persist(nextSession)
        updateIndicatorForRollover(sessionID: nextSession.id, state: nextState)
        scheduleAutomaticStop(for: nextSession)
    }

    private func updateIndicatorForRollover(
        sessionID: SessionID,
        state: SessionState
    ) {
        indicatorStore.begin(sessionID: sessionID)
        if state == .paused {
            indicatorStore.pause()
        }
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
                scheduledEventID: session.scheduledEventID,
                scheduledEndAt: session.scheduledEndAt,
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
