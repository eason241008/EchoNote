import Foundation
import XCTest
@testable import LectureAssistant

final class RealMicrophoneCaptureTests: XCTestCase {
    func testRealMicrophoneStartPauseResumeStop() async throws {
        guard ProcessInfo.processInfo.environment["LECTURE_ASSISTANT_REAL_MICROPHONE"] == "1" else {
            throw XCTSkip("Set LECTURE_ASSISTANT_REAL_MICROPHONE=1 to exercise real hardware.")
        }
        let authorization = SystemMicrophoneAuthorizationProvider()
        if authorization.status() != .authorized {
            guard await authorization.requestAccess() else {
                XCTFail("Microphone permission was not granted to the test runner.")
                return
            }
        }
        let device = try XCTUnwrap(CoreAudioInputDeviceProvider().inputDevices().first)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lecture-real-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let storage = SessionStorage(rootURL: rootURL)
        let session = LectureSession(title: "Real microphone smoke", state: .prepared)
        try await storage.createSession(
            manifest: SessionManifest(sessionID: session.id, state: .recording)
        )
        let capture = AVFoundationLectureCaptureService(storage: storage)

        try await capture.prepare(
            LectureCapturePreparation(session: session, deviceID: device.id)
        )
        try await capture.start()
        try await Task.sleep(for: .seconds(1))
        try await capture.pause()
        try await Task.sleep(for: .milliseconds(200))
        try await capture.resume()
        try await Task.sleep(for: .seconds(1))
        try await capture.stop()

        let manifest = try await storage.loadManifest(sessionID: session.id)
        XCTAssertEqual(manifest.chunks.count, 1)
        XCTAssertGreaterThan(manifest.chunks[0].byteCount, 0)
        let url = try await storage.finalizedChunkURL(
            sessionID: session.id,
            chunk: manifest.chunks[0]
        )
        let reopenedStorage = SessionStorage(rootURL: rootURL)
        var interrupted = try await reopenedStorage.loadManifest(sessionID: session.id)
        interrupted.state = .interrupted
        try await reopenedStorage.persist(manifest: interrupted)
        let recovery = SessionRecoveryCoordinator(storage: reopenedStorage, rootURL: rootURL)
        let recoveryReport = try await recovery.inspect(sessionID: session.id)
        XCTAssertEqual(recoveryReport.recoverableChunks.count, 1)
        XCTAssertEqual(recoveryReport.missingChunks, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
