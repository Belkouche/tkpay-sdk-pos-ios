import XCTest
@testable import TKPayNaps

/// Receipts parsed from DP blocks captured from the NAPS emulator (master, 10.00 MAD
/// payment then void). Spec §5: every line kept in order, as sent, PAN masked.
final class ReceiptGoldenTests: XCTestCase {

    // TM 101 (merchant copy) and TM 102 (customer copy) of the payment
    static let dp101 =
        "03000200031001G032001C033005TKpay"
        + "*03000202031001S032001G033032--------------------------------"
        + "*03000203031001S032001G03301907/11/2026 00:12:09"
        + "*03000204031001S032001G033010TKPAY DEMO"
        + "*03000206031001S032001G033010CASABLANCA"
        + "*03000207031001S032001G033032--------------------------------"
        + "*03000209031001S032001G033004VISA"
        + "*03000210031001S032001G033016516794******3315"
        + "*03000215031001S032001G033018Terminal: 00000001"
        + "*03000217031001S032001G033019Transaction: 514135"
        + "*03000218031001S032001G033020Autorisation: 820085"
        + "*03000219031001S032001G033012STAN: 514135"
        + "*03000220031001S032001G033032--------------------------------"
        + "*03000221031001S032001G033018MONTANT: 10.00 MAD"
        + "*03000222031001S032001G033032--------------------------------"
        + "*03000223031001S032001G033005DEBIT"
        + "*03000224031001S032001G033016Copie Commercant"
    static let dp102 =
        "03000200031001G032001C033005TKpay"
        + "*03000202031001S032001G033032--------------------------------"
        + "*03000203031001S032001G03301907/11/2026 00:12:10"
        + "*03000204031001S032001G033010TKPAY DEMO"
        + "*03000206031001S032001G033010CASABLANCA"
        + "*03000207031001S032001G033032--------------------------------"
        + "*03000209031001S032001G033004VISA"
        + "*03000210031001S032001G033016516794******3315"
        + "*03000215031001S032001G033018Terminal: 00000001"
        + "*03000217031001S032001G033019Transaction: 514135"
        + "*03000218031001S032001G033020Autorisation: 635927"
        + "*03000219031001S032001G033012STAN: 514135"
        + "*03000220031001S032001G033032--------------------------------"
        + "*03000221031001S032001G033018MONTANT: 10.00 MAD"
        + "*03000222031001S032001G033032--------------------------------"
        + "*03000223031001S032001G033005DEBIT"
        + "*03000224031001S032001G033012Copie Client"
    // TM 103 (merchant copy) and TM 104 (customer copy) of the void
    static let dp103 =
        "03000200031001G032001C033005TKpay"
        + "*03000202031001S032001G033032--------------------------------"
        + "*03000203031001S032001G03301907/11/2026 00:12:12"
        + "*03000204031001S032001G033010TKPAY DEMO"
        + "*03000206031001S032001G033010CASABLANCA"
        + "*03000207031001S032001G033032--------------------------------"
        + "*03000209031001S032001G033004VISA"
        + "*03000210031001S032001G033016516794******3315"
        + "*03000215031001S032001G033018Terminal: 00000001"
        + "*03000217031001S032001G033019Transaction: 514135"
        + "*03000218031001S032001G033020Autorisation: 378485"
        + "*03000219031001S032001G033012STAN: 514135"
        + "*03000220031001S032001G033032--------------------------------"
        + "*03000221031001S032001G033018MONTANT: 10.00 MAD"
        + "*03000222031001S032001G033032--------------------------------"
        + "*03000223031001S032001G033010ANNULATION"
        + "*03000224031001S032001G033016Copie Commercant"
    static let dp104 =
        "03000200031001G032001C033005TKpay"
        + "*03000202031001S032001G033032--------------------------------"
        + "*03000203031001S032001G03301907/11/2026 00:12:13"
        + "*03000204031001S032001G033010TKPAY DEMO"
        + "*03000206031001S032001G033010CASABLANCA"
        + "*03000207031001S032001G033032--------------------------------"
        + "*03000209031001S032001G033004VISA"
        + "*03000210031001S032001G033016516794******3315"
        + "*03000215031001S032001G033018Terminal: 00000001"
        + "*03000217031001S032001G033019Transaction: 208253"
        + "*03000218031001S032001G033020Autorisation: 108739"
        + "*03000219031001S032001G033012STAN: 208253"
        + "*03000220031001S032001G033032--------------------------------"
        + "*03000221031001S032001G033018MONTANT: 10.00 MAD"
        + "*03000222031001S032001G033032--------------------------------"
        + "*03000223031001S032001G033010ANNULATION"
        + "*03000224031001S032001G033012Copie Client"

    static func golden(stan: String, auth: String, date: String, label: String, copy: String) -> [String] {
        return [
            "TKpay",
            "--------------------------------",
            date,
            "TKPAY DEMO",
            "CASABLANCA",
            "--------------------------------",
            "VISA",
            "516794******3315",
            "Terminal: 00000001",
            "Transaction: \(stan)",
            "Autorisation: \(auth)",
            "STAN: \(stan)",
            "--------------------------------",
            "MONTANT: 10.00 MAD",
            "--------------------------------",
            label,
            copy,
        ]
    }

    private func trimmedLines(_ receipt: Receipt) -> [String] {
        return receipt.toPlainText().split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func testPaymentMerchantCopy() {
        let receipt = TLVProtocol.parseReceipt(Self.dp101, type: .merchant)
        XCTAssertEqual(trimmedLines(receipt), Self.golden(
            stan: "514135", auth: "820085", date: "07/11/2026 00:12:09", label: "DEBIT", copy: "Copie Commercant"))
    }

    func testPaymentCustomerCopy() {
        let receipt = TLVProtocol.parseReceipt(Self.dp102, type: .customer)
        XCTAssertEqual(trimmedLines(receipt), Self.golden(
            stan: "514135", auth: "635927", date: "07/11/2026 00:12:10", label: "DEBIT", copy: "Copie Client"))
    }

    func testVoidMerchantCopy() {
        let receipt = TLVProtocol.parseReceipt(Self.dp103, type: .merchant)
        XCTAssertEqual(trimmedLines(receipt), Self.golden(
            stan: "514135", auth: "378485", date: "07/11/2026 00:12:12", label: "ANNULATION", copy: "Copie Commercant"))
    }

    func testVoidCustomerCopy() {
        let receipt = TLVProtocol.parseReceipt(Self.dp104, type: .customer)
        XCTAssertEqual(trimmedLines(receipt), Self.golden(
            stan: "208253", auth: "108739", date: "07/11/2026 00:12:13", label: "ANNULATION", copy: "Copie Client"))
    }

    func testLineMetadataIsKept() {
        let lines = TLVProtocol.parseReceipt(Self.dp102, type: .customer).lines
        XCTAssertEqual(lines.map { $0.lineNumber },
                       ["00", "02", "03", "04", "06", "07", "09", "10", "15", "17", "18", "19", "20", "21", "22", "23", "24"])
        XCTAssertTrue(lines[0].bold)                      // 031 G
        XCTAssertEqual(lines[0].alignment, .center)       // 032 C
        XCTAssertTrue(lines.dropFirst().allSatisfy { !$0.bold && $0.alignment == .left })   // S / G
    }

    func testEndMarkerRightAlignmentAndFullPanMasking() {
        func line(_ n: String, _ text: String, _ style: String, _ align: String) -> String {
            return "030002\(n)031001\(style)032001\(align)033" + String(format: "%03d", text.count) + text
        }
        let dp = line("01", "TOTAL", "G", "D") + "*" + line("02", "Carte 5167940123453315", "S", "G")
            + "*" + line("03", "Merci?", "S", "C") + "?"
        let lines = TLVProtocol.parseReceipt(dp, type: .merchant).lines

        XCTAssertEqual(lines.map { $0.text }, ["TOTAL", "Carte 516794******3315", "Merci?"])
        XCTAssertEqual(lines.map { $0.alignment }, [.right, .left, .center])
        XCTAssertEqual(lines.map { $0.bold }, [true, false, false])
    }
}
