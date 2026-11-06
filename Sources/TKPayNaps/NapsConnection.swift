import Foundation
import Network

/// TCP connection manager for NAPS Pay terminal
///
/// Handles:
/// - Socket connection lifecycle
/// - Send/receive TLV messages
/// - Timeout management
/// - Connection reuse for two-phase payment flow
public class NapsConnection {
    private let config: NapsConfig
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "ma.tkpay.naps.connection")
    // Receive state — only touched on `queue`
    private var receiveOutstanding = false
    private var leftover = Data()
    private var chunkHandler: ((Data?, Bool, NWError?) -> Void)?

    public init(config: NapsConfig) {
        self.config = config
    }

    /// Check if connection is ready
    public var isConnected: Bool {
        return connection?.state == .ready
    }

    /// Connect to NAPS Pay terminal
    public func connect() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let resumeLock = NSLock()

            func safeResume(throwing error: Error? = nil) {
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true

                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }

            let host = NWEndpoint.Host(config.host)
            let port = NWEndpoint.Port(integerLiteral: UInt16(config.port))

            connection = NWConnection(host: host, port: port, using: .tcp)

            connection?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    safeResume()
                case .failed(let error):
                    self?.connection = nil
                    safeResume(throwing: NapsError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    self?.connection = nil
                    safeResume(throwing: NapsError.connectionFailed("Connection cancelled"))
                default:
                    break
                }
            }

            connection?.start(queue: self.queue)

            // Timeout for connection
            self.queue.asyncAfter(deadline: .now() + self.config.timeout) { [weak self] in
                if self?.connection?.state != .ready {
                    self?.connection?.cancel()
                }
            }
        }
    }

    /// Send TLV message and receive response
    public func sendAndReceive(_ tlvMessage: String, timeout: TimeInterval? = nil) async throws -> String {
        guard let connection = connection, connection.state == .ready else {
            throw NapsError.connectionFailed("Not connected")
        }

        // Send data
        let data = tlvMessage.data(using: .utf8)!
        try await send(data)

        // Receive response
        let effectiveTimeout = timeout ?? config.timeout
        let response = try await receive(timeout: effectiveTimeout)

        guard var responseString = String(data: response, encoding: .utf8), !responseString.isEmpty else {
            throw NapsError.invalidResponse("Empty response from terminal")
        }

        // Strip the trailing terminator ('!' v2, '?' v1) if present
        if let term = responseString.lastIndex(where: { NapsConnection.isTerminator($0) }) {
            responseString = String(responseString[..<term])
        }

        return responseString
    }

    /// End-of-message terminators: '!' (v2, NapsPay v5.4.4+) and '?' (v1). Both are
    /// always accepted so the reader tolerates a mismatch with the configured version.
    static func isTerminator(_ c: Character) -> Bool {
        return c == "!" || c == "?"
    }

    /// Whether a received buffer ends with an end-of-message terminator.
    static func endsWithTerminator(_ data: Data) -> Bool {
        guard let last = data.last else { return false }
        return last == UInt8(ascii: "!") || last == UInt8(ascii: "?")
    }

    /// Disconnect from terminal
    public func disconnect() {
        connection?.cancel()
        connection = nil
    }

    // MARK: - Private Methods

    private func send(_ data: Data) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            connection?.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: NapsError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receive(timeout: TimeInterval) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let resumeLock = NSLock()

            func safeResume(_ result: Result<Data, Error>) {
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true

                switch result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            // Set timeout
            queue.asyncAfter(deadline: .now() + timeout) {
                safeResume(.failure(NapsError.timeout()))
            }

            // Receive data
            receiveData { result in
                safeResume(result)
            }
        }
    }

    /// Read until the end-of-message terminator ('!' v2, '?' v1) is received, or until
    /// 1 second of silence after the first chunk (fallback for partial frames).
    /// The overall timeout is enforced by `receive(timeout:)`.
    private func receiveData(completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            // Bytes that arrived after a previous read ended on the silence fallback
            var receivedData = self.leftover
            self.leftover = Data()
            var chunkCount = 0
            var finished = false

            // Everything below runs on `queue` (NWConnection callbacks and asyncAfter share it).
            func finish(_ result: Result<Data, Error>) {
                guard !finished else { return }
                finished = true
                self.chunkHandler = nil
                completion(result)
            }

            func armSilenceFallback() {
                chunkCount += 1
                let chunkAtArm = chunkCount
                self.queue.asyncAfter(deadline: .now() + 1.0) {
                    if chunkCount == chunkAtArm {
                        finish(.success(receivedData))
                    }
                }
            }

            if NapsConnection.endsWithTerminator(receivedData) {
                finish(.success(receivedData))
                return
            }
            if !receivedData.isEmpty {
                armSilenceFallback()
            }

            self.chunkHandler = { content, isComplete, error in
                if let error = error {
                    finish(.failure(NapsError.connectionFailed(error.localizedDescription)))
                    return
                }

                if let data = content {
                    receivedData.append(data)
                }

                if isComplete || content == nil || NapsConnection.endsWithTerminator(receivedData) {
                    if receivedData.isEmpty {
                        finish(.failure(NapsError.invalidResponse("Empty response")))
                    } else {
                        finish(.success(receivedData))
                    }
                    return
                }

                // No terminator yet: keep reading, but treat 1 s of silence as end-of-message
                armSilenceFallback()
                self.pumpReceive()
            }
            self.pumpReceive()
        }
    }

    /// Issue a single outstanding receive. A receive left pending after a read
    /// finished (silence fallback / timeout) is reused by the next read, and any
    /// bytes it delivers with no active reader are kept in `leftover`.
    private func pumpReceive() {
        guard !receiveOutstanding, let connection = connection else { return }
        receiveOutstanding = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            self.receiveOutstanding = false
            if let handler = self.chunkHandler {
                handler(content, isComplete, error)
            } else if let data = content {
                self.leftover.append(data)
            }
        }
    }

    deinit {
        disconnect()
    }
}
