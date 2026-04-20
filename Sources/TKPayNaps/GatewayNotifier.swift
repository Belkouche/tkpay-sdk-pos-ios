import Foundation

/// Transaction notification payload for TKPay gateway
public struct TransactionNotification: Codable {
    public let terminalHost: String
    public let amount: Double
    public let currency: String
    public let responseCode: String
    public let stan: String?
    public let authNumber: String?
    public let maskedCardNumber: String?
    public let cardExpiry: String?
    public let entryMode: String?
    public let cardholderName: String?
    public let ncai: String?
    public let registerId: String?
    public let cashierId: String?
    public let sequence: String?
    public let transactionDate: String?
    public let transactionTime: String?
    public let success: Bool
    public let errorMessage: String?
    public let sdkVersion: String
    public let platform: String
    public let timestamp: String

    enum CodingKeys: String, CodingKey {
        case terminalHost = "terminal_host"
        case amount
        case currency
        case responseCode = "response_code"
        case stan
        case authNumber = "auth_number"
        case maskedCardNumber = "masked_card_number"
        case cardExpiry = "card_expiry"
        case entryMode = "entry_mode"
        case cardholderName = "cardholder_name"
        case ncai
        case registerId = "register_id"
        case cashierId = "cashier_id"
        case sequence
        case transactionDate = "transaction_date"
        case transactionTime = "transaction_time"
        case success
        case errorMessage = "error_message"
        case sdkVersion = "sdk_version"
        case platform
        case timestamp
    }
}

/// Gateway notifier for sending transaction data to TKPay backend
internal class GatewayNotifier {

    /// SDK version
    private static let sdkVersion = "1.0.0"

    /// Gateway URL (static, not configurable)
    private static let gatewayURL = "https://api.tkpay.ma"

    /// Gateway endpoint for transaction notifications
    private static let notificationEndpoint = "/v1/transactions/notify"

    /// Send transaction notification to TKPay gateway
    /// This is fire-and-forget - errors are logged but don't affect the payment flow
    internal static func notifyTransaction(
        terminalHost: String,
        request: PaymentRequest,
        result: PaymentResult
    ) {
        let notification = TransactionNotification(
            terminalHost: terminalHost,
            amount: request.amount,
            currency: "MAD",
            responseCode: result.responseCode,
            stan: result.stan,
            authNumber: result.authNumber,
            maskedCardNumber: result.maskedCardNumber,
            cardExpiry: result.cardExpiry,
            entryMode: result.entryMode,
            cardholderName: result.cardholderName,
            ncai: result.ncai ?? request.ncai,
            registerId: request.registerId,
            cashierId: request.cashierId,
            sequence: result.sequence ?? request.sequence,
            transactionDate: result.transactionDate,
            transactionTime: result.transactionTime,
            success: result.success,
            errorMessage: result.error,
            sdkVersion: sdkVersion,
            platform: "ios",
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        // Send notification asynchronously (fire-and-forget)
        // Using detached task to ensure it doesn't block or propagate errors
        Task.detached(priority: .background) {
            await Self.sendNotification(notification: notification)
        }
    }

    /// Send the notification to the gateway
    /// This method is completely isolated and will never throw or block the caller
    private static func sendNotification(
        notification: TransactionNotification
    ) async {
        do {
            guard let url = URL(string: gatewayURL + notificationEndpoint) else {
                return // Silently fail
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("TKPayNaps-iOS/\(sdkVersion)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10 // 10 second timeout

            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(notification)

            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                #if DEBUG
                if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
                    print("[TKPayNaps] Transaction notification sent successfully")
                } else {
                    print("[TKPayNaps] Gateway returned status: \(httpResponse.statusCode)")
                }
                #endif
            }
        } catch {
            // Silently fail - never affect payment flow
            #if DEBUG
            print("[TKPayNaps] Failed to send notification: \(error.localizedDescription)")
            #endif
        }
    }
}
