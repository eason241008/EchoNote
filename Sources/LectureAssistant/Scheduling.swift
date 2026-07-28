import Foundation
import SQLite3
import UserNotifications

public struct ScheduledLectureOccurrence: Equatable, Sendable {
    public enum Status: String, Sendable { case scheduled, cancelled }
    public let id: UUID
    public let courseID: CourseID
    public let sourceIdentity: String?
    public let startsAt: Date
    public let endsAt: Date
    public let status: Status
    public let manualOverride: Bool

    public init(
        id: UUID = UUID(), courseID: CourseID, sourceIdentity: String?,
        startsAt: Date, endsAt: Date, status: Status = .scheduled, manualOverride: Bool = false
    ) {
        self.id = id; self.courseID = courseID; self.sourceIdentity = sourceIdentity
        self.startsAt = startsAt; self.endsAt = endsAt; self.status = status
        self.manualOverride = manualOverride
    }
}

public enum ICSParserError: LocalizedError, Equatable {
    case invalidCalendar
    case missingRequiredField(String)
    case invalidDate(String)
    public var errorDescription: String? {
        switch self {
        case .invalidCalendar: return "The selected calendar is not a valid ICS calendar."
        case let .missingRequiredField(field): return "The calendar event is missing \(field)."
        case let .invalidDate(value): return "The calendar contains an invalid date: \(value)."
        }
    }
}

public struct ICSCourseEvent: Equatable, Sendable {
    public let uid: String
    public let summary: String
    public let startsAt: Date
    public let endsAt: Date
    public let recurrenceID: String?
    public let location: String?

    public init(
        uid: String,
        summary: String,
        startsAt: Date,
        endsAt: Date,
        recurrenceID: String?,
        location: String? = nil
    ) {
        self.uid = uid
        self.summary = summary
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.recurrenceID = recurrenceID
        self.location = location
    }
}

public struct ICSParser: Sendable {
    public init() {}

    public func parse(_ contents: String, occurrenceLimit: Int = 256) throws -> [ICSCourseEvent] {
        let lines = contents.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard lines.contains("BEGIN:VCALENDAR"), lines.contains("END:VCALENDAR") else {
            throw ICSParserError.invalidCalendar
        }
        var events: [ICSCourseEvent] = []
        var current: [String: String] = [:]
        var recurrenceRule: String?
        var inEvent = false
        for line in lines {
            if line == "BEGIN:VEVENT" { inEvent = true; current = [:]; recurrenceRule = nil; continue }
            if line == "END:VEVENT" {
                guard inEvent else { continue }
                guard let uid = current["UID"] else { throw ICSParserError.missingRequiredField("UID") }
                guard let summary = current["SUMMARY"] else { throw ICSParserError.missingRequiredField("SUMMARY") }
                guard let startValue = current["DTSTART"], let endValue = current["DTEND"] else {
                    throw ICSParserError.missingRequiredField("DTSTART/DTEND")
                }
                let start = try parseDate(startValue, timeZoneID: current["DTSTART-TZID"])
                let end = try parseDate(endValue, timeZoneID: current["DTEND-TZID"])
                let recurrenceID = current["RECURRENCE-ID"]
                for (index, occurrenceStart) in expand(
                    start: start,
                    rule: recurrenceRule,
                    limit: occurrenceLimit
                ).enumerated() {
                    let duration = end.timeIntervalSince(start)
                    events.append(ICSCourseEvent(
                        uid: uid,
                        summary: summary,
                        startsAt: occurrenceStart,
                        endsAt: occurrenceStart.addingTimeInterval(duration),
                        recurrenceID: recurrenceID ?? (recurrenceRule == nil ? "single" : "occurrence-\(index)"),
                        location: current["LOCATION"]
                    ))
                }
                inEvent = false; continue
            }
            guard inEvent, let separator = line.firstIndex(of: ":") else { continue }
            let rawKey = String(line[..<separator])
            let key = rawKey.split(separator: ";", maxSplits: 1).first.map(String.init) ?? rawKey
            current[key] = String(line[line.index(after: separator)...])
            if (key == "DTSTART" || key == "DTEND"),
               let timeZoneID = parameter(named: "TZID", in: rawKey) {
                current["\(key)-TZID"] = timeZoneID
            }
            if key == "RRULE" { recurrenceRule = current[key] }
        }
        return events
    }

    private func parseDate(_ value: String, timeZoneID: String? = nil) throws -> Date {
        let formats = ["yyyyMMdd'T'HHmmss'Z'", "yyyyMMdd'T'HHmmss", "yyyyMMdd"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = value.hasSuffix("Z")
                ? TimeZone(secondsFromGMT: 0)
                : timeZoneID.flatMap(TimeZone.init(identifier:)) ?? TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        throw ICSParserError.invalidDate(value)
    }

    private func parameter(named name: String, in key: String) -> String? {
        key.split(separator: ";").dropFirst().compactMap { parameter in
            let pieces = parameter.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2, pieces[0] == Substring(name) else { return nil }
            return String(pieces[1])
        }.first
    }

    private func expand(start: Date, rule: String?, limit: Int) -> [Date] {
        guard let rule else { return [start] }
        let fields = Dictionary(uniqueKeysWithValues: rule.split(separator: ";").compactMap { part -> (String, String)? in
            let pieces = part.split(separator: "=", maxSplits: 1); guard pieces.count == 2 else { return nil }
            return (String(pieces[0]), String(pieces[1]))
        })
        guard fields["FREQ"] == "WEEKLY" else { return [start] }
        let count = min(Int(fields["COUNT"] ?? "\(limit)") ?? limit, limit)
        let until = fields["UNTIL"].flatMap { value -> Date? in
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .init(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return formatter.date(from: value)
        }
        return (0..<count).compactMap { index in
            let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: index * 7, to: start)!
            return until.map { date <= $0 } ?? true ? date : nil
        }
    }
}

public struct ScheduleImportPreview: Equatable, Sendable {
    public enum Change: Equatable, Sendable { case addition, externalUpdate, unchanged, manualOverrideConflict }
    public let event: ICSCourseEvent
    public let change: Change
}

@MainActor
public struct SQLiteOccurrenceRepository {
    private let database: LectureDatabase
    public init(database: LectureDatabase) { self.database = database }

    public func all(courseID: CourseID) throws -> [ScheduledLectureOccurrence] {
        try database.query("SELECT id, source_identity, starts_at, ends_at, status, manual_override FROM course_occurrences WHERE course_id = ? ORDER BY starts_at", bindings: [.text(courseID.rawValue.uuidString)]) { statement in
            ScheduledLectureOccurrence(
                id: UUID(uuidString: String(cString: sqlite3_column_text(statement, 0)))!, courseID: courseID,
                sourceIdentity: sqlite3_column_text(statement, 1).map(String.init(cString:)),
                startsAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                endsAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                status: ScheduledLectureOccurrence.Status(rawValue: String(cString: sqlite3_column_text(statement, 4)))!,
                manualOverride: sqlite3_column_int(statement, 5) == 1
            )
        }
    }

    public func save(_ occurrence: ScheduledLectureOccurrence) throws {
        let now = Date().timeIntervalSince1970
        try database.execute("""
        INSERT INTO course_occurrences (id, course_id, source_identity, starts_at, ends_at, status, manual_override, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET starts_at=excluded.starts_at, ends_at=excluded.ends_at, status=excluded.status, manual_override=excluded.manual_override, updated_at=excluded.updated_at
        """, bindings: [.text(occurrence.id.uuidString), .text(occurrence.courseID.rawValue.uuidString), occurrence.sourceIdentity.map(SQLiteValue.text) ?? .null, .real(occurrence.startsAt.timeIntervalSince1970), .real(occurrence.endsAt.timeIntervalSince1970), .text(occurrence.status.rawValue), .integer(occurrence.manualOverride ? 1 : 0), .real(now), .real(now)])
    }

    public func applyLocalEdit(_ occurrence: ScheduledLectureOccurrence, startsAt: Date, endsAt: Date) throws {
        try save(ScheduledLectureOccurrence(id: occurrence.id, courseID: occurrence.courseID, sourceIdentity: occurrence.sourceIdentity, startsAt: startsAt, endsAt: endsAt, status: occurrence.status, manualOverride: true))
    }

    public func setStatus(_ occurrence: ScheduledLectureOccurrence, status: ScheduledLectureOccurrence.Status) throws {
        try save(ScheduledLectureOccurrence(id: occurrence.id, courseID: occurrence.courseID, sourceIdentity: occurrence.sourceIdentity, startsAt: occurrence.startsAt, endsAt: occurrence.endsAt, status: status, manualOverride: occurrence.manualOverride))
    }

    public func preview(
        events: [ICSCourseEvent],
        courseID: CourseID
    ) throws -> [ScheduleImportPreview] {
        let existingBySource = Dictionary(
            uniqueKeysWithValues: try all(courseID: courseID).compactMap { occurrence in
                occurrence.sourceIdentity.map { ($0, occurrence) }
            }
        )
        return events.map { event in
            let identity = sourceIdentity(for: event)
            guard let existing = existingBySource[identity] else {
                return ScheduleImportPreview(event: event, change: .addition)
            }
            let changed = existing.startsAt != event.startsAt || existing.endsAt != event.endsAt
            let change: ScheduleImportPreview.Change
            if changed && existing.manualOverride {
                change = .manualOverrideConflict
            } else if changed {
                change = .externalUpdate
            } else {
                change = .unchanged
            }
            return ScheduleImportPreview(event: event, change: change)
        }
    }

    public func apply(
        _ previews: [ScheduleImportPreview],
        courseID: CourseID
    ) throws {
        let existingBySource = Dictionary(
            uniqueKeysWithValues: try all(courseID: courseID).compactMap { occurrence in
                occurrence.sourceIdentity.map { ($0, occurrence) }
            }
        )
        for preview in previews {
            let identity = sourceIdentity(for: preview.event)
            switch preview.change {
            case .unchanged, .manualOverrideConflict:
                continue
            case .addition:
                try save(ScheduledLectureOccurrence(
                    courseID: courseID,
                    sourceIdentity: identity,
                    startsAt: preview.event.startsAt,
                    endsAt: preview.event.endsAt
                ))
            case .externalUpdate:
                guard let existing = existingBySource[identity] else { continue }
                try save(ScheduledLectureOccurrence(
                    id: existing.id,
                    courseID: courseID,
                    sourceIdentity: identity,
                    startsAt: preview.event.startsAt,
                    endsAt: preview.event.endsAt,
                    status: existing.status,
                    manualOverride: false
                ))
            }
        }
    }

    private func sourceIdentity(for event: ICSCourseEvent) -> String {
        "\(event.uid)#\(event.recurrenceID ?? "single")"
    }
}

@MainActor
public final class LectureReminderScheduler {
    private let center: UNUserNotificationCenter
    public init(center: UNUserNotificationCenter = .current()) { self.center = center }

    public func schedule(occurrence: ScheduledLectureOccurrence, leadTime: TimeInterval) async throws {
        let content = UNMutableNotificationContent(); content.title = "课程即将开始"; content.body = "打开 EchoNote 声译，准备课堂记录。"; content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: occurrence.startsAt.addingTimeInterval(-leadTime)), repeats: false)
        let request = UNNotificationRequest(identifier: "lecture-\(occurrence.id.uuidString)", content: content, trigger: trigger)
        try await center.add(request)
    }
}
