import Foundation
import SQLite3

public struct CourseTerminology: Equatable, Sendable {
    public let id: UUID
    public let courseID: CourseID
    public let term: String
    public let replacement: String?
    public let enabled: Bool

    public init(
        id: UUID = UUID(),
        courseID: CourseID,
        term: String,
        replacement: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.courseID = courseID
        self.term = term
        self.replacement = replacement
        self.enabled = enabled
    }
}

@MainActor
public struct SQLiteTerminologyRepository {
    private let database: LectureDatabase

    public init(database: LectureDatabase) {
        self.database = database
    }

    public func save(_ terminology: CourseTerminology) throws {
        let now = Date().timeIntervalSince1970
        try database.execute(
            """
            INSERT INTO terminology (
                id, course_id, term, replacement, enabled, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(course_id, term) DO UPDATE SET
                replacement = excluded.replacement,
                enabled = excluded.enabled,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(terminology.id.uuidString),
                .text(terminology.courseID.rawValue.uuidString),
                .text(terminology.term),
                terminology.replacement.map(SQLiteValue.text) ?? .null,
                .integer(terminology.enabled ? 1 : 0),
                .real(now),
                .real(now),
            ]
        )
    }

    public func enabled(courseID: CourseID) throws -> [CourseTerminology] {
        try database.query(
            """
            SELECT id, term, replacement, enabled
            FROM terminology
            WHERE course_id = ? AND enabled = 1
            ORDER BY term COLLATE NOCASE
            """,
            bindings: [.text(courseID.rawValue.uuidString)]
        ) { statement in
            CourseTerminology(
                id: UUID(uuidString: String(cString: sqlite3_column_text(statement, 0)))!,
                courseID: courseID,
                term: String(cString: sqlite3_column_text(statement, 1)),
                replacement: sqlite3_column_text(statement, 2).map { String(cString: $0) },
                enabled: sqlite3_column_int(statement, 3) == 1
            )
        }
    }

    public func prompt(courseID: CourseID) throws -> String? {
        let values = try enabled(courseID: courseID).map {
            if let replacement = $0.replacement, !replacement.isEmpty {
                return "\($0.term) (preferred: \(replacement))"
            }
            return $0.term
        }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }
}

public struct CaptionLatencyStatus: Equatable, Sendable {
    public let latestSeconds: Double
    public let medianSeconds: Double
    public let isDegraded: Bool
}

public actor CaptionLatencyTracker {
    private let thresholdSeconds: Double
    private let windowSize: Int
    private var values: [Double] = []

    public init(thresholdSeconds: Double = 5, windowSize: Int = 21) {
        self.thresholdSeconds = thresholdSeconds
        self.windowSize = max(1, windowSize)
    }

    public func record(
        windowCompletedAt: ContinuousClock.Instant,
        publishedAt: ContinuousClock.Instant = .now
    ) -> CaptionLatencyStatus {
        let latest = max(0, windowCompletedAt.duration(to: publishedAt).secondsValue)
        values.append(latest)
        if values.count > windowSize { values.removeFirst(values.count - windowSize) }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
        return CaptionLatencyStatus(
            latestSeconds: latest,
            medianSeconds: median,
            isDegraded: median > thresholdSeconds
        )
    }
}

private extension Duration {
    var secondsValue: Double {
        let value = components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}
