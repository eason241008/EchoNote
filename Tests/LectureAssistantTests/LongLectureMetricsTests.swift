import XCTest
@testable import LectureAssistant

final class LongLectureMetricsTests: XCTestCase {
    func testOneHourEquivalentBoundedMetricsRun() async throws {
        let metrics = try await LongLectureMetricsRunner().run()
        XCTAssertEqual(metrics.simulatedDurationSeconds, 3_600)
        XCTAssertEqual(metrics.processedWindows, 3_600)
        XCTAssertLessThan(metrics.medianCaptionLatencySeconds, 5)
        XCTAssertLessThan(metrics.diskGrowthBytes, 100_000)
        XCTAssertGreaterThanOrEqual(metrics.memoryGrowthBytes, 0)
        XCTAssertGreaterThan(metrics.wallTimeSeconds, 0)
        XCTAssertGreaterThanOrEqual(metrics.cpuTimeSeconds, 0)
    }
}
