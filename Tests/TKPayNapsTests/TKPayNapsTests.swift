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

        // Lines as sent (no rebranding, no added footer); full PAN masked, not blanked
        XCTAssertEqual(texts, ["Naps", "516794******3315", "Copie Client"])
        XCTAssertTrue(receipt.lines[0].bold)
        XCTAssertEqual(receipt.lines[0].alignment, .center)
        XCTAssertEqual(receipt.lines.last?.lineNumber, "24")
        XCTAssertEqual(receipt.lines.last?.alignment, .left)
    }

    /// Tags of a request frame, in order.
    private func tagOrder(_ frame: String) -> [String] {
        var tags: [String] = []
        var rest = Substring(frame)
        while rest.count >= 6, let length = Int(rest.dropFirst(3).prefix(3)) {
            tags.append(String(rest.prefix(3)))
            rest = rest.dropFirst(6 + length)
        }
        return tags
    }

    func testCancellationRequestFieldOrderAndSequences() {
        let frame = TLVProtocol.buildCancellationRequest(
            stan: "123456", ncai: "0100001", ns: "000042", sequence: "000321", amountCentimes: 15000)
        let T = TLVProtocol.Tags.self

        // Spec v2 §4.3: TM, NCAI, NS, DA, HE, DATR, HETR, STAN, MT, NSA
        XCTAssertEqual(tagOrder(frame), [T.TM, T.NCAI, T.NS, T.DA, T.HE, T.DATR, T.HETR, T.STAN, T.MT, T.NSA])
        let fields = TLVProtocol.parse(frame)
        XCTAssertEqual(fields[T.TM], TLVProtocol.MessageTypes.cancellationRequest)
        XCTAssertEqual(fields[T.NS], "000042")     // the void's own sequence
        XCTAssertEqual(fields[T.NSA], "000321")    // the payment's sequence
        XCTAssertEqual(fields[T.MT], "15000")
        XCTAssertEqual(fields[T.DATR], fields[T.DA])
        XCTAssertEqual(fields[T.HETR], fields[T.HE])
        XCTAssertFalse(frame.hasSuffix("!") || frame.hasSuffix("?"))

        // Without amount or payment sequence, MT and NSA are left out
        let bare = TLVProtocol.buildCancellationRequest(stan: "123456", ncai: "0100001", ns: "000042")
        XCTAssertEqual(tagOrder(bare), [T.TM, T.NCAI, T.NS, T.DA, T.HE, T.DATR, T.HETR, T.STAN])
    }

    func testCancellationConfirmationFieldOrder() {
        let frame = TLVProtocol.buildCancellationConfirmation(
            stan: "123456", ncai: "0100001", sequence: "000042", amount: "000000015000",
            currency: "504", datr: "10112026", hetr: "101500")
        let T = TLVProtocol.Tags.self

        // Spec v2 §4.4: TM, NCAI, NS, STAN, MT, DE, DATR, HETR, DA, HE — never NSA
        XCTAssertEqual(tagOrder(frame), [T.TM, T.NCAI, T.NS, T.STAN, T.MT, T.DE, T.DATR, T.HETR, T.DA, T.HE])
        let fields = TLVProtocol.parse(frame)
        XCTAssertEqual(fields[T.TM], TLVProtocol.MessageTypes.cancellationConfirmationRequest)
        XCTAssertEqual(fields[T.NS], "000042")
        XCTAssertEqual(fields[T.MT], "000000015000")   // echoed verbatim
        XCTAssertEqual(fields[T.DATR], "10112026")
        XCTAssertEqual(fields[T.HETR], "101500")
        XCTAssertNil(fields[T.NSA])
        XCTAssertFalse(frame.hasSuffix("!") || frame.hasSuffix("?"))

        // DE defaults to 504 with an amount; no amount means no MT/DE; no DATR/HETR when absent
        let noCurrency = TLVProtocol.parse(TLVProtocol.buildCancellationConfirmation(
            stan: "123456", ncai: "0100001", sequence: "000042", amount: "15000"))
        XCTAssertEqual(noCurrency[T.DE], "504")
        let bare = TLVProtocol.buildCancellationConfirmation(stan: "123456", ncai: "0100001", sequence: "000042")
        XCTAssertEqual(tagOrder(bare), [T.TM, T.NCAI, T.NS, T.STAN, T.DA, T.HE])
    }

    func testDuplicateReceiptRequestCanTargetStan() {
        let targeted = TLVProtocol.parse(TLVProtocol.buildDuplicateReceiptRequest(stan: "111111"))
        XCTAssertEqual(targeted[TLVProtocol.Tags.TM], TLVProtocol.MessageTypes.duplicateReceipt)
        XCTAssertEqual(targeted[TLVProtocol.Tags.STAN], "111111")
        XCTAssertNil(TLVProtocol.parse(TLVProtocol.buildDuplicateReceiptRequest())[TLVProtocol.Tags.STAN])
    }

    func testNegativeOrSignedLengthIsRejected() {
        // Int("-01") == -1 would move the cursor backwards (hang / crash)
        XCTAssertNil(TLVProtocol.tlvLength("-01"))
        XCTAssertNil(TLVProtocol.tlvLength("+01"))
        XCTAssertNil(TLVProtocol.tlvLength("1a3"))
        XCTAssertEqual(TLVProtocol.tlvLength("012"), 12)

        // Data that stops being TLV falls back to "ends with '!' or '?'"
        XCTAssertTrue(NapsConnection.isCompleteMessage(Data("001-01X!".utf8)))
        XCTAssertEqual(TLVProtocol.parse("001003101013-01X!"), ["001": "101"])
        // Terminators inside values are data; one between fields ends the frame
        XCTAssertEqual(TLVProtocol.parse("001003101010006Merci?013003000!008006999999"),
                       ["001": "101", "010": "Merci?", "013": "000"])
        XCTAssertEqual(TLVProtocol.parseReceipt("030-01X", type: .merchant).lines.map { $0.text }, [])
    }

    /// A DP block of `count` receipt lines, each "LINE nn" padded to 40 chars, with an
    /// optional extra line; lines are '*'-separated and the block ends with '?'.
    private func longDP(lines count: Int, extra: String? = nil) -> String {
        var texts = (1...count).map { "LINE \(String(format: "%02d", $0))".padding(toLength: 40, withPad: " ", startingAt: 0) }
        if let extra = extra { texts.append(extra) }
        return texts.enumerated().map { i, text in
            "030002" + String(format: "%02d", (i % 99) + 1) + "031001S032001G033" + String(format: "%03d", text.count) + text
        }.joined(separator: "*") + "?"
    }

    func testParseDPDeclared999RunsToItsEndMarker() {
        // Lane3600: a receipt longer than 999 chars is sent with length 999
        let dp = longDP(lines: 30, extra: "CARTE 5167940000123315")
        XCTAssertGreaterThan(dp.count, 999)
        let frame = "001003108" + "010999" + dp + "013003000" + "008006123456!"

        let fields = TLVProtocol.parse(frame)
        XCTAssertEqual(fields["001"], "108")
        XCTAssertEqual(fields["013"], "000")
        XCTAssertEqual(fields["008"], "123456")
        let parsedDP = try! XCTUnwrap(fields["010"])
        XCTAssertEqual(parsedDP.count, dp.count)          // whole block, '?' included
        XCTAssertTrue(parsedDP.hasSuffix("?"))
        let lines = TLVProtocol.parseReceipt(parsedDP, type: .merchant).lines.map { $0.text }
        XCTAssertEqual(lines.count, 31)
        XCTAssertEqual(lines.last, "CARTE 516794******3315")   // masked past the 999th char

        // maskFrame masks past the 999th char too and keeps the "999" header
        let masked = TLVProtocol.maskFrame(frame)
        XCTAssertTrue(masked.hasPrefix("001003108010999"))
        XCTAssertFalse(masked.contains("5167940000123315"))
        XCTAssertEqual(TLVProtocol.parse(masked)["013"], "000")

        // A DP declared 999 that is really 999 long (its '?' is the 999th char)
        let exact = "033992" + String(repeating: "x", count: 992) + "?"
        XCTAssertEqual(TLVProtocol.parse("001003101010999" + exact + "013003000!")["013"], "000")
    }

    func testParseKeepsFieldsAfterTerminatorsInsideReceipt() {
        let dp = "03000201031001S032001C033006Merci!*03000202031001S032001G033010A bientot??"
        let frame = "001003102" + TLVProtocol.buildField(tag: "010", value: dp) + "013003000" + "008006222222!"
        let fields = TLVProtocol.parse(frame)
        XCTAssertEqual(fields["013"], "000")
        XCTAssertEqual(fields["008"], "222222")
        XCTAssertEqual(TLVProtocol.parseReceipt(fields["010"] ?? "", type: .customer).lines.map { $0.text },
                       ["Merci!", "A bientot?"])
    }

    func testNonAsciiDigitsInHeadersStopTheWalkWithoutThrowing() {
        // Arabic-Indic, fullwidth and superscript digits are not header digits
        XCTAssertEqual(TLVProtocol.parse("001003101013\u{0660}\u{0660}\u{0663}000!"), ["001": "101"])
        XCTAssertEqual(TLVProtocol.parse("001003101013\u{FF10}\u{FF10}\u{FF13}000!"), ["001": "101"])
        XCTAssertEqual(TLVProtocol.parse("001003101\u{0660}13003000!"), ["001": "101"])
        XCTAssertEqual(TLVProtocol.parse("001003101013\u{00B9}23000!"), ["001": "101"])
        XCTAssertEqual(TLVProtocol.parse(""), [:])
        XCTAssertEqual(TLVProtocol.parse("010999030002"), [:])   // truncated DP 999: nothing, no crash
        XCTAssertEqual(TLVProtocol.parse("010999030\u{0660}02xx"), [:])
        XCTAssertEqual(TLVProtocol.maskFrame("001003101013\u{0660}\u{0660}\u{0663}000"),
                       "001003101013\u{0660}\u{0660}\u{0663}000")
    }

    func testCompleteMessageNeedsTerminatorOnFieldBoundary() {
        let dp = "03000201031001S032001C033006Merci!*03000202031001S032001G033010A bientot?*"
            + "03000203031001S032001G033004Fin.?"
        let reply = "001003104" + TLVProtocol.buildField(tag: "010", value: dp) + "013003000"
        // A read that stops right after the '!' or the '?' ending a receipt line is not complete
        for cut in ["Merci!", "A bientot?"] {
            let partial = String(reply[..<reply.range(of: cut)!.upperBound])
            XCTAssertFalse(NapsConnection.isCompleteMessage(Data(partial.utf8)), partial)
        }
        // Nor one that stops after the DP '?' end marker (the field boundary is past it)
        let afterDP = String(reply[..<reply.range(of: "Fin.?")!.upperBound])
        XCTAssertFalse(NapsConnection.isCompleteMessage(Data(afterDP.utf8)))
        XCTAssertTrue(NapsConnection.isCompleteMessage(Data((reply + "!").utf8)))
        XCTAssertTrue(NapsConnection.isCompleteMessage(Data((reply + "?").utf8)))

        // DP declared 999: complete only after its own end marker and the frame terminator
        let long = longDP(lines: 30)
        let frame = "001003108" + "010999" + long + "013003000"
        let lineCut = String(frame[..<frame.range(of: "LINE 25")!.upperBound])
        XCTAssertFalse(NapsConnection.isCompleteMessage(Data((lineCut + "?").utf8)))
        XCTAssertFalse(NapsConnection.isCompleteMessage(Data(("001003108010999" + long).utf8)))
        XCTAssertTrue(NapsConnection.isCompleteMessage(Data((frame + "!").utf8)))
    }

    func testTerminatorDetection() {
        XCTAssertTrue(NapsConnection.isCompleteMessage(Data("001003101!".utf8)))
        XCTAssertTrue(NapsConnection.isCompleteMessage(Data("001003101?".utf8)))
        XCTAssertFalse(NapsConnection.isCompleteMessage(Data("001003101".utf8)))
        XCTAssertFalse(NapsConnection.isCompleteMessage(Data()))
        // '!' inside a value, or at the end of a partial chunk, is not end-of-message
        XCTAssertFalse(NapsConnection.isCompleteMessage(Data("033010Merci!".utf8)))
        XCTAssertTrue(NapsConnection.isCompleteMessage(Data("033006Merci!!".utf8)))
        XCTAssertFalse(NapsConnection.isCompleteMessage(Data("033006Merci!013003000!".utf8).dropLast(4)))
    }
}
