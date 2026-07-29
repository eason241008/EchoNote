import AVFoundation
import Foundation
import XCTest
@testable import LectureAssistant

final class RealOfflineTranscriptionTests: XCTestCase {
    @MainActor
    func testNemotronStreamsSynthesizedSpeechWithoutDownloadingDuringInference() async throws {
        guard ProcessInfo.processInfo.environment["LECTURE_ASSISTANT_REAL_TRANSCRIPTION"] == "1" else {
            throw XCTSkip("Set LECTURE_ASSISTANT_REAL_TRANSCRIPTION=1 to exercise offline Nemotron inference.")
        }
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LectureAssistantRealModelCache", isDirectory: true)
        let modelsRoot = rootURL.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-sample-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let modelManager = SpeechModelManager(modelsRootURL: modelsRoot)
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
        let recognizer = try await NemotronStreamingSpeechRecognizer(modelFolder: modelFolder)
        let file = try AVAudioFile(forReading: audioURL)
        let frameCapacity = AVAudioFrameCount(file.processingFormat.sampleRate * 1.12)
        while file.framePosition < file.length {
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCapacity)
            )
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            _ = try await recognizer.consume(buffer)
        }
        let transcript = try await recognizer.finalize().lowercased()

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
}
