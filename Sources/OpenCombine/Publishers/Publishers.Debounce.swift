//
//  Publishers.Debounce.swift
//  
//
//  Created by Sergej Jaskiewicz on 17.12.2019.
//

extension Publisher {

    /// Publishes elements only after a specified time interval elapses between events.
    ///
    /// Use this operator when you want to wait for a pause in the delivery of events from
    /// the upstream publisher. For example, call `debounce` on the publisher from a text
    /// field to only receive elements when the user pauses or stops typing. When they
    /// start typing again, the `debounce` holds event delivery until the next pause.
    ///
    /// - Parameters:
    ///   - dueTime: The time the publisher should wait before publishing an element.
    ///   - scheduler: The scheduler on which this publisher delivers elements
    ///   - options: Scheduler options that customize this publisher’s delivery of elements.
    /// - Returns: A publisher that publishes events only after a specified time elapses.
    public func debounce<Context: Scheduler>(
        for dueTime: Context.SchedulerTimeType.Stride,
        scheduler: Context,
        options: Context.SchedulerOptions? = nil
    ) -> Publishers.Debounce<Self, Context> {
        return .init(upstream: self,
                     dueTime: dueTime,
                     scheduler: scheduler,
                     options: options)
    }
}


extension Publishers {

    /// A publisher that publishes elements only after a specified time interval elapses
    /// between events.
    public struct Debounce<Upstream: Publisher, Context: Scheduler>: Publisher {

        public typealias Output = Upstream.Output

        public typealias Failure = Upstream.Failure

        /// The publisher from which this publisher receives elements.
        public let upstream: Upstream

        /// The amount of time the publisher should wait before publishing an element.
        public let dueTime: Context.SchedulerTimeType.Stride

        /// The scheduler on which this publisher delivers elements.
        public let scheduler: Context

        /// Scheduler options that customize this publisher’s delivery of elements.
        public let options: Context.SchedulerOptions?

        public init(upstream: Upstream,
                    dueTime: Context.SchedulerTimeType.Stride,
                    scheduler: Context,
                    options: Context.SchedulerOptions?) {
            self.upstream = upstream
            self.dueTime = dueTime
            self.scheduler = scheduler
            self.options = options
        }

        public func receive<Downstream: Subscriber>(subscriber: Downstream)
            where Upstream.Failure == Downstream.Failure,
                  Upstream.Output == Downstream.Input
        {
            upstream.subscribe(Inner(parent: self, downstream: subscriber))
        }
    }
}

extension Publishers.Debounce {
    private final class Inner<Downstream: Subscriber>
        : Subscriber,
          Subscription,
          CustomStringConvertible,
          CustomReflectable,
          CustomPlaygroundDisplayConvertible
        where Upstream.Output == Downstream.Input,
              Upstream.Failure == Downstream.Failure
    {
        typealias Input = Upstream.Output

        typealias Failure = Upstream.Failure

        typealias Debounce = Publishers.Debounce<Upstream, Context>

        private typealias Generation = UInt64

        private let lock = UnfairLock.allocate() // 0x10

        private let downstreamLock = UnfairRecursiveLock.allocate() // 0x20

        private var state: (parent: Debounce, downstream: Downstream)? // 0x30

        private var upstreamSubscription: Subscription?

        private var currentCanceller: Cancellable? // 0xA0

        private var currentValue: Input?

        private var currentGeneration: Generation = 0 // 0xB0

        private var downstreamDemand = Subscribers.Demand.none // 0xB8

        init(parent: Debounce, downstream: Downstream) {
            state = (parent: parent, downstream: downstream)
        }

        deinit {
            lock.deallocate()
            downstreamLock.deallocate()
        }

        func receive(subscription: Subscription) {
            lock.lock()
            guard let (_, downstream) = state, upstreamSubscription == nil else {
                lock.unlock()
                subscription.cancel()
                return
            }
            upstreamSubscription = subscription
            lock.unlock()
            downstreamLock.lock()
            downstream.receive(subscription: self)
            downstreamLock.unlock()
            subscription.request(.unlimited)
        }

        func receive(_ input: Upstream.Output) -> Subscribers.Demand {
            lock.lock()
            guard let (parent, downstream) = state else {
                lock.unlock()
                return .none
            }
            currentGeneration += 1
            let generation = currentGeneration
            currentValue = input
            let due = parent.scheduler.now.advanced(by: parent.dueTime)
            lock.unlock()
            parent.scheduler.schedule(after: due,
                                      tolerance: parent.scheduler.minimumTolerance,
                                      options: parent.options) { [weak self] in
                self?.due(generation: generation)
            }
            return .none
        }

        private func due(generation: Generation) {
            lock.lock()
            guard let (parent, downstream) = state else {
                lock.unlock()
                return
            }
            if generation != currentGeneration {
                // TODO
            }
            // TODO
        }

        func receive(completion: Subscribers.Completion<Upstream.Failure>) {
            lock.lock()
            guard let (parent, downstream) = self.state else {
                lock.unlock()
                return
            }
            if let currentCanceller = self.currentCanceller {
                lock.unlock()
                currentCanceller.cancel()
            } else {
                lock.unlock()
            }
            parent.scheduler.schedule(options: parent.options) {
                self.downstreamLock.lock()
                downstream.receive(completion: completion)
                self.downstreamLock.unlock()
            }
        }

        func request(_ demand: Subscribers.Demand) {
            lock.lock()
            if state == nil {
                lock.unlock()
                return
            }
            downstreamDemand += demand
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            guard let upstreamSubscription = self.upstreamSubscription else {
                lock.unlock()
                return
            }
            lockedTerminate()
            lock.unlock()
            upstreamSubscription.cancel()
        }

        private func lockedTerminate() {
            state = nil
            upstreamSubscription = nil
            currentCanceller = nil
            currentCanceller = nil
            currentGeneration = 0
            downstreamDemand = .none
        }

        var description: String { return "Debounce" }

        var customMirror: Mirror {
            let children: [Mirror.Child] = [
                ("upstream", state?.parent.upstream as Any),
                ("downstream", state?.downstream as Any),
                ("upstreamSubscription", upstreamSubscription as Any),
                ("downstreamDemand", downstreamDemand),
                ("currentValue", currentValue as Any)
            ]
            return Mirror(self, children: children)
        }

        var playgroundDescription: Any { return description }
    }
}
