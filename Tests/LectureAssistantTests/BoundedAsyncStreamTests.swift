import XCTest
@testable import LectureAssistant

final class BoundedAsyncStreamTests: XCTestCase {
    func testDropsOldestElementsWhenProducerOutrunsConsumer() async {
        let bounded = BoundedAsyncStream<Int>(limit: 2)
        bounded.yield(1)
        bounded.yield(2)
        bounded.yield(3)
        bounded.finish()

        var values: [Int] = []
        for await value in bounded.stream {
            values.append(value)
        }

        XCTAssertEqual(values, [2, 3])
        XCTAssertEqual(bounded.droppedCount, 1)
    }
}
