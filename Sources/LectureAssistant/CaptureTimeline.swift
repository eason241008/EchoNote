import Foundation

public enum CaptureTimelineEvent: String, Sendable {
    case paused
    case resumed
    case deviceLost = "device_lost"
    case permissionRevoked = "permission_revoked"
    case systemSleep = "system_sleep"
    case audioEngineFailure = "audio_engine_failure"
    case storageFailure = "storage_failure"
    case stopped
}

@MainActor
public final class CaptureTimelineRecorder {
    private let timeline: SQLiteTimelineRepository
    private let sessionID: SessionID

    public init(database: LectureDatabase, sessionID: SessionID) {
        timeline = SQLiteTimelineRepository(database: database)
        self.sessionID = sessionID
    }

    @discardableResult
    public func record(
        _ event: CaptureTimelineEvent,
        details: [String: String] = [:],
        at date: Date = Date()
    ) throws -> TimelineEvent {
        let data = try JSONSerialization.data(withJSONObject: details, options: [.sortedKeys])
        let detailsJSON = String(decoding: data, as: UTF8.self)
        return try timeline.append(
            sessionID: sessionID,
            kind: event.rawValue,
            occurredAt: date,
            detailsJSON: detailsJSON
        )
    }
}
