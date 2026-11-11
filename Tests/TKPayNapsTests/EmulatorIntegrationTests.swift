import XCTest
@testable import TKPayNaps

/// Integration tests against the TKpay NAPS emulator (tkpay-naps-emulator).
///
/// Skipped unless `NAPS_EMULATOR_PORT` is set, e.g.:
///   python3 naps_emulator.py --port 4455
///   NAPS_EMULATOR_PORT=4455 swift test --filter EmulatorIntegrationTests
///
/// Set `NAPS_EMULATOR_MODE` (and `NAPS_EMULATOR_CODE`) to match the emulator's
/// `--mode` / `--code`; only the tests for that mode run (default: approve).
final class EmulatorIntegrationTests: XCTestCase {

    private var client: NapsPayClient!
    private var port = 0
    private let env = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        guard let portString = env["NAPS_EMULATOR_PORT"], let port = Int(portString) else {
            throw XCTSkip("NAPS_EMULATOR_PORT not set")
        }
        self.port = port
        client = NapsPayClient(config: NapsConfig(
            host: "127.0.0.1", port: port, timeout: 10, confirmationTimeout: 10))
    }

    private func requireMode(_ mode: String) throws {
        let current = env["NAPS_EMULATOR_MODE"] ?? "approve"
        guard current == mode else { throw XCTSkip("emulator mode is \(current), test needs \(mode)") }
    }

    private var code: String { env["NAPS_EMULATOR_CODE"] ?? "909" }

    private func pay() async throws -> PaymentResult {
        return try await client.processPayment(
            PaymentRequest(amount: 150.0, registerId: "01", cashierId: "00001"))
    }

    func testApprovedPaymentTwoPhase() async throws {
        try requireMode("approve")
        let start = Date()
        let result = try await client.processPayment(
            PaymentRequest(amount: 150.0, registerId: "01", cashierId: "00001"))

        XCTAssertTrue(result.isApproved, result.error ?? "")
        XCTAssertNotNil(result.stan)
        XCTAssertEqual(result.maskedCardNumber, "516794******3315")
        // Phase 1 must return as soon as the terminator arrives, not on timeout.
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        // Merchant copy comes from Phase 1, customer copy from Phase 2.
        let merchant = try XCTUnwrap(result.merchantReceipt).toPlainText()
        let customer = try XCTUnwrap(result.customerReceipt).toPlainText()
        XCTAssertTrue(merchant.contains("Copie Commerçant"), merchant)
        XCTAssertTrue(customer.contains("Copie Client"), customer)
    }

    func testSettlement() async throws {
        try requireMode("approve")
        let result = await client.settlement(registerId: "01", cashierId: "00001")
        XCTAssertTrue(result.success, result.error ?? "")
    }

    func testNetworkTest() async throws {
        try requireMode("approve")
        let result = try await client.networkTest()
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.responseCode, "UNSUPPORTED")
    }

    func testReferencing() async throws {
        try requireMode("approve")
        let result = try await client.referencing(tide: TLVProtocol.Tide.recharge)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.parameterSet, "02")
        XCTAssertNotNil(result.receiptText)
    }

    func testTotals() async throws {
        try requireMode("approve")
        let result = try await client.totals()
        XCTAssertTrue(result.success)
        XCTAssertNotNil(result.receiptText)
    }

    func testDuplicateReceipt() async throws {
        try requireMode("approve")
        let result = try await client.duplicateReceipt()
        XCTAssertTrue(result.isApproved, result.error ?? "")
        XCTAssertNotNil(result.merchantReceipt)
    }

    func testResetPinPad() async throws {
        try requireMode("approve")
        try await client.resetPinPad()
    }

    func testCancelTwoPhase() async throws {
        try requireMode("approve")
        let payment = try await client.processPayment(
            PaymentRequest(amount: 150.0, registerId: "01", cashierId: "00001", sequence: "000321"))
        let stan = try XCTUnwrap(payment.stan)

        let result = await client.cancelPayment(
            stan: stan, registerId: "01", cashierId: "00001", sequence: "000321", amountCentimes: 15000)

        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(result.responseCode, "000")
        XCTAssertNotNil(result.stan)
        XCTAssertNotEqual(result.stan, stan)   // void STAN from TM=104
        // Live terminals: TM 103 has no receipt; the TM 104 receipt is the merchant copy.
        XCTAssertTrue(result.merchantReceipt?.toPlainText().contains("Copie Commerçant") ?? false)
        XCTAssertNil(result.customerReceipt)
    }

    // MARK: - Receipts (spec §5: every DP line, in order, as sent)

    /// Asserts the emulator's receipt layout line by line; date, transaction and
    /// authorisation vary, the STAN must be `stan`.
    private func assertEmulatorReceipt(_ receipt: Receipt?, stan: String?, label: String, copy: String,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let receipt = try XCTUnwrap(receipt, "missing \(copy)", file: file, line: line)
        let lines = receipt.toPlainText().split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let stan = try XCTUnwrap(stan, file: file, line: line)
        let sep = "--------------------------------"
        let expected: [String] = [
            "TKpay", sep, "#date", "TKPAY DEMO", "CASABLANCA", sep, "VISA", "516794******3315",
            "Terminal: 00000001", "#Transaction: ", "#Autorisation: ", "STAN: \(stan)",
            sep, "MONTANT: 10.00 MAD", sep, label, copy,
        ]
        XCTAssertEqual(lines.count, expected.count, lines.joined(separator: "\n"), file: file, line: line)
        for (got, want) in zip(lines, expected) {
            if want == "#date" {
                XCTAssertNotNil(got.range(of: #"^\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression),
                                got, file: file, line: line)
            } else if want.hasPrefix("#") {
                let prefix = String(want.dropFirst())
                XCTAssertNotNil(got.range(of: "^\(prefix)\\d{6}$", options: .regularExpression), got, file: file, line: line)
            } else {
                XCTAssertEqual(got, want, file: file, line: line)
            }
        }
        XCTAssertTrue(receipt.lines[0].bold, file: file, line: line)
        XCTAssertEqual(receipt.lines[0].alignment, .center, file: file, line: line)
    }

    func testPaymentReceiptsBothCopies() async throws {
        try requireMode("approve")
        let result = try await client.processPayment(
            PaymentRequest(amount: 10.00, registerId: "01", cashierId: "00001"))
        XCTAssertTrue(result.isApproved, result.error ?? "")
        try assertEmulatorReceipt(result.merchantReceipt, stan: result.stan, label: "DEBIT", copy: "Copie Commerçant")
        try assertEmulatorReceipt(result.customerReceipt, stan: result.stan, label: "DEBIT", copy: "Copie Client")
        print("--- payment merchant copy\n\(result.merchantReceipt!.toPlainText())")
        print("--- payment customer copy\n\(result.customerReceipt!.toPlainText())")
    }

    func testVoidReceiptMerchantCopyFromTm104() async throws {
        try requireMode("approve")
        let payment = try await client.processPayment(
            PaymentRequest(amount: 10.00, registerId: "01", cashierId: "00001"))
        let stan = try XCTUnwrap(payment.stan)
        let result = await client.cancelPayment(
            stan: stan, registerId: "01", cashierId: "00001", sequence: "000322", amountCentimes: 1000)
        XCTAssertTrue(result.success, result.error ?? "")
        // Live terminals: TM 103 has no receipt; the TM 104 receipt (void STAN) is the merchant copy
        try assertEmulatorReceipt(result.merchantReceipt, stan: result.stan, label: "ANNULATION", copy: "Copie Commerçant")
        XCTAssertNil(result.customerReceipt)
        print("--- void merchant copy\n\(result.merchantReceipt!.toPlainText())")
    }

    // MARK: - Void modes (TM 103/104 arrive without a terminator)

    private func void(confirmationTimeout: TimeInterval = 10) async -> CancellationResult {
        let client = NapsPayClient(config: NapsConfig(
            host: "127.0.0.1", port: port, timeout: 10, confirmationTimeout: confirmationTimeout))
        return await client.cancelPayment(
            stan: "123456", registerId: "01", cashierId: "00001", sequence: "000321", amountCentimes: 15000)
    }

    func testVoid480Mode() async throws {
        try requireMode("void_480")
        let result = await void()
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertFalse(result.pending)
        XCTAssertEqual(result.responseCode, "480")
    }

    func testVoid995ModeIsPending() async throws {
        try requireMode("void_995")
        let result = await void()
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.pending)
        XCTAssertEqual(result.responseCode, "995")
        XCTAssertEqual(result.stan, "123456")   // TM 103 STAN kept for a TM 008 check
        XCTAssertNil(result.merchantReceipt)    // TM 103 carries no receipt on live terminals
    }

    func testVoidNoConfirmModeIsPending() async throws {
        try requireMode("void_no_confirm")
        let result = await void(confirmationTimeout: 2)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.pending)
        XCTAssertEqual(result.stan, "123456")
        XCTAssertNil(result.merchantReceipt)    // TM 103 carries no receipt on live terminals
    }

    func testVoidRefuseModeFails() async throws {
        try requireMode("void_refuse")
        let result = await void()
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.pending)
        XCTAssertEqual(result.responseCode, code)
    }

    // MARK: - Decline / error modes

    func testDeclineMode() async throws {
        try requireMode("decline")
        let result = try await pay()
        XCTAssertFalse(result.isApproved)
        XCTAssertEqual(result.responseCode, "100")
        XCTAssertEqual(result.error, "Do not honour — code: 100")
        XCTAssertTrue(result.merchantReceipt?.toPlainText().contains("REFUSEE") ?? false)
    }

    func testErrorMode() async throws {
        try requireMode("error")
        let result = try await pay()
        XCTAssertFalse(result.isApproved)
        XCTAssertEqual(result.responseCode, code)
        XCTAssertNotNil(result.error)
    }

    func testConfirmErrorMode() async throws {
        try requireMode("confirm_error")
        let result = try await pay()
        XCTAssertFalse(result.isApproved, "refused TM 102 must not be an approval")
        XCTAssertEqual(result.responseCode, code)
        XCTAssertNotNil(result.error)
    }

    func testNoConfirmModeTimesOut() async throws {
        try requireMode("no_confirm")
        let client = NapsPayClient(config: NapsConfig(
            host: "127.0.0.1", port: port, timeout: 10, confirmationTimeout: 2))
        do {
            _ = try await client.processPayment(PaymentRequest(amount: 150.0, registerId: "01", cashierId: "00001"))
            XCTFail("Expected confirmation timeout")
        } catch let error as NapsError {
            XCTAssertEqual(error.code, .timeout)
        }
    }

    func testTimeoutModeTimesOut() async throws {
        try requireMode("timeout")
        let client = NapsPayClient(config: NapsConfig(host: "127.0.0.1", port: port, timeout: 2))
        do {
            _ = try await client.processPayment(PaymentRequest(amount: 150.0, registerId: "01", cashierId: "00001"))
            XCTFail("Expected timeout")
        } catch let error as NapsError {
            XCTAssertEqual(error.code, .timeout)
        }
    }
}
