import Foundation

// MARK: - Configuration

/// SDK Configuration
public struct NapsConfig {
    /// Terminal IP address
    public let host: String
    /// Terminal port (default: 4444)
    public let port: Int
    /// Request timeout in seconds (default: 120)
    public let timeout: TimeInterval
    /// Confirmation timeout in seconds (default: 40)
    public let confirmationTimeout: TimeInterval
    /// NAPS TLV protocol version (default: v2). Selects the expected response
    /// terminator: `!` for v2, `?` for v1. TCP/Sunmi terminals use v2.
    public let protocolVersion: TLVProtocol.ProtocolVersion

    public init(
        host: String,
        port: Int = 4444,
        timeout: TimeInterval = 120,
        confirmationTimeout: TimeInterval = 40,
        protocolVersion: TLVProtocol.ProtocolVersion = .v2
    ) {
        self.host = host
        self.port = port
        self.timeout = timeout
        self.confirmationTimeout = confirmationTimeout
        self.protocolVersion = protocolVersion
    }
}

// MARK: - Payment Request

/// Payment Request
public struct PaymentRequest {
    /// Amount in MAD (e.g., 100.00)
    public let amount: Double
    /// Register ID (2 digits, e.g., "01")
    public let registerId: String
    /// Cashier ID (5 digits, e.g., "00001")
    public let cashierId: String
    /// Optional sequence number (6 digits)
    public let sequence: String?

    public init(
        amount: Double,
        registerId: String,
        cashierId: String,
        sequence: String? = nil
    ) {
        self.amount = amount
        self.registerId = registerId
        self.cashierId = cashierId
        self.sequence = sequence
    }

    /// Get NCAI (register + cashier)
    public var ncai: String {
        return registerId + cashierId
    }
}

// MARK: - Payment Result

/// Payment Result
public struct PaymentResult {
    /// Whether payment was successful
    public let success: Bool
    /// Response code (000 = approved)
    public let responseCode: String
    /// System Trace Audit Number
    public let stan: String?
    /// Masked card number (e.g., 516794******3315)
    public let maskedCardNumber: String?
    /// Card expiry (YYMM)
    public let cardExpiry: String?
    /// Cardholder name
    public let cardholderName: String?
    /// Entry mode (e.g., "CTLS" for contactless)
    public let entryMode: String?
    /// Authorization number
    public let authNumber: String?
    /// NCAI (register + cashier)
    public let ncai: String?
    /// Sequence number
    public let sequence: String?
    /// Transaction date (DDMMYYYY)
    public let transactionDate: String?
    /// Transaction time (HHMMSS)
    public let transactionTime: String?
    /// Merchant receipt
    public let merchantReceipt: Receipt?
    /// Customer receipt
    public let customerReceipt: Receipt?
    /// Error message if failed
    public let error: String?

    /// Check if payment was approved
    public var isApproved: Bool {
        return success && responseCode == "000"
    }

    /// Get formatted card number for display
    public var formattedCardNumber: String? {
        return maskedCardNumber
    }

    /// Get formatted expiry for display (MM/YY)
    public var formattedExpiry: String? {
        guard let expiry = cardExpiry, expiry.count == 4 else { return nil }
        let yy = String(expiry.prefix(2))
        let mm = String(expiry.suffix(2))
        return "\(mm)/\(yy)"
    }
}

// MARK: - Receipt

/// Receipt type
public enum ReceiptType {
    case merchant
    case customer
}

/// Text alignment
public enum Alignment {
    case left
    case center
    case right
}

/// Receipt line
public struct ReceiptLine {
    /// Line number
    public let lineNumber: String
    /// Text content
    public let text: String
    /// Whether text is bold
    public let bold: Bool
    /// Text alignment
    public let alignment: Alignment
}

/// Receipt
public struct Receipt {
    /// Receipt type
    public let type: ReceiptType
    /// Receipt lines
    public let lines: [ReceiptLine]

    /// Convert receipt to plain text
    public func toPlainText(width: Int = 40) -> String {
        var result: [String] = []

        for line in lines {
            var text = line.text

            switch line.alignment {
            case .center:
                let padding = max(0, (width - text.count) / 2)
                text = String(repeating: " ", count: padding) + text
            case .right:
                let padding = max(0, width - text.count)
                text = String(repeating: " ", count: padding) + text
            case .left:
                break
            }

            result.append(text)
        }

        return result.joined(separator: "\n")
    }
}

// MARK: - Settlement Result

/// Settlement result for TM=010 (telecollecte)
public struct SettlementResult {
    /// Whether settlement was accepted by NAPS server
    public let success: Bool
    /// Response code (000 = success)
    public let responseCode: String
    /// Settlement date (DDMMYYYY)
    public let date: String?
    /// Settlement time (HHMMSS)
    public let time: String?
    /// Error message if settlement failed
    public let error: String?
}

// MARK: - Cancellation Result

/// Cancellation result for a void (TM=003 → 103, then TM=004 → 104)
public struct CancellationResult {
    /// Whether the void completed (TM=104 with CR=000 or 480)
    public let success: Bool
    /// Response code (000 = success)
    public let responseCode: String
    /// STAN echoed by the terminal (the void's STAN from TM=104 when available)
    public let stan: String?
    /// Error message if cancellation failed
    public let error: String?
    /// Merchant copy of the void receipt (DP of TM=103)
    public var merchantReceipt: Receipt? = nil
    /// Customer copy of the void receipt (DP of TM=104)
    public var customerReceipt: Receipt? = nil
    /// Void outcome unknown (no TM=104 reply, or CR=995): `success` is false; verify
    /// with `duplicateReceipt` using `stan` (the original transaction's STAN)
    public var pending: Bool = false
}

// MARK: - Management Results

/// Network test result for TM=009
public struct NetworkTestResult {
    /// Whether the terminal reached the NAPS host (RC=000)
    public let success: Bool
    /// Response code (000 = success)
    public let responseCode: String
    /// "Network OK" on success, otherwise the response-code description
    public let message: String
}

/// Referencing result for TM=013 (parameter-set load)
public struct ReferencingResult {
    /// Whether the parameter set was loaded (RC=000)
    public let success: Bool
    /// Response code (000 = success)
    public let responseCode: String
    /// TIDE parameter set requested ("01" merchant, "02" recharge)
    public let parameterSet: String
    /// Raw printable data (DP) returned by the terminal, if any
    public let receiptText: String?
}

/// Totals report result for TM=010
public struct TotalsResult {
    /// Whether the totals were returned (RC=000)
    public let success: Bool
    /// Response code (000 = success)
    public let responseCode: String
    /// Raw printable data (DP) returned by the terminal, if any
    public let receiptText: String?
}

// MARK: - Errors

/// Error codes
public enum NapsErrorCode: String {
    case connectionFailed = "CONNECTION_FAILED"
    case timeout = "TIMEOUT"
    case paymentDeclined = "PAYMENT_DECLINED"
    case invalidResponse = "INVALID_RESPONSE"
    case terminalDown = "TERMINAL_DOWN"
    case transactionNotFound = "TRANSACTION_NOT_FOUND"
    case alreadyCancelled = "ALREADY_CANCELLED"
    case unknownError = "UNKNOWN_ERROR"
}

/// NAPS Error
public struct NapsError: Error, LocalizedError {
    public let code: NapsErrorCode
    public let message: String

    public var errorDescription: String? {
        return message
    }

    public static func connectionFailed(_ message: String? = nil) -> NapsError {
        return NapsError(
            code: .connectionFailed,
            message: message ?? "Failed to connect to NAPS Pay terminal"
        )
    }

    public static func timeout() -> NapsError {
        return NapsError(code: .timeout, message: "Request timeout")
    }

    public static func invalidResponse(_ message: String) -> NapsError {
        return NapsError(code: .invalidResponse, message: message)
    }

    public static func terminalDown() -> NapsError {
        return NapsError(code: .terminalDown, message: "Terminal or server is down")
    }

    public static func transactionNotFound() -> NapsError {
        return NapsError(code: .transactionNotFound, message: "Transaction not found")
    }

    public static func alreadyCancelled() -> NapsError {
        return NapsError(code: .alreadyCancelled, message: "Transaction already cancelled")
    }
}
