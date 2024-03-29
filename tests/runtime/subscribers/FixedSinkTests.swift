import XCTest
import Conbini
import Combine

/// Tests the correct behavior of the `Then` operator.
final class FixedSinkTests: XCTestCase {
  override func setUp() {
    self.continueAfterFailure = false
  }
  /// A custom error to send as a dummy.
  private struct _CustomError: Swift.Error {}
}

extension FixedSinkTests {
  /// Tests a subscription with a fixed sink yielding some values and a successful completion.
  func testSuccessfulCompletion() {
    let e = self.expectation(description: "Successful completion")

    let input = (0..<10)
    var received = [Int]()

    let subscriber = Subscribers.FixedSink<Int,_CustomError>(demand: input.count, receiveCompletion: {
      guard case .finished = $0 else { return XCTFail("A failure completion was received when a successful completion was expected.")}
      e.fulfill()
    }, receiveValue: { received.append($0) })

    input.publisher.setFailureType(to: _CustomError.self)
      .map { $0 * 2}
      .subscribe(subscriber)

    self.wait(for: [e], timeout: 1)
    XCTAssertEqual(input.map { $0 * 2 }, received)
    subscriber.cancel()
  }

  /// Tests a subscription with a fixed sink yielding some values and a successful completion.
  func testCutCompletion() {
    let e = self.expectation(description: "Successful completion")

    let input = (0..<10)
    var received = [Int]()

    let subscriber = Subscribers.FixedSink<Int,_CustomError>(demand: 3, receiveCompletion: {
      guard case .finished = $0 else { return XCTFail("A failure completion was received when a successful completion was expected.")}
      e.fulfill()
    }, receiveValue: { received.append($0) })

    input.publisher.setFailureType(to: _CustomError.self)
      .map { $0 * 2}
      .subscribe(subscriber)

    self.wait(for: [e], timeout: 1)
    XCTAssertEqual(input.prefix(upTo: 3).map { $0 * 2 }, received)
    subscriber.cancel()
  }

  /// Tests a subscription with a fixed sink yielding some values and a failure completion.
  func testFailedCompletion() {
    let e = self.expectation(description: "Failure completion")

    let input = (0..<5)
    var received = [Int]()

    let subscriber = Subscribers.FixedSink<Int,_CustomError>(demand: input.count + 1, receiveCompletion: {
      guard case .failure = $0 else { return XCTFail("A succesful completion was received when a failure completion was expected.")}
      e.fulfill()
    }, receiveValue: { received.append($0) })

    let subject = PassthroughSubject<Int,_CustomError>()
    subject.map { $0 * 2}
    .subscribe(subscriber)

    let queue = DispatchQueue(label: "io.dehesa.conbini.tests.subscribers.fixedSink")
    for i in input {
      queue.asyncAfter(deadline: .now() + .milliseconds(i * 10)) { subject.send(i) }
    }

    queue.asyncAfter(deadline: .now() + .milliseconds((input.last! + 1) * 10)) {
      subject.send(completion: .failure(_CustomError()))
    }

    self.wait(for: [e], timeout: 1)
    XCTAssertEqual(input.map { $0 * 2 }, received)
    subscriber.cancel()
  }
}
