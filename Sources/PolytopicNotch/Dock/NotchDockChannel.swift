import Foundation

/// A broadcast channel between the apps' docks. Delivery goes to every open channel, the sender's own included (as
/// `DistributedNotificationCenter` does); the dock ignores its own messages. Posting works whether or not the channel
/// is open.
@MainActor
public protocol NotchDockChannel: AnyObject {
    func open(receive: @escaping @MainActor (NotchDockMessage) -> Void)
    func close()
    func post(_ message: NotchDockMessage)
}

/// The real channel: `DistributedNotificationCenter`, observed and posted with `deliverImmediately`.
///
/// Measured on macOS 27.2 (two inactive agent apps, 4,000 messages): no loss, no reordering, median ~2 ms, also
/// after 90 s idle. An inactive *accessory* app's center isn't suspended; an inactive *regular* app's is (the apps
/// turn regular while a window is open), and then only `deliverImmediately` gets messages through, so both sides
/// keep it.
@MainActor
public final class DistributedNotchDockChannel: NotchDockChannel {
    public struct Options: Sendable {
        public var prefix: String = NotchDockWire.prefix
        /// Post with `.deliverImmediately`.
        public var postImmediately = true
        /// The observer's suspension behaviour.
        public var observeBehavior: DistributedNotificationCenter.SuspensionBehavior = .deliverImmediately
        /// For one release after a major bump: also post (not observe) on these older prefixes.
        public var alsoPostOn: [String] = []

        public init() {}
    }

    private let center: DistributedNotificationCenter
    private let options: Options
    private var observer: Observer?

    public init(options: Options = .init(), center: DistributedNotificationCenter = .default()) {
        self.options = options
        self.center = center
    }

    public func open(receive: @escaping @MainActor (NotchDockMessage) -> Void) {
        close()
        let observer = Observer(prefix: options.prefix, receive: receive)
        for kind in NotchDockMessage.Kind.allCases {
            center.addObserver(observer, selector: #selector(Observer.received(_:)),
                               name: Notification.Name(NotchDockWire.name(kind, prefix: options.prefix)), object: nil,
                               suspensionBehavior: options.observeBehavior)
        }
        self.observer = observer
    }

    public func close() {
        if let observer { center.removeObserver(observer) }
        observer = nil
    }

    public func post(_ message: NotchDockMessage) {
        let payload = NotchDockWire.encode(message)
        for prefix in [options.prefix] + options.alsoPostOn {
            center.postNotificationName(Notification.Name(NotchDockWire.name(message.kind, prefix: prefix)), object: payload,
                                        userInfo: nil, options: options.postImmediately ? [.deliverImmediately] : [])
        }
    }

    private final class Observer: NSObject {
        let prefix: String
        let receive: @MainActor (NotchDockMessage) -> Void

        init(prefix: String, receive: @escaping @MainActor (NotchDockMessage) -> Void) {
            self.prefix = prefix
            self.receive = receive
        }

        @objc func received(_ note: Notification) {
            guard let payload = note.object as? String,
                  let message = NotchDockWire.decode(name: note.name.rawValue, payload: payload, prefix: prefix) else { return }
            let receive = receive
            if Thread.isMainThread {
                MainActor.assumeIsolated { receive(message) }
            } else {
                DispatchQueue.main.async { receive(message) }
            }
        }
    }
}

/// An in-process bus for tests and previews: several docks in one process. Delivery is queued (like the real center,
/// never re-entrant) and happens on `flush()`. Messages go through the wire codec, so encoding is exercised too.
@MainActor
public final class InMemoryNotchDockBus {
    fileprivate var channels: [ObjectIdentifier: InMemoryNotchDockChannel] = [:]
    private var queue: [(kind: NotchDockMessage.Kind, payload: String)] = []
    /// Every message posted, in order.
    public private(set) var log: [NotchDockMessage] = []

    public init() {}

    public var hasPending: Bool { !queue.isEmpty }

    public func makeChannel() -> InMemoryNotchDockChannel { InMemoryNotchDockChannel(bus: self) }

    fileprivate func enqueue(_ message: NotchDockMessage) {
        log.append(message)
        queue.append((message.kind, NotchDockWire.encode(message)))
    }

    /// Delivers everything queued, including messages posted while delivering. Returns how many were delivered.
    @discardableResult
    /// Delivers until the queue is empty, or `limit` messages (so a message loop in a test fails instead of hanging).
    public func flush(limit: Int = 10_000) -> Int {
        var delivered = 0
        while !queue.isEmpty, delivered < limit {
            let item = queue.removeFirst()
            guard let message = NotchDockWire.decode(kind: item.kind, payload: item.payload) else { continue }
            for channel in channels.values { channel.receiver?(message) }
            delivered += 1
        }
        return delivered
    }
}

@MainActor
public final class InMemoryNotchDockChannel: NotchDockChannel {
    private weak var bus: InMemoryNotchDockBus?
    fileprivate var receiver: (@MainActor (NotchDockMessage) -> Void)?

    init(bus: InMemoryNotchDockBus) { self.bus = bus }

    public func open(receive: @escaping @MainActor (NotchDockMessage) -> Void) {
        receiver = receive
        bus?.channels[ObjectIdentifier(self)] = self
    }

    public func close() {
        receiver = nil
        bus?.channels[ObjectIdentifier(self)] = nil
    }

    public func post(_ message: NotchDockMessage) {
        bus?.enqueue(message)
    }
}
