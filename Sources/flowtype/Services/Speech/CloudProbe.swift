import Foundation
import Network
import os

/// 云端主机探测：只做一次 TCP+TLS 握手计时，用于「预测」网络差。
/// 不发送任何 HTTP 请求、不需要 API Key、不涉及音频与上下文。
enum CloudProbe {

    /// HTTPS/WSS share a TLS handshake. Reject unusable ports before conversion.
    static func probeEndpoint(fromBaseURL baseURL: String) -> (host: String, port: UInt16)? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let components = URLComponents(string: trimmed) else { return nil }
        guard let scheme = components.scheme?.lowercased(), ["https", "wss"].contains(scheme) else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }
        guard components.user == nil, components.password == nil,
              let port = UInt16(exactly: components.port ?? 443), port > 0 else { return nil }
        return (host, port)
    }

    /// 对主机做一次 TLS 握手计时（毫秒）。超时或失败返回 nil。
    static func measureLatency(host: String, port: UInt16, timeout: TimeInterval = 2.0) async -> Double? {
        guard ValidationEffects.live.allow(.network) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            let box = SingleResumeBox<Double?>()
            box.setContinuation(continuation)

            let start = DispatchTime.now().uptimeNanoseconds
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                box.resume(returning: nil)
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tls)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resume(returning: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                    connection.cancel()
                case .failed, .cancelled:
                    box.resume(returning: nil)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "flowtype.cloud-probe"))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.resume(returning: nil)
                connection.cancel()
            }
        }
    }
}

/// 保证 continuation 只 resume 一次（超时与状态回调存在竞争）。
private final class SingleResumeBox<T: Sendable>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Void>()
    private var continuation: CheckedContinuation<T, Never>?

    func setContinuation(_ continuation: CheckedContinuation<T, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(returning value: T) {
        let pending = lock.withLock { () -> CheckedContinuation<T, Never>? in
            let c = continuation
            continuation = nil
            return c
        }
        pending?.resume(returning: value)
    }
}
