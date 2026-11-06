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
            let confirm = TLVProtocol.parse(terminal.requests[1])
            XCTAssertEqual(confirm[TLVProtocol.Tags.TM], "004")
            XCTAssertEqual(confirm[TLVProtocol.Tags.MT], "15000")
            XCTAssertEqual(confirm[TLVProtocol.Tags.NSA], "000321")
        }
    }

    func testVoidSucceedsWhenTM104NeverArrives() async throws {
        let r103 = f("001", "103") + f("013", "000") + f("008", "111111") + f("010", dp("ANNULATION")) + "!"
        try await withTerminal([[r103]]) { port, _ in
            let client = NapsPayClient(config: NapsConfig(
                host: "127.0.0.1", port: port, timeout: 10, confirmationTimeout: 1))
            let result = await client.cancelPayment(
                stan: "111111", registerId: "01", cashierId: "00001", sequence: "000321", amountCentimes: 15000)

            XCTAssertTrue(result.success, result.error ?? "")
            XCTAssertEqual(result.stan, "111111")
            XCTAssertNotNil(result.merchantReceipt)
            XCTAssertNil(result.customerReceipt)
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
