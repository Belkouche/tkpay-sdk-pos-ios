# Changelog

All notable changes to the TKPay NAPS iOS SDK are documented here.

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
