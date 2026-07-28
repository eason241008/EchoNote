import Foundation

@MainActor
public final class TimetableStore: ObservableObject {
    @Published public private(set) var events: [ICSCourseEvent] = []
    @Published public private(set) var statusMessage: String?


    private let defaults: UserDefaults
    private let session: URLSession
    private let parser = ICSParser()
    private let contentsKey = "lecture-assistant.timetable-ics"
    private let subscriptionKey = "lecture-assistant.timetable-url"

    public init(defaults: UserDefaults = .standard, session: URLSession? = nil) {
        self.defaults = defaults
        self.session = session ?? Self.directSession()
        loadCachedCalendar()
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
}
