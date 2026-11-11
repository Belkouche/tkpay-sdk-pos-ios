import XCTest
import Network
@testable import TKPayNaps

/// Scripted in-process terminal: answers each request with the next canned reply.
/// A reply is a list of chunks sent with a short gap between them.
private final class FakeTerminal {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake.terminal")
    private var replies: [[String]]
    private(set) var requests: [String] = []

    init(replies: [[String]]) throws {
        self.replies = replies
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            conn.start(queue: self.queue)
            self.serve(conn)
        }
    }

    func start() throws -> Int {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
            throw XCTSkip("Fake terminal listener did not start")
        }
        return Int(port.rawValue)
    }

    func stop() { listener.cancel() }

    private func serve(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, error == nil else { return }
            self.requests.append(String(decoding: data, as: UTF8.self))
            if !self.replies.isEmpty {
                self.send(self.replies.removeFirst(), on: conn)
            }
            if !isComplete { self.serve(conn) }
        }
    }

    private func send(_ chunks: [String], on conn: NWConnection) {
        guard let first = chunks.first else { return }
        conn.send(content: Data(first.utf8), completion: .contentProcessed { _ in })
        let rest = Array(chunks.dropFirst())
        if !rest.isEmpty {
            queue.asyncAfter(deadline: .now() + 0.2) { self.send(rest, on: conn) }
        }
    }
}

final class FakeTerminalTests: XCTestCase {

    private func f(_ tag: String, _ value: String) -> String {
        return TLVProtocol.buildField(tag: tag, value: value)
    }

    private func dp(_ content: String) -> String {
        return "03000200" + "031001S" + "032001G" + "033" + String(format: "%03d", content.count) + content
    }

    private func withTerminal(_ replies: [[String]], _ body: (Int, FakeTerminal) async throws -> Void) async throws {
        let terminal = try FakeTerminal(replies: replies)
        let port = try terminal.start()
        defer { terminal.stop() }
        try await body(port, terminal)
    }

    func testReadStopsAtTerminatorAcrossChunks() async throws {
        let reply = f("001", "110") + f("013", "000")
        try await withTerminal([[String(reply.prefix(5)), String(reply.dropFirst(5)) + "!"]]) { port, _ in
            let connection = NapsConnection(config: NapsConfig(host: "127.0.0.1", port: port, timeout: 10))
            try await connection.connect()
            defer { connection.disconnect() }

            let start = Date()
            let response = try await connection.sendAndReceive("001003010", timeout: 10)

            XCTAssertEqual(response, reply)   // terminator stripped, both chunks joined
            XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        }
    }

    func testReadFallsBackOnSilenceWithoutTerminator() async throws {
        let reply = f("001", "110") + f("013", "000")
        try await withTerminal([[reply]]) { port, _ in
            let connection = NapsConnection(config: NapsConfig(host: "127.0.0.1", port: port, timeout: 10))
            try await connection.connect()
            defer { connection.disconnect() }

            let start = Date()
            let response = try await connection.sendAndReceive("001003010", timeout: 10)

            XCTAssertEqual(response, reply)
            XCTAssertLessThan(Date().timeIntervalSince(start), 3.0)
        }
    }

    func testDeclinedPaymentCarriesCardAndReceipt() async throws {
        let phase1 = f("001", "101") + f("013", "116") + f("007", "5167940123453315")
            + f("008", "123456") + f("010", dp("TRANSACTION REFUSEE")) + "!"
        try await withTerminal([[phase1]]) { port, terminal in
            let client = NapsPayClient(config: NapsConfig(host: "127.0.0.1", port: port, timeout: 10))
            let result = try await client.processPayment(
                PaymentRequest(amount: 10, registerId: "01", cashierId: "00001"))

            XCTAssertFalse(result.success)
            XCTAssertEqual(result.responseCode, "116")
            XCTAssertEqual(result.maskedCardNumber, "516794******3315")
            XCTAssertEqual(result.stan, "123456")
            XCTAssertEqual(result.error, "Insufficient funds — code: 116")
            XCTAssertTrue(result.merchantReceipt?.toPlainText().contains("TRANSACTION REFUSEE") ?? false)
            XCTAssertEqual(terminal.requests.count, 1)   // no confirmation after a decline
        }
    }

    func testApprovedPaymentTakesReceiptsFromEachPhase() async throws {
        let phase1 = f("001", "101") + f("013", "000") + f("002", "1000") + f("007", "5167940123453315")
            + f("008", "654321") + f("017", "3010") + f("010", dp("Copie Commercant")) + "!"
        let phase2 = f("001", "102") + f("013", "000") + f("008", "654321") + f("009", "777777")
            + f("010", dp("Copie Client")) + "!"
        try await withTerminal([[phase1], [phase2]]) { port, terminal in
            let client = NapsPayClient(config: NapsConfig(host: "127.0.0.1", port: port, timeout: 10))
            let result = try await client.processPayment(
                PaymentRequest(amount: 10, registerId: "01", cashierId: "00001", sequence: "000007"))

            XCTAssertTrue(result.isApproved, result.error ?? "")
            XCTAssertEqual(result.authNumber, "777777")
            XCTAssertTrue(result.merchantReceipt?.toPlainText().contains("Copie Commercant") ?? false)
            XCTAssertTrue(result.customerReceipt?.toPlainText().contains("Copie Client") ?? false)

            // Phase 2 echoes MT/NCAR/DAEX on the same connection
            XCTAssertEqual(terminal.requests.count, 2)
            let confirm = TLVProtocol.parse(terminal.requests[1])
            XCTAssertEqual(confirm[TLVProtocol.Tags.TM], "002")
            XCTAssertEqual(confirm[TLVProtocol.Tags.NS], "000007")
            XCTAssertEqual(confirm[TLVProtocol.Tags.MT], "1000")
            XCTAssertEqual(confirm[TLVProtocol.Tags.STAN], "654321")
            XCTAssertEqual(confirm[TLVProtocol.Tags.DAEX], "3010")
        }
    }

    func testReadDoesNotStopAtTerminatorInsideValue() async throws {
        let reply = f("001", "110") + f("033", "Merci!") + f("013", "000")
        let split = reply.range(of: "!")!.upperBound
        try await withTerminal([[String(reply[..<split]), String(reply[split...]) + "!"]]) { port, _ in
            let connection = NapsConnection(config: NapsConfig(host: "127.0.0.1", port: port, timeout: 10))
            try await connection.connect()
            defer { connection.disconnect() }

            let response = try await connection.sendAndReceive("001003010", timeout: 10)
            XCTAssertEqual(response, reply)
        }
    }

    func testRejectedConfirmationIsNotApproved() async throws {
        let phase1 = f("001", "101") + f("013", "000") + f("008", "654321") + "!"
        let phase2 = f("001", "102") + f("013", "307") + f("008", "654321") + "!"
        try await withTerminal([[phase1], [phase2]]) { port, _ in
            let client = NapsPayClient(config: NapsConfig(host: "127.0.0.1", port: port, timeout: 10))
            let result = try await client.processPayment(
                PaymentRequest(amount: 10, registerId: "01", cashierId: "00001"))

            XCTAssertFalse(result.isApproved)
            XCTAssertEqual(result.responseCode, "307")
            XCTAssertEqual(result.error, "Format error — code: 307")
        }
    }

    func testTotalsReceiptTextIsPanMasked() async throws {
        let reply = f("001", "110") + f("013", "000") + f("010", dp("Carte 5167940123453315")) + "!"
        try await withTerminal([[reply]]) { port, _ in
            let client = NapsPayClient(config: NapsConfig(host: "127.0.0.1", port: port, timeout: 10))
            let result = try await client.totals()

            XCTAssertTrue(result.receiptText?.contains("516794******3315") ?? false, result.receiptText ?? "")
            XCTAssertFalse(result.receiptText?.contains("5167940123453315") ?? true)
        }
    }

    func testVoidTwoPhaseCarriesReceiptsAndVoidStan() async throws {
        let r103 = f("001", "103") + f("013", "000") + f("002", "15000") + f("008", "111111")
            + f("010", dp("ANNULATION Copie Commercant")) + "!"
        let r104 = f("001", "104") + f("013", "000") + f("008", "222222")
            + f("010", dp("ANNULATION Copie Client")) + "!"
        try await withTerminal([[r103], [r104]]) { port, terminal in
            let client = NapsPayClient(config: NapsConfig(host: "127.0.0.1", port: port, timeout: 10))
            let result = await client.cancelPayment(
                stan: "111111", registerId: "01", cashierId: "00001", sequence: "000321", amountCentimes: 15000)

            XCTAssertTrue(result.success, result.error ?? "")
            XCTAssertEqual(result.stan, "222222")   // void STAN from TM=104
            XCTAssertTrue(result.merchantReceipt?.toPlainText().contains("Copie Commercant") ?? false)
            XCTAssertTrue(result.customerReceipt?.toPlainText().contains("Copie Client") ?? false)

            XCTAssertEqual(terminal.requests.count, 2)
            let request = TLVProtocol.parse(terminal.requests[0])
            XCTAssertEqual(request[TLVProtocol.Tags.TM], "003")
            XCTAssertEqual(request[TLVProtocol.Tags.NSA], "000321")   // the payment's sequence
            let voidNS = try XCTUnwrap(request[TLVProtocol.Tags.NS])   // a new sequence for the void
            XCTAssertNotEqual(voidNS, "000321")
            let confirm = TLVProtocol.parse(terminal.requests[1])
            XCTAssertEqual(confirm[TLVProtocol.Tags.TM], "004")
            XCTAssertEqual(confirm[TLVProtocol.Tags.MT], "15000")
            XCTAssertEqual(confirm[TLVProtocol.Tags.DE], "504")
            XCTAssertEqual(confirm[TLVProtocol.Tags.NS], voidNS)   // same NS as TM=003
            XCTAssertNil(confirm[TLVProtocol.Tags.NSA])
            // TCP requests carry no '!' / '?' terminator
            for frame in terminal.requests {
                XCTAssertFalse(frame.hasSuffix("!") || frame.hasSuffix("?"), frame)
            }
            XCTAssertFalse(result.pending)
        }
    }

    func testVoidReceiptOnlyInTM104IsTheMerchantCopy() async throws {
        // Lane3600 / Sunmi P2: TM 103 carries no receipt; TM 104 carries the only one
        let r103 = f("001", "103") + f("013", "000") + f("002", "15000") + f("008", "111111") + "!"
        let r104 = f("001", "104") + f("013", "000") + f("008", "222222")
            + f("010", dp("ANNULATION Copie Commercant")) + "!"
        try await withTerminal([[r103], [r104]]) { port, _ in
            let client = NapsPayClient(config: NapsConfig(host: "127.0.0.1", port: port, timeout: 10))
            let result = await client.cancelPayment(
                stan: "111111", registerId: "01", cashierId: "00001", sequence: "000321", amountCentimes: 15000)

            XCTAssertTrue(result.success, result.error ?? "")
            XCTAssertEqual(result.merchantReceipt?.type, .merchant)
            XCTAssertTrue(result.merchantReceipt?.toPlainText().contains("Copie Commercant") ?? false)
            XCTAssertNil(result.customerReceipt)
        }
    }

    func testVoidIsPendingWhenTM104NeverArrives() async throws {
        let r103 = f("001", "103") + f("013", "000") + f("008", "111111") + f("010", dp("ANNULATION")) + "!"
        try await withTerminal([[r103]]) { port, _ in
            let client = NapsPayClient(config: NapsConfig(
                host: "127.0.0.1", port: port, timeout: 10, confirmationTimeout: 1))
            let result = await client.cancelPayment(
                stan: "111111", registerId: "01", cashierId: "00001", sequence: "000321", amountCentimes: 15000)

            XCTAssertFalse(result.success)
            XCTAssertTrue(result.pending)
            XCTAssertEqual(result.responseCode, "")
            XCTAssertEqual(result.stan, "111111")   // original STAN, for a TM=008 check
            XCTAssertNotNil(result.merchantReceipt)
            XCTAssertNil(result.customerReceipt)
            XCTAssertNotNil(result.error)
        }
    }

    private func void(tm104 cr: String) async throws -> CancellationResult {
        let r103 = f("001", "103") + f("013", "000") + f("002", "15000") + f("008", "111111")
            + f("010", dp("ANNULATION Copie Commercant")) + "!"
        let r104 = f("001", "104") + f("013", cr) + f("008", "222222") + "!"
        var result: CancellationResult?
        try await withTerminal([[r103], [r104]]) { port, _ in
            let client = NapsPayClient(config: NapsConfig(host: "127.0.0.1", port: port, timeout: 10))
            result = await client.cancelPayment(
                stan: "111111", registerId: "01", cashierId: "00001", sequence: "000321", amountCentimes: 15000)
        }
        return try XCTUnwrap(result)
    }

    func testVoidTM104Code480IsSuccess() async throws {
        let result = try await void(tm104: "480")
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertFalse(result.pending)
        XCTAssertEqual(result.responseCode, "480")
        XCTAssertEqual(result.stan, "222222")
    }

    func testVoidTM104Code995IsPending() async throws {
        let result = try await void(tm104: "995")
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.pending)
        XCTAssertEqual(result.responseCode, "995")
        XCTAssertEqual(result.stan, "111111")   // original STAN, for a TM=008 check
        XCTAssertNotNil(result.merchantReceipt)
    }

    func testVoidTM104OtherCodeIsFailure() async throws {
        let result = try await void(tm104: "482")
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.pending)
        XCTAssertEqual(result.responseCode, "482")
        XCTAssertEqual(result.error, "Cancellation failed with code: 482")
    }

    func testUnterminatedFrameKeepsDPEndMarker() async throws {
        // TM 103/104 arrive without a frame terminator; the DP value itself ends with
        // the spec §5 '?' end marker, which must not be stripped as a terminator.
        let r103 = f("001", "103") + f("013", "000") + f("002", "15000") + f("008", "111111")
        let r104 = f("001", "104") + f("013", "000") + f("008", "222222")
            + f("010", dp("ANNULATION") + "*03000224031001S032001G033012Copie Client?")
        try await withTerminal([[r103], [r104]]) { port, _ in
            let client = NapsPayClient(config: NapsConfig(host: "127.0.0.1", port: port, timeout: 10))
            let result = await client.cancelPayment(
                stan: "111111", registerId: "01", cashierId: "00001", sequence: "000321", amountCentimes: 15000)

            XCTAssertTrue(result.success, result.error ?? "")
            // TM 103 had no receipt, so the TM 104 receipt is the merchant copy
            XCTAssertEqual(result.merchantReceipt?.lines.map { $0.text }, ["ANNULATION", "Copie Client"])
            XCTAssertNil(result.customerReceipt)
        }
    }

    // MARK: - Card number masking

    private static let pan = "5167940000123315"
    private static let pan19 = "6012345678901234567"

    /// Fails if `text` contains a full card number, with or without spaces/dashes.
    private func assertNoFullPan(_ text: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let compact = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        XCTAssertFalse(compact.contains(Self.pan), "full PAN in \(what): \(text)", file: file, line: line)
        XCTAssertFalse(compact.contains(Self.pan19), "full 19-digit number in \(what): \(text)", file: file, line: line)
    }

    private final class CapturedOutput {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    /// Captures everything written to stdout/stderr while `body` runs.
    private func captureOutput(_ body: () async throws -> Void) async throws -> String {
        let pipe = Pipe()
        let savedOut = dup(STDOUT_FILENO), savedErr = dup(STDERR_FILENO)
        let captured = CapturedOutput()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            captured.append(handle.availableData)
        }
        fflush(stdout); fflush(stderr)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        defer {
            fflush(stdout); fflush(stderr)
            dup2(savedOut, STDOUT_FILENO); dup2(savedErr, STDERR_FILENO)
            close(savedOut); close(savedErr)
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        try await body()
        try await Task.sleep(nanoseconds: 2_000_000_000)   // let background logging finish
        fflush(stdout); fflush(stderr)
        try await Task.sleep(nanoseconds: 200_000_000)   // drain the pipe
        return captured.text
    }

    private func dpLines(_ lines: [String]) -> String {
        return lines.enumerated().map { i, text in
            "030002" + String(format: "%02d", i) + "031001S032001G033" + String(format: "%03d", text.count) + text
        }.joined(separator: "*")
    }

    func testMaskCardNumbersInTextCoversLengthsAndSeparators() {
        // Shared rule across the NAPS SDKs
        let vectors: [(String, String)] = [
            ("5167940000123315", "516794******3315"),
            ("5167 9400 0012 3315", "5167 94** **** 3315"),
            ("5167-9400-0012-3315", "5167-94**-****-3315"),
            ("5167.9400.0012.3315", "5167.94**.****.3315"),
            ("6011000990139424127", "601100*********4127"),
            ("5167 9400 0012 3315 0000", "5167 94** **** **** 0000"),
            ("07/11/2026 00:12:10", "07/11/2026 00:12:10"),
            ("MONTANT: 10.00 MAD", "MONTANT: 10.00 MAD"),
            ("Terminal: 00000001", "Terminal: 00000001"),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(TLVProtocol.maskCardNumbersInText(input), expected, input)
        }
        // Tab and non-breaking space separate; two separators in a row do not
        XCTAssertEqual(TLVProtocol.maskCardNumbersInText("5167\t9400\t0012\t3315"), "5167\t94**\t****\t3315")
        XCTAssertEqual(TLVProtocol.maskCardNumbersInText("5167\u{00A0}9400\u{00A0}0012\u{00A0}3315"),
                       "5167\u{00A0}94**\u{00A0}****\u{00A0}3315")
        XCTAssertEqual(TLVProtocol.maskCardNumbersInText("516794  0000123315"), "516794  0000123315")
        // Left alone: amounts, short runs, already-masked numbers; text around a run kept
        for untouched in ["1 250,00 MAD", "123456789012", "STAN: 514135", "Autorisation: 820085",
                          "516794******3315"] {
            XCTAssertEqual(TLVProtocol.maskCardNumbersInText(untouched), untouched)
        }
        XCTAssertEqual(TLVProtocol.maskCardNumbersInText("Ref " + Self.pan19), "Ref 601234*********4567")

        // Tag 007: first 6 + '*' + last 4, whatever the grouping
        XCTAssertEqual(TLVProtocol.maskCardNumber(Self.pan), "516794******3315")
        XCTAssertEqual(TLVProtocol.maskCardNumber("5167 9400 0012 3315"), "516794******3315")
        XCTAssertEqual(TLVProtocol.maskCardNumber("5167-9400-0012-3315"), "516794******3315")
        XCTAssertEqual(TLVProtocol.maskCardNumber("516794******3315"), "516794******3315")
        XCTAssertEqual(TLVProtocol.parse(TLVProtocol.maskFrame(f("001", "101") + f("007", "5167 9400 0012 3315")
            + f("013", "000")))[TLVProtocol.Tags.NCAR], "516794******3315")   // length field rewritten
    }

    func testFullPanNeverLeavesTheParser() async throws {
        let receiptText = ["TKpay", "VISA", Self.pan, "Carte 5167 9400 0012 3315", "Ref " + Self.pan19, "Copie Client"]
        let maskedText = ["TKpay", "VISA", "516794******3315", "Carte 5167 94** **** 3315", "Ref 601234*********4567", "Copie Client"]
        let phase1 = f("001", "101") + f("013", "000") + f("002", "1000") + f("007", Self.pan) + f("008", "654321")
            + f("017", "3010") + f("010", dpLines(receiptText)) + "!"
        let phase2 = f("001", "102") + f("013", "000") + f("007", Self.pan) + f("008", "654321") + f("009", "777777")
            + f("010", dpLines(receiptText)) + "!"
        let declined = f("001", "101") + f("013", "116") + f("007", Self.pan) + f("010", dpLines(receiptText)) + "!"
        let totals = f("001", "110") + f("013", "000") + f("010", dpLines(receiptText)) + "!"

        try await withTerminal([[phase1], [phase2], [declined], [totals], [phase1]]) { port, terminal in
            let config = NapsConfig(host: "127.0.0.1", port: port, timeout: 10)
            let client = NapsPayClient(config: config)
            var dumps: [String] = []

            let output = try await captureOutput {
                print("capture-check")
                let approved = try await client.processPayment(
                    PaymentRequest(amount: 10, registerId: "01", cashierId: "00001"))
                XCTAssertTrue(approved.isApproved, approved.error ?? "")
                XCTAssertEqual(approved.maskedCardNumber, "516794******3315")
                XCTAssertEqual(approved.merchantReceipt?.lines.map { $0.text }, maskedText)
                XCTAssertEqual(approved.customerReceipt?.lines.map { $0.text }, maskedText)
                dumps.append(String(reflecting: approved))

                let decline = try await client.processPayment(
                    PaymentRequest(amount: 10, registerId: "01", cashierId: "00001"))
                XCTAssertFalse(decline.success)
                XCTAssertEqual(decline.merchantReceipt?.lines.map { $0.text }, maskedText)
                dumps.append(String(reflecting: decline))
                dumps.append(decline.error ?? "")

                let report = try await client.totals()
                XCTAssertEqual(report.receipt?.lines.map { $0.text }, maskedText)
                dumps.append(String(reflecting: report))

                // The raw reply from the public connection API is masked too
                let connection = NapsConnection(config: config)
                try await connection.connect()
                let raw = try await connection.sendAndReceive("001003001", timeout: 10)
                connection.disconnect()
                XCTAssertEqual(TLVProtocol.parse(raw)[TLVProtocol.Tags.NCAR], "516794******3315")
                dumps.append(raw)
            }

            for (i, dump) in dumps.enumerated() { assertNoFullPan(dump, "result \(i)") }
            for (i, request) in terminal.requests.enumerated() { assertNoFullPan(request, "request frame \(i)") }
            XCTAssertEqual(TLVProtocol.parse(terminal.requests[1])[TLVProtocol.Tags.NCAR], "516794******3315")
            XCTAssertTrue(output.contains("capture-check"), "output capture is not working")
            assertNoFullPan(output, "captured stdout/stderr")
        }
    }

    func testRejectsInvalidSequenceLength() async {
        let client = NapsPayClient(config: NapsConfig(host: "127.0.0.1", port: 1))
        do {
            _ = try await client.processPayment(
                PaymentRequest(amount: 10, registerId: "01", cashierId: "00001", sequence: "123"))
            XCTFail("Expected validation error")
        } catch let error as NapsError {
            XCTAssertEqual(error.message, "Sequence must be 6 digits")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
