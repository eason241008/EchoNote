import Foundation
import SQLite3

public enum BookmarkKind: String, Codable, Sendable { case important, question }

public struct LectureBookmark: Codable, Equatable, Sendable {
    public let id: UUID
    public let sessionID: SessionID
    public let kind: BookmarkKind
    public let sessionTime: TimeInterval
    public let text: String?
    public init(id: UUID = UUID(), sessionID: SessionID, kind: BookmarkKind, sessionTime: TimeInterval, text: String? = nil) {
        self.id = id; self.sessionID = sessionID; self.kind = kind; self.sessionTime = sessionTime; self.text = text
    }
}

@MainActor
public struct SQLiteBookmarkRepository {
    private let database: LectureDatabase
    public init(database: LectureDatabase) { self.database = database }
    @discardableResult public func save(_ bookmark: LectureBookmark) throws -> LectureBookmark {
        try database.execute("INSERT INTO bookmarks (id, session_id, kind, session_time, text, created_at) VALUES (?, ?, ?, ?, ?, ?)", bindings: [.text(bookmark.id.uuidString), .text(bookmark.sessionID.rawValue.uuidString), .text(bookmark.kind.rawValue), .real(bookmark.sessionTime), bookmark.text.map(SQLiteValue.text) ?? .null, .real(Date().timeIntervalSince1970)])
        return bookmark
    }
    public func all(sessionID: SessionID) throws -> [LectureBookmark] {
        try database.query("SELECT id, kind, session_time, text FROM bookmarks WHERE session_id = ? ORDER BY session_time", bindings: [.text(sessionID.rawValue.uuidString)]) { statement in
            LectureBookmark(
                id: UUID(uuidString: String(cString: sqlite3_column_text(statement, 0)))!,
                sessionID: sessionID,
                kind: BookmarkKind(rawValue: String(cString: sqlite3_column_text(statement, 1)))!,
                sessionTime: sqlite3_column_double(statement, 2),
                text: sqlite3_column_text(statement, 3).map(String.init(cString:))
            )
        }
    }
}

public struct NoteEvidence: Codable, Equatable, Sendable {
    public let revisionID: TranscriptRevisionID
    public let start: TimeInterval
    public let end: TimeInterval
}

public struct StructuredStudyNote: Codable, Equatable, Sendable {
    public let summary: [String]
    public let keyConcepts: [String]
    public let terminology: [String]
    public let actionItems: [String]
    public let bookmarkedQuestions: [String]
    public let evidence: [NoteEvidence]
    public init(summary: [String], keyConcepts: [String], terminology: [String], actionItems: [String], bookmarkedQuestions: [String], evidence: [NoteEvidence]) {
        self.summary = summary; self.keyConcepts = keyConcepts; self.terminology = terminology; self.actionItems = actionItems; self.bookmarkedQuestions = bookmarkedQuestions; self.evidence = evidence
    }
}

public enum StudyNoteValidationError: LocalizedError, Equatable { case noEvidence, unknownRevision(TranscriptRevisionID), malformed
    public var errorDescription: String? { switch self { case .noEvidence: return "Generated notes contain no evidence references."; case let .unknownRevision(id): return "Generated notes cite an unavailable transcript revision: \(id.rawValue.uuidString)."; case .malformed: return "The provider returned malformed study notes." } }
}

public struct TextOnlyStudyNoteRequest: Codable, Equatable, Sendable {
    public let transcript: [TranslationSourceSegment]
    public let bookmarks: [LectureBookmark]
    public let terminology: [String]
}

public protocol StudyNoteGenerating: Sendable { var providerID: String { get }; var model: String { get }; func generate(_ request: TextOnlyStudyNoteRequest) async throws -> StructuredStudyNote }

public struct ValidatingStudyNoteGenerator: Sendable {
    private let provider: any StudyNoteGenerating
    public init(provider: any StudyNoteGenerating) { self.provider = provider }
    public var providerID: String { provider.providerID }
    public var model: String { provider.model }
    public func generate(_ request: TextOnlyStudyNoteRequest, availableRevisionIDs: Set<TranscriptRevisionID>) async throws -> StructuredStudyNote {
        let note = try await provider.generate(request)
        guard !note.evidence.isEmpty else { throw StudyNoteValidationError.noEvidence }
        for evidence in note.evidence where !availableRevisionIDs.contains(evidence.revisionID) { throw StudyNoteValidationError.unknownRevision(evidence.revisionID) }
        return note
    }
}

@MainActor
public struct StudyNotePipeline {
    private let generator: ValidatingStudyNoteGenerator
    private let repository: SQLiteNoteVersionRepository

    public init(
        generator: ValidatingStudyNoteGenerator,
        repository: SQLiteNoteVersionRepository
    ) {
        self.generator = generator
        self.repository = repository
    }

    public func generateAndPersist(
        sessionID: SessionID,
        request: TextOnlyStudyNoteRequest
    ) async throws -> StoredNoteVersion {
        let availableIDs = Set(request.transcript.map(\.revisionID))
        let note = try await generator.generate(
            request,
            availableRevisionIDs: availableIDs
        )
        let contentJSON = String(
            data: try JSONEncoder().encode(note),
            encoding: .utf8
        )!
        return try repository.save(
            sessionID: sessionID,
            contentJSON: contentJSON,
            providerID: generator.providerID,
            model: generator.model,
            evidenceRevisionIDs: note.evidence.map(\.revisionID)
        )
    }
}
