import Combine

extension Subscribers {
  /// A  subscriber that requests the given number of values upon subscription and then don't request any further.
  ///
  /// For example, if the subscriber is initialized with a demand of 5, this subscriber will received 0 to 5 values, but no more.
  /// ```swift
  /// let subscriber = FixedSink<Int,Never>(demand: .max(5), receiveValue: { print($0) })
  /// ```
  /// If five values are received, then a successful completion is send to `receiveCompletion` and the upstream gets cancelled.
  public final class FixedSink<Input,Failure>: Subscriber, Cancellable where Failure:Error {
    /// The total allowed value events.
    public let demand: Int
    /// The closure executed when a value is received.
    public private(set) var receiveValue: ((Input)->Void)?
    /// The closure executed when a completion event is received.
    public private(set) var receiveCompletion: ((Subscribers.Completion<Failure>)->Void)?
    /// The subscriber's state.
    @ConduitLock private var state: ConduitState<Void,_Configuration>

    /// Designated initializer specifying the number of expected values.
    /// - precondition: `demand` must be greater than zero.
    /// - parameter demand: The maximum number of values to be received.
    /// - parameter receiveCompletion: The closure executed when the provided amount of values are received or a completion event is received.
    /// - parameter receiveValue: The closure executed when a value is received.
    public init(demand: Int, receiveCompletion: ((Subscribers.Completion<Failure>)->Void)? = nil, receiveValue: ((Input)->Void)? = nil) {
      precondition(demand > 0)
      self.demand = demand
      self.receiveValue = receiveValue
      self.receiveCompletion = receiveCompletion
      self.state = .awaitingSubscription(())
    }

    deinit {
      self.cancel()
      self._state.invalidate()
    }

    public func receive(subscription: Subscription) {
      guard case .some = self._state.activate(atomic: { _ in .init(upstream: subscription, receivedValues: 0) }) else {
        return subscription.cancel()
      }
      subscription.request(.max(self.demand))
    }

    public func receive(_ input: Input) -> Subscribers.Demand {
      self._state.lock()
      guard var config = self._state.value.activeConfiguration else {
        self._state.unlock()
        return .none
      }
      config.receivedValues += 1

      if config.receivedValues < self.demand {
        self._state.value = .active(config)
        self._state.unlock()
        self.receiveValue?(input)
      } else {
        self._state.value = .terminated
        self._state.unlock()
        self.receiveValue?(input)
        self.receiveValue = nil
        self.receiveCompletion?(.finished)
        self.receiveCompletion = nil
        config.upstream.cancel()
      }

      return .none
    }

    public func receive(completion: Subscribers.Completion<Failure>) {
      guard case .active = self._state.terminate() else { return }
      self.receiveValue = nil
      self.receiveCompletion?(completion)
      self.receiveCompletion = nil
    }

    public func cancel() {
      guard case .active = self._state.terminate() else { return }
      self.receiveValue = nil
      self.receiveCompletion = nil
    }
  }
}

private extension Subscribers.FixedSink {
  /// Variables required during the *active* stage.
  struct _Configuration {
    /// Upstream subscription.
    let upstream: Subscription
    /// The current amount of values received.
    var receivedValues: Int
  }
}
