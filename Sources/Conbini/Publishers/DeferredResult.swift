import Combine

/// A publisher returning the result of a given closure only executed on the first positive demand.
///
/// This publisher is used at the origin of a publisher chain and it only provides the value when it receives a request with a demand greater than zero.
public struct DeferredResult<Output,Failure:Swift.Error>: Publisher {
    /// The closure type being store for delated execution.
    public typealias Closure = () -> Result<Output,Failure>
    /// Deferred closure.
    /// - note: The closure is kept in the publisher, thus if you keep the publisher around any reference in the closure will be kept too.
    private let closure: Closure
    
    /// Creates a publisher that send a value and completes successfully or just fails depending on the result of the given closure.
    /// - parameter closure: Closure in charge of generating the value to be emitted.
    /// - attention: The closure is kept in the publisher, thus if you keep the publisher around any reference in the closure will be kept too.
    public init(closure: @escaping Closure) {
        self.closure = closure
    }
    
    public func receive<S>(subscriber: S) where S: Subscriber, Output==S.Input, Failure==S.Failure {
        let subscription = Conduit(downstream: subscriber, closure: self.closure)
        subscriber.receive(subscription: subscription)
    }
}

extension DeferredResult {
    /// The shadow subscription chain's origin.
    private struct Conduit<Downstream>: Subscription where Downstream:Subscriber, Downstream.Input==Output, Downstream.Failure==Failure {
        /// Enum listing all possible conduit states.
        @Locked private var state: State<(),Configuration>
        
        init(downstream: Downstream, closure: @escaping Closure) {
            _state = .init(active: .init(downstream: downstream, closure: closure))
        }
        
        var combineIdentifier: CombineIdentifier {
            _state.combineIdentifier
        }
        
        func request(_ demand: Subscribers.Demand) {
            guard demand > 0,
                  case .active(let config) = _state.terminate() else { return }
            
            switch config.closure() {
            case .success(let value):
                _ = config.downstream.receive(value)
                config.downstream.receive(completion: .finished)
            case .failure(let error):
                config.downstream.receive(completion: .failure(error))
            }
        }
        
        func cancel() {
            _state.terminate()
        }
        
        /// The configuration for the subscription active state.
        private struct Configuration {
            let downstream: Downstream
            let closure: Closure
        }
    }
}
