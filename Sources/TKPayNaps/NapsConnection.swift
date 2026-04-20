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

        guard let responseString = String(data: response, encoding: .utf8), !responseString.isEmpty else {
            throw NapsError.invalidResponse("Empty response from terminal")
        }

        return responseString
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

    private func receiveData(completion: @escaping (Result<Data, Error>) -> Void) {
        var receivedData = Data()

        func receiveMore() {
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] content, _, isComplete, error in
                if let error = error {
                    completion(.failure(NapsError.connectionFailed(error.localizedDescription)))
                    return
                }

                if let data = content {
                    receivedData.append(data)
                }

                if isComplete || content == nil {
                    if receivedData.isEmpty {
                        completion(.failure(NapsError.invalidResponse("Empty response")))
                    } else {
                        completion(.success(receivedData))
                    }
                    return
                }

                // Check if more data is available after a short delay
                self?.queue.asyncAfter(deadline: .now() + 0.5) {
                    // Try to receive more data with a short timeout
                    self?.connection?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { additionalContent, _, _, _ in
                        if let additionalData = additionalContent, !additionalData.isEmpty {
                            receivedData.append(additionalData)
                            receiveMore()
                        } else {
                            // No more data, return what we have
                            completion(.success(receivedData))
                        }
                    }
                }
            }
        }

        receiveMore()
    }

    deinit {
        disconnect()
    }
}
