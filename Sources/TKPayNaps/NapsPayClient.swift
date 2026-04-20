import Foundation

/// Main client for NAPS Pay M2M integration
///
/// Usage:
/// ```swift
/// let config = NapsConfig(host: "192.168.24.214")
/// let client = NapsPayClient(config: config)
///
/// do {
///     let result = try await client.processPayment(
///         PaymentRequest(
///             amount: 100.0,
///             registerId: "01",
///             cashierId: "00001"
///         )
///     )
///
///     if result.isApproved {
///         print("Payment approved!")
///         print("STAN: \(result.stan ?? "")")
///         print("Card: \(result.formattedCardNumber ?? "")")
///     } else {
///         print("Payment failed: \(result.error ?? "")")
///     }
/// } catch {
///     print("Error: \(error)")
/// }
/// ```
public class NapsPayClient {
    private let config: NapsConfig
    private var sequenceCounter: Int = 1

    public init(config: NapsConfig) {
        self.config = config
    }

    /// Process a payment transaction
    ///
    /// This performs the complete two-phase payment flow:
    /// 1. Send payment request -> Customer taps card
    /// 2. Send confirmation -> Transaction complete
    ///
    /// - Parameter request: Payment request data
    /// - Returns: PaymentResult with transaction details
    /// - Throws: NapsError if payment fails
    public func processPayment(_ request: PaymentRequest) async throws -> PaymentResult {
        // Validate request
        try validateRequest(request)

        let ncai = request.ncai
        let sequence = request.sequence ?? generateSequence()

        let connection = NapsConnection(config: config)

        do {
            try await connection.connect()

            // Phase 1: Payment Request
            let paymentResponse = try await sendPaymentRequest(
                connection: connection,
                amount: request.amount,
                ncai: ncai,
                sequence: sequence
            )

            // Check response code
            guard let responseCode = paymentResponse[TLVProtocol.Tags.CR] else {
                throw NapsError.invalidResponse("Missing response code")
            }

            if responseCode != "000" {
                connection.disconnect()
                let result = buildFailedResult(responseCode: responseCode, fields: paymentResponse)
                // Send notification to gateway
                GatewayNotifier.notifyTransaction(
                    terminalHost: config.host,
                    request: request,
                    result: result
                )
                return result
            }

            // Get STAN for confirmation
            guard let stan = paymentResponse[TLVProtocol.Tags.STAN] else {
                throw NapsError.invalidResponse("Missing STAN")
            }

            // Phase 2: Confirmation (must be on same connection, within 40 seconds)
            let confirmResponse = try await sendConfirmation(
                connection: connection,
                stan: stan,
                ncai: ncai,
                sequence: sequence
            )

            connection.disconnect()

            // Build successful result
            let result = buildSuccessResult(fields: confirmResponse)

            // Send notification to gateway
            GatewayNotifier.notifyTransaction(
                terminalHost: config.host,
                request: request,
                result: result
            )

            return result

        } catch {
            connection.disconnect()
            throw error
        }
    }

    /// Test connection to terminal
    ///
    /// - Returns: true if connection successful, false otherwise
    public func testConnection() async -> Bool {
        let connection = NapsConnection(config: NapsConfig(
            host: config.host,
            port: config.port,
            timeout: 5  // Short timeout for test
        ))

        do {
            try await connection.connect()
            let connected = connection.isConnected
            connection.disconnect()
            return connected
        } catch {
            return false
        }
    }

    // MARK: - Private Methods

    private func validateRequest(_ request: PaymentRequest) throws {
        guard request.amount > 0 else {
            throw NapsError(code: .invalidResponse, message: "Amount must be positive")
        }
        guard request.registerId.count == 2 else {
            throw NapsError(code: .invalidResponse, message: "Register ID must be 2 digits")
        }
        guard request.cashierId.count == 5 else {
            throw NapsError(code: .invalidResponse, message: "Cashier ID must be 5 digits")
        }
    }

    private func generateSequence() -> String {
        let seq = sequenceCounter
        sequenceCounter += 1
        if sequenceCounter > 999999 {
            sequenceCounter = 1
        }
        return String(format: "%06d", seq)
    }

    private func sendPaymentRequest(
        connection: NapsConnection,
        amount: Double,
        ncai: String,
        sequence: String
    ) async throws -> [String: String] {
        let tlvRequest = TLVProtocol.buildPaymentRequest(
            amount: amount,
            ncai: ncai,
            sequence: sequence
        )

        let response = try await connection.sendAndReceive(tlvRequest, timeout: config.timeout)
        return TLVProtocol.parse(response)
    }

    private func sendConfirmation(
        connection: NapsConnection,
        stan: String,
        ncai: String,
        sequence: String
    ) async throws -> [String: String] {
        let tlvConfirm = TLVProtocol.buildConfirmationRequest(
            stan: stan,
            ncai: ncai,
            sequence: sequence
        )

        let response = try await connection.sendAndReceive(tlvConfirm, timeout: config.confirmationTimeout)
        return TLVProtocol.parse(response)
    }

    private func buildSuccessResult(fields: [String: String]) -> PaymentResult {
        // Parse receipts
        let dpValue = fields[TLVProtocol.Tags.DP]
        let merchantReceipt = dpValue.map { TLVProtocol.parseReceipt($0, type: .merchant) }
        let customerReceipt = dpValue.map { TLVProtocol.parseReceipt($0, type: .customer) }

        return PaymentResult(
            success: true,
            responseCode: fields[TLVProtocol.Tags.CR] ?? "000",
            stan: fields[TLVProtocol.Tags.STAN],
            maskedCardNumber: fields[TLVProtocol.Tags.NCAR],
            cardExpiry: fields[TLVProtocol.Tags.DAEX],
            cardholderName: fields[TLVProtocol.Tags.NPRT],
            entryMode: fields[TLVProtocol.Tags.EM],
            authNumber: fields[TLVProtocol.Tags.NA],
            ncai: fields[TLVProtocol.Tags.NCAI],
            sequence: fields[TLVProtocol.Tags.NS],
            transactionDate: fields[TLVProtocol.Tags.DATR],
            transactionTime: fields[TLVProtocol.Tags.HETR],
            merchantReceipt: merchantReceipt,
            customerReceipt: customerReceipt,
            error: nil
        )
    }

    private func buildFailedResult(responseCode: String, fields: [String: String]) -> PaymentResult {
        let errorMessage: String
        switch responseCode {
        case "909":
            errorMessage = "Terminal or server is down"
        case "302":
            errorMessage = "Transaction not found"
        case "482":
            errorMessage = "Transaction already cancelled"
        case "480":
            errorMessage = "Transaction cancelled"
        default:
            errorMessage = "Payment declined with code: \(responseCode)"
        }

        return PaymentResult(
            success: false,
            responseCode: responseCode,
            stan: fields[TLVProtocol.Tags.STAN],
            maskedCardNumber: nil,
            cardExpiry: nil,
            cardholderName: nil,
            entryMode: nil,
            authNumber: nil,
            ncai: nil,
            sequence: nil,
            transactionDate: nil,
            transactionTime: nil,
            merchantReceipt: nil,
            customerReceipt: nil,
            error: errorMessage
        )
    }
}
