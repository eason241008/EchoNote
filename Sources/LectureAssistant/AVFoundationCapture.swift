import AVFoundation
import CoreAudio
import Foundation

public struct CapturedAudioFrame: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let capturedAt: ContinuousClock.Instant
    public let activity: AudioActivityLevel

    public init(
        buffer: AVAudioPCMBuffer,
        capturedAt: ContinuousClock.Instant,
        activity: AudioActivityLevel
    ) {
        self.buffer = buffer
        self.capturedAt = capturedAt
        self.activity = activity
    }
}

public enum AVFoundationCaptureError: LocalizedError, Equatable {
    case notPrepared
    case alreadyRunning
    case deviceSelectionFailed(OSStatus)
    case invalidInputFormat
    case audioEngineFailed
    case chunkWriteFailed

    public var errorDescription: String? {
        switch self {
        case .notPrepared: return "Prepare a lecture session before starting capture."
        case .alreadyRunning: return "Microphone capture is already running."
        case .deviceSelectionFailed: return "The selected microphone could not be activated."
        case .invalidInputFormat: return "The selected microphone has an unsupported input format."
        case .audioEngineFailed: return "The microphone audio engine could not start."
        case .chunkWriteFailed: return "Captured audio could not be written safely."
        }
    }
}

private final class CaptureWriterState: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.lectureassistant.capture-writer", qos: .userInitiated)
    var audioFile: AVAudioFile?
    var stagingURL: URL?
    var chunkID: UUID?
    var frameStream: BoundedAsyncStream<CapturedAudioFrame>?
    var failure: Error?
}

public actor AVFoundationLectureCaptureService: LectureCaptureService {
    // Passing a non-nil format makes AVFAudio call SetOutputFormat on the
    // microphone node. That can raise an Objective-C exception while macOS is
    // still settling a newly selected route. A nil tap format keeps the
    // device-negotiated format and avoids the uncatchable SIGABRT.
    static var inputTapFormat: AVAudioFormat? { nil }

    private let storage: SessionStorage
    private let engine: AVAudioEngine
    private let writer = CaptureWriterState()
    private let timeline: CaptureTimelineRecorder?
    private var preparation: LectureCapturePreparation?
    private var recordingStartedAt: ContinuousClock.Instant?
    private var isRunning = false
    private var isPaused = false
    private let frameStream: BoundedAsyncStream<CapturedAudioFrame>
    public nonisolated let frames: AsyncStream<CapturedAudioFrame>
    public nonisolated var droppedFrameCount: Int { frameStream.droppedCount }

    public init(
        storage: SessionStorage,
        frameBufferLimit: Int = 512,
        timeline: CaptureTimelineRecorder? = nil
    ) {
        self.storage = storage
        self.timeline = timeline
        engine = AVAudioEngine()
        let frameStream = BoundedAsyncStream<CapturedAudioFrame>(limit: frameBufferLimit)
        self.frameStream = frameStream
        frames = frameStream.stream
        writer.frameStream = frameStream
    }

    deinit {
        frameStream.finish()
    }

    public func prepare(_ preparation: LectureCapturePreparation) async throws {
        guard !isRunning else { throw AVFoundationCaptureError.alreadyRunning }
        self.preparation = preparation
    }

    public func start() async throws {
        guard let preparation else { throw AVFoundationCaptureError.notPrepared }
        guard !isRunning else { throw AVFoundationCaptureError.alreadyRunning }
        let inputNode = engine.inputNode
        try setInputDevice(AudioDeviceID(preparation.deviceID), inputNode: inputNode)
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AVFoundationCaptureError.invalidInputFormat
        }

        let manifest = try await storage.loadManifest(sessionID: preparation.session.id)
        let nextSequence = (manifest.lastCommittedChunk ?? -1) + 1
        let chunkID = try await storage.beginChunk(
            sessionID: preparation.session.id,
            sequenceNumber: nextSequence,
            startsAt: 0,
            externalWriter: true
        )
        let stagingURL = try await storage.activeChunkStagingURL(
            sessionID: preparation.session.id,
            chunkID: chunkID
        )
        var tapInstalled = false
        do {
            writer.audioFile = nil
            writer.stagingURL = stagingURL
            writer.chunkID = chunkID
            writer.failure = nil
            installTap(inputNode: inputNode)
            tapInstalled = true
            engine.prepare()
            try engine.start()
            recordingStartedAt = .now
            isRunning = true
            isPaused = false
        } catch {
            if tapInstalled {
                inputNode.removeTap(onBus: 0)
            }
            writer.audioFile = nil
            writer.stagingURL = nil
            writer.chunkID = nil
            await storage.abandonActiveChunk(sessionID: preparation.session.id)
            throw AVFoundationCaptureError.audioEngineFailed
        }
    }

    public func pause() async throws {
        guard isRunning else { return }
        _ = try? await timeline?.record(.paused)
        engine.pause()
        isPaused = true
    }

    public func resume() async throws {
        guard isRunning, isPaused else { return }
        do {
            try engine.start()
            isPaused = false
            _ = try? await timeline?.record(.resumed)
        } catch {
            throw AVFoundationCaptureError.audioEngineFailed
        }
    }

    public func stop() async throws {
        guard isRunning, let preparation, let startedAt = recordingStartedAt else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try await flushWriterQueue()
        frameStream.finish()
        guard let chunkID = writer.chunkID, writer.audioFile != nil else {
            _ = try? await timeline?.record(.storageFailure)
            await storage.abandonActiveChunk(sessionID: preparation.session.id)
            resetCaptureState()
            throw AVFoundationCaptureError.chunkWriteFailed
        }
        if writer.failure != nil {
            _ = try? await timeline?.record(.storageFailure)
            await storage.abandonActiveChunk(sessionID: preparation.session.id)
            resetCaptureState()
            throw AVFoundationCaptureError.chunkWriteFailed
        }
        writer.audioFile = nil
        let duration = startedAt.duration(to: .now).seconds
        _ = try await storage.finalizeChunk(
            sessionID: preparation.session.id,
            chunkID: chunkID,
            endsAt: duration
        )
        _ = try? await timeline?.record(.stopped)
        resetCaptureState()
    }

    private func installTap(inputNode: AVAudioInputNode) {
        inputNode.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: Self.inputTapFormat
        ) { [writer] buffer, _ in
            guard let copy = buffer.deepCopy() else { return }
            let capturedAt = ContinuousClock.now
            let activity = AudioActivityMeter.measure(buffer: copy)
            writer.queue.async {
                guard writer.failure == nil, writer.chunkID != nil,
                      let stagingURL = writer.stagingURL else { return }
                do {
                    let file: AVAudioFile
                    if let existingFile = writer.audioFile {
                        file = existingFile
                    } else {
                        let newFile = try AVAudioFile(
                            forWriting: stagingURL,
                            settings: copy.format.settings
                        )
                        writer.audioFile = newFile
                        file = newFile
                    }
                    try file.write(from: copy)
                    writer.frameStream?.yield(
                        CapturedAudioFrame(
                            buffer: copy,
                            capturedAt: capturedAt,
                            activity: activity
                        )
                    )
                } catch {
                    writer.failure = error
                }
            }
        }
    }

    private func flushWriterQueue() async throws {
        await withCheckedContinuation { continuation in
            writer.queue.async { continuation.resume() }
        }
    }

    private func resetCaptureState() {
        writer.audioFile = nil
        writer.stagingURL = nil
        writer.chunkID = nil
        recordingStartedAt = nil
        isRunning = false
        isPaused = false
    }

    private func setInputDevice(
        _ deviceID: AudioDeviceID,
        inputNode: AVAudioInputNode
    ) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw AVFoundationCaptureError.deviceSelectionFailed(kAudio_ParamError)
        }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AVFoundationCaptureError.deviceSelectionFailed(status)
        }
    }
}

private extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData else {
                continue
            }
            memcpy(destinationData, sourceData, Int(source[index].mDataByteSize))
            destination[index].mDataByteSize = source[index].mDataByteSize
        }
        return copy
    }
}

private extension Duration {
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
