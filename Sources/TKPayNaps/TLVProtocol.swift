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
/// Tag mapping sourced from decompiled NAPS Pay v5.0.3; protocol baseline is
/// TLV Protocol Specification v2.0 / NapsPay v5.4.4.
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
        public static let cancellationConfirmationResponse = "104"
        @available(*, deprecated, renamed: "cancellationConfirmationResponse")
        public static let cancellationCorrection = "104"
        public static let settlementRequest = "010"
        public static let settlementResponse = "110"
        public static let duplicateReceipt = "008"     // Reprint last receipt
        public static let networkTest = "009"          // Ping / network test
        public static let totals = "010"               // Totals report (shares TM with settlement)
        public static let resetPinPad = "012"          // Reset the PIN pad
        public static let referencing = "013"          // Load parameter set (referencement)
    }

    /// TIDE (020) parameter sets for referencing (TM=013)
    public enum Tide {
        public static let merchant = "01"
        public static let recharge = "02"
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

    /// Build payment request TLV (TM=001).
    /// Sends the current date/time in both DA/HE (local clock) and DATR/HETR (transaction).
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
            + buildField(tag: Tags.DA, value: dateTime.date)
            + buildField(tag: Tags.HE, value: dateTime.time)
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

    /// Build cancellation request TLV (TM=003) — Phase 1 of a void (spec v2 §4.3).
    ///
    /// Fields and order: TM, NCAI, NS, DA, HE, DATR, HETR, STAN, [MT], [NSA].
    /// - `ns`: a new sequence number for the void itself; TM=004 repeats it.
    /// - `sequence`: the NS of the payment being voided, sent as NSA (005); omitted when nil or empty.
    /// - `amountCentimes`: the original amount — NapsPay v5.4.4+ requires it.
    public static func buildCancellationRequest(
        stan: String,
        ncai: String,
        ns: String,
        sequence: String? = nil,
        amountCentimes: Int? = nil
    ) -> String {
        let dateTime = getCurrentDateTime()
        var msg = buildField(tag: Tags.TM, value: MessageTypes.cancellationRequest)
            + buildField(tag: Tags.NCAI, value: ncai)
            + buildField(tag: Tags.NS, value: ns)
            + buildField(tag: Tags.DA, value: dateTime.date)
            + buildField(tag: Tags.HE, value: dateTime.time)
            + buildField(tag: Tags.DATR, value: dateTime.date)
            + buildField(tag: Tags.HETR, value: dateTime.time)
            + buildField(tag: Tags.STAN, value: stan)
        if let amount = amountCentimes {
            msg += buildField(tag: Tags.MT, value: String(amount))
        }
        if let sequence = sequence, !sequence.isEmpty {
            msg += buildField(tag: Tags.NSA, value: sequence)
        }
        return msg
    }

    /// Build cancellation confirmation request TLV (TM=004) — Phase 2 of a void (spec v2 §4.4).
    ///
    /// Sent on the same connection after MT=103 CR=000; it executes the reversal.
    /// Fields and order: TM, NCAI, NS, STAN, [MT, DE], [DATR], [HETR], DA, HE. No NSA.
    /// - `sequence`: the NS of the TM=003 being confirmed.
    /// - `amount`, `currency`, `datr`, `hetr`: echoed from MT=103. Omitting the amount is
    ///   refused with CR=909 on NapsPay v5.4.4+; DE defaults to "504" when absent.
    public static func buildCancellationConfirmation(
        stan: String,
        ncai: String,
        sequence: String,
        amount: String? = nil,
        currency: String? = nil,
        datr: String? = nil,
        hetr: String? = nil
    ) -> String {
        let dateTime = getCurrentDateTime()
        var msg = buildField(tag: Tags.TM, value: MessageTypes.cancellationConfirmationRequest)
            + buildField(tag: Tags.NCAI, value: ncai)
            + buildField(tag: Tags.NS, value: sequence)
            + buildField(tag: Tags.STAN, value: stan)
        if let amount = amount, !amount.isEmpty {
            msg += buildField(tag: Tags.MT, value: amount)
            msg += buildField(tag: Tags.DE, value: (currency?.isEmpty ?? true) ? Currency.MAD : currency!)
        }
        if let datr = datr, !datr.isEmpty {
            msg += buildField(tag: Tags.DATR, value: datr)
        }
        if let hetr = hetr, !hetr.isEmpty {
            msg += buildField(tag: Tags.HETR, value: hetr)
        }
        msg += buildField(tag: Tags.DA, value: dateTime.date)
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

    // MARK: - Management Requests (TM 008/009/010/012/013)

    /// Build a management-operation TLV frame: TM + NCAI + NS + DA + HE (+ optional
    /// extra fields). Used by the network test, totals, duplicate-receipt, reset and
    /// referencing operations, which carry no amount.
    public static func buildManagementRequest(
        tm: String,
        ncai: String = "0100001",
        sequence: String = "000001",
        extraFields: [(tag: String, value: String)] = []
    ) -> String {
        let dateTime = getCurrentDateTime()

        var msg = buildField(tag: Tags.TM, value: tm)
            + buildField(tag: Tags.NCAI, value: ncai)
            + buildField(tag: Tags.NS, value: sequence)
            + buildField(tag: Tags.DA, value: dateTime.date)
            + buildField(tag: Tags.HE, value: dateTime.time)

        for field in extraFields {
            msg += buildField(tag: field.tag, value: field.value)
        }

        return msg
    }

    /// Build a network-test request (TM=009)
    public static func buildNetworkTestRequest(ncai: String = "0100001", sequence: String = "000001") -> String {
        return buildManagementRequest(tm: MessageTypes.networkTest, ncai: ncai, sequence: sequence)
    }

    /// Build a referencing request (TM=013) carrying the TIDE (020) parameter set:
    /// "01" merchant, "02" recharge.
    public static func buildReferencingRequest(
        tide: String = Tide.merchant,
        ncai: String = "0100001",
        sequence: String = "000001"
    ) -> String {
        return buildManagementRequest(tm: MessageTypes.referencing, ncai: ncai, sequence: sequence,
                                      extraFields: [(Tags.TIDE, tide)])
    }

    /// Build a totals-report request (TM=010)
    public static func buildTotalsRequest(ncai: String = "0100001", sequence: String = "000001") -> String {
        return buildManagementRequest(tm: MessageTypes.totals, ncai: ncai, sequence: sequence)
    }

    /// Build a duplicate-receipt (reprint) request (TM=008)
    /// `stan` targets a specific transaction (spec §4.6); omitted = last transaction.
    public static func buildDuplicateReceiptRequest(ncai: String = "0100001", sequence: String = "000001",
                                                    stan: String? = nil) -> String {
        return buildManagementRequest(tm: MessageTypes.duplicateReceipt, ncai: ncai, sequence: sequence,
                                      extraFields: stan.map { [(tag: Tags.STAN, value: $0)] } ?? [])
    }

    /// Build a reset-PIN-pad request (TM=012)
    public static func buildResetPinPadRequest(ncai: String = "0100001", sequence: String = "000001") -> String {
        return buildManagementRequest(tm: MessageTypes.resetPinPad, ncai: ncai, sequence: sequence)
    }

    // MARK: - Parsing TLV

    /// Parse TLV string into fields dictionary.
    ///
    /// Parsing stops at the first end-of-message terminator (`!` for v2, `?` for v1)
    /// so any receipt content or noise after it is ignored. Both terminators are
    /// accepted so the parser is protocol-version agnostic.
    public static func parse(_ tlvString: String) -> [String: String] {
        var fields: [String: String] = [:]

        var index = tlvString.startIndex

        while index < tlvString.endIndex {
            // A terminator ('!' v2, '?' v1) ends the frame only between fields; inside
            // a value (e.g. the DP '?' end marker, "Merci!") it is data.
            if tlvString[index] == "!" || tlvString[index] == "?" { break }
            // Need at least 6 chars for tag + length
            guard tlvString.distance(from: index, to: tlvString.endIndex) >= 6 else { break }

            let tagEnd = tlvString.index(index, offsetBy: 3)
            let tag = String(tlvString[index..<tagEnd])

            let lengthEnd = tlvString.index(tagEnd, offsetBy: 3)
            let lengthStr = String(tlvString[tagEnd..<lengthEnd])

            // Validate length is numeric
            guard let length = tlvLength(lengthStr) else { break }

            // Check if we have enough data for the value
            guard tlvString.distance(from: lengthEnd, to: tlvString.endIndex) >= length else { break }

            let valueEnd = tlvString.index(lengthEnd, offsetBy: length)
            var value = String(tlvString[lengthEnd..<valueEnd])

            // Card numbers are masked as soon as they are parsed: NCAR and DP line text
            if tag == Tags.NCAR {
                value = maskCardNumber(value)
            } else if tag == Tags.DP {
                value = maskReceiptData(value)
            }

            fields[tag] = value
            index = valueEnd
        }

        return fields
    }

    // MARK: - Receipt Parsing

    /// Parse receipt data from DP tag value (spec §5).
    ///
    /// Each line is 030(line number) 031(S/G bold) 032(C/D/G alignment) 033(text).
    /// Sub-tags are read by their declared lengths, so a '*' or '?' inside a value
    /// (e.g. a masked PAN "516794******3315") stays part of the text; between lines
    /// '*' separates and '?' ends the block. Every line is kept, in order, exactly as
    /// sent, except that a full PAN in the text is masked.
    public static func parseReceipt(_ dpValue: String, type: ReceiptType) -> Receipt {
        var lines: [ReceiptLine] = []
        var lineNumber: String?
        var format = "S"
        var alignmentCode = "G"
        var content = ""

        func flush() {
            if let number = lineNumber {
                lines.append(createReceiptLine(number, maskCardNumbersInText(content), format, alignmentCode))
            }
            lineNumber = nil
            format = "S"
            alignmentCode = "G"
            content = ""
        }

        var index = dpValue.startIndex
        while index < dpValue.endIndex {
            let c = dpValue[index]
            if c == "*" {
                flush()
                index = dpValue.index(after: index)
                continue
            }
            if c == "?" { break }
            guard dpValue.distance(from: index, to: dpValue.endIndex) >= 6 else { break }
            let tagEnd = dpValue.index(index, offsetBy: 3)
            let lengthEnd = dpValue.index(tagEnd, offsetBy: 3)
            guard let length = tlvLength(dpValue[tagEnd..<lengthEnd]),
                  dpValue.distance(from: lengthEnd, to: dpValue.endIndex) >= length else { break }
            let valueEnd = dpValue.index(lengthEnd, offsetBy: length)
            let value = String(dpValue[lengthEnd..<valueEnd])

            switch String(dpValue[index..<tagEnd]) {
            case ReceiptTags.lineNumber:
                if lineNumber != nil { flush() }   // new line without a '*' separator
                lineNumber = value
            case ReceiptTags.format: format = value
            case ReceiptTags.alignment: alignmentCode = value
            case ReceiptTags.content: content = value
            default: break
            }
            index = valueEnd
        }
        flush()

        return Receipt(type: type, lines: lines)
    }

    // MARK: - Security

    /// Mask a card number (tag 007): always returned as the first 6 digits, '*' for
    /// each middle digit, and the last 4 digits, whatever grouping it arrived in.
    /// Example: "5167 9400 0012 3315" -> "516794******3315". Already-masked digits
    /// ('*') count as digits. Values with fewer than 10 digits are returned unchanged.
    public static func maskCardNumber(_ cardNumber: String) -> String {
        let digits = cardNumber.filter { ($0.isASCII && $0.isNumber) || $0 == "*" }
        guard digits.count >= 10 else { return cardNumber }
        return String(digits.prefix(6)) + String(repeating: "*", count: digits.count - 10) + String(digits.suffix(4))
    }

    /// Mask every card-shaped run in free text: 13 or more digits, consecutive digits
    /// adjacent or separated by exactly one space, dash, dot, tab or non-breaking
    /// space. Every digit except the first 6 and last 4 of the run becomes '*' (runs
    /// longer than 19 digits too); separators and the rest of the text are unchanged.
    public static func maskCardNumbersInText(_ text: String) -> String {
        let pattern = #"(?<![0-9])[0-9](?:[ \-.\t\x{00A0}]?[0-9]){12,}(?![0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        var result = text

        let matches = regex.matches(in: text, options: [], range: range)
        for match in matches.reversed() {
            if let matchRange = Range(match.range, in: result) {
                result.replaceSubrange(matchRange, with: maskDigitsKeepingLayout(String(result[matchRange])))
            }
        }

        return result
    }

    /// Replace every digit except the first 6 and last 4 with '*'; other characters stay.
    private static func maskDigitsKeepingLayout(_ run: String) -> String {
        let digitCount = run.filter { $0.isASCII && $0.isNumber }.count
        var seen = 0
        return String(run.map { c -> Character in
            guard c.isASCII && c.isNumber else { return c }
            seen += 1
            return seen <= 6 || seen > digitCount - 4 ? c : "*"
        })
    }

    /// Mask card numbers in a raw reply frame: tag 007 (NCAR) and the text (033) of
    /// each DP receipt line (tag 010). Length fields are rewritten to match.
    public static func maskFrame(_ frame: String) -> String {
        return maskFields(frame) { tag, value in
            switch tag {
            case Tags.NCAR: return maskCardNumber(value)
            case Tags.DP: return maskReceiptData(value)
            default: return value
            }
        }
    }

    /// Mask the line text (sub-tag 033) of a DP block, leaving its structure intact.
    static func maskReceiptData(_ dp: String) -> String {
        return maskFields(dp) { tag, value in
            tag == ReceiptTags.content ? maskCardNumbersInText(value) : value
        }
    }

    /// Walk TLV units (skipping '*' between them, stopping at '?'/'!' or malformed
    /// data) and rewrite each value; everything not walked is copied unchanged.
    private static func maskFields(_ text: String, _ transform: (String, String) -> String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "*" {
                result.append("*")
                index = text.index(after: index)
                continue
            }
            guard text.distance(from: index, to: text.endIndex) >= 6 else { break }
            let tagEnd = text.index(index, offsetBy: 3)
            let lengthEnd = text.index(tagEnd, offsetBy: 3)
            guard let length = tlvLength(text[tagEnd..<lengthEnd]),
                  text.distance(from: lengthEnd, to: text.endIndex) >= length else { break }
            let valueEnd = text.index(lengthEnd, offsetBy: length)
            let value = transform(String(text[index..<tagEnd]), String(text[lengthEnd..<valueEnd]))
            result += text[index..<tagEnd] + String(format: "%03d", value.count) + value
            index = valueEnd
        }
        result += text[index...]
        return result
    }

    // MARK: - Private Helpers

    /// TLV length field: exactly three ASCII digits. Rejects signs ("-01", "+01")
    /// and non-ASCII digits that `Int(_:)` would otherwise accept.
    static func tlvLength<S: StringProtocol>(_ field: S) -> Int? {
        guard field.count == 3, field.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(field)
    }

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
}
