# Errors

Every error is the same envelope, whatever the endpoint or status:

```json
{ "error": { "code": "insufficient_funds", "message": "…" } }
```

`code` is stable and published — added, never renamed, never removed. Branch on
it. `message` is human-readable copy that may change.

## Two namespaces

The two kinds of "it didn't work" behave differently with money.

- **Rejections** — the request was refused. **No payout was created and nothing
  was held.** Fix the request, or wait where retryable, and submit again.
- **Failure codes** — a payout was accepted, held funds, and later died. It is
  terminal, `failure: { code, message }` is set, and **the hold is always
  released back to `available`**. Resubmission is always a *new* payout with a
  *new* `Idempotency-Key`.

## Rejection codes

| Code | HTTP | Meaning | Retry? |
| --- | --- | --- | --- |
| `validation_error` | 400 | Malformed request: bad JSON, missing field, or a missing `Idempotency-Key` on create. | After fixing the request. |
| `unauthorized` | 401 | Missing, malformed, revoked, or unknown API key. | No — fix the key. |
| `forbidden` | 403 | Org suspended, or request IP not on your allowlist. | No — resolve with Jenzy, or fix the allowlist. |
| `not_found` | 404 | No such resource in your org. Unknown, foreign, and malformed ids look identical. | No. |
| `insufficient_funds` | 402 | The amount **plus its fee** exceeds `available`. | After funding. |
| `conflict` | 409 | This `Idempotency-Key` was used with a different body, or its original request is still in progress. | Different body → new key. In progress → same key, shortly. |
| `unknown_institution` | 422 | `institution_id` isn't payable on this endpoint's rail. The message says whether it is unknown or belongs to the other rail. | After re-fetching `GET /institutions`, or posting to the other rail's endpoint. |
| `invalid_mobile_number` | 422 | Not 12 digits in full international form — `265`, then `9` (Airtel Money) or `8` (TNM Mpamba), then 8 digits. Numbers are never corrected for you. | After fixing the number. |
| `mobile_number_institution_mismatch` | 422 | The number's network isn't the institution chosen — the payout would misroute. The message names the institution that number belongs to. | After choosing the matching institution. The number is fine. |
| `invalid_account_number` | 422 | The account number fails validation for the target bank. | After fixing the number. |
| `amount_limit_exceeded` | 422 | Above the per-payout maximum. | With a smaller amount. |
| `rate_limited` | 429 | Too many requests. | Yes — honor `Retry-After`. |
| `org_limit_exceeded` | 429 | Your org's rolling daily cap or hourly payout velocity tripped. | Yes — later. Not a request-rate problem; backing off per-request does not clear it. |
| `sandbox_only` | 403 | A sandbox-only endpoint was called in production. | No. |
| `internal_error` | 500 | Something broke on the Hermes side. | Yes — and on create, reuse the **same** `Idempotency-Key`: you get the original outcome if one was reached, never a double payout. |
| `rail_disabled` | 503 | This rail is administratively paused. | Yes — later. |
| `service_unavailable` | 503 | A dependency is unavailable (e.g. reference data has never synced). | Yes — later. |

## Failure codes

Carried in `failure.code` on a `failed` payout — identically on
`GET /payouts/{id}` and in the `payout.failed` webhook. `failure.message` is
fixed copy per code, safe to show your own users.

| Code | Meaning | Can a resubmission succeed? |
| --- | --- | --- |
| `recipient_account_invalid` | The provider rejected the destination — the account doesn't resolve, or the number is invalid. | Only after the destination is corrected. |
| `declined` | The provider declined the payout, or failed it without a reason. The catch-all. | Unlikely unchanged — investigate before resubmitting. |
| `provider_unavailable` | Timeout or outage at the downstream provider. | Yes — a fresh payout may plausibly succeed; retry shortly. |
| `temporarily_unavailable` | A temporary condition on the Hermes side. | Yes — retry later; no funds were deducted. |

These four are the complete failure vocabulary — anything unmappable lands in
`declined`. A failed payout is never retried automatically by Hermes.

## Handling shape

Map each code once, at the boundary, into one of five outcomes:

1. **Fix and resubmit** — `validation_error`, `unknown_institution`,
   `invalid_mobile_number`, `mobile_number_institution_mismatch`,
   `invalid_account_number`, `amount_limit_exceeded`. Surface to whoever supplied
   the destination or amount; retrying the same bytes never helps.
2. **Back off and retry the same intent** — `rate_limited` (honor `Retry-After`),
   `org_limit_exceeded`, `rail_disabled`, `service_unavailable`,
   `internal_error`, and `conflict` where the original is still in progress.
   Reuse the **same** `Idempotency-Key`: that is what makes the retry safe.
3. **Fund, then resubmit** — `insufficient_funds`. Quote first next time;
   `total_debit`, not the amount, is what must fit in `available`.
4. **Alert a human** — `unauthorized`, `forbidden`, `sandbox_only`. These are
   configuration or account state, and no retry policy resolves them.
5. **New intent** — every `failure.code` whose row says a resubmission may
   succeed. A new payout with a new key; reusing the old key replays the failure.

`not_found` is a read outcome, not a payout outcome: treat it as "not yours or
not real", never as "not yet".
