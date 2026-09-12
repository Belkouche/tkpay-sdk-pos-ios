import Foundation

/// TLV Protocol implementation for NAPS Pay M2M
///
/// Tag-Length-Value format:
/// - TAG: 3 digits
/// - LENGTH: 3 digits
/// - VALUE: variable length
///
/// Example: 001003001 = Tag 001, Length 003, Value "001"
///
/// Tag mapping sourced from decompiled NAPS Pay v5.0.3
public enum TLVProtocol {

    // MARK: - Tags

    /// TLV Tag codes (3-digit numeric)
    /// Mapping verified against NAPS Pay v5.0.3
    public enum Tags {
        public static let TM   = "001"    // Message Type (3 chars)
        public static let MT   = "002"    // Amount (12 chars)
        public static let NCAI = "003"    // Terminal Number - Register(2) + Cashier(5) (7 chars)
        public static let NS   = "004"    // Sequence Number (6 chars)
        public static let NSA  = "005"    // Cancellation Sequence Number (6 chars)
        public static let NHC  = "006"    // Hostess Number (2 chars)
        public static let NCAR = "007"    // Card Number (masked) (16 chars)
        public static let STAN = "008"    // System Trace Audit Number (6 chars)
        public static let NA   = "009"    // Authorization Number (6 chars)
        public static let DP   = "010"    // Printable Data / Receipt (3500 chars)
        public static let CB   = "011"    // Barcode (100 chars)
        public static let DE   = "012"    // Currency Code (3 chars)
        public static let CR   = "013"    // Response Code (3 chars)
        public static let DA   = "014"    // Date (8 chars)
        public static let HE   = "015"    // Time (6 chars)
        public static let NPRT = "016"    // Cardholder Name (48 chars)
        public static let DAEX = "017"    // Expiration Date (4 chars, YYMM)
        public static let DATR = "018"    // Transaction Date (8 chars, DDMMYYYY)
        public static let HETR = "019"    // Transaction Time (6 chars, HHMMSS)
        public static let TIDE = "020"    // Ticket Type (2 chars)
        public static let TYPA = "021"    // Transaction Type (1 char)
        public static let RE   = "022"    // Receipt Data (256 chars)
        public static let RECB = "023"    // Receipt Copy (25 chars)
        public static let REQU = "024"    // Request Type (2 chars)
        public static let RESE = "025"    // Response Message (25 chars)
        public static let RECO = "026"    // Receipt Confirmation (25 chars)
        public static let RERA = "027"    // Response Reason (2 chars)
        public static let MDLC = "028"    // Model Code (3 chars)
        public static let EM   = "040"    // Entry Mode (3 chars)
    }

    /// Message Types
    public enum MessageTypes {
        public static let paymentRequest = "001"
        public static let paymentResponse = "101"
        public static let confirmationRequest = "002"
        public static let confirmationResponse = "102"
        public static let cancellationRequest = "003"
        public static let cancellationResponse = "103"
        public static let cancellationConfirmationRequest = "004"
        public static let cancellationCorrection = "104"
        public static let settlementRequest = "010"
        public static let settlementResponse = "110"
    }

    /// Receipt Sub-tags (within DP/010)
    public enum ReceiptTags {
        public static let lineNumber = "030"    // 2 chars
        public static let format = "031"        // S=Simple, G=Gras/Bold
        public static let alignment = "032"     // C=Center, D=Droite/Right, G=Gauche/Left
        public static let content = "033"       // Variable length
    }

    /// Currency Codes
    public enum Currency {
        public static let MAD = "504"  // Moroccan Dirham
    }

    // MARK: - Protocol Version

    /// NAPS TLV protocol version. Selects the expected response terminator:
    /// `!` for v2, `?` for v1. TCP/Sunmi terminals default to v2.
    public enum ProtocolVersion: Equatable {
        case v1
        case v2

        /// End-of-message terminator character emitted by the terminal for this version.
        public var terminator: Character {
            switch self {
            case .v1: return "?"
            case .v2: return "!"
            }
        }
    }

    // MARK: - Response Codes (§6)

    /// Response codes (CR / tag 013) that indicate an approval.
    public static let approvedCodes: Set<String> = ["000", "001", "003", "007"]

    /// CR (013) response codes from the v2 spec §6. Code 000 always means success;
    /// 001/003/007 are also approvals. All others describe a specific condition.
    public static let responseCodes: [String: String] = [
        "000": "Approved",
        "001": "Approved with identification",
        "003": "Approved (VIP)",
        "007": "Approved, microchip update required",
        "100": "Do not honour",
        "101": "Card expired",
        "102": "Fraud suspected",
        "104": "Restricted card use",
        "106": "Allowed PIN tries exceeded",
        "107": "Refer to card issuer",
        "108": "Refer to issuer special conditions",
        "109": "Invalid merchant",
        "110": "Invalid amount",
        "111": "Invalid card number",
        "112": "PIN information required",
        "114": "No account of requested type",
        "115": "Requested function not supported",
        "116": "Insufficient funds",
        "117": "Incorrect PIN",
        "118": "Card not registered",
        "119": "Transaction not permitted to cardholder",
        "120": "Transaction not permitted at terminal",
        "121": "Withdrawal limit exceeded",
        "122": "Security violation",
        "123": "Withdrawal frequency exceeded",
        "125": "Card not in service",
        "126": "Invalid PIN format",
        "127": "PIN length error",
        "128": "PIN key sync error",
        "129": "Card counterfeiting suspected",
        "180": "Credit account does not exist",
        "181": "Cheque account does not exist",
        "182": "Savings account does not exist",
        "183": "Invalid CVV",
        "184": "Invalid date",
        "200": "Do not honour — capture card",
        "201": "Card expired — capture card",
        "202": "Fraud suspected — capture card",
        "204": "Restricted card — capture card",
        "205": "Security service — capture card",
        "206": "PIN tries exceeded — capture card",
        "207": "Special conditions — capture card",
        "208": "Lost card — capture card",
        "209": "Stolen card — capture card",
        "210": "Counterfeiting suspected — capture card",
        "280": "Alternative amount cancelled",
        "299": "Capture card",
        "300": "Processing completed",
        "301": "Not supported by recipient",
        "302": "Record not found on file",
        "303": "Duplicate record, old record replaced",
        "304": "Field edit error",
        "305": "File locked",
        "306": "Processing failure",
        "307": "Format error",
        "308": "Duplicate processing, new record rejected",
        "309": "File unknown",
        "381": "Record not found. Account unsettled. Withdrawal not processed",
        "382": "Balance record deleted",
        "383": "Balance enquiry",
        "480": "Reversal accepted",
        "481": "Reversal incorrect",
        "482": "Transaction already cancelled",
        "501": "Reversal amount incorrect",
        "503": "Totals not available",
        "581": "Reconciliation complete",
        "582": "Reconciliation procedure not available",
        "700": "Top-ups fully reserved",
        "701": "Top-ups partially reserved",
        "702": "Top-ups not reserved",
        "750": "Message or ECR request not authorised by centre",
        "800": "Cut-off in progress",
        "880": "Connection not accepted",
        "902": "Invalid transaction",
        "908": "Transaction recipient not referenced for routing",
        "909": "System failure",
        "911": "Issuer did not respond in time",
        "912": "Card issuer unavailable",
        "992": "Issuer not found",
        "993": "PIN verification impossible",
        "994": "Transaction processing error",
        "995": "Server processing error",
    ]

    /// Human-readable description of a CR code, or a fallback string if unknown.
    public static func describeResponse(_ cr: String?) -> String {
        guard let cr = cr else { return "Unknown response code: (none)" }
        return responseCodes[cr] ?? "Unknown response code: \(cr)"
    }

    /// Whether a CR code indicates an approval.
    public static func isApproved(_ cr: String?) -> Bool {
        guard let cr = cr else { return false }
        return approvedCodes.contains(cr)
    }

    // MARK: - Building TLV

    /// Build TLV field
    public static func buildField(tag: String, value: String) -> String {
        let length = String(format: "%03d", value.count)
        return "\(tag)\(length)\(value)"
    }

    /// Build payment request TLV
    public static func buildPaymentRequest(
        amount: Double,
        ncai: String,
        sequence: String
    ) -> String {
        let amountMinor = String(Int(amount * 100))
        let dateTime = getCurrentDateTime()

        return buildField(tag: Tags.TM, value: MessageTypes.paymentRequest)
            + buildField(tag: Tags.MT, value: amountMinor)
            + buildField(tag: Tags.NCAI, value: ncai)
            + buildField(tag: Tags.NS, value: sequence)
            + buildField(tag: Tags.DE, value: Currency.MAD)
            + buildField(tag: Tags.DATR, value: dateTime.date)
            + buildField(tag: Tags.HETR, value: dateTime.time)
    }

    /// Build payment confirmation request TLV (TM=002).
    ///
    /// Per v2 spec §4.2 the confirmation carries, alongside TM/NCAI/NS/STAN/DA/HE:
    /// - MT (002) = amount in centimes, and DE (012) = currency, when an amount is given
    /// - NCAR (007) = masked PAN from the approved Payment Response (TM=101), when present
    /// - DAEX (017) = card expiry from the approved Payment Response, when present
    ///
    /// Field order mirrors the reference SDK: TM, NCAI, NS, [MT, DE], STAN, [NCAR], [DAEX], DA, HE.
    /// Optional args keep older callers working — omitted fields are simply not emitted.
    public static func buildConfirmationRequest(
        stan: String,
        ncai: String,
        sequence: String,
        amountCentimes: Int? = nil,
        currency: String = Currency.MAD,
        ncar: String? = nil,
        daex: String? = nil
    ) -> String {
        let dateTime = getCurrentDateTime()

        var msg = buildField(tag: Tags.TM, value: MessageTypes.confirmationRequest)
            + buildField(tag: Tags.NCAI, value: ncai)
            + buildField(tag: Tags.NS, value: sequence)

        if let amount = amountCentimes {
            msg += buildField(tag: Tags.MT, value: String(amount))
            msg += buildField(tag: Tags.DE, value: currency)
        }

        msg += buildField(tag: Tags.STAN, value: stan)

        if let ncar = ncar, !ncar.isEmpty {
            msg += buildField(tag: Tags.NCAR, value: ncar)
        }
        if let daex = daex, !daex.isEmpty {
            msg += buildField(tag: Tags.DAEX, value: daex)
        }

        msg += buildField(tag: Tags.DA, value: dateTime.date)
            + buildField(tag: Tags.HE, value: dateTime.time)

        return msg
    }

    /// Build cancellation request TLV (TM=003)
    ///
    /// NapsPay v5.4.4+ requires the original amount (TAG 002) in the frame.
    /// Pass `amountCentimes` when targeting v5.4.4+.
    public static func buildCancellationRequest(
        stan: String,
        ncai: String,
        sequence: String,
        amountCentimes: Int? = nil
    ) -> String {
        let dateTime = getCurrentDateTime()
        var msg = buildField(tag: Tags.TM, value: MessageTypes.cancellationRequest)
        if let amount = amountCentimes {
            msg += buildField(tag: Tags.MT, value: String(amount))
        }
        msg += buildField(tag: Tags.STAN, value: stan)
            + buildField(tag: Tags.NCAI, value: ncai)
            + buildField(tag: Tags.NSA, value: sequence)
            + buildField(tag: Tags.DA, value: dateTime.date)
            + buildField(tag: Tags.HE, value: dateTime.time)
        return msg
    }

    /// Build cancellation confirmation request TLV (TM=004)
    ///
    /// Sent on the same connection after receiving MT=103 from TM=003.
    /// `amount` must echo the amount (TAG 002, 12-digit) from the MT=103
    /// response — omitting it is refused with CR=909 on NapsPay v5.4.4+.
    public static func buildCancellationConfirmation(
        stan: String,
        ncai: String,
        sequence: String,
        amount: String? = nil
    ) -> String {
        let dateTime = getCurrentDateTime()
        var msg = buildField(tag: Tags.TM, value: MessageTypes.cancellationConfirmationRequest)
        if let amount = amount {
            msg += buildField(tag: Tags.MT, value: amount)
        }
        msg += buildField(tag: Tags.STAN, value: stan)
            + buildField(tag: Tags.NCAI, value: ncai)
            + buildField(tag: Tags.NS, value: sequence)
            + buildField(tag: Tags.DA, value: dateTime.date)
            + buildField(tag: Tags.HE, value: dateTime.time)
        return msg
    }

    /// Build settlement request TLV (TM=010 — telecollecte)
    public static func buildSettlementRequest(ncai: String) -> String {
        let dateTime = getCurrentDateTime()

        return buildField(tag: Tags.TM, value: MessageTypes.settlementRequest)
            + buildField(tag: Tags.NCAI, value: ncai)
            + buildField(tag: Tags.DA, value: dateTime.date)
            + buildField(tag: Tags.HE, value: dateTime.time)
    }

    // MARK: - Parsing TLV

    /// Parse TLV string into fields dictionary.
    ///
    /// Parsing stops at the first end-of-message terminator (`!` for v2, `?` for v1)
    /// so any receipt content or noise after it is ignored. Both terminators are
    /// accepted so the parser is protocol-version agnostic.
    public static func parse(_ tlvString: String) -> [String: String] {
        var fields: [String: String] = [:]

        // Truncate at the first terminator ('!' v2, '?' v1) if present.
        let body: Substring
        if let term = tlvString.firstIndex(where: { $0 == "!" || $0 == "?" }) {
            body = tlvString[tlvString.startIndex..<term]
        } else {
            body = tlvString[...]
        }
        let tlvString = String(body)

        var index = tlvString.startIndex

        while index < tlvString.endIndex {
            // Need at least 6 chars for tag + length
            guard tlvString.distance(from: index, to: tlvString.endIndex) >= 6 else { break }

            let tagEnd = tlvString.index(index, offsetBy: 3)
            let tag = String(tlvString[index..<tagEnd])

            let lengthEnd = tlvString.index(tagEnd, offsetBy: 3)
            let lengthStr = String(tlvString[tagEnd..<lengthEnd])

            // Validate length is numeric
            guard let length = Int(lengthStr) else { break }

            // Check if we have enough data for the value
            guard tlvString.distance(from: lengthEnd, to: tlvString.endIndex) >= length else { break }

            let valueEnd = tlvString.index(lengthEnd, offsetBy: length)
            var value = String(tlvString[lengthEnd..<valueEnd])

            // SECURITY: Immediately mask PAN in tag 007 (NCAR)
            if tag == Tags.NCAR {
                value = maskCardNumber(value)
            }

            fields[tag] = value
            index = valueEnd
        }

        return fields
    }

    // MARK: - Receipt Parsing

    /// Parse receipt data from DP tag value
    public static func parseReceipt(_ dpValue: String, type: ReceiptType) -> Receipt {
        var lines: [ReceiptLine] = []
        var index = dpValue.startIndex
        var lineNumber = ""
        var format = "S"
        var alignmentCode = "G"
        var content = ""

        while index < dpValue.endIndex {
            guard dpValue.distance(from: index, to: dpValue.endIndex) >= 6 else { break }

            let tagEnd = dpValue.index(index, offsetBy: 3)
            let tag = String(dpValue[index..<tagEnd])

            let lengthEnd = dpValue.index(tagEnd, offsetBy: 3)
            let lengthStr = String(dpValue[tagEnd..<lengthEnd])

            guard let length = Int(lengthStr) else { break }
            guard dpValue.distance(from: lengthEnd, to: dpValue.endIndex) >= length else { break }

            let valueEnd = dpValue.index(lengthEnd, offsetBy: length)
            let value = String(dpValue[lengthEnd..<valueEnd])

            switch tag {
            case ReceiptTags.lineNumber:
                // Save previous line if exists
                if !lineNumber.isEmpty && !content.isEmpty {
                    lines.append(createReceiptLine(lineNumber, content, format, alignmentCode))
                }
                lineNumber = value
                format = "S"
                alignmentCode = "G"
                content = ""
            case ReceiptTags.format:
                format = value
            case ReceiptTags.alignment:
                alignmentCode = value
            case ReceiptTags.content:
                content = value
            default:
                break
            }

            index = valueEnd
        }

        // Don't forget the last line
        if !lineNumber.isEmpty && !content.isEmpty {
            lines.append(createReceiptLine(lineNumber, content, format, alignmentCode))
        }

        // Apply TKPAY branding
        let brandedLines = applyBranding(lines)

        // Mask any card numbers in receipt
        let maskedLines = brandedLines.map { line in
            ReceiptLine(
                lineNumber: line.lineNumber,
                text: maskCardNumbersInText(line.text),
                bold: line.bold,
                alignment: line.alignment
            )
        }

        return Receipt(type: type, lines: maskedLines)
    }

    // MARK: - Security

    /// Mask card number to show only first 6 and last 4 digits
    /// Example: 5167940123453315 -> 516794******3315
    public static func maskCardNumber(_ cardNumber: String) -> String {
        guard cardNumber.count >= 10 else { return cardNumber }

        let first6 = String(cardNumber.prefix(6))
        let last4 = String(cardNumber.suffix(4))
        let masked = String(repeating: "*", count: cardNumber.count - 10)

        return "\(first6)\(masked)\(last4)"
    }

    /// Mask any 16-digit card numbers in text
    public static func maskCardNumbersInText(_ text: String) -> String {
        let pattern = "\\b\\d{16}\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        var result = text

        let matches = regex.matches(in: text, options: [], range: range)
        for match in matches.reversed() {
            if let matchRange = Range(match.range, in: result) {
                let cardNumber = String(result[matchRange])
                result.replaceSubrange(matchRange, with: maskCardNumber(cardNumber))
            }
        }

        return result
    }

    // MARK: - Private Helpers

    private static func getCurrentDateTime() -> (date: String, time: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        formatter.dateFormat = "ddMMyyyy"
        let date = formatter.string(from: Date())

        formatter.dateFormat = "HHmmss"
        let time = formatter.string(from: Date())

        return (date, time)
    }

    private static func createReceiptLine(
        _ lineNumber: String,
        _ content: String,
        _ format: String,
        _ alignmentCode: String
    ) -> ReceiptLine {
        let bold = format == "G"  // G = Gras (Bold)

        let alignment: Alignment
        switch alignmentCode {
        case "C":
            alignment = .center
        case "D":
            alignment = .right  // Droite
        default:
            alignment = .left   // Gauche
        }

        return ReceiptLine(
            lineNumber: lineNumber,
            text: content,
            bold: bold,
            alignment: alignment
        )
    }

    private static func applyBranding(_ lines: [ReceiptLine]) -> [ReceiptLine] {
        var result: [ReceiptLine] = []
        var brandingApplied = false

        for line in lines {
            if !brandingApplied &&
               line.text.lowercased().contains("naps") &&
               line.alignment == .center {

                // Replace with TKPAY header
                result.append(ReceiptLine(
                    lineNumber: line.lineNumber,
                    text: "TKPAY",
                    bold: true,
                    alignment: .center
                ))

                // Add "Powered by NAPS" below
                let nextLineNum = String(format: "%02d", (Int(line.lineNumber) ?? 0) + 1)
                result.append(ReceiptLine(
                    lineNumber: nextLineNum,
                    text: "Powered by NAPS",
                    bold: false,
                    alignment: .center
                ))

                brandingApplied = true
            } else {
                result.append(line)
            }
        }

        return result
    }
}
