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
    /// Upper bound on a single response (DP receipts are at most 3500 chars)
    static let maxResponseBytes = 64 * 1024
    // Receive state — only touched on `queue`
    private var receiveOutstanding = false
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

        // Strip the trailing terminator ('!' v2, '?' v1) only when it follows complete
        // TLV units: a '?' that ends a DP value (spec §5) belongs to the value.
        if NapsConnection.endsWithTerminator(response) {
            responseString.removeLast()
        }

        // Callers only ever see the reply with card numbers masked
        return TLVProtocol.maskFrame(responseString)
    }

    /// End-of-message terminators: '!' (v2, NapsPay v5.4.4+) and '?' (v1). Both are
    /// always accepted so the reader tolerates a mismatch with the configured version.
    static func isTerminator(_ c: Character) -> Bool {
        return c == "!" || c == "?"
    }

    /// Whether a received buffer is a complete frame: whole TLV units followed by a
    /// single terminator as the last character. A '!' or '?' inside a value (or at the
    /// end of a partial chunk) is not treated as end-of-message.
    static func endsWithTerminator(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8), let last = text.last, isTerminator(last) else {
            return false
        }
        let body = text.dropLast()
        var index = body.startIndex
        while index < body.endIndex {
            guard body.distance(from: index, to: body.endIndex) >= 6 else { return false }
            let lengthStart = body.index(index, offsetBy: 3)
            let lengthEnd = body.index(lengthStart, offsetBy: 3)
            guard let length = TLVProtocol.tlvLength(body[lengthStart..<lengthEnd]),
                  body.distance(from: lengthEnd, to: body.endIndex) >= length else { return false }
            index = body.index(lengthEnd, offsetBy: length)
        }
        return true
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
            var receivedData = Data()
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

            self.chunkHandler = { content, isComplete, error in
                if let error = error {
                    finish(.failure(NapsError.connectionFailed(error.localizedDescription)))
                    return
                }

                if let data = content {
                    receivedData.append(data)
                }

                if receivedData.count > NapsConnection.maxResponseBytes {
                    finish(.failure(NapsError.invalidResponse("Response exceeds \(NapsConnection.maxResponseBytes) bytes")))
                    return
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
    /// finished (silence fallback / timeout) is reused by the next read; bytes it
    /// delivers with no active reader belong to an earlier exchange and are dropped.
    private func pumpReceive() {
        guard !receiveOutstanding, let connection = connection else { return }
        receiveOutstanding = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            self.receiveOutstanding = false
            self.chunkHandler?(content, isComplete, error)
        }
    }

    deinit {
        disconnect()
    }
}
