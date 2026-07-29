import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import LectureAssistant

final class RealNemotronBenchmarkTests: XCTestCase {
    func testRepeatedStreamingSessionMetrics() async throws {
        guard ProcessInfo.processInfo.environment["LECTURE_ASSISTANT_REAL_BENCHMARK"] == "1" else {
            throw XCTSkip("Set LECTURE_ASSISTANT_REAL_BENCHMARK=1 for repeated Nemotron inference.")
        }
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("LectureAssistantRealModelCache/models", isDirectory: true)
        let manager = await MainActor.run { SpeechModelManager(modelsRootURL: cache) }
        await manager.refresh()
        guard case let .ready(modelFolder) = await manager.state else {
            throw XCTSkip("Run the real offline transcription test once to populate the model cache.")
        }
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("benchmark-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try synthesize("The lecture discusses dynamic programming and optimal substructure.", to: audioURL)
        let buffers = try loadBuffers(from: audioURL)
        let recognizer = try await NemotronStreamingSpeechRecognizer(modelFolder: modelFolder)
        let memoryBefore = residentMemory()
        let cpuBefore = cpuTime()
        let wallStart = ContinuousClock.now
        var latencies: [Double] = []
        let sessionCount = Int(
            ProcessInfo.processInfo.environment["LECTURE_ASSISTANT_BENCHMARK_WINDOWS"] ?? "12"
        ) ?? 12

        for _ in 0..<sessionCount {
            let start = ContinuousClock.now
            for buffer in buffers { _ = try await recognizer.consume(buffer) }
            let result = try await recognizer.finalize()
            XCTAssertFalse(result.isEmpty)
            latencies.append(start.duration(to: .now).seconds)
        }
        let memoryGrowth = max(0, residentMemory() - memoryBefore)
        let cpu = max(0, cpuTime() - cpuBefore)
        let median = latencies.sorted()[latencies.count / 2]
        let wall = wallStart.duration(to: .now).seconds
        print("REAL_NEMOTRON_BENCHMARK sessions=\(sessionCount) median=\(median) wall=\(wall) cpu=\(cpu) rss_growth=\(memoryGrowth)")
        XCTAssertLessThan(median, 2)
        XCTAssertLessThan(memoryGrowth, 2_000_000_000)
    }

    private func synthesize(_ text: String, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func loadBuffers(from url: URL) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url)
        let capacity = AVAudioFrameCount(file.processingFormat.sampleRate * 1.12)
        var buffers: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)
            )
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            buffers.append(buffer)
        }
        return buffers
    }

    private func residentMemory() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return Int64(info.resident_size)
    }

    private func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
