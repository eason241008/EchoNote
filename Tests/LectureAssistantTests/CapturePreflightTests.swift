import AVFoundation
import Foundation
import XCTest
@testable import LectureAssistant

private struct StubAuthorizationProvider: MicrophoneAuthorizationProviding {
    let authorization: MicrophoneAuthorization

    func status() -> MicrophoneAuthorization { authorization }
    func requestAccess() async -> Bool { authorization == .authorized }
}

private struct StubInputDeviceProvider: AudioInputDeviceProviding {
    let devices: [AudioInputDevice]

    func inputDevices() throws -> [AudioInputDevice] { devices }
}

final class CapturePreflightTests: XCTestCase {
    func testReadyPreflightSelectsDefaultDeviceAndLeavesNoProbe() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-preflight-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaultDevice = AudioInputDevice(id: 42, name: "Built-in Microphone", isDefault: true)
        let service = CapturePreflightService(
            authorizationProvider: StubAuthorizationProvider(authorization: .authorized),
            deviceProvider: StubInputDeviceProvider(devices: [defaultDevice])
        )

        let result = try service.evaluate(
            selectedDeviceID: nil,
            storageRootURL: rootURL,
            transcriptionModelReady: true
        )

        XCTAssertTrue(result.isReady)
        XCTAssertEqual(result.selectedDevice, defaultDevice)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rootURL.path), [])
    }

    func testPreflightReportsIndependentPermissionDeviceStorageAndModelIssues() throws {
        let service = CapturePreflightService(
            authorizationProvider: StubAuthorizationProvider(authorization: .denied),
            deviceProvider: StubInputDeviceProvider(devices: [])
        )
        let nonDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-preflight-file-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: nonDirectoryURL)
        defer { try? FileManager.default.removeItem(at: nonDirectoryURL) }

        let result = try service.evaluate(
            selectedDeviceID: 999,
            storageRootURL: nonDirectoryURL,
            transcriptionModelReady: false
        )

        XCTAssertEqual(
            result.issues,
            [
                .microphonePermissionDenied,
                .selectedDeviceUnavailable,
                .storageUnavailable,
                .transcriptionModelUnavailable,
            ]
        )
    }

    func testPreflightDoesNotRequestUndeterminedPermission() throws {
        let service = CapturePreflightService(
            authorizationProvider: StubAuthorizationProvider(authorization: .notDetermined),
            deviceProvider: StubInputDeviceProvider(
                devices: [AudioInputDevice(id: 1, name: "Input", isDefault: true)]
            )
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-preflight-undetermined-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let result = try service.evaluate(
            selectedDeviceID: nil,
            storageRootURL: rootURL,
            transcriptionModelReady: true
        )

        XCTAssertEqual(result.issues, [.microphonePermissionRequired])
    }

    func testActivityMeterMeasuresKnownSignalAndSilence() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        )
        let signal = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        signal.frameLength = 4
        signal.floatChannelData?[0][0] = 0.5
        signal.floatChannelData?[0][1] = -0.5
        signal.floatChannelData?[0][2] = 0.5
        signal.floatChannelData?[0][3] = -0.5

        let measured = AudioActivityMeter.measure(buffer: signal)
        XCTAssertEqual(measured.rootMeanSquare, 0.5, accuracy: 0.0001)
        XCTAssertEqual(measured.decibels, -6.0206, accuracy: 0.001)

        let silence = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        silence.frameLength = 4
        XCTAssertEqual(AudioActivityMeter.measure(buffer: silence).decibels, -80)
    }

    func testSystemDeviceProviderEnumeratesInputsWithoutDuplicateIDs() throws {
        let devices = try CoreAudioInputDeviceProvider().inputDevices()
        XCTAssertEqual(Set(devices.map(\.id)).count, devices.count)
        XCTAssertFalse(devices.contains { $0.name.isEmpty })
    }
}
