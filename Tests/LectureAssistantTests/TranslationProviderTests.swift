import AVFoundation
import Foundation
import XCTest
@testable import LectureAssistant

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Response {
        case http(Int, Data)
        case error(URLError)
    }

    static let lock = NSLock()
    static var response: Response = .error(URLError(.notConnectedToInternet))
    static var capturedRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock {
            Self.capturedRequest = request
            switch Self.response {
            case let .http(status, data):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case let .error(error):
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}

    static func configure(_ response: Response) {
        lock.withLock {
            self.response = response
            capturedRequest = nil
        }
    }
}

final class TranslationProviderTests: XCTestCase {
    func testSuccessfulTextOnlyRequestProducesValidatedTranslation() async throws {
        let fixture = try providerFixture()
        let translation = try SimplifiedChineseTranslation(
            revisionID: fixture.revisionID,
            text: "动态规划"
        )
        let envelope = try JSONEncoder().encode(["translations": [translation]])
        let content = String(data: envelope, encoding: .utf8)!
        let response = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content]]]
        ])
        StubURLProtocol.configure(.http(200, response))

        let result = try await fixture.provider.translate(fixture.request)

        XCTAssertEqual(result.translations, [translation])
        let captured = try XCTUnwrap(StubURLProtocol.capturedRequest)
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        let contractBody = String(
            data: try JSONEncoder().encode(fixture.request),
            encoding: .utf8
        )!
        XCTAssertFalse(contractBody.contains("test-secret"))
        XCTAssertFalse(contractBody.localizedCaseInsensitiveContains("audio"))
        XCTAssertFalse(contractBody.localizedCaseInsensitiveContains("path"))
    }

    func testMalformedProviderOutputIsRejected() async throws {
        let fixture = try providerFixture()
        let response = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": "not-json"]]]
        ])
        StubURLProtocol.configure(.http(200, response))
        await XCTAssertThrowsAsyncError(
            try await fixture.provider.translate(fixture.request),
            equals: TranslationContractError.malformedProviderOutput
        )
    }

    func testUnauthorizedQuotaTimeoutAndOfflineAreClassified() async throws {
        let fixture = try providerFixture()
        let cases: [(StubURLProtocol.Response, TranslationProviderError)] = [
            (.http(401, Data()), .unauthorized),
            (.http(429, Data()), .quotaLimited),
            (.error(URLError(.timedOut)), .timedOut),
            (.error(URLError(.notConnectedToInternet)), .offline),
        ]
        for (response, expected) in cases {
            StubURLProtocol.configure(response)
            await XCTAssertThrowsAsyncError(
                try await fixture.provider.translate(fixture.request),
                equals: expected
            )
        }
    }

    func testProviderFailureDoesNotPreventLocalEnglishOutput() async throws {
        let providerFixture = try providerFixture()
        StubURLProtocol.configure(.http(401, Data()))
        do {
            _ = try await providerFixture.provider.translate(providerFixture.request)
            XCTFail("Expected unauthorized response")
        } catch {}

        let recognizer = ProviderFailureSpeechRecognizer()
        let pipeline = LiveTranscriptionPipeline(
            sessionID: SessionID(),
            recognizer: recognizer,
            finalWindowSeconds: 1,
            partialWindowSeconds: 1
        )
        let collector = Task { () -> [LiveTranscriptSegment] in
            var values: [LiveTranscriptSegment] = []
            for await value in pipeline.segments { values.append(value) }
            return values
        }
        await pipeline.consume(try englishFrame())
        await pipeline.finish()
        let values = await collector.value
        XCTAssertTrue(values.contains { $0.text == "English continues" && $0.isFinal })
    }

    private func providerFixture() throws -> (
        provider: OpenAICompatibleTranslationProvider,
        request: SimplifiedChineseTranslationRequest,
        revisionID: TranscriptRevisionID
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let revisionID = TranscriptRevisionID()
        let request = try SimplifiedChineseTranslationRequest(segments: [
            try TranslationSourceSegment(revisionID: revisionID, text: "Dynamic programming")
        ])
        return (
            OpenAICompatibleTranslationProvider(
                configuration: ProviderConfiguration(
                    providerID: "test",
                    baseURL: URL(string: "https://provider.test/v1")!,
                    model: "translation-model"
                ),
                apiKey: "test-secret",
                session: URLSession(configuration: configuration)
            ),
            request,
            revisionID
        )
    }

    private func englishFrame() throws -> CapturedAudioFrame {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        return CapturedAudioFrame(
            buffer: buffer,
            capturedAt: .now,
            activity: AudioActivityLevel(rootMeanSquare: 0, decibels: -80)
        )
    }
}

private actor ProviderFailureSpeechRecognizer: LocalSpeechRecognizing {
    func transcribe(samples: [Float], prompt: String?) async throws -> [SpeechRecognitionOutput] {
        [SpeechRecognitionOutput(text: "English continues", start: 0, end: 1)]
    }
}

private extension XCTestCase {
    func XCTAssertThrowsAsyncError<E: Error & Equatable>(
        _ expression: @autoclosure () async throws -> Any,
        equals expected: E,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? E, expected, file: file, line: line)
        }
    }
}
