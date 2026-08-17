import AVFoundation
import Foundation
import XCTest
@testable import LectureAssistant

final class RealOfflineTranscriptionTests: XCTestCase {
    @MainActor
    func testLargeV3TranscribesSynthesizedSpeechWithoutModelDownloadDuringInference() async throws {
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

    @MainActor
    func testLargeV3TranscribesLocalEchoNoteRecording() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let audioPath = environment["LECTURE_ASSISTANT_LOCAL_AUDIO"],
              let modelsRootPath = environment["LECTURE_ASSISTANT_LOCAL_MODELS_ROOT"] else {
            throw XCTSkip(
                "Set LECTURE_ASSISTANT_LOCAL_AUDIO and LECTURE_ASSISTANT_LOCAL_MODELS_ROOT to diagnose a local EchoNote recording."
            )
        }
        let audioURL = URL(fileURLWithPath: audioPath)
        let manager = SpeechModelManager(modelsRootURL: URL(fileURLWithPath: modelsRootPath))
        await manager.refresh()
        let modelFolder = try XCTUnwrap(
            manager.readyModelFolder,
            "The local large-v3 model must already be installed and validated."
        )
        let samples = try loadMonoSamples16k(from: audioURL)
        let audioDuration = Double(samples.count) / 16_000
        let recognizer = try await WhisperKitSpeechRecognizer(modelFolder: modelFolder)
        let startedAt = ContinuousClock.now
        let windowSeconds = Double(environment["LECTURE_ASSISTANT_LOCAL_WINDOW_SECONDS"] ?? "0") ?? 0
        let windowSamples = windowSeconds > 0 ? Int(windowSeconds * 16_000) : samples.count
        var outputs: [SpeechRecognitionOutput] = []
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + windowSamples)
            let windowOutputs = try await recognizer.transcribe(
                samples: Array(samples[offset..<end]),
                prompt: nil
            )
            let windowOffset = Double(offset) / 16_000
            outputs.append(contentsOf: windowOutputs.map {
                SpeechRecognitionOutput(
                    text: $0.text,
                    start: windowOffset + $0.start,
                    end: windowOffset + $0.end
                )
            })
            offset = end
        }

        let elapsed = startedAt.duration(to: .now)
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let transcript = outputs.map(\.text).joined(separator: " ")
        print(
            "LOCAL_RECORDING_RESULT duration=\(audioDuration) window=\(windowSeconds) latency=\(elapsedSeconds) rtf=\(elapsedSeconds / audioDuration) transcript=\(transcript)"
        )
        XCTAssertFalse(transcript.isEmpty)
    }

    @MainActor
    func testLivePipelineCoversLocalEchoNoteRecordingWithoutDroppingWindows() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let audioPath = environment["LECTURE_ASSISTANT_LOCAL_AUDIO"],
              let modelsRootPath = environment["LECTURE_ASSISTANT_LOCAL_MODELS_ROOT"] else {
            throw XCTSkip(
                "Set LECTURE_ASSISTANT_LOCAL_AUDIO and LECTURE_ASSISTANT_LOCAL_MODELS_ROOT to diagnose the live pipeline."
            )
        }
        let manager = SpeechModelManager(
            modelsRootURL: URL(fileURLWithPath: modelsRootPath)
        )
        await manager.refresh()
        let modelFolder = try XCTUnwrap(manager.readyModelFolder)
        let samples = try loadMonoSamples16k(from: URL(fileURLWithPath: audioPath))
        let recognizer = try await WhisperKitSpeechRecognizer(modelFolder: modelFolder)
        let pipeline = LiveTranscriptionPipeline(
            sessionID: SessionID(),
            recognizer: recognizer,
            finalWindowSeconds: 30,
            partialWindowSeconds: 5
        )
        let collector = Task { () -> [LiveTranscriptSegment] in
            var values: [LiveTranscriptSegment] = []
            for await segment in pipeline.segments where segment.isFinal {
                values.append(segment)
            }
            return values
        }
        let frameSamples = 2_048
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + frameSamples)
            await pipeline.consume(try makeFrame(samples: Array(samples[offset..<end])))
            offset = end
        }
        await pipeline.finish()
        let finalized = await collector.value
        let transcript = finalized.map(\.text).joined(separator: " ")
        let expectedWindows = Int(ceil(Double(samples.count) / (30 * 16_000)))
        print(
            "LOCAL_LIVE_PIPELINE_RESULT paragraphs=\(finalized.count) minimum_windows=\(expectedWindows) words=\(transcript.split(whereSeparator: \.isWhitespace).count) transcript=\(transcript)"
        )

        XCTAssertGreaterThanOrEqual(finalized.count, expectedWindows)
        XCTAssertGreaterThan(transcript.split(whereSeparator: \.isWhitespace).count, 50)
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

    private func makeFrame(samples: [Float]) throws -> CapturedAudioFrame {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        return CapturedAudioFrame(
            buffer: buffer,
            capturedAt: .now,
            activity: AudioActivityMeter.measure(buffer: buffer)
        )
    }
}
