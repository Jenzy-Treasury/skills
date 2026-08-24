---
name: hermes-mwk
description: Integrate with the Jenzy Hermes MWK API (api.jenzy.com, api.sandbox.jenzy.com). Use when creating bank or mobile-money payouts from a prefunded kwacha balance, consuming pay-in collections, verifying Hermes webhook signatures, quoting fees, resolving a Hermes error code, or moving an integration from sandbox to production.
---

# Jenzy Hermes integration

Hermes pays Malawian kwacha out of a balance your org prefunds. Three moves:
**fund** — someone sends MWK to your account number, it lands as a *collection*
and credits your balance; **draw down** — `POST /payouts/bank` or
`POST /payouts/momo` holds the funds and sends them; **track** — a webhook or a
poll tells you the outcome.

Build against the sandbox first. Work the steps in order; each ends on a
condition you can check.

With a sandbox key in hand, `scripts/smoke-sandbox.sh` walks that whole loop and
prints the real response at every step. Run it before writing code — it is the
cheapest way to see what you are integrating against.

## Non-negotiables

These hold in every branch of the integration.

- **The base URL selects the money.** `https://api.sandbox.jenzy.com/v1` is test
  money; `https://api.jenzy.com/v1` is real. Every key starts `jz_live_` in both
  environments, so the prefix tells you nothing — and a key works against its own
  base URL only. Label your secrets by environment.
- **tambala** — one hundredth of a kwacha is the money atom, so every MWK figure
  Hermes sends is an exact decimal string at two places (`"99177.50"`). Parse
  each one with a decimal type; `parseFloat` on money is a defect. Amounts you
  send are either a JSON integer of whole kwacha (`250000`) or a 2 dp string
  (`"250000.50"`) — a fractional JSON number is rejected by design, so asking for
  a subunit stays explicit in the request body.
- **One intent, one `Idempotency-Key`.** Required on every payout create. The
  same key with the same body replays the original response byte-for-byte; the
  same key with a different body is `409 conflict`. Mint a UUID per payout
  intent.
- **`202` means decided** — funds are held and the payout is queued. `4xx` means
  nothing happened: no payout exists and nothing is held.
- **terminal is `succeeded` or `failed`.** Nothing else is final.
- **The quote is the fee authority.** `POST /fees/quote` returns the exact
  figures under your org's own agreed rates. A fee you derive from a percentage
  lands a tambala off, because each line rounds to the tambala on its own.
- **Branch on `error.code`.** Codes are published — added, never renamed or
  removed. `message` copy changes.
- **A payer's name is a string, not a fact.** Hermes' own fields are safe to
  branch on and show: every status, `error.code`, `failure.code`,
  `failure.message`, every amount. A collection's sender identity is not —
  `source_customer_name`, `source_account_number`, `source_institution` and
  `rtp_reference_number` are relayed exactly as the provider reported them, so
  treat them as **tainted**: escape at every sink you render or log them to, and
  fence them as data if a record ever reaches an LLM. Match on them all you
  like; let ids and amounts decide anything.

## 1. Wire the client against sandbox

Every call carries `Authorization: Bearer <key>`. Issue a sandbox key yourself
at `https://hermes.sandbox.jenzy.com` under integration settings; the full key
appears exactly once, so put it straight into your secrets manager. Read the
base URL and the key from configuration, so going live is a config change.

**Done when** `GET /ping` against `api.sandbox.jenzy.com/v1` returns your org
name, `mode`, and `key_prefix`, and neither the base URL nor the key is written
at a call site.

## 2. Model money as tambala

Carry MWK as a decimal type or an integer count of tambala end to end — wire
string in, decimal in your domain, wire string out.

**Done when** every money field you consume (`amount_mwk`, `fee`,
`amount_credited`, `available`, `held`, `shortfall`, `total_fee`, `total_debit`)
parses through that type, and a search for float parsing and float arithmetic
across your Hermes code paths accounts for every hit.

## 3. Fund the sandbox balance

A payout draws the balance down, so fund it first. `POST /collections/simulate`
makes a pay-in that is real in every way that touches your code: it becomes a
collection, credits your balance less the fee, and fires `collection.settled`.
`amount_mwk` is what the pretend sender pays *in*; you are credited
`amount_credited`. This endpoint is sandbox only — production answers `403
sandbox_only`, because money arrives there only when a sender pays your account
number.

It is **not** idempotent, and a `202` means the pay-in exists but has not
credited yet: poll `GET /collections` rather than resending, since a second
request makes a second pay-in.

**Done when** `GET /balance` shows `available` risen by that collection's
`amount_credited`.

## 4. Quote, then create the payout

**The endpoint is the rail** — there is no `rail` field in the body. Take
`institution_id` from `GET /institutions`, whose entries each name their own
rail; cache the list and re-fetch when a create returns `unknown_institution`.
Posting an institution to the other rail's endpoint is rejected, never
misrouted.

Call `POST /fees/quote` with `direction: "payout"` first. At accept Hermes holds
`amount_mwk` **plus** the fee, so `available` must cover `total_debit`; if it
doesn't, you get `insufficient_funds` (402) and nothing is held. Your
beneficiary still receives the full `amount_mwk`.

Momo numbers go in full international form — `265`, then `9` for Airtel Money or
`8` for TNM Mpamba, then 8 digits — matching the institution you chose. A number
in any other shape is rejected rather than corrected. In the sandbox, payouts
reach the designated test accounts only — `reference/endpoints.md`, or
https://docs.jenzy.com/test-accounts.

**Done when** a create returns `202` with `status: "held"`, `available` has
dropped by the quote's `total_debit`, and the returned `id` is persisted against
your own intent record — with its `Idempotency-Key` — before your handler
returns, so a crash mid-flight is recoverable by replaying the same key.

## 5. Track to terminal

Register a webhook endpoint in the portal and handle `payout.succeeded` /
`payout.failed`; verify the signature per `reference/webhooks.md`, or
https://docs.jenzy.com/webhooks. Polling `GET /payouts/{id}` carries identical
data, so `GET /payouts` (newest first, keyset via `next_before_id`) is always a
valid catch-up path after an outage.

Delivery is at-least-once and can arrive out of order, so apply events by
`event.id` and let a repeat be a no-op.

**Done when** your store moves a payout to `succeeded` or `failed` with its
`terminal_at`, replaying the same event — or a poll that arrives after it —
leaves the record unchanged, and every tainted field is escaped at each sink you
carry it to.

## 6. Map every error code, and handle reversals

Read `reference/errors.md`, or https://docs.jenzy.com/errors. Rejections mean
the request was refused and nothing was held; failure codes mean an accepted
payout died and its full hold — amount and fee — is already released back to
`available`. Resubmission is always a **new** payout with a **new** key.

Reversals are the case that needs a human-visible path: **the event leads, the
balance lags.** A `payout.reversed` or `collection.reversed` event means money
that had already moved was clawed back by the provider. The correction is posted
manually by Jenzy operations, so for a short window `GET /balance` reads stale —
high after a reversed pay-in, still-spent after a reversed payout. Treat the
event as authoritative, hold back goods or services, and contact Jenzy about any
reversal you cannot account for.

**Done when** every rejection code has a branch (fix the request / back off and
retry / fund the balance / alert a human), every `failure.code` has a
resubmit-or-not decision, `reversed` is handled on both payouts and collections,
and no code falls through to a silent default.

## 7. Go live

Sandbox and production share nothing: API key, webhook endpoint and its signing
secret, and IP allowlist are all per environment and must be set up again. In
code, change the host from `api.sandbox.jenzy.com` to `api.jenzy.com` and keep
`/v1` and every route identical. Production has no simulate endpoint — fund by
sending real MWK to your account number, found in the portal under integration
settings.

**Done when** `GET /ping` against `api.jenzy.com` shows your org, and one small
payout to a destination you control reaches `succeeded`. Walk the first live
payouts with your Jenzy contact.

## Traps

- **A generated client can block every sandbox momo payout.** `openapi.json`
  publishes `^265[89][0-9]{8}$` for `mobile_number`, which is the production
  form; the sandbox test wallets (`1111…`) are exempted server-side and never
  match it. Keep that pattern out of your own client-side validation, or the
  sandbox rejects payouts the API would have accepted.
- **`fee: null` means not yet known, never free.** A payout's fee is filled in
  from the provider's own charge once it settles, and the settled figure is the
  *observed* charge — it can differ slightly from the quote, with the difference
  returned to `available`. `status`, not `fee`, tells you whether a payout is
  still moving.
- **`GET /balance` is the only authoritative balance.** The `balance` snapshot in
  a webhook envelope is a convenience as-of-preparation read; events arrive out
  of order, so balance math off webhooks drifts.
- **Reusing a key to retry a failed payout replays the failure.** The
  idempotency record returns the original outcome; a fresh attempt needs a fresh
  key.
- **`org_limit_exceeded` is not `rate_limited`.** Both are `429`, but the first
  is your org's daily cap or hourly payout velocity, the second is request rate
  with a `Retry-After` header. Backing off harder fixes only one of them.
- **Your webhook endpoint must answer `2xx` directly, within 10 seconds.**
  Redirects count as failures and are never followed. Do real work
  asynchronously.

## Reference

Each of these ships beside this file in the skill bundle, and is published on
the docs site — reach for whichever you have.

- `reference/endpoints.md` · https://docs.jenzy.com — every endpoint: request
  shape, response shape, pagination, sandbox test accounts, rate limits.
- `reference/errors.md` · https://docs.jenzy.com/errors — the full rejection and
  failure tables, with the retry decision for each code.
- `reference/webhooks.md` · https://docs.jenzy.com/webhooks — envelope, event
  catalog, and signature verification in Node and Python.
- `scripts/smoke-sandbox.sh` — ping → quote → simulated pay-in → payout → poll
  to terminal, against the sandbox. Run it to prove the loop end to end.
