import XCTest
@testable import TKPayNaps

final class TKPayNapsTests: XCTestCase {

    // MARK: - TLV Protocol Tests

    func testBuildField() {
        let field = TLVProtocol.buildField(tag: "001", value: "001")
        XCTAssertEqual(field, "001003001")
    }

    func testBuildFieldWithLongerValue() {
        let field = TLVProtocol.buildField(tag: "002", value: "10000")
        XCTAssertEqual(field, "00200510000")
    }

    func testParseTLV() {
        let tlv = "001003001002005100000030070100001"
        let fields = TLVProtocol.parse(tlv)

        XCTAssertEqual(fields["001"], "001")
        XCTAssertEqual(fields["002"], "10000")
        XCTAssertEqual(fields["003"], "0100001")
    }

    func testMaskCardNumber() {
        let masked = TLVProtocol.maskCardNumber("5167940123453315")
        XCTAssertEqual(masked, "516794******3315")
    }

    func testMaskCardNumberShort() {
        let masked = TLVProtocol.maskCardNumber("123456789")
        XCTAssertEqual(masked, "123456789") // Not masked - too short
    }

    func testMaskCardNumbersInText() {
        let text = "Card: 5167940123453315 was used"
        let masked = TLVProtocol.maskCardNumbersInText(text)
        XCTAssertEqual(masked, "Card: 516794******3315 was used")
    }

    // MARK: - Models Tests

    func testPaymentRequestNCAI() {
        let request = PaymentRequest(
            amount: 100.0,
            registerId: "01",
            cashierId: "00001"
        )
        XCTAssertEqual(request.ncai, "0100001")
    }

    func testPaymentResultIsApproved() {
        let result = PaymentResult(
            success: true,
            responseCode: "000",
            stan: "000001",
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
            error: nil
        )
        XCTAssertTrue(result.isApproved)
    }

    func testPaymentResultNotApproved() {
        let result = PaymentResult(
            success: false,
            responseCode: "909",
            stan: nil,
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
            error: "Terminal down"
        )
        XCTAssertFalse(result.isApproved)
    }

    func testFormattedExpiry() {
        let result = PaymentResult(
            success: true,
            responseCode: "000",
            stan: nil,
            maskedCardNumber: nil,
            cardExpiry: "2512",
            cardholderName: nil,
            entryMode: nil,
            authNumber: nil,
            ncai: nil,
            sequence: nil,
            transactionDate: nil,
            transactionTime: nil,
            merchantReceipt: nil,
            customerReceipt: nil,
            error: nil
        )
        XCTAssertEqual(result.formattedExpiry, "12/25")
    }

    // MARK: - Config Tests

    func testDefaultConfig() {
        let config = NapsConfig(host: "192.168.1.1")
        XCTAssertEqual(config.host, "192.168.1.1")
        XCTAssertEqual(config.port, 4444)
        XCTAssertEqual(config.timeout, 120)
        XCTAssertEqual(config.confirmationTimeout, 40)
    }

    func testCustomConfig() {
        let config = NapsConfig(
            host: "10.0.0.1",
            port: 5555,
            timeout: 60,
            confirmationTimeout: 30
        )
        XCTAssertEqual(config.host, "10.0.0.1")
        XCTAssertEqual(config.port, 5555)
        XCTAssertEqual(config.timeout, 60)
        XCTAssertEqual(config.confirmationTimeout, 30)
    }

    // MARK: - Receipt Tests

    func testReceiptToPlainText() {
        let lines = [
            ReceiptLine(lineNumber: "01", text: "TKPAY", bold: true, alignment: .center),
            ReceiptLine(lineNumber: "02", text: "Amount: 100.00", bold: false, alignment: .left)
        ]
        let receipt = Receipt(type: .merchant, lines: lines)
        let text = receipt.toPlainText(width: 20)

        XCTAssertTrue(text.contains("TKPAY"))
        XCTAssertTrue(text.contains("Amount: 100.00"))
    }
}
