import AVFoundation
import Foundation
import XCTest
@testable import LectureAssistant

final class RealOfflineTranscriptionTests: XCTestCase {
    @MainActor
    func testSmallEnglishTranscribesSynthesizedSpeechWithoutModelDownloadDuringInference() async throws {
        guard ProcessInfo.processInfo.environment["LECTURE_ASSISTANT_REAL_TRANSCRIPTION"] == "1" else {
            throw XCTSkip("Set LECTURE_ASSISTANT_REAL_TRANSCRIPTION=1 to exercise offline WhisperKit inference.")
        }
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LectureAssistantRealModelCache", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-sample-\(UUID().uuidString).aiff")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let modelManager = SpeechModelManager(modelsRootURL: rootURL.appendingPathComponent("models"))
        await modelManager.refresh()
        if !modelManager.isReady {
            try await modelManager.downloadAfterUserConfirmation()
        }
        guard case let .ready(modelFolder) = modelManager.state else {
            return XCTFail("Expected validated model")
        }

        try synthesizeSpeech(
            "The lecture assistant verifies offline transcription on this Mac.",
            to: audioURL
        )
        let samples = try loadMonoSamples16k(from: audioURL)
        let recognizer = try await WhisperKitSpeechRecognizer(modelFolder: modelFolder)

        let outputs = try await recognizer.transcribe(
            samples: samples,
            prompt: "lecture assistant, offline transcription"
        )
        let transcript = outputs.map(\.text).joined(separator: " ").lowercased()

        XCTAssertFalse(transcript.isEmpty)
        XCTAssertTrue(
            transcript.contains("lecture") || transcript.contains("transcription"),
            "Unexpected transcript: \(transcript)"
        )
    }

    private func synthesizeSpeech(_ text: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func loadMonoSamples16k(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        let input = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: input)
        let outputFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let converter = try XCTUnwrap(AVAudioConverter(from: inputFormat, to: outputFormat))
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / inputFormat.sampleRate))
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity))
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        XCTAssertNotEqual(status, .error)
        XCTAssertNil(conversionError)
        let channel = try XCTUnwrap(output.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
