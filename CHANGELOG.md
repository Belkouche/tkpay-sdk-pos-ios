# Changelog

All notable changes to the TKPay NAPS iOS SDK are documented here.

## Unreleased — Sunmi P2 / Ingenico Lane3600 fixes

Ported from the canonical C# SDK and the Node SDK, where these frames were verified live
on a Sunmi P2 (TCP) and a Lane3600 (USB). This SDK is TCP only, so the USB serial fixes
(port warm-up, waits between frames, byte lengths, kept-open port) do not apply.

- **fix (void frames, spec v2 §4.3/§4.4):** TM 003 is now TM, NCAI, NS, DA, HE, DATR,
  HETR, STAN, MT, NSA. Its NS is a new sequence generated for the void; the `sequence`
  passed to `cancelPayment` is the payment's NS and goes in NSA. TM 004 is TM, NCAI, NS
  (same as TM 003), STAN, MT and DE echoed from TM 103 (DE `504` if absent), DATR/HETR
  echoed from TM 103, DA, HE; never NSA. TM 004 used to carry the caller's `sequence` as
  NS. `cancelPayment`'s signature is unchanged; `TLVProtocol.buildCancellationRequest`
  takes a new `ns:` argument and `buildCancellationConfirmation` new optional
  `currency:`, `datr:` and `hetr:` arguments.
- **fix (void receipt):** when TM 103 carries no receipt and TM 104 does, as on the Sunmi
  P2 (printed "Copie Commerçant") and the Lane3600, `cancelPayment` returns the TM 104
  receipt as `merchantReceipt` and no `customerReceipt`. Terminals that send a receipt
  with TM 103 are unchanged.
- **fix (network test):** `networkTest()` sends nothing over TCP and returns
  `success == false`, `responseCode == "UNSUPPORTED"`. The NapsPay app on a Sunmi P2
  answers TM 009 with TM 101 / CR 902, and a test frame crashed the app.
- **fix (reader):** a reply ends at a `!` / `?` terminator on a field boundary, with fields
  walked by their length; the walk only runs when the data ends with `!` or `?`. A receipt
  line ending in `?` no longer ends the reply when a read stops right after it. Data that
  stops being TLV falls back to "ends with `!` or `?`". The 1 s silence fallback and the
  64 KB cap are kept.
- **fix (long receipts):** a DP declared 999 long (the Lane3600 writes 999 when the
  receipt is longer) now runs to its own `?` end marker, walking receipt sub-tags
  030–039 only; it used to be cut at 999 chars. A DP exactly 999 long without `?` still
  ends at 999 chars, so it cannot swallow the fields after it.
- **fix (parser):** `parse`, `maskFrame` and the reader share one field walker. Header
  digits are ASCII `0`–`9` only; malformed input stops the walk and never throws.
- **fix (card numbers):** receipt masking covers every DP sub-tag value, not only the line
  text, and any part of a reply that cannot be walked as fields is masked as text instead
  of being copied as is.
- Requests over TCP still carry no `!` / `?` terminator (a `!`-terminated frame got no
  reply from the Sunmi P2); now covered by a test. Management operations already used
  `timeout` (120 s), not a shorter fixed timeout.

## [1.4.0] - 2026-11-09

- **Removed the gateway notification.** `processPayment` no longer sends a background
  `POST` to `https://api.tkpay.ma` after each payment. The SDK only talks to the terminal.

## [1.3.1] - 2026-11-07

- **Card numbers.** Card numbers are masked (first 6 + last 4 digits) as soon as the
  reply is read, and the full number is never exposed or logged:
  - tag 007 is always returned as first 6 + `*` + last 4 digits, whatever grouping it
    arrived in;
  - receipt and other text mask every run of 13 or more digits whose digits are
    adjacent or separated by exactly one space, dash, dot, tab or non-breaking space
    (previously only 16 contiguous digits). All digits but the first 6 and last 4 of
    the run become `*`, separators and layout are kept, and runs longer than 19
    digits are masked too. Dates, times and amounts are left alone;
  - the DP block is masked line by line when the reply is parsed, so
    `TotalsResult.receiptText` and `ReferencingResult.receiptText` no longer leak a PAN
    that followed a sub-tag length header;
  - `NapsConnection.sendAndReceive` returns the reply with card numbers masked
    (`TLVProtocol.maskFrame`).

## [1.3.0] - 2026-11-06

Sync with NapsPay v5.4.4 / canonical C# SDK (TKPay.Naps 1.4.0).

### Fixed
- **Responses now end at the `!` / `?` terminator.** The socket read loop waited
  for more data after the first chunk and only returned on timeout, so every
  exchange against a v5.4.4 terminal timed out. Reads now stop at the terminator,
  fall back to 1 s of inter-chunk silence for unterminated frames, and strip the
  terminator before parsing.
- **Receipts (spec §5).** The DP block is parsed by sub-tag length, so a `*` or `?`
  inside a line (e.g. the masked PAN `516794******3315`, previously a blank line) no
  longer splits or truncates it. Every line is kept in order with its line number,
  bold flag and alignment, exactly as sent; a full PAN in the text is masked. The
  merchant copy comes from the Phase-1 response (TM=101) and the customer copy from
  Phase 2 (TM=102); both were previously parsed from Phase 2.
- **Terminators inside values.** `TLVProtocol.parse` cut the frame at the first `!`/`?`
  anywhere, losing a DP field that contained one (e.g. the spec's `?` end marker), and
  the reader stripped a final `?` that belonged to a DP value. Both now treat a
  terminator as end-of-frame only between fields.
- **Framing.** A terminator only ends a read when it follows complete TLV units, so a
  `!`/`?` inside a value or at the end of a partial chunk no longer truncates the
  response. Late bytes from an earlier exchange are dropped, never prepended.
- **Phase-2 result.** The confirmation response must be TM=102 with CR=000; a rejected
  confirmation (e.g. CR=307 coherence failure) is now returned as a failed payment
  instead of an approval.
- **TLV length hardening.** Length fields must be exactly three ASCII digits; a
  signed length such as `-01` previously made the parser crash or the framer loop.
  Responses larger than 64 KB are rejected.
- **PAN masking.** `ReferencingResult.receiptText` and `TotalsResult.receiptText`
  mask card numbers like every other receipt path.

### Changed
- Payment request (TM=001) sends DA/HE alongside DATR/HETR, matching the reference SDK.
- Declined payments carry the masked PAN (NCAR) and the refusal receipt (DP) as
  `merchantReceipt`; the error reads `"<description> — code: <CR>"`, with dedicated
  messages for 909/302/482/480.
- Settlement errors: `052` → "Already settled today", `909` → "Terminal or server is down".
- `PaymentRequest.sequence`, when provided, must be 6 digits.
- Receipts carry no SDK-added text: the "Powered by NAPS" footer and the rewriting of
  centred "Naps" lines to "TKPAY" are removed.
- `TotalsResult.receipt` and `ReferencingResult.receipt`: the parsed TM 110 / TM 113 receipt.

### Changed — void (TM 003 → 103, TM 004 → 104), per spec v2.0 §4.3–4.4
Checked against the NapsPay ECR TLV Protocol Specification v2.0 and the live
v5.4.4 terminal test (tkpay-sdk-pos-naps-rn 5fcfeb0).
- TM 004 sends the sequence in NS (004), the same value as the TM 003 it confirms,
  and echoes the amount (002) from TM 103. TM 003 is unchanged.
- TM 104 CR=000 or 480 = void completed. CR=995 and a missing TM 104 reply
  (confirmation timeout) **fail closed**: `success == false`, the new
  `CancellationResult.pending == true`, and `stan` is the original transaction's
  STAN (from TM 103), with the TM 103 merchant receipt attached. TM 103 CR=000 only
  means "transaction found"; TM 004 performs the reversal. Any other code = failure.
  The same rules apply when firmware answers TM 003 with TM 104 directly.
- `duplicateReceipt(stan:)` / `buildDuplicateReceiptRequest(stan:)` (optional, spec
  §4.6) reprint a specific transaction, so a pending void can be checked by STAN.
- `CancellationResult` gains `merchantReceipt` (DP of TM 103) and `customerReceipt`
  (DP of TM 104); on success `stan` is the void STAN from TM 104.
- `MessageTypes.cancellationConfirmationResponse` ("104") added;
  `cancellationCorrection` is deprecated (104 is the reply to TM 004).

### Added — management operations on `NapsPayClient`
- `networkTest()` (TM=009) → `NetworkTestResult`
- `referencing(tide:)` (TM=013, TIDE 020: `"01"` merchant, `"02"` recharge) → `ReferencingResult`
- `totals()` (TM=010) → `TotalsResult`
- `duplicateReceipt()` (TM=008) → `PaymentResult`
- `resetPinPad()` (TM=012)
- Matching `TLVProtocol` builders (`buildManagementRequest`, `buildNetworkTestRequest`, …),
  `MessageTypes` constants and `TLVProtocol.Tide`.

### Docs
- README rewritten as an integrator guide (payment and void flows, every operation,
  errors and timeouts, gateway notification, emulator testing, troubleshooting); every
  Swift snippet compiles against the public API.
- README receipt section: which copy is where, printing both copies, line metadata.
- `Example/Quickstart`: runnable command-line quickstart (`swift run`), same code as
  the README.

### Tests
- In-process fake-terminal tests (terminator handling, silence fallback, decline,
  per-phase receipts, confirmation echo, two-phase void) and emulator integration
  tests (`NAPS_EMULATOR_PORT=<port> [NAPS_EMULATOR_MODE=<mode> NAPS_EMULATOR_CODE=<rc>]
  swift test`) covering approve, strict-confirm, v1, decline, error, confirm_error,
  no_confirm, timeout and the void modes void_480, void_995, void_no_confirm and
  void_refuse (emulator 5cc8536: unterminated TM 103/104, TM 004 NS and amount checks).

## [1.2.0] - 2026-09-12

### Added
- **NAPS TLV v2 protocol support.**
  - `NapsConfig.protocolVersion` (`.v1` / `.v2`, default `.v2`) selects the expected
    response terminator: `!` for v2, `?` for v1.
  - Enriched payment confirmation (TM=002): `buildConfirmationRequest` now carries
    the amount (MT/DE), masked PAN (NCAR) and card expiry (DAEX) from the approved
    payment response. `processPayment` threads these fields automatically. Field order
    matches the reference SDK: TM, NCAI, NS, [MT, DE], STAN, [NCAR], [DAEX], DA, HE.
  - Full v2 §6 response-code table with `TLVProtocol.describeResponse(_:)` and
    `TLVProtocol.isApproved(_:)` (approved codes: 000, 001, 003, 007). Failed payment
    results now use the table for their human-readable message.

### Changed
- `TLVProtocol.parse` now stops at the first end-of-message terminator (`!` or `?`),
  ignoring any receipt content or noise after it.

### Notes
- `buildConfirmationRequest` gained optional parameters (`amountCentimes`, `currency`,
  `ncar`, `daex`); existing callers are unaffected.

## [1.1.0]

- Two-phase cancellation flow (TM=003 → TM=004) with amount echo for NapsPay v5.4.4+.

## [1.0.0]

- Initial release: two-phase payment flow, settlement (TM=010), receipt parsing,
  PAN masking, TCP connection management.
