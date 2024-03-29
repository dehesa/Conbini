import Combine

extension Publishers {
  /// Transform the upstream successful completion event into a new or existing publisher.
  public struct Then<Child,Upstream>: Publisher where Upstream:Publisher, Child:Publisher, Upstream.Failure==Child.Failure {
    public typealias Output = Child.Output
    public typealias Failure = Child.Failure
    /// Closure generating the publisher to be pipelined after upstream completes.
    public typealias Closure = () -> Child

    /// Publisher emitting the events being received here.
    public let upstream: Upstream
    /// The maximum demand requested to the upstream at the same time.
    public let maxDemand: Subscribers.Demand
    /// Closure that will crete the publisher that will emit events downstream once a successful completion is received.
    public let transform: Closure

    /// Designated initializer providing the upstream publisher and the closure in charge of arranging the transformation.
    ///
    /// The `maxDemand` must be greater than zero (`precondition`).
    /// - parameter upstream: Upstream publisher chain which successful completion will trigger the `transform` closure.
    /// - parameter maxDemand: The maximum demand requested to the upstream at the same time.
    /// - parameter transfom: Closure providing the new (or existing) publisher.
    @inlinable public init(upstream: Upstream, maxDemand: Subscribers.Demand = .unlimited, transform: @escaping ()->Child) {
      precondition(maxDemand > .none)
      self.upstream = upstream
      self.maxDemand = maxDemand
      self.transform = transform
    }

    public func receive<S>(subscriber: S) where S:Subscriber, S.Input==Output, S.Failure==Failure {
      let conduitDownstream = _DownstreamConduit(downstream: subscriber, transform: self.transform)
      let conduitUpstream = UpstreamConduit(subscriber: conduitDownstream, maxDemand: self.maxDemand)
      self.upstream.subscribe(conduitUpstream)
    }
  }
}

// MARK: -

fileprivate extension Publishers.Then {
  /// Helper that acts as a `Subscriber` for the upstream, but just forward events to the given `Conduit` instance.
  final class UpstreamConduit<Downstream>: Subscription, Subscriber where Downstream:Subscriber, Downstream.Input==Child.Output, Downstream.Failure==Child.Failure {
    typealias Input = Upstream.Output
    typealias Failure = Upstream.Failure

    /// Enum listing all possible conduit states.
    @ConduitLock private var state: ConduitState<_WaitConfiguration,_ActiveConfiguration>
    /// The combine identifier shared with the `DownstreamConduit`.
    let combineIdentifier: CombineIdentifier
    /// The maximum demand requested to the upstream at the same time.
    private let _maxDemand: Subscribers.Demand

    /// Designated initializer for this helper establishing the strong bond between the `Conduit` and the created helper.
    init(subscriber: _DownstreamConduit<Downstream>, maxDemand: Subscribers.Demand) {
      precondition(maxDemand > .none)
      self.state = .awaitingSubscription(_WaitConfiguration(downstream: subscriber))
      self.combineIdentifier = subscriber.combineIdentifier
      self._maxDemand = maxDemand
    }

    deinit {
      self.cancel()
      self._state.invalidate()
    }

    func receive(subscription: Subscription) {
      guard let config = self._state.activate(atomic: { _ActiveConfiguration(upstream: subscription, downstream: $0.downstream, didDownstreamRequestValues: false) }) else {
        return subscription.cancel()
      }
      config.downstream.receive(subscription: self)
    }

    func request(_ demand: Subscribers.Demand) {
      guard demand > 0 else { return }

      self._state.lock()
      guard var config = self._state.value.activeConfiguration, !config.didDownstreamRequestValues else { return self._state.unlock() }
      config.didDownstreamRequestValues = true
      self._state.value = .active(config)
      self._state.unlock()

      config.upstream.request(self._maxDemand)
    }

    func receive(_ input: Upstream.Output) -> Subscribers.Demand {
      .max(1)
    }

    func receive(completion: Subscribers.Completion<Upstream.Failure>) {
      guard case .active(let config) = self._state.terminate() else { return }
      config.downstream.receive(completion: completion)
    }

    func cancel() {
      guard case .active(let config) = self._state.terminate() else { return }
      config.upstream.cancel()
    }
  }
}

private extension Publishers.Then.UpstreamConduit {
  /// The necessary variables during the *awaiting* stage.
  ///
  /// The *Conduit* has been initialized, but it is not yet connected to the upstream.
  struct _WaitConfiguration {
    let downstream: Publishers.Then<Child,Upstream>._DownstreamConduit<Downstream>
  }
  /// The necessary variables during the *active* stage.
  ///
  /// The *Conduit* is receiving values from upstream.
  struct _ActiveConfiguration {
    let upstream: Subscription
    let downstream: Publishers.Then<Child,Upstream>._DownstreamConduit<Downstream>
    var didDownstreamRequestValues: Bool
  }
}

// MARK: -

private extension Publishers.Then {
  /// Represents an active `Then` publisher taking both the role of `Subscriber` (for upstream publishers) and `Subscription` (for downstream subscribers).
  ///
  /// This subscriber takes as inputs any value provided from upstream, but ignores them. Only when a successful completion has been received, a `Child` publisher will get generated.
  /// The child events will get emitted as-is (i.e. without any modification).
  final class _DownstreamConduit<Downstream>: Subscription, Subscriber where Downstream: Subscriber, Downstream.Input==Child.Output, Downstream.Failure==Child.Failure {
    typealias Input = Downstream.Input
    typealias Failure = Downstream.Failure

    /// Enum listing all possible conduit states.
    @ConduitLock private var state: ConduitState<_WaitConfiguration,_ActiveConfiguration>

    /// Designated initializer holding the downstream subscribers.
    /// - parameter downstream: The subscriber receiving values downstream.
    /// - parameter transform: The closure that will eventually generate another publisher to switch to.
    init(downstream: Downstream, transform: @escaping Closure) {
      self.state = .awaitingSubscription(_WaitConfiguration(closure: transform, downstream: downstream))
    }

    deinit {
      self.cancel()
      self._state.invalidate()
    }

    func receive(subscription: Subscription) {
      // A subscription can be received in the following two cases:
      //  a) The pipeline has just started and an acknowledgment is being waited from the upstream.
      //  b) The upstream has completed successfully and a child has been instantiated. The acknowledgement is being waited upon.
      self._state.lock()
      switch self._state.value {
      case .awaitingSubscription(let config):
        self._state.value = .active(_ActiveConfiguration(stage: .upstream(subscription: subscription, closure: config.closure, storedRequests: .none), downstream: config.downstream))
        self._state.unlock()
        config.downstream.receive(subscription: self)
      case .active(var config):
        guard case .awaitingChild(let storedRequests) = config.stage else { fatalError() }
        config.stage = .child(subscription: subscription)
        self._state.value = .active(config)
        self._state.unlock()
        subscription.request(storedRequests)
      case .terminated:
        self._state.unlock()
      }
    }

    func request(_ demand: Subscribers.Demand) {
      guard demand > 0 else { return }

      self._state.lock()
      guard var config = self._state.value.activeConfiguration else { return self._state.unlock() }

      switch config.stage {
      case .upstream(let subscription, let closure, let requests):
        config.stage = .upstream(subscription: subscription, closure: closure, storedRequests: requests + demand)
        self._state.value = .active(config)
        self._state.unlock()
        if requests == .none { subscription.request(.max(1)) }
      case .awaitingChild(let requests):
        config.stage = .awaitingChild(storedRequests: requests + demand)
        self._state.value = .active(config)
        self._state.unlock()
      case .child(let subscription):
        self._state.unlock()
        return subscription.request(demand)
      }
    }
    
    func receive(_ input: Downstream.Input) -> Subscribers.Demand {
      self._state.lock()
      guard let config = self._state.value.activeConfiguration else { self._state.unlock(); return .unlimited }
      guard case .child = config.stage else { fatalError() }
      self._state.unlock()
      return config.downstream.receive(input)
    }

    func receive(completion: Subscribers.Completion<Downstream.Failure>) {
      self._state.lock()
      guard var config = self._state.value.activeConfiguration else { return self._state.unlock() }

      switch config.stage {
      case .upstream(_, let closure, let requests):
        switch completion {
        case .finished:
          config.stage = .awaitingChild(storedRequests: requests)
          self._state.value = .active(config)
          self._state.unlock()
          closure().subscribe(self)
        case .failure:
          self._state.value = .terminated
          self._state.unlock()
          config.downstream.receive(completion: completion)
        }
      case .awaitingChild:
        fatalError()
      case .child:
        self._state.value = .terminated
        self._state.unlock()
        config.downstream.receive(completion: completion)
      }
    }

    func cancel() {
      guard case .active(let config) = self._state.terminate() else { return }
      switch config.stage {
      case .upstream(let subscription, _, _): subscription.cancel()
      case .awaitingChild(_): break
      case .child(let subscription): subscription.cancel()
      }
    }
  }
}

private extension Publishers.Then._DownstreamConduit {
  /// The necessary variables during the *awaiting* stage.
  ///
  /// The `Conduit` has been initialized, but it is not yet connected to the upstream.
  struct _WaitConfiguration {
    /// Closure generating the publisher which will take over once the publisher has completed (successfully).
    let closure: Publishers.Then<Child,Upstream>.Closure
    /// The subscriber further down the chain.
    let downstream: Downstream
  }
  /// The necessary variables during the *active* stage.
  ///
  /// The *Conduit* is receiving values from upstream or child publisher.
  struct _ActiveConfiguration {
    /// The active stage
    var stage: Stage
    /// The subscriber further down the chain.
    let downstream: Downstream

    /// Once the pipeline is activated, there are two main stages: upsatream connection, and child publishing.
    enum Stage {
      /// Values are being received from upstream, but the child publisher hasn't been activated (switched to) yet.
      case upstream(subscription: Subscription, closure: ()->Child, storedRequests: Subscribers.Demand)
      /// Upstream has completed successfully and the child publisher has been instantiated and it is being waited for subscription acknowledgement.
      case awaitingChild(storedRequests: Subscribers.Demand)
      /// Upstream has completed successfully and the child is sending values.
      case child(subscription: Subscription)
    }
  }
}
