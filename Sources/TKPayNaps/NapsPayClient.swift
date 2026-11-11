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
                return buildFailedResult(responseCode: responseCode, fields: paymentResponse)
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

            // Phase 2 must be a confirmation response (TM=102) with CR=000; a rejected
            // confirmation (e.g. CR=307 coherence failure) is not an approval.
            if let tm = confirmResponse[TLVProtocol.Tags.TM], tm != TLVProtocol.MessageTypes.confirmationResponse {
                throw NapsError.invalidResponse("Unexpected confirmation message type: \(tm)")
            }
            let confirmCode = confirmResponse[TLVProtocol.Tags.CR] ?? ""
            if confirmCode != "000" {
                return buildFailedResult(responseCode: confirmCode, fields: confirmResponse)
            }

            // Build successful result — merchant copy from Phase 1, customer copy from Phase 2
            return buildSuccessResult(phase1Fields: paymentResponse, fields: confirmResponse)

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
                error: responseCode != "000" ? settlementError(responseCode) : nil
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
    ///   2. Send TM=004 echoing the amount from MT=103 → terminal executes the
    ///      reversal and replies MT=104 (CR=000/480 = completed).
    ///      TM=103 CR=000 only means "transaction found", so a missing MT=104 reply
    ///      or CR=995 is returned as `pending` (not success): verify the void with
    ///      `duplicateReceipt` using the returned STAN.
    ///
    /// - Parameters:
    ///   - stan: STAN of the transaction to cancel
    ///   - registerId: Register ID (2 digits)
    ///   - cashierId: Cashier ID (5 digits)
    ///   - sequence: Sequence number (NS) of the payment to void, sent as NSA on TM=003.
    ///     The void itself gets a new NS, generated by the client and repeated on TM=004.
    ///   - amountCentimes: Original amount in centimes (required for v5.4.4+)
    public func cancelPayment(
        stan: String,
        registerId: String,
        cashierId: String,
        sequence: String,
        amountCentimes: Int? = nil
    ) async -> CancellationResult {
        let ncai = registerId + cashierId
        let voidSequence = generateSequence()
        let tlvRequest = TLVProtocol.buildCancellationRequest(
            stan: stan, ncai: ncai, ns: voidSequence, sequence: sequence, amountCentimes: amountCentimes)
        let connection = NapsConnection(config: config)

        do {
            try await connection.connect()

            // Phase 1: TM=003 → MT=103
            let response = try await connection.sendAndReceive(tlvRequest, timeout: config.timeout)
            let fields = TLVProtocol.parse(response)
            let responseCode = fields[TLVProtocol.Tags.CR] ?? ""
            let mt = fields[TLVProtocol.Tags.TM] ?? ""

            // MT=104 direct means already finalised (single-phase firmware)
            if mt == TLVProtocol.MessageTypes.cancellationConfirmationResponse {
                connection.disconnect()
                return cancellationOutcome(fields, originalStan: fields[TLVProtocol.Tags.STAN] ?? stan,
                                           merchantReceipt: nil)
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

            // Phase 2: TM=004 on the same connection, with the TM=003 NS and the
            // amount, currency and transaction date/time echoed from MT=103
            let confirmRequest = TLVProtocol.buildCancellationConfirmation(
                stan: fields[TLVProtocol.Tags.STAN] ?? stan,
                ncai: ncai,
                sequence: voidSequence,
                amount: fields[TLVProtocol.Tags.MT] ?? amountCentimes.map { String($0) },
                currency: fields[TLVProtocol.Tags.DE],
                datr: fields[TLVProtocol.Tags.DATR],
                hetr: fields[TLVProtocol.Tags.HETR]
            )
            let merchantReceipt = fields[TLVProtocol.Tags.DP].map { TLVProtocol.parseReceipt($0, type: .merchant) }
            let confirmResponse: String
            do {
                confirmResponse = try await connection.sendAndReceive(confirmRequest, timeout: config.confirmationTimeout)
            } catch let error as NapsError where error.code == .timeout {
                // TM=103 CR=000 only means "found"; TM=004 executes the reversal, so
                // without TM=104 the outcome is unknown — fail closed.
                connection.disconnect()
                return CancellationResult(
                    success: false,
                    responseCode: "",
                    stan: fields[TLVProtocol.Tags.STAN] ?? stan,
                    error: "Void unconfirmed: no TM=104 reply — verify with duplicate receipt",
                    merchantReceipt: merchantReceipt,
                    pending: true
                )
            }
            connection.disconnect()

            return cancellationOutcome(TLVProtocol.parse(confirmResponse),
                                       originalStan: fields[TLVProtocol.Tags.STAN] ?? stan,
                                       merchantReceipt: merchantReceipt)
        } catch {
            connection.disconnect()
            return CancellationResult(success: false, responseCode: "", stan: nil,
                                      error: error.localizedDescription)
        }
    }

    /// Map a TM=104 reply (spec §4.4): CR=000/480 = void completed; CR=995 (seen with
    /// completed voids on live terminals) = pending, keeping the original STAN for a
    /// duplicate-receipt check; anything else = failed.
    private func cancellationOutcome(_ fields: [String: String], originalStan: String,
                                     merchantReceipt: Receipt?) -> CancellationResult {
        let cr = fields[TLVProtocol.Tags.CR] ?? ""
        let customerReceipt = fields[TLVProtocol.Tags.DP].map { TLVProtocol.parseReceipt($0, type: .customer) }
        if cr == "000" || cr == "480" {
            return CancellationResult(success: true, responseCode: cr,
                                      stan: fields[TLVProtocol.Tags.STAN] ?? originalStan, error: nil,
                                      merchantReceipt: merchantReceipt, customerReceipt: customerReceipt)
        }
        if cr == "995" {
            return CancellationResult(success: false, responseCode: cr, stan: originalStan,
                                      error: "Void unconfirmed: code 995 — verify with duplicate receipt",
                                      merchantReceipt: merchantReceipt, customerReceipt: customerReceipt,
                                      pending: true)
        }
        return CancellationResult(success: false, responseCode: cr,
                                  stan: fields[TLVProtocol.Tags.STAN] ?? originalStan,
                                  error: "Cancellation failed with code: \(cr)",
                                  merchantReceipt: merchantReceipt, customerReceipt: customerReceipt)
    }

    /// Network test / ping (TM=009). Verifies the terminal can reach the NAPS host.
    public func networkTest(registerId: String = "01", cashierId: String = "00001") async throws -> NetworkTestResult {
        let fields = try await sendManagement(
            TLVProtocol.buildNetworkTestRequest(ncai: registerId + cashierId, sequence: generateSequence()))
        let rc = fields[TLVProtocol.Tags.CR] ?? ""
        return NetworkTestResult(
            success: rc == "000",
            responseCode: rc,
            message: rc == "000" ? "Network OK" : TLVProtocol.describeResponse(rc)
        )
    }

    /// Referencing (TM=013) — loads a terminal parameter set selected by TIDE (020).
    ///
    /// - Parameter tide: Parameter set: "01" merchant (default), "02" recharge
    public func referencing(
        tide: String = TLVProtocol.Tide.merchant,
        registerId: String = "01",
        cashierId: String = "00001"
    ) async throws -> ReferencingResult {
        let fields = try await sendManagement(
            TLVProtocol.buildReferencingRequest(tide: tide, ncai: registerId + cashierId, sequence: generateSequence()))
        let rc = fields[TLVProtocol.Tags.CR] ?? ""
        return ReferencingResult(
            success: rc == "000",
            responseCode: rc,
            parameterSet: tide,
            receiptText: fields[TLVProtocol.Tags.DP].map(TLVProtocol.maskCardNumbersInText),
            receipt: fields[TLVProtocol.Tags.DP].map { TLVProtocol.parseReceipt($0, type: .merchant) }
        )
    }

    /// Totals report (TM=010). Requests the terminal's running batch totals.
    public func totals(registerId: String = "01", cashierId: String = "00001") async throws -> TotalsResult {
        let fields = try await sendManagement(
            TLVProtocol.buildTotalsRequest(ncai: registerId + cashierId, sequence: generateSequence()))
        let rc = fields[TLVProtocol.Tags.CR] ?? ""
        return TotalsResult(success: rc == "000", responseCode: rc,
                            receiptText: fields[TLVProtocol.Tags.DP].map(TLVProtocol.maskCardNumbersInText),
                            receipt: fields[TLVProtocol.Tags.DP].map { TLVProtocol.parseReceipt($0, type: .merchant) })
    }

    /// Duplicate receipt / reprint (TM=008). Reprints the receipt of `stan`, or of the
    /// last transaction when omitted. Use it to verify a `pending` void.
    public func duplicateReceipt(registerId: String = "01", cashierId: String = "00001",
                                 stan: String? = nil) async throws -> PaymentResult {
        let fields = try await sendManagement(
            TLVProtocol.buildDuplicateReceiptRequest(ncai: registerId + cashierId, sequence: generateSequence(),
                                                     stan: stan))
        let rc = fields[TLVProtocol.Tags.CR] ?? ""
        guard rc == "000" else {
            return buildFailedResult(responseCode: rc, fields: fields)
        }
        let merchantReceipt = fields[TLVProtocol.Tags.DP].map { TLVProtocol.parseReceipt($0, type: .merchant) }
        return buildSuccessResult(fields: fields, merchantReceipt: merchantReceipt, customerReceipt: nil)
    }

    /// Reset the PIN pad (TM=012). Fire-and-forget maintenance command.
    public func resetPinPad(registerId: String = "01", cashierId: String = "00001") async throws {
        _ = try await sendManagement(
            TLVProtocol.buildResetPinPadRequest(ncai: registerId + cashierId, sequence: generateSequence()))
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
        if let sequence = request.sequence, sequence.count != 6 {
            throw NapsError(code: .invalidResponse, message: "Sequence must be 6 digits")
        }
    }

    /// Open a connection, send a single management TLV frame and parse the response.
    private func sendManagement(_ tlv: String) async throws -> [String: String] {
        let connection = NapsConnection(config: config)
        defer { connection.disconnect() }
        try await connection.connect()
        let response = try await connection.sendAndReceive(tlv, timeout: config.timeout)
        return TLVProtocol.parse(response)
    }

    private func settlementError(_ responseCode: String) -> String {
        switch responseCode {
        case "052": return "Already settled today"
        case "909": return "Terminal or server is down"
        default: return "Settlement failed with code: \(responseCode)"
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

    private func buildSuccessResult(phase1Fields: [String: String], fields: [String: String]) -> PaymentResult {
        // The terminal returns the merchant copy with Phase 1 (TM=101) and the
        // customer copy with Phase 2 (TM=102).
        let merchantReceipt = phase1Fields[TLVProtocol.Tags.DP].map { TLVProtocol.parseReceipt($0, type: .merchant) }
        let customerReceipt = fields[TLVProtocol.Tags.DP].map { TLVProtocol.parseReceipt($0, type: .customer) }
        return buildSuccessResult(fields: fields, merchantReceipt: merchantReceipt, customerReceipt: customerReceipt)
    }

    private func buildSuccessResult(
        fields: [String: String],
        merchantReceipt: Receipt?,
        customerReceipt: Receipt?
    ) -> PaymentResult {
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
        let errorMessage: String
        switch responseCode {
        case "909": errorMessage = "Terminal or server is down"
        case "302": errorMessage = "Transaction not found"
        case "482": errorMessage = "Transaction already cancelled"
        case "480": errorMessage = "Transaction cancelled"
        default:
            errorMessage = TLVProtocol.responseCodes[responseCode].map { "\($0) — code: \(responseCode)" }
                ?? "Payment declined — code: \(responseCode)"
        }

        // Declines may carry a printable refusal receipt (DP)
        let declineReceipt = fields[TLVProtocol.Tags.DP].map { TLVProtocol.parseReceipt($0, type: .merchant) }

        return PaymentResult(
            success: false,
            responseCode: responseCode,
            stan: fields[TLVProtocol.Tags.STAN],
            maskedCardNumber: fields[TLVProtocol.Tags.NCAR],
            cardExpiry: nil,
            cardholderName: nil,
            entryMode: nil,
            authNumber: nil,
            ncai: nil,
            sequence: nil,
            transactionDate: nil,
            transactionTime: nil,
            merchantReceipt: declineReceipt,
            customerReceipt: nil,
            error: errorMessage
        )
    }
}
