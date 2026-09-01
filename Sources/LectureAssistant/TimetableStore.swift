import Foundation

public struct TimetableRecordingContext: Equatable, Sendable {
    public let event: ICSCourseEvent
    public let weekNumber: Int
    public let title: String

    public init(event: ICSCourseEvent, weekNumber: Int, title: String) {
        self.event = event
        self.weekNumber = weekNumber
        self.title = title
    }

    public var automaticStopAt: Date {
        event.endsAt.addingTimeInterval(5 * 60)
    }
}

@MainActor
public final class TimetableStore: ObservableObject {
    @Published public private(set) var events: [ICSCourseEvent] = []
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var selectedRecordingEvent: ICSCourseEvent?


    private let defaults: UserDefaults
    private let session: URLSession
    private let parser = ICSParser()
    private let contentsKey = "lecture-assistant.timetable-ics"
    private let subscriptionKey = "lecture-assistant.timetable-url"

    public init(
        defaults: UserDefaults = .standard,
        session: URLSession? = nil,
        initialEvents: [ICSCourseEvent]? = nil
    ) {
        self.defaults = defaults
        self.session = session ?? Self.directSession()
        if let initialEvents {
            events = initialEvents.sorted { $0.startsAt < $1.startsAt }
        } else {
            loadCachedCalendar()
        }
    }

    public var subscriptionURL: URL? {
        defaults.string(forKey: subscriptionKey).flatMap(URL.init(string:))
    }

    public func setSubscriptionURL(_ value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: normalized),
              let scheme = url.scheme,
              scheme == "https" || scheme == "http" else {
            throw URLError(.badURL)
        }
        defaults.set(url.absoluteString, forKey: subscriptionKey)
        statusMessage = "课表订阅地址已保存。"
        objectWillChange.send()
    }

    public func refresh() async {
        guard let subscriptionURL else {
            statusMessage = events.isEmpty ? "请在偏好设置中配置 ICS 课表订阅地址。" : nil
            return
        }
        do {
            let (data, response) = try await session.data(from: subscriptionURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let contents = String(data: data, encoding: .utf8) else {
                throw URLError(.badServerResponse)
            }
            try importCalendar(contents)
            statusMessage = "课表已同步，共载入 \(events.count) 节课程。"
        } catch {
            statusMessage = events.isEmpty
                ? "无法同步课表：\(error.localizedDescription)"
                : "课表同步失败，正在显示上次成功同步的课程。"
        }
    }

    public func importCalendar(_ contents: String) throws {
        let parsed = try parser.parse(contents).sorted { $0.startsAt < $1.startsAt }
        defaults.set(contents, forKey: contentsKey)
        events = parsed
    }

    public func selectForRecording(_ event: ICSCourseEvent) {
        selectedRecordingEvent = event
    }

    public func clearRecordingSelection() {
        selectedRecordingEvent = nil
    }

    public func recordingContext(
        at date: Date,
        preparationLeadTime: TimeInterval = 15 * 60
    ) -> TimetableRecordingContext? {
        if let selectedRecordingEvent,
           date < selectedRecordingEvent.endsAt.addingTimeInterval(5 * 60) {
            return recordingContext(for: selectedRecordingEvent)
        }
        let matching = events.filter {
            date >= $0.startsAt.addingTimeInterval(-preparationLeadTime)
                && date < $0.endsAt.addingTimeInterval(5 * 60)
        }.min { lhs, rhs in
            abs(lhs.startsAt.timeIntervalSince(date)) < abs(rhs.startsAt.timeIntervalSince(date))
        }
        return matching.flatMap(recordingContext(for:))
    }

    public func recordingContext(for event: ICSCourseEvent) -> TimetableRecordingContext? {
        guard events.contains(event) else { return nil }
        let peers = events.filter {
            recordingSeriesKey(for: $0) == recordingSeriesKey(for: event)
        }.sorted { $0.startsAt < $1.startsAt }
        guard let index = peers.firstIndex(of: event) else { return nil }
        let courseLabel = event.courseCode.map { String($0.suffix(5)) }
            ?? event.summary.split(separator: ",").first.map(String.init)
            ?? event.summary
        let activityLabel = event.activity ?? "课堂"
        let weekNumber = index + 1
        return TimetableRecordingContext(
            event: event,
            weekNumber: weekNumber,
            title: "第\(weekNumber)周 · \(courseLabel) · \(activityLabel)"
        )
    }

    public func recordingEventIdentifier(for event: ICSCourseEvent) -> String {
        "\(event.uid)#\(event.recurrenceID ?? "single")"
    }

    public func recordingContext(
        matching eventIdentifier: String
    ) -> TimetableRecordingContext? {
        event(matching: eventIdentifier).flatMap(recordingContext(for:))
    }

    public func followingRecordingContext(
        after eventIdentifier: String,
        maximumGap: TimeInterval = 5 * 60
    ) -> TimetableRecordingContext? {
        guard let event = event(matching: eventIdentifier),
              let nextEvent = nextContiguousEvent(after: event, maximumGap: maximumGap)
        else { return nil }
        return recordingContext(for: nextEvent)
    }

    public func automaticStopDeadline(
        after eventIdentifier: String,
        maximumGap: TimeInterval = 5 * 60
    ) -> Date? {
        guard var current = event(matching: eventIdentifier) else { return nil }
        var visited = Set([recordingEventIdentifier(for: current)])
        while let nextEvent = nextContiguousEvent(after: current, maximumGap: maximumGap) {
            let identifier = recordingEventIdentifier(for: nextEvent)
            guard visited.insert(identifier).inserted else { break }
            current = nextEvent
        }
        return current.endsAt.addingTimeInterval(maximumGap)
    }

    private static func directSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }

    private func loadCachedCalendar() {
        guard let contents = defaults.string(forKey: contentsKey),
              let parsed = try? parser.parse(contents) else { return }
        events = parsed.sorted { $0.startsAt < $1.startsAt }
    }

    private func event(matching eventIdentifier: String) -> ICSCourseEvent? {
        events.first { recordingEventIdentifier(for: $0) == eventIdentifier }
    }

    private func nextContiguousEvent(
        after event: ICSCourseEvent,
        maximumGap: TimeInterval
    ) -> ICSCourseEvent? {
        let currentIdentifier = recordingEventIdentifier(for: event)
        let cutoff = event.endsAt.addingTimeInterval(maximumGap)
        return events
            .filter { candidate in
                let identifier = recordingEventIdentifier(for: candidate)
                return identifier != currentIdentifier
                    && candidate.startsAt >= event.endsAt
                    && candidate.startsAt <= cutoff
            }
            .min { lhs, rhs in
                if lhs.startsAt == rhs.startsAt {
                    return recordingEventIdentifier(for: lhs) < recordingEventIdentifier(for: rhs)
                }
                return lhs.startsAt < rhs.startsAt
            }
    }

    private func recordingSeriesKey(for event: ICSCourseEvent) -> String {
        if let courseCode = event.courseCode {
            return "\(courseCode)|\(event.activity ?? event.summary)"
        }
        return event.summary
    }
}
