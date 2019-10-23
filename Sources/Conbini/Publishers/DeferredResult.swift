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
    
    /// The shadow subscription chain's origin.
    private final class Conduit<Downstream>: Subscription where Downstream: Subscriber, Output==Downstream.Input, Failure==Downstream.Failure {
        @SubscriptionState
        private var state: (downstream: Downstream, closure: Closure)
        
        init(downstream: Downstream, closure: @escaping Closure) {
            self._state = .init(wrappedValue: (downstream, closure))
        }
        
        func request(_ demand: Subscribers.Demand) {
            guard demand > 0, let (downstream, closure) = self._state.remove() else { return }
            
            switch closure() {
            case .success(let value):
                _ = downstream.receive(value)
                downstream.receive(completion: .finished)
            case .failure(let error):
                downstream.receive(completion: .failure(error))
            }
        }
        
        func cancel() {
            self._state.remove()
        }
    }
}