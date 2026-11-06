import XCTest
@testable import TKPayNaps

/// Integration tests against the TKpay NAPS emulator (tkpay-naps-emulator).
///
/// Skipped unless `NAPS_EMULATOR_PORT` is set, e.g.:
///   python3 naps_emulator.py --port 4455
///   NAPS_EMULATOR_PORT=4455 swift test --filter EmulatorIntegrationTests
final class EmulatorIntegrationTests: XCTestCase {

    private var client: NapsPayClient!

    override func setUpWithError() throws {
        guard let portString = ProcessInfo.processInfo.environment["NAPS_EMULATOR_PORT"],
              let port = Int(portString) else {
            throw XCTSkip("NAPS_EMULATOR_PORT not set")
        }
        client = NapsPayClient(config: NapsConfig(
            host: "127.0.0.1", port: port, timeout: 10, confirmationTimeout: 10))
    }

    func testApprovedPaymentTwoPhase() async throws {
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
        XCTAssertTrue(merchant.contains("Copie Commercant"), merchant)
        XCTAssertTrue(customer.contains("Copie Client"), customer)
    }

    func testSettlement() async {
        let result = await client.settlement(registerId: "01", cashierId: "00001")
        XCTAssertTrue(result.success, result.error ?? "")
    }

    func testNetworkTest() async throws {
        let result = try await client.networkTest()
        XCTAssertTrue(result.success, result.message)
        XCTAssertEqual(result.message, "Network OK")
    }

    func testReferencing() async throws {
        let result = try await client.referencing(tide: TLVProtocol.Tide.recharge)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.parameterSet, "02")
        XCTAssertNotNil(result.receiptText)
    }

    func testTotals() async throws {
        let result = try await client.totals()
        XCTAssertTrue(result.success)
        XCTAssertNotNil(result.receiptText)
    }

    func testDuplicateReceipt() async throws {
        let result = try await client.duplicateReceipt()
        XCTAssertTrue(result.isApproved, result.error ?? "")
        XCTAssertNotNil(result.merchantReceipt)
    }

    func testResetPinPad() async throws {
        try await client.resetPinPad()
    }
}
