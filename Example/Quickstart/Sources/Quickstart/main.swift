import Foundation
import TKPayNaps

let port = Int(ProcessInfo.processInfo.environment["NAPS_PORT"] ?? "") ?? 4444
let client = NapsPayClient(config: NapsConfig(host: "127.0.0.1", port: port))

guard await client.testConnection() else {
    print("Terminal unreachable on 127.0.0.1:\(port)")
    exit(1)
}

let result = try await client.processPayment(
    PaymentRequest(amount: 150.00, registerId: "01", cashierId: "00001"))

if result.isApproved {
    print("Approved: STAN \(result.stan ?? "-"), card \(result.maskedCardNumber ?? "-")")
    print(result.customerReceipt?.toPlainText() ?? "(no receipt)")
} else {
    print("Not approved: CR \(result.responseCode), \(result.error ?? "")")
}
