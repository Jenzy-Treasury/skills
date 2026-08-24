# Endpoints

Base URL: `https://api.jenzy.com/v1` (production) or
`https://api.sandbox.jenzy.com/v1` (sandbox). HTTPS only, JSON bodies, every
request carries `Authorization: Bearer <jz_live_…>`.

Money on the wire: everything Hermes returns is an exact decimal string at two
places. Everything you send is a JSON integer of whole kwacha or a 2 dp string.

## `GET /ping`

Exercises the whole auth chain and echoes who you are. `200`, `401`, `403`,
`429`.

```json
{ "org": "Acme Remittances Ltd", "mode": "live", "key_prefix": "jz_live_AbC123Xy" }
```

`mode` is the **key's** mode, not the environment's: every key Hermes issues is
`live`, in the sandbox as well as production, so this reads `"live"` everywhere
and is not a signal for which environment you reached. The base URL is. (`test`
is in the published enum but is never minted.) `key_prefix` is the only part of a
key that ever appears again — quote it when talking to Jenzy support.

## `GET /balance`

`200`, `401`.

```json
{ "available": "1250000.00", "held": "50000.00", "shortfall": "0.00", "currency": "MWK" }
```

- `available` — spendable now.
- `held` — reserved by payouts in flight, each amount plus its expected fee.
- `shortfall` — normally `"0.00"`. Non-zero means fees already incurred exceeded
  the balance; the next top-up covers it before adding to `available`.

## `GET /institutions`

`200`, `401`, `503` (`service_unavailable` if reference data has never synced).

```json
{
  "institutions": [
    { "institution_id": 112400, "name": "Airtel Money",  "rail": "momo" },
    { "institution_id": 112500, "name": "TNM Mpamba",    "rail": "momo" },
    { "institution_id": 221400, "name": "NBS Bank",      "rail": "bank" }
  ],
  "synced_at": "2026-07-08T06:00:11.000Z"
}
```

Only institutions Hermes can actually pay are listed. One list covers both
rails; each entry names its own. Cache it — it changes rarely — and re-fetch
when a create returns `unknown_institution`.

## `POST /payouts/momo`

Headers: `Idempotency-Key` (**required**), `Content-Type: application/json`.
`202`, `400`, `401`, `402`, `409`, `422`, `429`, `503`.

```json
{
  "amount_mwk": 5000,
  "institution_id": 112400,
  "mobile_number": "265991234567",
  "beneficiary_name": "Chikondi Banda"
}
```

All four fields required. `mobile_number` is full international form: `265`,
then `9` (Airtel Money) or `8` (TNM Mpamba), then 8 digits. It is sent to the
provider exactly as given — a near miss is rejected, never normalized. A number
whose network disagrees with `institution_id` is
`mobile_number_institution_mismatch`.

## `POST /payouts/bank`

Same headers and status codes as momo.

```json
{
  "amount_mwk": 250000,
  "institution_id": 221400,
  "account_number": "1000123456789",
  "beneficiary_name": "Acme Supplies Ltd"
}
```

All four fields required. `beneficiary_name` is required on both rails because
the provider needs it at submission.

## The payout resource

Returned by create, by both read endpoints, and as `data` in every payout
webhook — the same shape in all four places.

```json
{
  "id": "0d5e63b2-59f3-4d2a-8f57-2f14a3c14f6d",
  "amount_mwk": "5000.00",
  "fee": "282.00",
  "rail": "momo",
  "status": "succeeded",
  "destination": {
    "institution_id": 112400,
    "mobile_number": "265991234567",
    "beneficiary_name": "Chikondi Banda"
  },
  "failure": null,
  "created_at": "2026-07-08T09:14:02.000Z",
  "terminal_at": "2026-07-08T09:14:31.000Z"
}
```

`destination` carries `account_number` instead of `mobile_number` on the bank
rail. `failure` is `{ code, message }` on a failed payout, otherwise `null`.

### Status lifecycle

```
held → submitted → pending → succeeded | failed
```

- `held` — funds reserved, not yet sent to the provider.
- `submitted` — handed to the provider.
- `pending` — the only resting in-flight state, awaiting the provider's outcome.
  A payout can sit here a while; Hermes re-checks rather than resubmitting.
- `succeeded` / `failed` — terminal.
- `reversed` — had succeeded, then clawed back by the provider. Not a failure:
  `failure` stays `null` and `terminal_at` keeps the *original* success
  timestamp. `terminal_at` is set once and never moves.

`received` and `validated` also appear in the published enum; they are internal
accept-path states you will not normally observe.

### Fees on a payout

Passed through at cost, with no Jenzy margin. `POST /fees/quote` is the exact
figure; the schedule below is the commercial summary.

| Line | Rate |
| --- | --- |
| Transaction fee | 0.94% of the amount (0.8% + VAT) |
| Convenience fee — mobile money | 235 MWK flat (200 + VAT) |
| Convenience fee — bank | 587.50 MWK flat (500 + VAT) |
| Government levy | 0.05% of the amount, only above 100,000 MWK |

The convenience fee applies to every payout at any amount. Each line rounds to
the tambala on its own, so re-deriving a total from these rates can land a
tambala off.

- Charged only on **success**. A `failed` payout reads `fee: "0.00"` and its full
  hold returns to `available`.
- A `reversed` payout keeps the fee it was charged — it did succeed first.
- The published `fee` is the **observed** provider charge, not the quote, so the
  actual debit can differ slightly from the estimate; the difference returns to
  `available`.

### Limits

Independent of your balance: a per-payout maximum (`amount_limit_exceeded`,
422), a rolling 24-hour volume cap and a rolling 1-hour payout count
(both `org_limit_exceeded`, 429). Measured on the amount, not amount plus fee.

## `GET /payouts`

Query: `limit` (1–200, default 50), `before_id` (keyset cursor — the previous
page's `next_before_id`). `200`, `400`, `401`.

```json
{ "payouts": [ … ], "has_more": true, "next_before_id": "0d5e63b2-…" }
```

Newest first. Page until `has_more` is `false`.

## `GET /payouts/{id}`

`200`, `401`, `404`. Unknown, foreign, and malformed ids all return `not_found`
— identically, so an id from another org is indistinguishable from one that
never existed.

## `POST /fees/quote`

`200`, `400`, `401`. No idempotency key; it moves no money.

```json
{ "direction": "payout", "rail": "momo", "amount_mwk": 10000 }
```

`direction` is `payout` or `collection` — the two are priced differently. `rail`
is `momo` or `bank`; pricing depends on the rail only, never on the institution.
`amount_mwk` must be positive and at most 1,000,000,000,000 MWK.

```json
{
  "currency": "MWK",
  "amount_mwk": "10000.00",
  "direction": "payout",
  "rail": "momo",
  "fees": {
    "convenience_fee": "200.00",
    "transaction_fee": "80.00",
    "levy": "0.00",
    "vat": "49.00"
  },
  "total_fee": "329.00",
  "total_debit": "10329.00",
  "amount_received": null
}
```

- `total_debit` — amount plus fee, what leaves your balance. Set on `payout`.
- `amount_received` — amount minus fee, what credits your balance. Set on
  `collection`.
- The itemization breaks VAT out as its own line rather than folding it into each
  fee the way the commercial schedule does. **Reconcile on `total_fee`, not line
  by line.**

## `GET /collections`

Query: `limit` (1–200, default 50), `before_id`. `200`, `400`, `401`. Newest
first, same keyset shape as payouts (`collections`, `has_more`,
`next_before_id`).

## `GET /collections/{id}`

`200`, `401`, `404`.

## The collection resource

```json
{
  "id": "7a4be2a4-90f4-4a5e-b7c9-1d2f5f6f8a31",
  "status": "settled",
  "amount_mwk": "100000.00",
  "fee": "1500.00",
  "amount_credited": "98500.00",
  "rail": "momo",
  "source_customer_name": "PETER BANDA",
  "source_account_number": "265991234567",
  "source_institution": "Airtel Money",
  "rtp_reference_number": null,
  "created_at": "2026-08-05T09:40:53.000Z"
}
```

`status` is `settled` or `reversed`. The three money figures always agree:
`amount_mwk − fee = amount_credited`. The fee is one combined figure, never
itemized further.

Pay-ins cost **one percentage fee of the amount sent, all-in** — 1.5% as
standard, or your agreed rate. No minimum, no flat component, MWK only. Because
your rate may not be standard and the fee rounds to the tambala, `POST
/fees/quote` with `direction: "collection"` is the only safe source; its
`amount_received` matches the credit exactly.

The sender's identity arrives in full, as the provider reports it — for mobile
money, `source_account_number` is the payer's wallet number. It is how you match
a pay-in to your own customer, and it is personal data you are responsible for
handling.

## `POST /collections/simulate` (sandbox only)

`201`, `202`, `400`, `401`, `403` (`sandbox_only` in production), `503`.

```json
{ "amount_mwk": 50000, "rail": "momo" }
```

`amount_mwk` is what the pretend sender pays in — the gross, before fees; you
are credited less, exactly as on a real pay-in. Positive, at most 5,000,000,000
MWK. `rail` is `momo` (default) or `bank` and decides the resulting `rail` and
`source_institution` only; it does not change the price. Returns the collection.

Nothing marks the result as simulated: it becomes a collection, credits the
balance, and fires `collection.settled`.

**Not idempotent.** A `202` means the pay-in exists but has not credited yet —
poll `GET /collections` instead of resending, because a second request makes a
second pay-in. Only `4xx` and `503` mean nothing was made.

## Sandbox test accounts

The sandbox has no connection to the rails, so it pays these destinations only;
a real account or wallet is refused. They do not work in production. Any
institution of the matching rail works.

Bank accounts, all successful: `3333888800` … `3333888809` (consecutive).

Mobile wallets, all successful: `111100000112`, `111100000221`, `111100000330`,
`111100000445`, `111100000553`, `111100000662`, `111100000778`, `111100000889`,
`111100000990`, `111100000498`.

These wallet numbers do not match the published production `mobile_number`
pattern; they are exempted server-side in the sandbox. Do not enforce that
pattern in your own client, or you will block them locally.

## Authentication, allowlisting, rate limits

- Keys are opaque: `jz_live_` plus a long random body. Only the first 16
  characters — the prefix — ever appear again. The full key is shown once at
  issuance and cannot be recovered.
- Rotation is overlap, not an event: an org can hold several active keys. Issue
  the new one, switch over, then have the old one revoked. There is no keyless
  window to schedule.
- An org admin can restrict a key to an exact list of IPv4/IPv6 addresses (no
  CIDR) in the portal. With a non-empty allowlist, any other address gets `403
  forbidden`. The allowlist is managed by portal session only — a leaked key
  cannot widen its own reach.
- Rate limits are per org. Over the limit: `429` with code `rate_limited` and a
  `Retry-After` header in seconds. Polling `GET /balance` and `GET /payouts/{id}`
  at a modest cadence stays comfortably under it.
