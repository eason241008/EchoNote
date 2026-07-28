import Darwin
import Foundation

public struct LongLectureMetrics: Codable, Equatable, Sendable {
    public let simulatedDurationSeconds: TimeInterval
    public let processedWindows: Int
    public let medianCaptionLatencySeconds: Double
    public let memoryGrowthBytes: Int64
    public let diskGrowthBytes: Int64
    public let wallTimeSeconds: Double
    public let cpuTimeSeconds: Double
}

public actor LongLectureMetricsRunner {
    private let durationSeconds: Int
    private let samplesPerWindow: Int

    public init(durationSeconds: Int = 3_600, samplesPerWindow: Int = 16_000) {
        self.durationSeconds = durationSeconds
        self.samplesPerWindow = samplesPerWindow
    }

    public func run() async throws -> LongLectureMetrics {
        let memoryBefore = residentMemoryBytes()
        let diskRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lecture-metrics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: diskRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: diskRoot) }
        let diskBefore = directorySize(diskRoot)
        let wallStart = ContinuousClock.now
        let cpuStart = processCPUTime()
        let tracker = CaptionLatencyTracker(windowSize: 101)
        var finalStatus = CaptionLatencyStatus(latestSeconds: 0, medianSeconds: 0, isDegraded: false)
        let sampleBytes = Data(count: samplesPerWindow * MemoryLayout<Float>.size)
        let sinkURL = diskRoot.appendingPathComponent("bounded-audio-window.bin")

        for index in 0..<durationSeconds {
            let completedAt = ContinuousClock.now
            finalStatus = await tracker.record(
                windowCompletedAt: completedAt,
                publishedAt: completedAt.advanced(by: .milliseconds(250 + index % 7))
            )
            try sampleBytes.write(to: sinkURL, options: .atomic)
        }

        let wallTime = wallStart.duration(to: .now).secondsValue
        let memoryAfter = residentMemoryBytes()
        let diskAfter = directorySize(diskRoot)
        return LongLectureMetrics(
            simulatedDurationSeconds: TimeInterval(durationSeconds),
            processedWindows: durationSeconds,
            medianCaptionLatencySeconds: finalStatus.medianSeconds,
            memoryGrowthBytes: max(0, memoryAfter - memoryBefore),
            diskGrowthBytes: max(0, diskAfter - diskBefore),
            wallTimeSeconds: wallTime,
            cpuTimeSeconds: max(0, processCPUTime() - cpuStart)
        )
    }

    private func residentMemoryBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }

    private func processCPUTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }


    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return enumerator.compactMap {
            guard let fileURL = $0 as? URL else { return nil }
            return try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }
        .reduce(0) { $0 + Int64($1 ?? 0) }
    }
}

private extension Duration {
    var secondsValue: Double {
        let value = components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}
