import Foundation
import SQLite3

public enum TranscriptRevisionStatus: String, Sendable {
    case partial
    case finalized
    case confirmed
    case gap
}

public enum DerivedContentState: String, Sendable {
    case current
    case stale
    case failed
}

public struct StoredTranslation: Equatable, Sendable {
    public let id: UUID
    public let sessionID: SessionID
    public let sourceRevisionID: TranscriptRevisionID
    public let languageCode: String
    public let text: String
    public let providerID: String
    public let model: String
    public let state: DerivedContentState
}

public struct StoredNoteVersion: Equatable, Sendable {
    public let id: UUID
    public let sessionID: SessionID
    public let versionNumber: Int64
    public let contentJSON: String
    public let providerID: String
    public let model: String
    public let state: DerivedContentState
}

@MainActor
public struct SQLiteTranscriptRevisionRepository {
    private let database: LectureDatabase

    public init(database: LectureDatabase) {
        self.database = database
    }

    @discardableResult
    public func createRevision(
        sessionID: SessionID,
        segmentID: String,
        sourceChunkID: UUID? = nil,
        startsAt: TimeInterval,
        endsAt: TimeInterval,
        text: String,
        status: TranscriptRevisionStatus,
        createdAt: Date = Date()
    ) throws -> TranscriptRevision {
        try database.transaction {
            let previous = try currentRevision(sessionID: sessionID, segmentID: segmentID)
            let revisionNumber = try database.query(
                """
                SELECT COALESCE(MAX(revision_number), 0) + 1
                FROM transcript_revisions
                WHERE session_id = ? AND segment_id = ?
                """,
                bindings: [.text(sessionID.rawValue.uuidString), .text(segmentID)]
            ) { sqlite3_column_int64($0, 0) }.first ?? 1
            let revision = TranscriptRevision(
                sessionID: sessionID,
                start: startsAt,
                end: endsAt,
                text: text,
                createdAt: LectureTimestamp(createdAt),
                supersedes: previous?.id
            )
            try database.execute(
                """
                INSERT INTO transcript_revisions (
                    id, session_id, segment_id, revision_number, source_chunk_id,
                    starts_at, ends_at, text, status, supersedes_id, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(revision.id.rawValue.uuidString),
                    .text(sessionID.rawValue.uuidString),
                    .text(segmentID),
                    .integer(revisionNumber),
                    sourceChunkID.map { .text($0.uuidString) } ?? .null,
                    .real(startsAt),
                    .real(endsAt),
                    .text(text),
                    .text(status.rawValue),
                    previous.map { .text($0.id.rawValue.uuidString) } ?? .null,
                    .real(createdAt.timeIntervalSince1970),
                ]
            )
            if let previous {
                try markDependentsStale(sourceRevisionID: previous.id)
            }
            return revision
        }
    }

    public func currentRevision(sessionID: SessionID, segmentID: String) throws -> TranscriptRevision? {
        try database.query(
            """
            SELECT id, starts_at, ends_at, text, created_at, supersedes_id
            FROM transcript_revisions
            WHERE session_id = ? AND segment_id = ?
            ORDER BY revision_number DESC
            LIMIT 1
            """,
            bindings: [.text(sessionID.rawValue.uuidString), .text(segmentID)]
        ) { statement in
            let supersedes: TranscriptRevisionID?
            if let value = sqlite3_column_text(statement, 5),
               let uuid = UUID(uuidString: String(cString: value)) {
                supersedes = TranscriptRevisionID(rawValue: uuid)
            } else {
                supersedes = nil
            }
            return TranscriptRevision(
                id: TranscriptRevisionID(
                    rawValue: UUID(uuidString: String(cString: sqlite3_column_text(statement, 0)))!
                ),
                sessionID: sessionID,
                start: sqlite3_column_double(statement, 1),
                end: sqlite3_column_double(statement, 2),
                text: String(cString: sqlite3_column_text(statement, 3)),
                createdAt: LectureTimestamp(
                    Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                ),
                supersedes: supersedes
            )
        }.first
    }

    public func history(sessionID: SessionID, segmentID: String) throws -> [TranscriptRevision] {
        try database.query(
            """
            SELECT id, starts_at, ends_at, text, created_at, supersedes_id
            FROM transcript_revisions
            WHERE session_id = ? AND segment_id = ?
            ORDER BY revision_number
            """,
            bindings: [.text(sessionID.rawValue.uuidString), .text(segmentID)]
        ) { statement in
            let supersedes = sqlite3_column_text(statement, 5).flatMap {
                UUID(uuidString: String(cString: $0)).map(TranscriptRevisionID.init(rawValue:))
            }
            return TranscriptRevision(
                id: TranscriptRevisionID(
                    rawValue: UUID(uuidString: String(cString: sqlite3_column_text(statement, 0)))!
                ),
                sessionID: sessionID,
                start: sqlite3_column_double(statement, 1),
                end: sqlite3_column_double(statement, 2),
                text: String(cString: sqlite3_column_text(statement, 3)),
                createdAt: LectureTimestamp(
                    Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                ),
                supersedes: supersedes
            )
        }
    }

    private func markDependentsStale(sourceRevisionID: TranscriptRevisionID) throws {
        let id = sourceRevisionID.rawValue.uuidString
        try database.execute(
            "UPDATE translations SET state = 'stale' WHERE source_revision_id = ? AND state = 'current'",
            bindings: [.text(id)]
        )
        try database.execute(
            """
            UPDATE note_versions
            SET state = 'stale'
            WHERE state = 'current' AND id IN (
                SELECT DISTINCT note_version_id
                FROM evidence_spans
                WHERE source_revision_id = ?
            )
            """,
            bindings: [.text(id)]
        )
        try database.execute(
            """
            DELETE FROM lecture_search
            WHERE (content_type = 'translation' AND source_revision_id = ?)
               OR (content_type = 'note' AND content_id IN (
                    SELECT note_version_id
                    FROM evidence_spans
                    WHERE source_revision_id = ?
               ))
            """,
            bindings: [.text(id), .text(id)]
        )
    }
}

@MainActor
public struct SQLiteTranslationRepository {
    let database: LectureDatabase

    public init(database: LectureDatabase) {
        self.database = database
    }

    @discardableResult
    public func save(
        sessionID: SessionID,
        sourceRevisionID: TranscriptRevisionID,
        languageCode: String,
        text: String,
        providerID: String,
        model: String,
        state: DerivedContentState = .current,
        createdAt: Date = Date()
    ) throws -> StoredTranslation {
        let translation = StoredTranslation(
            id: UUID(),
            sessionID: sessionID,
            sourceRevisionID: sourceRevisionID,
            languageCode: languageCode,
            text: text,
            providerID: providerID,
            model: model,
            state: state
        )
        try database.execute(
            """
            INSERT INTO translations (
                id, session_id, source_revision_id, language_code, text,
                provider_id, model, state, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(translation.id.uuidString),
                .text(sessionID.rawValue.uuidString),
                .text(sourceRevisionID.rawValue.uuidString),
                .text(languageCode),
                .text(text),
                .text(providerID),
                .text(model),
                .text(state.rawValue),
                .real(createdAt.timeIntervalSince1970),
            ]
        )
        return translation
    }

    public func state(id: UUID) throws -> DerivedContentState? {
        try database.query(
            "SELECT state FROM translations WHERE id = ?",
            bindings: [.text(id.uuidString)]
        ) { statement in
            DerivedContentState(rawValue: String(cString: sqlite3_column_text(statement, 0)))!
        }.first
    }
}

@MainActor
public struct SQLiteNoteVersionRepository {
    let database: LectureDatabase

    public init(database: LectureDatabase) {
        self.database = database
    }

    @discardableResult
    public func save(
        sessionID: SessionID,
        contentJSON: String,
        providerID: String,
        model: String,
        evidenceRevisionIDs: [TranscriptRevisionID],
        state: DerivedContentState = .current,
        createdAt: Date = Date()
    ) throws -> StoredNoteVersion {
        try database.transaction {
            let versionNumber = try database.query(
                "SELECT COALESCE(MAX(version_number), 0) + 1 FROM note_versions WHERE session_id = ?",
                bindings: [.text(sessionID.rawValue.uuidString)]
            ) { sqlite3_column_int64($0, 0) }.first ?? 1
            let note = StoredNoteVersion(
                id: UUID(),
                sessionID: sessionID,
                versionNumber: versionNumber,
                contentJSON: contentJSON,
                providerID: providerID,
                model: model,
                state: state
            )
            try database.execute(
                """
                INSERT INTO note_versions (
                    id, session_id, version_number, content_json,
                    provider_id, model, state, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(note.id.uuidString),
                    .text(sessionID.rawValue.uuidString),
                    .integer(note.versionNumber),
                    .text(contentJSON),
                    .text(providerID),
                    .text(model),
                    .text(state.rawValue),
                    .real(createdAt.timeIntervalSince1970),
                ]
            )
            for revisionID in Set(evidenceRevisionIDs) {
                try database.execute(
                    """
                    INSERT INTO evidence_spans (
                        id, note_version_id, source_revision_id,
                        start_offset, end_offset, created_at
                    ) VALUES (?, ?, ?, 0, 0, ?)
                    """,
                    bindings: [
                        .text(UUID().uuidString),
                        .text(note.id.uuidString),
                        .text(revisionID.rawValue.uuidString),
                        .real(createdAt.timeIntervalSince1970),
                    ]
                )
            }
            return note
        }
    }

    public func state(id: UUID) throws -> DerivedContentState? {
        try database.query(
            "SELECT state FROM note_versions WHERE id = ?",
            bindings: [.text(id.uuidString)]
        ) { statement in
            DerivedContentState(rawValue: String(cString: sqlite3_column_text(statement, 0)))!
        }.first
    }
}
