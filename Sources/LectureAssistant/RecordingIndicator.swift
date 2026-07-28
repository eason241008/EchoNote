import Foundation

public enum RecordingIndicatorState: String, Codable, Equatable, Sendable {
    case hidden
    case recording
    case paused
    case stopping
    case completed
    case interrupted

    public var isMicrophoneOwned: Bool {
        self == .recording || self == .paused || self == .stopping
    }

    public var accessibilityLabel: String {
        switch self {
        case .hidden: return "Not recording"
        case .recording: return "Recording in progress"
        case .paused: return "Recording paused"
        case .stopping: return "Stopping recording"
        case .completed: return "Recording complete"
        case .interrupted: return "Recording interrupted"
        }
    }
}

public struct RecordingIndicatorSnapshot: Codable, Equatable, Sendable {
    public let state: RecordingIndicatorState
    public let sessionID: SessionID?
    public let startedAt: Date?
    public let updatedAt: Date

    public init(
        state: RecordingIndicatorState,
        sessionID: SessionID? = nil,
        startedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.state = state
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

@MainActor
public final class RecordingIndicatorStore: ObservableObject {
    @Published public private(set) var snapshot: RecordingIndicatorSnapshot

    private let defaults: UserDefaults
    private let key = "lecture-assistant.recording-indicator"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode(RecordingIndicatorSnapshot.self, from: data) {
            snapshot = stored.state.isMicrophoneOwned
                ? RecordingIndicatorSnapshot(
                    state: .interrupted,
                    sessionID: stored.sessionID,
                    startedAt: stored.startedAt
                )
                : stored
        } else {
            snapshot = RecordingIndicatorSnapshot(state: .hidden)
        }
        persist()
    }

    public func begin(sessionID: SessionID, at date: Date = Date()) {
        update(RecordingIndicatorSnapshot(state: .recording, sessionID: sessionID, startedAt: date))
    }

    public func pause(at date: Date = Date()) {
        guard snapshot.state == .recording else { return }
        update(RecordingIndicatorSnapshot(
            state: .paused,
            sessionID: snapshot.sessionID,
            startedAt: snapshot.startedAt,
            updatedAt: date
        ))
    }

    public func resume(at date: Date = Date()) {
        guard snapshot.state == .paused else { return }
        update(RecordingIndicatorSnapshot(
            state: .recording,
            sessionID: snapshot.sessionID,
            startedAt: snapshot.startedAt,
            updatedAt: date
        ))
    }

    public func stopping(at date: Date = Date()) {
        guard snapshot.state == .recording || snapshot.state == .paused else { return }
        update(RecordingIndicatorSnapshot(
            state: .stopping,
            sessionID: snapshot.sessionID,
            startedAt: snapshot.startedAt,
            updatedAt: date
        ))
    }

    public func completed(at date: Date = Date()) {
        update(RecordingIndicatorSnapshot(
            state: .completed,
            sessionID: snapshot.sessionID,
            startedAt: snapshot.startedAt,
            updatedAt: date
        ))
    }

    public func hide(at date: Date = Date()) {
        update(RecordingIndicatorSnapshot(state: .hidden, updatedAt: date))
    }

    private func update(_ snapshot: RecordingIndicatorSnapshot) {
        self.snapshot = snapshot
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}
