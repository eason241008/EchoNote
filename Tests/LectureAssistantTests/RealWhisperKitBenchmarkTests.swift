import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import LectureAssistant

final class RealWhisperKitBenchmarkTests: XCTestCase {
    func testRepeatedOfflineInferenceMetrics() async throws {
        guard ProcessInfo.processInfo.environment["LECTURE_ASSISTANT_REAL_BENCHMARK"] == "1" else {
            throw XCTSkip("Set LECTURE_ASSISTANT_REAL_BENCHMARK=1 for repeated Core ML inference.")
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
        let samples = try loadSamples(from: audioURL)
        let recognizer = try await WhisperKitSpeechRecognizer(modelFolder: modelFolder)
        let memoryBefore = residentMemory()
        let cpuBefore = cpuTime()
        let wallStart = ContinuousClock.now
        var latencies: [Double] = []
        let windowCount = Int(
            ProcessInfo.processInfo.environment["LECTURE_ASSISTANT_BENCHMARK_WINDOWS"]
                ?? "12"
        ) ?? 12

        for _ in 0..<windowCount {
            let start = ContinuousClock.now
            let result = try await recognizer.transcribe(samples: samples, prompt: "dynamic programming")
            XCTAssertFalse(result.isEmpty)
            latencies.append(start.duration(to: .now).seconds)
        }
        let memoryGrowth = max(0, residentMemory() - memoryBefore)
        let cpu = max(0, cpuTime() - cpuBefore)
        let median = latencies.sorted()[latencies.count / 2]
        let wall = wallStart.duration(to: .now).seconds
        print("REAL_WHISPER_BENCHMARK windows=\(windowCount) median=\(median) wall=\(wall) cpu=\(cpu) rss_growth=\(memoryGrowth)")
        XCTAssertLessThan(median, 5)
        XCTAssertLessThan(memoryGrowth, 2_000_000_000)
    }

    private func synthesize(_ text: String, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, text]; try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url); let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))); try file.read(into: input)
        let outputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)); let converter = try XCTUnwrap(AVAudioConverter(from: input.format, to: outputFormat)); let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 16_000 / input.format.sampleRate + 1)))
        var supplied = false; var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in if supplied { status.pointee = .endOfStream; return nil }; supplied = true; status.pointee = .haveData; return input }
        if let error { throw error }; let channel = try XCTUnwrap(output.floatChannelData?[0]); return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    private func residentMemory() -> Int64 { var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size); _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }; return Int64(info.resident_size) }
    private func cpuTime() -> Double { var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6 }
}

private extension Duration { var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 } }
