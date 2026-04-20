/// TKPay NAPS SDK
///
/// iOS SDK for integrating NAPS Pay terminals with your applications.
///
/// ## Quick Start
///
/// ```swift
/// import TKPayNaps
///
/// let client = NapsPayClient(config: NapsConfig(host: "192.168.24.214"))
///
/// let result = try await client.processPayment(
///     PaymentRequest(amount: 100.0, registerId: "01", cashierId: "00001")
/// )
///
/// if result.isApproved {
///     print("STAN: \(result.stan ?? "")")
/// }
/// ```

// Re-export all public types
@_exported import Foundation
