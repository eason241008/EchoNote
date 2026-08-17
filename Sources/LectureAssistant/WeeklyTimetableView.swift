import SwiftUI

struct WeeklyTimetableView: View {
    let events: [ICSCourseEvent]
    @Binding var weekOffset: Int
    let selectForRecording: (ICSCourseEvent) -> Void

    private let calendar: Calendar
    private let firstHour = 8
    private let lastHour = 20
    private let hourHeight: CGFloat = 66
    private let timeColumnWidth: CGFloat = 58

    init(
        events: [ICSCourseEvent],
        weekOffset: Binding<Int>,
        selectForRecording: @escaping (ICSCourseEvent) -> Void
    ) {
        self.events = events
        _weekOffset = weekOffset
        self.selectForRecording = selectForRecording
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Australia/Melbourne") ?? .current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        self.calendar = calendar
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = layout(for: proxy.size.width)
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    header(dayColumnWidth: layout.dayColumnWidth)
                    Divider().opacity(0.7)
                    ScrollView(.vertical) {
                        ZStack(alignment: .topLeading) {
                            grid(
                                dayColumnWidth: layout.dayColumnWidth,
                                contentWidth: layout.contentWidth
                            )
                            eventBlocks(dayColumnWidth: layout.dayColumnWidth)
                        }
                        .frame(
                            width: layout.contentWidth,
                            height: hourHeight * CGFloat(lastHour - firstHour)
                        )
                    }
                    .frame(height: 620)
                }
                .frame(width: layout.contentWidth)
            }
        }
        .frame(height: 684)
        .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(nsColor: .separatorColor).opacity(0.72)))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func header(dayColumnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeColumnWidth, height: 62)
            ForEach(days, id: \.self) { day in
                VStack(spacing: 4) {
                    Text(day.formatted(.dateTime.weekday(.wide)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(day.formatted(.dateTime.day()))
                        .font(.system(size: 18, weight: calendar.isDateInToday(day) ? .bold : .semibold, design: .rounded))
                        .foregroundStyle(calendar.isDateInToday(day) ? Color.accentColor : Color.primary)
                }
                .frame(width: dayColumnWidth, height: 62)
                .background(calendar.isDateInToday(day) ? Color.accentColor.opacity(0.09) : .clear)
            }
        }
    }

    private func grid(dayColumnWidth: CGFloat, contentWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0...lastHour - firstHour, id: \.self) { index in
                let y = CGFloat(index) * hourHeight
                Path { path in
                    path.move(to: CGPoint(x: timeColumnWidth, y: y))
                    path.addLine(to: CGPoint(x: contentWidth, y: y))
                }
                .stroke(Color(nsColor: .separatorColor).opacity(0.42), lineWidth: 0.7)

                if index < lastHour - firstHour {
                    Text(String(format: "%02d:00", firstHour + index))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: timeColumnWidth - 8, alignment: .trailing)
                        .offset(y: index == 0 ? 6 : y - 7)
                }
            }

            ForEach(0...days.count, id: \.self) { index in
                let x = timeColumnWidth + CGFloat(index) * dayColumnWidth
                Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: hourHeight * CGFloat(lastHour - firstHour)))
                }
                .stroke(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 0.7)
            }
        }
    }

    private func eventBlocks(dayColumnWidth: CGFloat) -> some View {
        ForEach(Array(visibleEvents.enumerated()), id: \.offset) { _, event in
            if let dayIndex = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: event.startsAt) }) {
                Button { selectForRecording(event) } label: {
                    TimetableEventBlock(event: event)
                }
                .buttonStyle(.plain)
                .frame(
                    width: dayColumnWidth - 10,
                    height: max(44, blockHeight(for: event))
                )
                .offset(
                    x: timeColumnWidth + CGFloat(dayIndex) * dayColumnWidth + 5,
                    y: yOffset(for: event)
                )
                .accessibilityLabel("记录 \(event.summary)")
            }
        }
    }

    private var days: [Date] {
        guard let start = calendar.dateInterval(of: .weekOfYear, for: displayedDate)?.start else { return [] }
        return (0..<5).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var displayedDate: Date {
        calendar.date(byAdding: .weekOfYear, value: weekOffset, to: Date()) ?? Date()
    }

    private var visibleEvents: [ICSCourseEvent] {
        guard let first = days.first,
              let end = calendar.date(byAdding: .day, value: 5, to: first) else { return [] }
        return events.filter { $0.startsAt >= first && $0.startsAt < end }
    }

    private func layout(for availableWidth: CGFloat) -> (contentWidth: CGFloat, dayColumnWidth: CGFloat) {
        let minimumDayWidth: CGFloat = 132
        let minimumContentWidth = timeColumnWidth + minimumDayWidth * CGFloat(days.count)
        let contentWidth = max(minimumContentWidth, availableWidth)
        return (
            contentWidth,
            (contentWidth - timeColumnWidth) / CGFloat(max(1, days.count))
        )
    }

    private func yOffset(for event: ICSCourseEvent) -> CGFloat {
        let components = calendar.dateComponents([.hour, .minute], from: event.startsAt)
        let hour = CGFloat((components.hour ?? firstHour) - firstHour)
        let minute = CGFloat(components.minute ?? 0) / 60
        return max(0, (hour + minute) * hourHeight)
    }

    private func blockHeight(for event: ICSCourseEvent) -> CGFloat {
        CGFloat(event.endsAt.timeIntervalSince(event.startsAt) / 3600) * hourHeight - 4
    }
}

private struct TimetableEventBlock: View {
    let event: ICSCourseEvent
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(shortTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(timeRange)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.82))
            if let location = event.location, !location.isEmpty {
                Text(location)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.68)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(isHovered ? 0.34 : 0.16)))
        .shadow(color: Color.accentColor.opacity(isHovered ? 0.34 : 0.16), radius: isHovered ? 12 : 5, y: isHovered ? 5 : 2)
        .scaleEffect(isHovered ? 1.018 : 1)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onHover { isHovered = $0 }
        .help("\(event.summary)\n\(timeRange)\n\(event.location ?? "")")
    }

    private var shortTitle: String {
        event.summary.replacingOccurrences(of: "\\,", with: ",")
    }

    private var timeRange: String {
        "\(event.startsAt.formatted(date: .omitted, time: .shortened))–\(event.endsAt.formatted(date: .omitted, time: .shortened))"
    }
}
