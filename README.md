# TKPay NAPS iOS SDK

Native iOS SDK for integrating NAPS Pay terminals with your iOS applications.

## Requirements

- iOS 13.0+
- macOS 10.15+ (for development)
- Swift 5.5+
- Xcode 13.0+

## Installation

### Swift Package Manager

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Belkouche/tkpay-sdk-pos-naps-ios.git", from: "1.0.0")
]
```

Or in Xcode:
1. File → Add Packages...
2. Enter: `https://github.com/Belkouche/tkpay-sdk-pos-naps-ios.git`
3. Click "Add Package"

## Quick Start

```swift
import TKPayNaps

// Configure the client
let config = NapsConfig(host: "192.168.24.214")
let client = NapsPayClient(config: config)

// Process a payment
do {
    let result = try await client.processPayment(
        PaymentRequest(
            amount: 100.0,        // Amount in MAD
            registerId: "01",     // 2-digit register ID
            cashierId: "00001"    // 5-digit cashier ID
        )
    )

    if result.isApproved {
        print("Payment approved!")
        print("STAN: \(result.stan ?? "")")
        print("Card: \(result.maskedCardNumber ?? "")")
    } else {
        print("Payment failed: \(result.error ?? "")")
    }
} catch {
    print("Error: \(error)")
}
```

## Configuration

```swift
let config = NapsConfig(
    host: "192.168.24.214",    // Terminal IP address
    port: 4444,                // Default: 4444
    timeout: 120,              // Payment timeout in seconds (default: 120)
    confirmationTimeout: 40,   // Confirmation timeout in seconds (default: 40)
    protocolVersion: .v2       // TLV protocol version (default: .v2)
)
```

### Protocol version (v1 / v2)

The SDK speaks the NAPS TLV **v2** protocol by default (TCP/Sunmi terminals). The
version selects the expected response terminator — `!` for v2, `?` for v1 — and the
parser tolerates both. Set `protocolVersion: .v1` only when targeting a legacy
terminal that ends messages with `?`.

Under v2 the payment confirmation (TM=002) is enriched: it echoes the amount (MT/DE),
the masked PAN (NCAR) and the card expiry (DAEX) from the approved payment response so
the terminal can reinforce its coherence checks. This threading happens automatically
inside `processPayment`.

## API Reference

### NapsPayClient

The main client for interacting with NAPS Pay terminals.

#### Methods

##### `processPayment(_ request: PaymentRequest) async throws -> PaymentResult`

Process a payment transaction using the two-phase flow:
1. Send payment request → Customer taps card
2. Send confirmation → Transaction complete

```swift
let result = try await client.processPayment(request)
```

##### `testConnection() async -> Bool`

Test connectivity to the terminal.

```swift
let isConnected = await client.testConnection()
```

### PaymentRequest

```swift
let request = PaymentRequest(
    amount: 100.0,           // Amount in MAD
    registerId: "01",        // 2-digit register ID
    cashierId: "00001",      // 5-digit cashier ID
    sequence: nil            // Optional: auto-generated if not provided
)
```

### PaymentResult

```swift
struct PaymentResult {
    let success: Bool
    let responseCode: String?
    let stan: String?                  // System Trace Audit Number
    let maskedCardNumber: String?      // e.g., "516794******3315"
    let cardExpiry: String?            // YYMM format
    let cardholderName: String?
    let entryMode: String?
    let authNumber: String?
    let ncai: String?
    let sequence: String?
    let transactionDate: String?       // DDMMYYYY
    let transactionTime: String?       // HHMMSS
    let merchantReceipt: Receipt?
    let customerReceipt: Receipt?
    let error: String?

    var isApproved: Bool               // true if responseCode == "000"
    var formattedExpiry: String?       // MM/YY format
    var formattedCardNumber: String?   // Same as maskedCardNumber
}
```

### Receipt

```swift
struct Receipt {
    let type: ReceiptType              // .merchant or .customer
    let lines: [ReceiptLine]

    func toPlainText(width: Int = 32) -> String
}

struct ReceiptLine {
    let lineNumber: String
    let text: String
    let bold: Bool
    let alignment: Alignment           // .left, .center, .right
}
```

### NapsError

```swift
enum NapsErrorCode {
    case connectionFailed
    case timeout
    case invalidResponse
}

struct NapsError: Error {
    let code: NapsErrorCode
    let message: String
}
```

## Response Codes

The full v2 §6 response-code table is built into the SDK. Look up a human-readable
message for any CR code with `TLVProtocol.describeResponse(_:)`, and test for approval
with `TLVProtocol.isApproved(_:)` (approved codes: `000`, `001`, `003`, `007`).

```swift
TLVProtocol.describeResponse("116")   // "Insufficient funds"
TLVProtocol.isApproved("000")         // true
```

Common codes:

| Code | Description |
|------|-------------|
| 000  | Approved |
| 001  | Approved with identification |
| 003  | Approved (VIP) |
| 007  | Approved, microchip update required |
| 100  | Do not honour |
| 101  | Card expired |
| 116  | Insufficient funds |
| 117  | Incorrect PIN |
| 120  | Transaction not permitted at terminal |
| 280  | Alternative amount cancelled |
| 302  | Record not found on file |
| 307  | Format error |
| 480  | Reversal accepted |
| 482  | Transaction already cancelled |
| 909  | System failure |
| 911  | Issuer did not respond in time |
| 912  | Card issuer unavailable |
| 995  | Server processing error |

## Security

This SDK implements PCI-DSS compliant card number masking:
- Card numbers are masked immediately upon receipt (first 6 + last 4 digits visible)
- Full PANs are never stored or logged
- All card numbers in receipts are automatically masked

## Network Requirements

- The iOS device must be on the same network as the NAPS terminal
- Port 4444 must be accessible
- Add the following to your `Info.plist` for local network access:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Required to communicate with payment terminal</string>
<key>NSBonjourServices</key>
<array>
    <string>_tcp._tcp</string>
</array>
```

## Example App

See the `Example/` directory for a complete iOS app demonstrating SDK usage.

## TLV Protocol

The SDK implements the NAPS M2M TLV (Tag-Length-Value) protocol:

| Tag | Name | Description |
|-----|------|-------------|
| 001 | TM | Message Type |
| 002 | MT | Amount (minor units) |
| 003 | NCAI | Register(2) + Cashier(5) |
| 004 | NS | Sequence Number |
| 007 | NCAR | Card Number (masked) |
| 008 | STAN | System Trace Audit Number |
| 009 | NA | Authorization Number |
| 010 | DP | Print Data (Receipt) |
| 012 | DE | Currency Code |
| 013 | CR | Response Code |
| 014 | DV | Card Expiry |
| 015 | SH | Entry Mode |
| 016 | DT | Transaction Date |
| 017 | HT | Transaction Time |
| 018 | NC | Cardholder Name |

## License

MIT License - see LICENSE file for details.

## Support

For issues and questions, please visit:
https://github.com/Belkouche/tkpay-sdk-pos-naps-ios/issues
