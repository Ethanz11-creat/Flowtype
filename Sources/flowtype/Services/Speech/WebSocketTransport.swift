import Foundation

/// Text is protocol control; binary is raw PCM, in either direction.
enum WebSocketFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

enum WebSocketTransportError: Error { case closed, invalidFrame }

protocol WebSocketTransport: Sendable {
    func connect(request: URLRequest) async throws
    func sendText(_ text: String) async throws
    func sendBinary(_ data: Data) async throws
    func receive() async throws -> WebSocketFrame
    /// Must unblock pending connect/send/receive operations; safe before connect.
    func close() async
}

/// One isolated URLSession/socket per recording. No retry or stream replay.
actor URLSessionWebSocketTransport: WebSocketTransport {
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var closed = false

    func connect(request: URLRequest) async throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard socket == nil else { return }
        guard let url = request.url, isValidRealtimeEndpoint(url.absoluteString) else {
            throw RealtimeASRConfigurationError.invalidEndpoint
        }
        guard ValidationEffects.live.allow(.network) else { throw URLError(.notConnectedToInternet) }
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: request)
        self.session = session
        self.socket = socket
        socket.resume()
        // The first send awaits the upgrade, inside the adapter's start deadline.
    }

    func sendText(_ text: String) async throws {
        let socket = try activeSocket()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await socket.send(.string(text))
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }

    func sendBinary(_ data: Data) async throws {
        let socket = try activeSocket()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await socket.send(.data(data))
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }

    func receive() async throws -> WebSocketFrame {
        let socket = try activeSocket()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            switch try await socket.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .binary(data)
            @unknown default: throw WebSocketTransportError.invalidFrame
            }
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        socket = nil
        session = nil
    }

    private func activeSocket() throws -> URLSessionWebSocketTask {
        guard !closed, let socket else { throw WebSocketTransportError.closed }
        return socket
    }
}
