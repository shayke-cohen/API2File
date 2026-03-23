import Foundation
import Network

/// Monitors network connectivity using NWPathMonitor
public final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.api2file.network-monitor")
    private var _isConnected: Bool = true
    private let lock = NSLock()

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    public var onStatusChange: (@Sendable (Bool) -> Void)?

    public init() {}

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied
            self.lock.lock()
            let changed = self._isConnected != connected
            self._isConnected = connected
            self.lock.unlock()

            if changed {
                self.onStatusChange?(connected)
            }
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
    }
}
