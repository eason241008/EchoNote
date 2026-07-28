import Foundation

public struct CourseID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct SessionID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct TranscriptRevisionID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct LectureTimestamp: Codable, Hashable, Sendable {
    public let date: Date

    public init(_ date: Date = Date()) {
        self.date = date
    }
}

public struct Course: Codable, Hashable, Sendable {
    public let id: CourseID
    public var code: String
    public var title: String

    public init(id: CourseID = CourseID(), code: String, title: String) {
        self.id = id
        self.code = code
        self.title = title
    }
}

public enum SessionState: String, Codable, Sendable {
    case prepared
    case recording
    case paused
    case interrupted
    case completed
}

public struct LectureSession: Codable, Hashable, Sendable {
    public let id: SessionID
    public var courseID: CourseID?
    public var title: String
    public var state: SessionState
    public var createdAt: LectureTimestamp
    public var updatedAt: LectureTimestamp

    public init(
        id: SessionID = SessionID(),
        courseID: CourseID? = nil,
        title: String,
        state: SessionState = .prepared,
        createdAt: LectureTimestamp = LectureTimestamp(),
        updatedAt: LectureTimestamp = LectureTimestamp()
    ) {
        self.id = id
        self.courseID = courseID
        self.title = title
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TranscriptRevision: Codable, Hashable, Sendable {
    public let id: TranscriptRevisionID
    public let sessionID: SessionID
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    public let createdAt: LectureTimestamp
    public let supersedes: TranscriptRevisionID?

    public init(
        id: TranscriptRevisionID = TranscriptRevisionID(),
        sessionID: SessionID,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        createdAt: LectureTimestamp = LectureTimestamp(),
        supersedes: TranscriptRevisionID? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.start = start
        self.end = end
        self.text = text
        self.createdAt = createdAt
        self.supersedes = supersedes
    }
}
