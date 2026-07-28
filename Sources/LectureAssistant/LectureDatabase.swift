import Foundation
import SQLite3

public enum LectureDatabaseError: LocalizedError, Equatable {
    case openFailed(Int32)
    case statementFailed(Int32)
    case migrationFailed(version: Int, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .openFailed:
            return "The lecture database could not be opened."
        case .statementFailed:
            return "The lecture database operation failed."
        case let .migrationFailed(version, _):
            return "Lecture database migration \(version) failed."
        }
    }
}

public struct LectureDatabaseMigration: Sendable {
    public let version: Int32
    public let statements: [String]

    public init(version: Int32, statements: [String]) {
        self.version = version
        self.statements = statements
    }
}

public enum LectureDatabaseSchema {
    public static let migrations: [LectureDatabaseMigration] = [
        LectureDatabaseMigration(
            version: 1,
            statements: [
                """
                CREATE TABLE courses (
                    id TEXT PRIMARY KEY NOT NULL,
                    code TEXT NOT NULL,
                    title TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                ) STRICT
                """,
                """
                CREATE TABLE course_occurrences (
                    id TEXT PRIMARY KEY NOT NULL,
                    course_id TEXT NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
                    source_identity TEXT,
                    starts_at REAL NOT NULL,
                    ends_at REAL NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('scheduled', 'cancelled')),
                    manual_override INTEGER NOT NULL DEFAULT 0 CHECK (manual_override IN (0, 1)),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    UNIQUE(course_id, source_identity)
                ) STRICT
                """,
                """
                CREATE TABLE lecture_sessions (
                    id TEXT PRIMARY KEY NOT NULL,
                    course_id TEXT REFERENCES courses(id) ON DELETE SET NULL,
                    occurrence_id TEXT REFERENCES course_occurrences(id) ON DELETE SET NULL,
                    title TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('prepared', 'recording', 'paused', 'interrupted', 'completed')),
                    selected_device_id TEXT,
                    transcription_model TEXT,
                    started_at REAL,
                    ended_at REAL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                ) STRICT
                """,
                """
                CREATE TABLE audio_chunks (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL REFERENCES lecture_sessions(id) ON DELETE CASCADE,
                    sequence_number INTEGER NOT NULL CHECK (sequence_number >= 0),
                    relative_path TEXT NOT NULL,
                    starts_at REAL NOT NULL,
                    ends_at REAL,
                    byte_count INTEGER NOT NULL DEFAULT 0 CHECK (byte_count >= 0),
                    sha256 TEXT,
                    finalized_at REAL,
                    UNIQUE(session_id, sequence_number),
                    UNIQUE(session_id, relative_path)
                ) STRICT
                """,
                """
                CREATE TABLE timeline_events (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL REFERENCES lecture_sessions(id) ON DELETE CASCADE,
                    sequence_number INTEGER NOT NULL CHECK (sequence_number >= 0),
                    kind TEXT NOT NULL,
                    occurred_at REAL NOT NULL,
                    details_json TEXT NOT NULL DEFAULT '{}',
                    UNIQUE(session_id, sequence_number)
                ) STRICT
                """,
                """
                CREATE TABLE transcript_revisions (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL REFERENCES lecture_sessions(id) ON DELETE CASCADE,
                    segment_id TEXT NOT NULL,
                    revision_number INTEGER NOT NULL CHECK (revision_number > 0),
                    source_chunk_id TEXT REFERENCES audio_chunks(id) ON DELETE SET NULL,
                    starts_at REAL NOT NULL,
                    ends_at REAL NOT NULL,
                    text TEXT NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('partial', 'finalized', 'confirmed', 'gap')),
                    supersedes_id TEXT REFERENCES transcript_revisions(id) ON DELETE SET NULL,
                    created_at REAL NOT NULL,
                    UNIQUE(session_id, segment_id, revision_number)
                ) STRICT
                """,
                """
                CREATE TABLE translations (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL REFERENCES lecture_sessions(id) ON DELETE CASCADE,
                    source_revision_id TEXT NOT NULL REFERENCES transcript_revisions(id) ON DELETE CASCADE,
                    language_code TEXT NOT NULL,
                    text TEXT NOT NULL,
                    provider_id TEXT NOT NULL,
                    model TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('current', 'stale', 'failed')),
                    created_at REAL NOT NULL,
                    UNIQUE(source_revision_id, language_code, provider_id, model)
                ) STRICT
                """,
                """
                CREATE TABLE bookmarks (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL REFERENCES lecture_sessions(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL CHECK (kind IN ('important', 'question')),
                    session_time REAL NOT NULL CHECK (session_time >= 0),
                    text TEXT,
                    created_at REAL NOT NULL
                ) STRICT
                """,
                """
                CREATE TABLE note_versions (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL REFERENCES lecture_sessions(id) ON DELETE CASCADE,
                    version_number INTEGER NOT NULL CHECK (version_number > 0),
                    content_json TEXT NOT NULL,
                    provider_id TEXT NOT NULL,
                    model TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('current', 'stale', 'failed')),
                    created_at REAL NOT NULL,
                    UNIQUE(session_id, version_number)
                ) STRICT
                """,
                """
                CREATE TABLE evidence_spans (
                    id TEXT PRIMARY KEY NOT NULL,
                    note_version_id TEXT NOT NULL REFERENCES note_versions(id) ON DELETE CASCADE,
                    source_revision_id TEXT NOT NULL REFERENCES transcript_revisions(id) ON DELETE CASCADE,
                    start_offset INTEGER NOT NULL CHECK (start_offset >= 0),
                    end_offset INTEGER NOT NULL CHECK (end_offset >= start_offset),
                    created_at REAL NOT NULL
                ) STRICT
                """,
                """
                CREATE TABLE terminology (
                    id TEXT PRIMARY KEY NOT NULL,
                    course_id TEXT NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
                    term TEXT NOT NULL,
                    replacement TEXT,
                    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    UNIQUE(course_id, term)
                ) STRICT
                """,
                """
                CREATE TABLE exports (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL REFERENCES lecture_sessions(id) ON DELETE CASCADE,
                    format TEXT NOT NULL CHECK (format IN ('markdown', 'pdf', 'srt', 'json')),
                    relative_path TEXT NOT NULL,
                    snapshot_json TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('staging', 'completed', 'failed')),
                    created_at REAL NOT NULL,
                    completed_at REAL
                ) STRICT
                """,
                "CREATE INDEX course_occurrences_starts_at_idx ON course_occurrences(starts_at)",
                "CREATE INDEX lecture_sessions_course_date_idx ON lecture_sessions(course_id, started_at)",
                "CREATE INDEX audio_chunks_session_sequence_idx ON audio_chunks(session_id, sequence_number)",
                "CREATE INDEX timeline_events_session_sequence_idx ON timeline_events(session_id, sequence_number)",
                "CREATE INDEX transcript_revisions_session_time_idx ON transcript_revisions(session_id, starts_at)",
                "CREATE INDEX translations_session_idx ON translations(session_id)",
                "CREATE INDEX bookmarks_session_time_idx ON bookmarks(session_id, session_time)",
                "CREATE INDEX note_versions_session_version_idx ON note_versions(session_id, version_number)",
                "CREATE INDEX evidence_spans_revision_idx ON evidence_spans(source_revision_id)",
                "CREATE INDEX terminology_course_idx ON terminology(course_id, enabled)",
                "CREATE INDEX exports_session_created_idx ON exports(session_id, created_at)",
            ]
        ),
        LectureDatabaseMigration(
            version: 2,
            statements: [
                """
                CREATE VIRTUAL TABLE lecture_search USING fts5(
                    content_id UNINDEXED,
                    session_id UNINDEXED,
                    content_type UNINDEXED,
                    source_revision_id UNINDEXED,
                    starts_at UNINDEXED,
                    ends_at UNINDEXED,
                    text,
                    tokenize = 'unicode61 remove_diacritics 2'
                )
                """,
            ]
        ),
    ]
}

@MainActor
public final class LectureDatabase {
    var connection: OpaquePointer?

    public init(url: URL) throws {
        var openedConnection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &openedConnection, flags, nil)
        guard status == SQLITE_OK, let openedConnection else {
            if let openedConnection { sqlite3_close(openedConnection) }
            throw LectureDatabaseError.openFailed(status)
        }
        connection = openedConnection
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
    }

    deinit {
        if let connection { sqlite3_close(connection) }
    }

    public func migrate() throws {
        let currentVersion = try userVersion()
        for migration in LectureDatabaseSchema.migrations where migration.version > currentVersion {
            try execute("BEGIN IMMEDIATE")
            do {
                for statement in migration.statements {
                    try execute(statement)
                }
                try execute("PRAGMA user_version = \(migration.version)")
                try execute("COMMIT")
            } catch let error as LectureDatabaseError {
                try? execute("ROLLBACK")
                let code: Int32
                switch error {
                case let .openFailed(status), let .statementFailed(status): code = status
                case let .migrationFailed(_, status): code = status
                }
                throw LectureDatabaseError.migrationFailed(version: Int(migration.version), code: code)
            }
        }
    }

    public func userVersion() throws -> Int32 {
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(connection, "PRAGMA user_version", -1, &statement, nil)
        guard prepareStatus == SQLITE_OK, let statement else {
            throw LectureDatabaseError.statementFailed(prepareStatus)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LectureDatabaseError.statementFailed(sqlite3_errcode(connection))
        }
        return sqlite3_column_int(statement, 0)
    }

    public func tableNames() throws -> Set<String> {
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK, let statement else {
            throw LectureDatabaseError.statementFailed(prepareStatus)
        }
        defer { sqlite3_finalize(statement) }

        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0) else { continue }
            names.insert(String(cString: value))
        }
        return names
    }

    func execute(_ sql: String) throws {
        let status = sqlite3_exec(connection, sql, nil, nil, nil)
        guard status == SQLITE_OK else {
            throw LectureDatabaseError.statementFailed(status)
        }
    }
}
