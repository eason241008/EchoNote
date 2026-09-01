import Foundation
import XCTest
@testable import LectureAssistant

@MainActor
final class SchedulingTests: XCTestCase {
    func testRecurringICSExpandsAndPreservesUID() throws {
        let contents = #"""
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:lecture-uid@example
        SUMMARY:Algorithms
        LOCATION:PAR-160-G-G01-JH Michell Theatre (298)
        DTSTART:20260901T090000Z
        DTEND:20260901T100000Z
        RRULE:FREQ=WEEKLY;COUNT=3
        END:VEVENT
        END:VCALENDAR
        """#

        let events = try ICSParser().parse(contents)

        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(Set(events.map(\.uid)), ["lecture-uid@example"])
        XCTAssertEqual(events.first?.location, "PAR-160-G-G01-JH Michell Theatre (298)")
        XCTAssertEqual(events[1].startsAt.timeIntervalSince(events[0].startsAt), 7 * 24 * 3600, accuracy: 0.1)
    }

    func testTZIDPreservesMelbourneWallClockTime() throws {
        let contents = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:melbourne-lecture
        SUMMARY:Machine Learning
        DTSTART;TZID=Australia/Melbourne:20260729T140000
        DTEND;TZID=Australia/Melbourne:20260729T150000
        END:VEVENT
        END:VCALENDAR
        """
        let event = try XCTUnwrap(ICSParser().parse(contents).first)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Melbourne"))
        let components = calendar.dateComponents([.hour, .minute], from: event.startsAt)
        XCTAssertEqual(components.hour, 14)
        XCTAssertEqual(components.minute, 0)
    }

    func testMelbourneCalendarMetadataBuildsWeekBasedRecordingTitle() throws {
        let contents = #"""
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:week-1
        DTSTART;TZID=Australia/Melbourne:20260728T160000
        DTEND;TZID=Australia/Melbourne:20260728T173000
        SUMMARY:Software Processes and Management\, Tutorial1
        DESCRIPTION:SWEN90016_U_1_SM2\, Tutorial1\, 2
        END:VEVENT
        BEGIN:VEVENT
        UID:week-2
        DTSTART;TZID=Australia/Melbourne:20260804T160000
        DTEND;TZID=Australia/Melbourne:20260804T173000
        SUMMARY:Software Processes and Management\, Tutorial1
        DESCRIPTION:SWEN90016_U_1_SM2\, Tutorial1\, 2
        END:VEVENT
        END:VCALENDAR
        """#
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = TimetableStore(defaults: defaults)
        try store.importCalendar(contents)

        let event = try XCTUnwrap(store.events.last)
        let context = try XCTUnwrap(store.recordingContext(for: event))

        XCTAssertEqual(event.courseCode, "SWEN90016")
        XCTAssertEqual(event.activity, "Tutorial1")
        XCTAssertEqual(context.weekNumber, 2)
        XCTAssertEqual(context.title, "第2周 · 90016 · Tutorial1")
        XCTAssertEqual(
            store.recordingContext(at: event.startsAt.addingTimeInterval(60))?.event,
            event
        )
    }

    @MainActor
    func testBackToBackEventsFormOneAutomaticCaptureChain() throws {
        let first = ICSCourseEvent(
            uid: "first",
            summary: "COMP90016 Tutorial",
            startsAt: Date(timeIntervalSince1970: 100),
            endsAt: Date(timeIntervalSince1970: 200),
            recurrenceID: nil,
            courseCode: "COMP90016",
            activity: "Tutorial"
        )
        let second = ICSCourseEvent(
            uid: "second",
            summary: "COMP90054 Lecture",
            startsAt: Date(timeIntervalSince1970: 200),
            endsAt: Date(timeIntervalSince1970: 300),
            recurrenceID: nil,
            courseCode: "COMP90054",
            activity: "Lecture"
        )
        let later = ICSCourseEvent(
            uid: "later",
            summary: "COMP90015 Workshop",
            startsAt: Date(timeIntervalSince1970: 700),
            endsAt: Date(timeIntervalSince1970: 800),
            recurrenceID: nil
        )
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = TimetableStore(
            defaults: defaults,
            initialEvents: [later, second, first]
        )
        let firstID = store.recordingEventIdentifier(for: first)

        XCTAssertEqual(store.followingRecordingContext(after: firstID)?.event, second)
        XCTAssertEqual(
            store.automaticStopDeadline(after: firstID),
            second.endsAt.addingTimeInterval(5 * 60)
        )
    }

    func testInvalidICSReportsUserSafeError() {
        XCTAssertThrowsError(try ICSParser().parse("not a calendar")) { error in
            XCTAssertEqual(error as? ICSParserError, .invalidCalendar)
        }
    }

    func testLocalOverrideSurvivesStatusChanges() throws {
        let fixture = try makeFixture()
        let occurrence = ScheduledLectureOccurrence(
            courseID: fixture.course.id,
            sourceIdentity: "uid-1",
            startsAt: Date(timeIntervalSince1970: 100),
            endsAt: Date(timeIntervalSince1970: 200)
        )
        let repository = SQLiteOccurrenceRepository(database: fixture.database)
        try repository.save(occurrence)
        let movedStart = Date(timeIntervalSince1970: 120)
        try repository.applyLocalEdit(occurrence, startsAt: movedStart, endsAt: Date(timeIntervalSince1970: 220))
        let edited = try XCTUnwrap(try repository.all(courseID: fixture.course.id).first)
        XCTAssertTrue(edited.manualOverride)
        XCTAssertEqual(edited.startsAt, movedStart)

        try repository.setStatus(edited, status: .cancelled)
        let cancelled = try XCTUnwrap(try repository.all(courseID: fixture.course.id).first)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertTrue(cancelled.manualOverride)
        try repository.setStatus(cancelled, status: .scheduled)
        XCTAssertEqual(try repository.all(courseID: fixture.course.id).first?.status, .scheduled)
    }

    func testImportPreviewAppliesExternalUpdatesButProtectsManualOverrides() throws {
        let fixture = try makeFixture()
        let repository = SQLiteOccurrenceRepository(database: fixture.database)
        let first = ICSCourseEvent(
            uid: "uid",
            summary: "Algorithms",
            startsAt: Date(timeIntervalSince1970: 100),
            endsAt: Date(timeIntervalSince1970: 200),
            recurrenceID: "single"
        )
        let additions = try repository.preview(
            events: [first],
            courseID: fixture.course.id
        )
        XCTAssertEqual(additions.map(\.change), [.addition])
        try repository.apply(additions, courseID: fixture.course.id)

        let moved = ICSCourseEvent(
            uid: first.uid,
            summary: first.summary,
            startsAt: Date(timeIntervalSince1970: 120),
            endsAt: Date(timeIntervalSince1970: 220),
            recurrenceID: first.recurrenceID
        )
        let external = try repository.preview(
            events: [moved],
            courseID: fixture.course.id
        )
        XCTAssertEqual(external.map(\.change), [.externalUpdate])
        try repository.apply(external, courseID: fixture.course.id)
        let updated = try XCTUnwrap(
            try repository.all(courseID: fixture.course.id).first
        )
        XCTAssertEqual(updated.startsAt, moved.startsAt)

        try repository.applyLocalEdit(
            updated,
            startsAt: Date(timeIntervalSince1970: 140),
            endsAt: Date(timeIntervalSince1970: 240)
        )
        let externallyMovedAgain = ICSCourseEvent(
            uid: first.uid,
            summary: first.summary,
            startsAt: Date(timeIntervalSince1970: 160),
            endsAt: Date(timeIntervalSince1970: 260),
            recurrenceID: first.recurrenceID
        )
        let conflict = try repository.preview(
            events: [externallyMovedAgain],
            courseID: fixture.course.id
        )
        XCTAssertEqual(conflict.map(\.change), [.manualOverrideConflict])
        try repository.apply(conflict, courseID: fixture.course.id)
        XCTAssertEqual(
            try repository.all(courseID: fixture.course.id).first?.startsAt,
            Date(timeIntervalSince1970: 140)
        )
    }

    private func makeFixture() throws -> (database: LectureDatabase, course: Course) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduling-\(UUID().uuidString).sqlite")
        let database = try LectureDatabase(url: url)
        try database.migrate()
        let course = Course(code: "COMP90054", title: "Algorithms")
        try SQLiteCourseRepository(database: database).save(course)
        return (database, course)
    }
}
