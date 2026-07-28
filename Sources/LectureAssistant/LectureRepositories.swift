import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteValue: Sendable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null
}

@MainActor
public extension LectureDatabase {
    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String, bindings: [SQLiteValue]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LectureDatabaseError.statementFailed(sqlite3_errcode(connection))
        }
    }

    func query<T>(
        _ sql: String,
        bindings: [SQLiteValue] = [],
        map: (OpaquePointer) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append(try map(statement))
            case SQLITE_DONE:
                return rows
            default:
                throw LectureDatabaseError.statementFailed(sqlite3_errcode(connection))
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw LectureDatabaseError.statementFailed(status)
        }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case let .text(text):
                status = sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            case let .integer(integer):
                status = sqlite3_bind_int64(statement, index, sqlite3_int64(integer))
            case let .real(real):
                status = sqlite3_bind_double(statement, index, real)
            case .null:
                status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else {
                throw LectureDatabaseError.statementFailed(status)
            }
        }
    }
}

public struct TimelineEvent: Equatable, Sendable {
    public let id: UUID
    public let sessionID: SessionID
    public let sequenceNumber: Int64
    public let kind: String
    public let occurredAt: Date
    public let detailsJSON: String

    public init(
        id: UUID = UUID(),
        sessionID: SessionID,
        sequenceNumber: Int64,
        kind: String,
        occurredAt: Date,
        detailsJSON: String
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sequenceNumber = sequenceNumber
        self.kind = kind
        self.occurredAt = occurredAt
        self.detailsJSON = detailsJSON
    }
}

@MainActor
public struct SQLiteCourseRepository {
    private let database: LectureDatabase

    public init(database: LectureDatabase) {
        self.database = database
    }

    public func save(_ course: Course) throws {
        let now = Date().timeIntervalSince1970
        try database.execute(
            """
            INSERT INTO courses (id, code, title, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                code = excluded.code,
                title = excluded.title,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(course.id.rawValue.uuidString),
                .text(course.code),
                .text(course.title),
                .real(now),
                .real(now),
            ]
        )
    }

    public func all() throws -> [Course] {
        try database.query("SELECT id, code, title FROM courses ORDER BY code, title") { statement in
            Course(
                id: CourseID(rawValue: UUID(uuidString: String(cString: sqlite3_column_text(statement, 0)))!),
                code: String(cString: sqlite3_column_text(statement, 1)),
                title: String(cString: sqlite3_column_text(statement, 2))
            )
        }
    }
}

@MainActor
public struct SQLiteLectureSessionRepository {
    private let database: LectureDatabase

    public init(database: LectureDatabase) {
        self.database = database
    }

    public func save(_ session: LectureSession) throws {
        try database.execute(
            """
            INSERT INTO lecture_sessions (
                id, course_id, occurrence_id, title, state, selected_device_id,
                transcription_model, started_at, ended_at, created_at, updated_at
            ) VALUES (?, ?, NULL, ?, ?, NULL, NULL, NULL, NULL, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                course_id = excluded.course_id,
                title = excluded.title,
                state = excluded.state,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(session.id.rawValue.uuidString),
                session.courseID.map { .text($0.rawValue.uuidString) } ?? .null,
                .text(session.title),
                .text(session.state.rawValue),
                .real(session.createdAt.date.timeIntervalSince1970),
                .real(session.updatedAt.date.timeIntervalSince1970),
            ]
        )
    }

    public func session(id: SessionID) throws -> LectureSession? {
        try database.query(
            """
            SELECT course_id, title, state, created_at, updated_at
            FROM lecture_sessions WHERE id = ?
            """,
            bindings: [.text(id.rawValue.uuidString)]
        ) { statement in
            let courseID: CourseID?
            if let value = sqlite3_column_text(statement, 0),
               let uuid = UUID(uuidString: String(cString: value)) {
                courseID = CourseID(rawValue: uuid)
            } else {
                courseID = nil
            }
            return LectureSession(
                id: id,
                courseID: courseID,
                title: String(cString: sqlite3_column_text(statement, 1)),
                state: SessionState(rawValue: String(cString: sqlite3_column_text(statement, 2)))!,
                createdAt: LectureTimestamp(Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))),
                updatedAt: LectureTimestamp(Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)))
            )
        }.first
    }
}

@MainActor
public struct SQLiteTimelineRepository {
    private let database: LectureDatabase

    public init(database: LectureDatabase) {
        self.database = database
    }

    @discardableResult
    public func append(
        sessionID: SessionID,
        kind: String,
        occurredAt: Date = Date(),
        detailsJSON: String = "{}"
    ) throws -> TimelineEvent {
        try database.transaction {
            let nextSequence = try database.query(
                "SELECT COALESCE(MAX(sequence_number), -1) + 1 FROM timeline_events WHERE session_id = ?",
                bindings: [.text(sessionID.rawValue.uuidString)]
            ) { sqlite3_column_int64($0, 0) }.first ?? 0
            let event = TimelineEvent(
                sessionID: sessionID,
                sequenceNumber: nextSequence,
                kind: kind,
                occurredAt: occurredAt,
                detailsJSON: detailsJSON
            )
            try database.execute(
                """
                INSERT INTO timeline_events (
                    id, session_id, sequence_number, kind, occurred_at, details_json
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(event.id.uuidString),
                    .text(sessionID.rawValue.uuidString),
                    .integer(event.sequenceNumber),
                    .text(event.kind),
                    .real(event.occurredAt.timeIntervalSince1970),
                    .text(event.detailsJSON),
                ]
            )
            return event
        }
    }

    public func events(sessionID: SessionID) throws -> [TimelineEvent] {
        try database.query(
            """
            SELECT id, sequence_number, kind, occurred_at, details_json
            FROM timeline_events
            WHERE session_id = ?
            ORDER BY sequence_number
            """,
            bindings: [.text(sessionID.rawValue.uuidString)]
        ) { statement in
            TimelineEvent(
                id: UUID(uuidString: String(cString: sqlite3_column_text(statement, 0)))!,
                sessionID: sessionID,
                sequenceNumber: sqlite3_column_int64(statement, 1),
                kind: String(cString: sqlite3_column_text(statement, 2)),
                occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                detailsJSON: String(cString: sqlite3_column_text(statement, 4))
            )
        }
    }
}
