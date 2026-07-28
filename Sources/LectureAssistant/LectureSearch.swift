import Foundation
import SQLite3

public enum SearchContentType: String, Sendable {
    case transcript
    case translation
    case bookmark
    case note
}

public struct LectureSearchResult: Equatable, Sendable {
    public let contentID: String
    public let sessionID: SessionID
    public let contentType: SearchContentType
    public let sourceRevisionID: TranscriptRevisionID?
    public let startsAt: TimeInterval?
    public let endsAt: TimeInterval?
    public let snippet: String

    public init(
        contentID: String,
        sessionID: SessionID,
        contentType: SearchContentType,
        sourceRevisionID: TranscriptRevisionID?,
        startsAt: TimeInterval?,
        endsAt: TimeInterval?,
        snippet: String
    ) {
        self.contentID = contentID
        self.sessionID = sessionID
        self.contentType = contentType
        self.sourceRevisionID = sourceRevisionID
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.snippet = snippet
    }
}

@MainActor
public struct SQLiteLectureSearchRepository {
    private let database: LectureDatabase

    public init(database: LectureDatabase) {
        self.database = database
    }

    public func indexCurrentTranscript(sessionID: SessionID, segmentID: String) throws {
        let rows = try database.query(
            """
            SELECT id, starts_at, ends_at, text
            FROM transcript_revisions
            WHERE session_id = ? AND segment_id = ?
            ORDER BY revision_number DESC
            LIMIT 1
            """,
            bindings: [.text(sessionID.rawValue.uuidString), .text(segmentID)]
        ) { statement in
            (
                id: String(cString: sqlite3_column_text(statement, 0)),
                startsAt: sqlite3_column_double(statement, 1),
                endsAt: sqlite3_column_double(statement, 2),
                text: String(cString: sqlite3_column_text(statement, 3))
            )
        }
        try database.transaction {
            try database.execute(
                "DELETE FROM lecture_search WHERE session_id = ? AND content_type = 'transcript' AND content_id = ?",
                bindings: [.text(sessionID.rawValue.uuidString), .text(segmentID)]
            )
            if let row = rows.first {
                try insert(
                    contentID: segmentID,
                    sessionID: sessionID,
                    contentType: .transcript,
                    sourceRevisionID: row.id,
                    startsAt: row.startsAt,
                    endsAt: row.endsAt,
                    text: row.text
                )
            }
        }
    }

    public func indexTranslation(id: UUID) throws {
        let rows = try database.query(
            """
            SELECT session_id, source_revision_id, text, state
            FROM translations WHERE id = ?
            """,
            bindings: [.text(id.uuidString)]
        ) { statement in
            (
                sessionID: String(cString: sqlite3_column_text(statement, 0)),
                revisionID: String(cString: sqlite3_column_text(statement, 1)),
                text: String(cString: sqlite3_column_text(statement, 2)),
                state: String(cString: sqlite3_column_text(statement, 3))
            )
        }
        try database.transaction {
            try database.execute(
                "DELETE FROM lecture_search WHERE content_type = 'translation' AND content_id = ?",
                bindings: [.text(id.uuidString)]
            )
            guard let row = rows.first, row.state == DerivedContentState.current.rawValue,
                  let sessionUUID = UUID(uuidString: row.sessionID) else { return }
            let range = try transcriptRange(revisionID: row.revisionID)
            try insert(
                contentID: id.uuidString,
                sessionID: SessionID(rawValue: sessionUUID),
                contentType: .translation,
                sourceRevisionID: row.revisionID,
                startsAt: range?.startsAt,
                endsAt: range?.endsAt,
                text: row.text
            )
        }
    }

    public func indexBookmark(id: UUID) throws {
        let rows = try database.query(
            "SELECT session_id, session_time, text FROM bookmarks WHERE id = ?",
            bindings: [.text(id.uuidString)]
        ) { statement in
            (
                sessionID: String(cString: sqlite3_column_text(statement, 0)),
                time: sqlite3_column_double(statement, 1),
                text: sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            )
        }
        try database.transaction {
            try database.execute(
                "DELETE FROM lecture_search WHERE content_type = 'bookmark' AND content_id = ?",
                bindings: [.text(id.uuidString)]
            )
            guard let row = rows.first, !row.text.isEmpty,
                  let sessionUUID = UUID(uuidString: row.sessionID) else { return }
            try insert(
                contentID: id.uuidString,
                sessionID: SessionID(rawValue: sessionUUID),
                contentType: .bookmark,
                sourceRevisionID: nil,
                startsAt: row.time,
                endsAt: row.time,
                text: row.text
            )
        }
    }

    public func indexNoteVersion(id: UUID) throws {
        let rows = try database.query(
            "SELECT session_id, content_json, state FROM note_versions WHERE id = ?",
            bindings: [.text(id.uuidString)]
        ) { statement in
            (
                sessionID: String(cString: sqlite3_column_text(statement, 0)),
                text: String(cString: sqlite3_column_text(statement, 1)),
                state: String(cString: sqlite3_column_text(statement, 2))
            )
        }
        try database.transaction {
            try database.execute(
                "DELETE FROM lecture_search WHERE content_type = 'note' AND content_id = ?",
                bindings: [.text(id.uuidString)]
            )
            guard let row = rows.first, row.state == DerivedContentState.current.rawValue,
                  let sessionUUID = UUID(uuidString: row.sessionID) else { return }
            try insert(
                contentID: id.uuidString,
                sessionID: SessionID(rawValue: sessionUUID),
                contentType: .note,
                sourceRevisionID: nil,
                startsAt: nil,
                endsAt: nil,
                text: row.text
            )
        }
    }

    public func search(_ query: String, limit: Int = 50) throws -> [LectureSearchResult] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return try database.query(
            """
            SELECT content_id, session_id, content_type, source_revision_id,
                   starts_at, ends_at, snippet(lecture_search, 6, '[', ']', '…', 12)
            FROM lecture_search
            WHERE lecture_search MATCH ?
            ORDER BY bm25(lecture_search)
            LIMIT ?
            """,
            bindings: [.text(query), .integer(Int64(max(1, limit)))]
        ) { statement in
            let revisionID = sqlite3_column_text(statement, 3).flatMap {
                UUID(uuidString: String(cString: $0)).map(TranscriptRevisionID.init(rawValue:))
            }
            let startsAt = sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, 4)
            let endsAt = sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, 5)
            return LectureSearchResult(
                contentID: String(cString: sqlite3_column_text(statement, 0)),
                sessionID: SessionID(
                    rawValue: UUID(uuidString: String(cString: sqlite3_column_text(statement, 1)))!
                ),
                contentType: SearchContentType(
                    rawValue: String(cString: sqlite3_column_text(statement, 2))
                )!,
                sourceRevisionID: revisionID,
                startsAt: startsAt,
                endsAt: endsAt,
                snippet: String(cString: sqlite3_column_text(statement, 6))
            )
        }
    }

    private func insert(
        contentID: String,
        sessionID: SessionID,
        contentType: SearchContentType,
        sourceRevisionID: String?,
        startsAt: TimeInterval?,
        endsAt: TimeInterval?,
        text: String
    ) throws {
        try database.execute(
            """
            INSERT INTO lecture_search (
                content_id, session_id, content_type, source_revision_id,
                starts_at, ends_at, text
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(contentID),
                .text(sessionID.rawValue.uuidString),
                .text(contentType.rawValue),
                sourceRevisionID.map(SQLiteValue.text) ?? .null,
                startsAt.map(SQLiteValue.real) ?? .null,
                endsAt.map(SQLiteValue.real) ?? .null,
                .text(text),
            ]
        )
    }

    private func transcriptRange(revisionID: String) throws -> (startsAt: Double, endsAt: Double)? {
        try database.query(
            "SELECT starts_at, ends_at FROM transcript_revisions WHERE id = ?",
            bindings: [.text(revisionID)]
        ) { statement in
            (
                startsAt: sqlite3_column_double(statement, 0),
                endsAt: sqlite3_column_double(statement, 1)
            )
        }.first
    }
}
