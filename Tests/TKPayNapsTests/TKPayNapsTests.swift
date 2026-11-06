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

    // MARK: - v2 Confirmation Tests

    func testConfirmationOmitsOptionalFieldsByDefault() {
        // Old callers (no amount/ncar/daex) must still produce a valid frame
        // without MT, DE, NCAR or DAEX.
        let msg = TLVProtocol.buildConfirmationRequest(
            stan: "123456", ncai: "0100001", sequence: "000001")
        let fields = TLVProtocol.parse(msg)

        XCTAssertEqual(fields[TLVProtocol.Tags.TM], TLVProtocol.MessageTypes.confirmationRequest)
        XCTAssertEqual(fields[TLVProtocol.Tags.STAN], "123456")
        XCTAssertEqual(fields[TLVProtocol.Tags.NCAI], "0100001")
        XCTAssertEqual(fields[TLVProtocol.Tags.NS], "000001")
        XCTAssertNil(fields[TLVProtocol.Tags.MT])
        XCTAssertNil(fields[TLVProtocol.Tags.DE])
        XCTAssertNil(fields[TLVProtocol.Tags.NCAR])
        XCTAssertNil(fields[TLVProtocol.Tags.DAEX])
    }

    func testConfirmationCarriesEnrichedFields() {
        let msg = TLVProtocol.buildConfirmationRequest(
            stan: "123456",
            ncai: "0100001",
            sequence: "000001",
            amountCentimes: 10000,
            ncar: "516794******3315",
            daex: "2512"
        )
        let fields = TLVProtocol.parse(msg)

        XCTAssertEqual(fields[TLVProtocol.Tags.MT], "10000")
        XCTAssertEqual(fields[TLVProtocol.Tags.DE], TLVProtocol.Currency.MAD)
        XCTAssertEqual(fields[TLVProtocol.Tags.STAN], "123456")
        XCTAssertEqual(fields[TLVProtocol.Tags.DAEX], "2512")
        // NCAR is re-masked by parse (tag 007), but an already-masked value round-trips.
        XCTAssertEqual(fields[TLVProtocol.Tags.NCAR], "516794******3315")
    }

    func testConfirmationFieldOrder() {
        // Field order must be TM, NCAI, NS, MT, DE, STAN, NCAR, DAEX, DA, HE.
        // Build the deterministic prefix (everything up to the trailing DA/HE, whose
        // values depend on wall-clock time) and assert the frame starts with it.
        let msg = TLVProtocol.buildConfirmationRequest(
            stan: "123456",
            ncai: "0100001",
            sequence: "000001",
            amountCentimes: 10000,
            ncar: "516794******3315",
            daex: "2512"
        )
        let expectedPrefix =
            TLVProtocol.buildField(tag: TLVProtocol.Tags.TM, value: TLVProtocol.MessageTypes.confirmationRequest)
            + TLVProtocol.buildField(tag: TLVProtocol.Tags.NCAI, value: "0100001")
            + TLVProtocol.buildField(tag: TLVProtocol.Tags.NS, value: "000001")
            + TLVProtocol.buildField(tag: TLVProtocol.Tags.MT, value: "10000")
            + TLVProtocol.buildField(tag: TLVProtocol.Tags.DE, value: TLVProtocol.Currency.MAD)
            + TLVProtocol.buildField(tag: TLVProtocol.Tags.STAN, value: "123456")
            + TLVProtocol.buildField(tag: TLVProtocol.Tags.NCAR, value: "516794******3315")
            + TLVProtocol.buildField(tag: TLVProtocol.Tags.DAEX, value: "2512")
        XCTAssertTrue(msg.hasPrefix(expectedPrefix), "Confirmation fields out of order.\nGot: \(msg)")
    }

    // MARK: - Terminator Tests

    func testParseStopsAtV2Terminator() {
        let tlv = "001003002008006123456RECEIPTGARBAGE!004006000001"
        let fields = TLVProtocol.parse(tlv)
        XCTAssertEqual(fields[TLVProtocol.Tags.TM], "002")
        XCTAssertEqual(fields[TLVProtocol.Tags.STAN], "123456")
        // Nothing after '!' should be parsed.
        XCTAssertNil(fields["004"])
    }

    func testParseStopsAtV1Terminator() {
        let tlv = "001003002008006123456?trailing"
        let fields = TLVProtocol.parse(tlv)
        XCTAssertEqual(fields[TLVProtocol.Tags.TM], "002")
        XCTAssertEqual(fields[TLVProtocol.Tags.STAN], "123456")
    }

    func testProtocolVersionTerminators() {
        XCTAssertEqual(TLVProtocol.ProtocolVersion.v2.terminator, "!")
        XCTAssertEqual(TLVProtocol.ProtocolVersion.v1.terminator, "?")
    }

    func testDefaultProtocolVersionIsV2() {
        let config = NapsConfig(host: "192.168.1.1")
        XCTAssertEqual(config.protocolVersion, .v2)
    }

    func testExplicitProtocolVersionOverride() {
        let config = NapsConfig(host: "192.168.1.1", protocolVersion: .v1)
        XCTAssertEqual(config.protocolVersion, .v1)
    }

    // MARK: - Response Code (§6) Tests

    func testDescribeKnownResponse() {
        XCTAssertEqual(TLVProtocol.describeResponse("000"), "Approved")
        XCTAssertEqual(TLVProtocol.describeResponse("116"), "Insufficient funds")
        XCTAssertEqual(TLVProtocol.describeResponse("480"), "Reversal accepted")
        XCTAssertEqual(TLVProtocol.describeResponse("995"), "Server processing error")
    }

    func testDescribeUnknownResponse() {
        XCTAssertEqual(TLVProtocol.describeResponse("777"), "Unknown response code: 777")
        XCTAssertEqual(TLVProtocol.describeResponse(nil), "Unknown response code: (none)")
    }

    func testApprovedCodes() {
        for code in ["000", "001", "003", "007"] {
            XCTAssertTrue(TLVProtocol.isApproved(code), "\(code) should be approved")
        }
        for code in ["100", "116", "480", "909"] {
            XCTAssertFalse(TLVProtocol.isApproved(code), "\(code) should not be approved")
        }
        XCTAssertFalse(TLVProtocol.isApproved(nil))
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

    // MARK: - v5.4.4 Sync Tests

    func testPaymentRequestCarriesDateTimeInBothTagPairs() {
        let fields = TLVProtocol.parse(
            TLVProtocol.buildPaymentRequest(amount: 150.0, ncai: "0100001", sequence: "000001"))

        XCTAssertEqual(fields[TLVProtocol.Tags.TM], TLVProtocol.MessageTypes.paymentRequest)
        XCTAssertEqual(fields[TLVProtocol.Tags.MT], "15000")
        XCTAssertEqual(fields[TLVProtocol.Tags.DE], TLVProtocol.Currency.MAD)
        XCTAssertEqual(fields[TLVProtocol.Tags.DA]?.count, 8)
        XCTAssertEqual(fields[TLVProtocol.Tags.HE]?.count, 6)
        XCTAssertEqual(fields[TLVProtocol.Tags.DATR], fields[TLVProtocol.Tags.DA])
        XCTAssertEqual(fields[TLVProtocol.Tags.HETR], fields[TLVProtocol.Tags.HE])
    }

    func testManagementRequests() {
        let cases: [(String, String)] = [
            (TLVProtocol.buildNetworkTestRequest(ncai: "0200002", sequence: "000042"), "009"),
            (TLVProtocol.buildTotalsRequest(ncai: "0200002", sequence: "000042"), "010"),
            (TLVProtocol.buildDuplicateReceiptRequest(ncai: "0200002", sequence: "000042"), "008"),
            (TLVProtocol.buildResetPinPadRequest(ncai: "0200002", sequence: "000042"), "012"),
            (TLVProtocol.buildReferencingRequest(ncai: "0200002", sequence: "000042"), "013"),
        ]
        for (msg, tm) in cases {
            let fields = TLVProtocol.parse(msg)
            XCTAssertEqual(fields[TLVProtocol.Tags.TM], tm)
            XCTAssertEqual(fields[TLVProtocol.Tags.NCAI], "0200002")
            XCTAssertEqual(fields[TLVProtocol.Tags.NS], "000042")
            XCTAssertNotNil(fields[TLVProtocol.Tags.DA])
            XCTAssertNotNil(fields[TLVProtocol.Tags.HE])
            XCTAssertNil(fields[TLVProtocol.Tags.MT])
        }
        XCTAssertTrue(TLVProtocol.buildManagementRequest(tm: "009").hasPrefix("001003009003007010000100400600000"))
    }

    func testReferencingCarriesTide() {
        XCTAssertEqual(TLVProtocol.parse(TLVProtocol.buildReferencingRequest())[TLVProtocol.Tags.TIDE], "01")
        let recharge = TLVProtocol.buildReferencingRequest(tide: TLVProtocol.Tide.recharge)
        XCTAssertEqual(TLVProtocol.parse(recharge)[TLVProtocol.Tags.TIDE], "02")
    }

    private func receiptLine(_ num: String, _ content: String, align: String = "G", style: String = "S") -> String {
        return "030002\(num)031001\(style)032001\(align)033" + String(format: "%03d", content.count) + content
    }

    func testParseReceiptSplitsOnEntrySeparator() {
        let dp = [
            receiptLine("00", "Naps", align: "C", style: "G"),
            receiptLine("10", "5167940300023315"),   // PAN containing "030002"
            receiptLine("24", "Copie Client"),
        ].joined(separator: "*")

        let receipt = TLVProtocol.parseReceipt(dp, type: .customer)
        let texts = receipt.lines.map { $0.text }

        XCTAssertEqual(texts, ["TKPAY", "516794******3315", "Copie Client", "Powered by NAPS"])
        XCTAssertTrue(receipt.lines[0].bold)
        XCTAssertEqual(receipt.lines[0].alignment, .center)
        XCTAssertEqual(receipt.lines.last?.lineNumber, "25")
        XCTAssertEqual(receipt.lines.last?.alignment, .center)
    }

    func testTerminatorDetection() {
        XCTAssertTrue(NapsConnection.endsWithTerminator(Data("001003101!".utf8)))
        XCTAssertTrue(NapsConnection.endsWithTerminator(Data("001003101?".utf8)))
        XCTAssertFalse(NapsConnection.endsWithTerminator(Data("001003101".utf8)))
        XCTAssertFalse(NapsConnection.endsWithTerminator(Data()))
    }
}
