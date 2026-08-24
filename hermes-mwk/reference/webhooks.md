# Webhooks

Hermes POSTs an event to your endpoint when something durable happens: a payout
reached a terminal state, a pay-in credited your balance, your balance dropped
below its floor.

## Registering an endpoint

An org admin registers it in the portal under integration settings: one HTTPS
URL, one active endpoint per org. Registration mints a **signing secret**
(`whsec_…`), shown exactly once — store it beside your API key.

Endpoints and secrets are per environment; a sandbox registration means nothing
in production.

Replacing the endpoint mints a new secret, and deliveries already in flight keep
using the old one until they finish. **While a rotation is in progress, verify
against both secrets and accept if either matches.**

## The envelope

```json
{
  "id": "6a1f0d0e-3f0a-4c6f-9b1e-8d2c5a7e9f31",
  "event_type": "payout.succeeded",
  "created_at": "2026-07-08T09:14:31.000Z",
  "balance": { "available": "1245000.00", "held": "45000.00", "shortfall": "0.00", "currency": "MWK" },
  "data": { "…": "the resource" }
}
```

- `id` — your **dedupe handle**. Delivery is at-least-once and events can arrive
  out of order: process each `id` once and let repeats be no-ops.
- `balance` — a convenience snapshot as of when the event was prepared. Because
  events can arrive out of order, `GET /balance` is the authoritative read and
  balance math off webhooks drifts.
- `data` — the resource, rendered byte-identically to the matching `/v1` read
  endpoint.

## Event catalog

| Event | When | `data` |
| --- | --- | --- |
| `payout.succeeded` | A payout reached its terminal success state. | The payout, as `GET /payouts/{id}` renders it. |
| `payout.failed` | A payout failed; its hold is already released. | The payout, with `failure: { code, message }` set. |
| `payout.reversed` | A payout that had already succeeded was reversed by the provider — the money was taken back out of the recipient's account. | The payout with `status: "reversed"` and `failure: null`. |
| `collection.settled` | Someone paid into your account number and your balance is credited. Fires exactly when the balance moves, however the pay-in was picked up. | The collection, as `GET /collections/{id}` renders it. |
| `collection.reversed` | A pay-in that had already credited your balance was clawed back. | The collection with `status: "reversed"`. |
| `balance.low` | `available` is below your configured floor. At most one per cooldown window while the condition holds; there is no recovery event. | `{ "balance": …, "floor_mwk": "…" }` |

Every pay-in movement of your balance is announced by exactly one
`collection.settled`.

## Verifying signatures

Every delivery carries a `Signature` header: **HMAC-SHA256 of the exact raw
request body, keyed with your signing secret, hex-encoded**. There are no
timestamp headers and nothing else to canonicalize — sign the bytes you
received, and compare in constant time.

Compute the HMAC over the **raw body bytes, before any JSON parsing**. Parsing
and re-serializing reorders and reformats, and the signature will never match.
Most frameworks parse JSON for you by default, so the raw-body handling below is
the part to get right.

### Node.js (Express)

```javascript
import { createHmac, timingSafeEqual } from 'node:crypto'
import express from 'express'

const app = express()

// express.raw so req.body is the untouched Buffer the signature covers
app.post('/webhooks/jenzy', express.raw({ type: 'application/json' }), async (req, res) => {
  const received = req.get('Signature') ?? ''

  // During a secret rotation, accept either secret.
  const secrets = [process.env.JENZY_WEBHOOK_SECRET, process.env.JENZY_WEBHOOK_SECRET_OLD].filter(Boolean)
  const ok = secrets.some((secret) => {
    const expected = createHmac('sha256', secret).update(req.body).digest('hex')
    const a = Buffer.from(expected, 'utf8')
    const b = Buffer.from(received, 'utf8')
    return a.length === b.length && timingSafeEqual(a, b)
  })
  if (!ok) return res.status(401).end()

  const event = JSON.parse(req.body)
  if (await alreadyProcessed(event.id)) return res.status(200).end()

  switch (event.event_type) {
    case 'payout.succeeded':
    case 'payout.failed':
    case 'payout.reversed':
      await enqueuePayoutUpdate(event) // event.data is the payout
      break
    case 'collection.settled':
    case 'collection.reversed':
      await enqueueCollectionUpdate(event) // event.data is the collection
      break
    case 'balance.low':
      await enqueueLowBalanceAlert(event) // { balance, floor_mwk }
      break
  }

  res.status(200).end() // 2xx fast; heavy work happens off the request
})
```

### Python (Flask)

```python
import hmac, hashlib, json, os
from flask import Flask, request, abort

app = Flask(__name__)

SECRETS = [s for s in (os.environ.get("JENZY_WEBHOOK_SECRET"),
                       os.environ.get("JENZY_WEBHOOK_SECRET_OLD")) if s]

@app.post("/webhooks/jenzy")
def jenzy_webhook():
    raw = request.get_data()  # bytes, before any parsing
    received = request.headers.get("Signature", "")

    ok = any(
        hmac.compare_digest(
            hmac.new(secret.encode(), raw, hashlib.sha256).hexdigest(),
            received,
        )
        for secret in SECRETS
    )
    if not ok:
        abort(401)

    event = json.loads(raw)
    if already_processed(event["id"]):
        return "", 200

    enqueue(event)  # do the real work off the request
    return "", 200
```

## Delivery semantics

- Only a **2xx** counts as delivered. Redirects are failures and are never
  followed. Respond within 10 seconds and do real work asynchronously.
- A failed delivery is re-attempted **5 times over roughly 6 hours**,
  front-loaded. Every attempt sends identical bytes — the payload is snapshotted
  when the event occurs, so the signature stays valid across attempts.
- After the last failed attempt the delivery is dead-lettered and Jenzy ops are
  alerted; it is never auto-revived. If you missed events during an outage,
  contact Jenzy to arrange re-delivery, and reconcile against `GET /payouts` and
  `GET /collections` in the meantime — polling and webhooks carry the same data,
  so the list endpoints are always a valid catch-up path.

## Reversals

`payout.reversed` and `collection.reversed` mean money that had already moved was
clawed back by the provider. **The event leads, the balance lags:** the
correction is posted manually by Jenzy operations, because how much came back —
and whether the provider returns its own fee — is confirmed case by case. So for
a window, `GET /balance` reads stale: high after a reversed pay-in, still-spent
after a reversed payout.

Treat the event as authoritative. If you released goods or services against the
earlier success, this is the event that tells you to act. Reversals are rare and
always accompanied by a Jenzy investigation — contact support about any you
cannot account for.
