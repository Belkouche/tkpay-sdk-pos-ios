# Changelog

All notable changes to the TKPay NAPS iOS SDK are documented here.

## [1.3.0] - 2026-11-06

Sync with NapsPay v5.4.4 / canonical C# SDK (TKPay.Naps 1.4.0).

### Fixed
- **Responses now end at the `!` / `?` terminator.** The socket read loop waited
  for more data after the first chunk and only returned on timeout, so every
  exchange against a v5.4.4 terminal timed out. Reads now stop at the terminator,
  fall back to 1 s of inter-chunk silence for unterminated frames, and strip the
  terminator before parsing.
- **Receipts.** DP entry groups are split on the `*` separator (digit runs inside
  a value such as a PAN can no longer be misread as sub-tags). The merchant copy
  comes from the Phase-1 response (TM=101) and the customer copy from Phase 2
  (TM=102); both were previously parsed from Phase 2.
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
- Receipt branding matches the reference SDK: centred "Naps" lines become "TKPAY"
  and "Powered by NAPS" is appended as the last line.

### Changed — void (TM 003 → 103, TM 004 → 104), aligned with TKPay.Naps 1.5.0
- TM 004 carries the same fields as TM 003: the sequence is now sent in NSA (005)
  instead of NS (004).
- `CancellationResult` gains `merchantReceipt` (DP of TM 103) and `customerReceipt`
  (DP of TM 104); `stan` prefers the void STAN from TM 104.
- A missing TM 104 reply (confirmation timeout) after an accepted TM 103 is reported
  as a successful void — the void is committed at TM 103.
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

### Tests
- In-process fake-terminal tests (terminator handling, silence fallback, decline,
  per-phase receipts, confirmation echo, two-phase void) and emulator integration
  tests (`NAPS_EMULATOR_PORT=<port> [NAPS_EMULATOR_MODE=<mode> NAPS_EMULATOR_CODE=<rc>]
  swift test`) covering approve, strict-confirm, v1, decline, error, confirm_error,
  no_confirm and timeout modes.

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
