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

            // Phase 2: Confirmation (must be on same connection, within 40 seconds).
            // v2 §4.2: thread MT + NCAR + DAEX from the Phase-1 (TM=101) response
            // so the terminal can reinforce its coherence checks. Prefer the amount
            // echoed by the terminal (MT); fall back to the requested amount.
            let confirmAmount = paymentResponse[TLVProtocol.Tags.MT].flatMap { Int($0) }
                ?? Int((request.amount * 100).rounded())
            let confirmResponse = try await sendConfirmation(
                connection: connection,
                stan: stan,
                ncai: ncai,
                sequence: sequence,
                amountCentimes: confirmAmount,
                ncar: paymentResponse[TLVProtocol.Tags.NCAR],
                daex: paymentResponse[TLVProtocol.Tags.DAEX]
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

    /// Force end-of-day settlement (telecollecte) — TM=010
    ///
    /// Sends batch totals to the NAPS server. The terminal must be idle
    /// ("Attente Caisse") and referencing must have run at least once.
    ///
    /// - Parameters:
    ///   - registerId: Register ID (2 digits, e.g., "01")
    ///   - cashierId: Cashier ID (5 digits, e.g., "00001")
    /// - Returns: SettlementResult with response code
    public func settlement(registerId: String, cashierId: String) async -> SettlementResult {
        let ncai = registerId + cashierId
        let tlvRequest = TLVProtocol.buildSettlementRequest(ncai: ncai)
        let connection = NapsConnection(config: config)

        do {
            try await connection.connect()
            let response = try await connection.sendAndReceive(tlvRequest, timeout: config.timeout)
            connection.disconnect()

            let fields = TLVProtocol.parse(response)
            let responseCode = fields[TLVProtocol.Tags.CR] ?? ""

            return SettlementResult(
                success: responseCode == "000",
                responseCode: responseCode,
                date: fields[TLVProtocol.Tags.DA],
                time: fields[TLVProtocol.Tags.HE],
                error: responseCode != "000" ? "Settlement failed with code: \(responseCode)" : nil
            )
        } catch {
            connection.disconnect()
            return SettlementResult(success: false, responseCode: "", date: nil, time: nil, error: error.localizedDescription)
        }
    }

    /// Cancel (void) a previous transaction — two-phase flow (TM=003 → TM=004)
    ///
    /// NapsPay v5.4.4+ requires the original amount (TAG 002) in the TM=003 frame.
    /// Flow on a single TCP connection:
    ///   1. Send TM=003 → terminal replies MT=103 (CR=000 = accepted)
    ///   2. Send TM=004 echoing the amount from MT=103 → terminal replies
    ///      MT=104 with the final result (CR=000/995 = success)
    ///
    /// - Parameters:
    ///   - stan: STAN of the transaction to cancel
    ///   - registerId: Register ID (2 digits)
    ///   - cashierId: Cashier ID (5 digits)
    ///   - sequence: Sequence number of the original transaction
    ///   - amountCentimes: Original amount in centimes (required for v5.4.4+)
    public func cancelPayment(
        stan: String,
        registerId: String,
        cashierId: String,
        sequence: String,
        amountCentimes: Int? = nil
    ) async -> CancellationResult {
        let ncai = registerId + cashierId
        let tlvRequest = TLVProtocol.buildCancellationRequest(
            stan: stan, ncai: ncai, sequence: sequence, amountCentimes: amountCentimes)
        let connection = NapsConnection(config: config)

        do {
            try await connection.connect()

            // Phase 1: TM=003 → MT=103
            let response = try await connection.sendAndReceive(tlvRequest, timeout: config.timeout)
            let fields = TLVProtocol.parse(response)
            let responseCode = fields[TLVProtocol.Tags.CR] ?? ""
            let mt = fields[TLVProtocol.Tags.TM] ?? ""

            // MT=104 direct means already finalised (single-phase firmware)
            if mt == TLVProtocol.MessageTypes.cancellationCorrection {
                connection.disconnect()
                return CancellationResult(
                    success: responseCode == "000",
                    responseCode: responseCode,
                    stan: fields[TLVProtocol.Tags.STAN],
                    error: responseCode == "000" ? nil : "Cancellation failed with code: \(responseCode)"
                )
            }

            guard mt == TLVProtocol.MessageTypes.cancellationResponse, responseCode == "000" else {
                connection.disconnect()
                return CancellationResult(
                    success: false,
                    responseCode: responseCode,
                    stan: fields[TLVProtocol.Tags.STAN],
                    error: "Cancellation failed with code: \(responseCode)"
                )
            }

            // Phase 2: TM=004 on the same connection, echoing the amount from MT=103
            let confirmRequest = TLVProtocol.buildCancellationConfirmation(
                stan: fields[TLVProtocol.Tags.STAN] ?? stan,
                ncai: ncai,
                sequence: sequence,
                amount: fields[TLVProtocol.Tags.MT]
            )
            let confirmResponse = try await connection.sendAndReceive(confirmRequest, timeout: config.confirmationTimeout)
            connection.disconnect()

            let fields2 = TLVProtocol.parse(confirmResponse)
            let cr2 = fields2[TLVProtocol.Tags.CR] ?? ""
            // CR=000 = confirmed, CR=995 = host processing (also success)
            let success2 = cr2 == "000" || cr2 == "995"

            return CancellationResult(
                success: success2,
                responseCode: cr2,
                stan: fields2[TLVProtocol.Tags.STAN] ?? fields[TLVProtocol.Tags.STAN],
                error: success2 ? nil : "Cancellation failed with code: \(cr2)"
            )
        } catch {
            connection.disconnect()
            return CancellationResult(success: false, responseCode: "", stan: nil,
                                      error: error.localizedDescription)
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
        sequence: String,
        amountCentimes: Int? = nil,
        ncar: String? = nil,
        daex: String? = nil
    ) async throws -> [String: String] {
        let tlvConfirm = TLVProtocol.buildConfirmationRequest(
            stan: stan,
            ncai: ncai,
            sequence: sequence,
            amountCentimes: amountCentimes,
            ncar: ncar,
            daex: daex
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
        // Use the §6 response-code table for a human-readable message; fall back
        // to a generic string for codes not in the table.
        let errorMessage = TLVProtocol.responseCodes[responseCode]
            ?? "Payment declined with code: \(responseCode)"

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
