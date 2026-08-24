#!/usr/bin/env bash
# Prove the Hermes loop end to end against the SANDBOX: ping, quote, simulated
# pay-in, payout, poll to terminal. Test money only — the script refuses to run
# against any host that is not the sandbox.
#
#   JENZY_API_KEY=jz_live_... ./smoke-sandbox.sh [--rail momo|bank] [--amount 50000]
#
# Requires: curl, jq.

set -euo pipefail

BASE_URL="${JENZY_BASE_URL:-https://api.sandbox.jenzy.com/v1}"
RAIL="momo"
AMOUNT="50000"

while [ $# -gt 0 ]; do
  case "$1" in
    --rail)   RAIL="${2:?--rail needs momo or bank}"; shift 2 ;;
    --amount) AMOUNT="${2:?--amount needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$BASE_URL" in
  *sandbox.jenzy.com*) ;;
  *) echo "refusing to run: BASE_URL '$BASE_URL' is not the sandbox. This script creates payouts." >&2
     exit 2 ;;
esac
case "$RAIL" in momo|bank) ;; *) echo "--rail must be momo or bank" >&2; exit 2 ;; esac
: "${JENZY_API_KEY:?set JENZY_API_KEY to a sandbox key}"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

# Sandbox-only destinations. Anything else is refused by the provider sandbox.
TEST_WALLET="111100000112"
TEST_ACCOUNT="3333888800"

api() { # api METHOD PATH [BODY] [EXTRA_HEADER]
  local method="$1" path="$2" body="${3:-}" extra="${4:-}"
  local args=(-sS -w '\n%{http_code}' -X "$method" "$BASE_URL$path"
              -H "Authorization: Bearer $JENZY_API_KEY")
  [ -n "$extra" ] && args+=(-H "$extra")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
  curl "${args[@]}"
}

step=0
call() { # call NAME METHOD PATH [BODY] [EXTRA_HEADER] [EXPECTED_STATUS...]
  local name="$1" method="$2" path="$3" body="${4:-}" extra="${5:-}"; shift 5 || true
  local raw status
  raw="$(api "$method" "$path" "$body" "$extra")"
  status="$(printf '%s' "$raw" | tail -n1)"
  RESP="$(printf '%s' "$raw" | sed '$d')"
  step=$((step + 1))
  if [ "$#" -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$status"; then
    echo "  [$step] $name -> HTTP $status (expected: $*)" >&2
    printf '%s\n' "$RESP" | jq . >&2 2>/dev/null || printf '%s\n' "$RESP" >&2
    exit 1
  fi
  echo "  [$step] $name -> HTTP $status"
}

uuid() { command -v uuidgen >/dev/null && uuidgen | tr 'A-Z' 'a-z' \
  || python3 -c 'import uuid; print(uuid.uuid4())'; }

echo "Hermes sandbox smoke test — $BASE_URL (rail: $RAIL, pay-in: $AMOUNT MWK)"

echo "auth"
call "GET /ping" GET /ping "" "" 200
jq -r '"      org: \(.org)  mode: \(.mode)  key: \(.key_prefix)"' <<<"$RESP"

echo "fund"
call "POST /fees/quote (collection)" POST /fees/quote \
  "{\"direction\":\"collection\",\"rail\":\"$RAIL\",\"amount_mwk\":$AMOUNT}" "" 200
jq -r '"      total_fee: \(.total_fee)  amount_received: \(.amount_received)"' <<<"$RESP"
EXPECTED_CREDIT="$(jq -r '.amount_received' <<<"$RESP")"

call "GET /balance (before)" GET /balance "" "" 200
BEFORE="$(jq -r '.available' <<<"$RESP")"
echo "      available: $BEFORE"

# Not idempotent: a 202 means it exists but has not credited. Never resend.
call "POST /collections/simulate" POST /collections/simulate \
  "{\"amount_mwk\":$AMOUNT,\"rail\":\"$RAIL\"}" "" 201 202
COLLECTION_ID="$(jq -r '.id' <<<"$RESP")"
jq -r '"      collection \(.id) \(.status)  gross: \(.amount_mwk)  fee: \(.fee)  credited: \(.amount_credited)"' <<<"$RESP"
CREDITED="$(jq -r '.amount_credited' <<<"$RESP")"
[ "$CREDITED" = "$EXPECTED_CREDIT" ] \
  && echo "      quote matches the credit exactly" \
  || echo "      NOTE: quote said $EXPECTED_CREDIT, credit was $CREDITED" >&2

echo "destination"
call "GET /institutions" GET /institutions "" "" 200
INSTITUTION_ID="$(jq -r --arg rail "$RAIL" \
  'first(.institutions[] | select(.rail == $rail)) | .institution_id' <<<"$RESP")"
INSTITUTION_NAME="$(jq -r --arg rail "$RAIL" \
  'first(.institutions[] | select(.rail == $rail)) | .name' <<<"$RESP")"
[ "$INSTITUTION_ID" = "null" ] && { echo "no $RAIL institution listed" >&2; exit 1; }
echo "      $INSTITUTION_NAME ($INSTITUTION_ID)"

echo "draw down"
PAYOUT_AMOUNT="$(jq -rn --arg c "$CREDITED" '($c | tonumber / 2 | floor)')"
[ "$PAYOUT_AMOUNT" -lt 1 ] && { echo "credited $CREDITED is too small to pay out" >&2; exit 1; }

call "POST /fees/quote (payout)" POST /fees/quote \
  "{\"direction\":\"payout\",\"rail\":\"$RAIL\",\"amount_mwk\":$PAYOUT_AMOUNT}" "" 200
jq -r '"      amount: \(.amount_mwk)  total_fee: \(.total_fee)  total_debit: \(.total_debit)"' <<<"$RESP"
TOTAL_DEBIT="$(jq -r '.total_debit' <<<"$RESP")"

# One intent, one key — reused verbatim on any retry of this same intent.
IDEM_KEY="$(uuid)"
if [ "$RAIL" = "momo" ]; then
  # The sandbox test wallet does not match the published production pattern;
  # it is exempted server-side. Client-side regex here would block it.
  BODY="{\"amount_mwk\":$PAYOUT_AMOUNT,\"institution_id\":$INSTITUTION_ID,\"mobile_number\":\"$TEST_WALLET\",\"beneficiary_name\":\"Smoke Test\"}"
  PATH_="/payouts/momo"
else
  BODY="{\"amount_mwk\":$PAYOUT_AMOUNT,\"institution_id\":$INSTITUTION_ID,\"account_number\":\"$TEST_ACCOUNT\",\"beneficiary_name\":\"Smoke Test\"}"
  PATH_="/payouts/bank"
fi
call "POST $PATH_ (key $IDEM_KEY)" POST "$PATH_" "$BODY" "Idempotency-Key: $IDEM_KEY" 202
PAYOUT_ID="$(jq -r '.id' <<<"$RESP")"
jq -r '"      payout \(.id) \(.status)  amount: \(.amount_mwk)  fee: \(.fee // "null — not yet known")"' <<<"$RESP"

# A replay of the same key + body must return the original response, not a second payout.
call "POST $PATH_ (replay, same key)" POST "$PATH_" "$BODY" "Idempotency-Key: $IDEM_KEY" 202 409
REPLAY_ID="$(jq -r '.id // empty' <<<"$RESP")"
if [ "$REPLAY_ID" = "$PAYOUT_ID" ]; then
  echo "      replay returned the same payout — idempotency holds"
elif [ -n "$REPLAY_ID" ]; then
  echo "      REPLAY MADE A SECOND PAYOUT ($REPLAY_ID) — stop and report this" >&2
  exit 1
else
  echo "      replay is still in progress (409 conflict) — expected under concurrency"
fi

call "GET /balance (after accept)" GET /balance "" "" 200
jq -r '"      available: \(.available)  held: \(.held)  shortfall: \(.shortfall)"' <<<"$RESP"
echo "      held should cover the amount plus its fee (quoted total_debit: $TOTAL_DEBIT)"

echo "track"
STATUS="unknown"
for attempt in $(seq 1 20); do
  call "GET /payouts/$PAYOUT_ID (attempt $attempt)" GET "/payouts/$PAYOUT_ID" "" "" 200
  STATUS="$(jq -r '.status' <<<"$RESP")"
  case "$STATUS" in
    succeeded|failed|reversed) break ;;
  esac
  sleep 3
done

jq -r '"      status: \(.status)  fee: \(.fee // "null")  terminal_at: \(.terminal_at // "null")  failure: \(.failure // "null" | tostring)"' <<<"$RESP"

call "GET /balance (final)" GET /balance "" "" 200
jq -r '"      available: \(.available)  held: \(.held)"' <<<"$RESP"

echo
case "$STATUS" in
  succeeded)
    echo "PASS — the whole loop works: funded, quoted, paid, terminal."
    echo "       collection $COLLECTION_ID, payout $PAYOUT_ID" ;;
  failed)
    echo "TERMINAL BUT FAILED — the integration path works; the payout itself died."
    echo "       Check failure.code against reference/errors.md." >&2
    exit 1 ;;
  reversed)
    echo "REVERSED — succeeded, then clawed back. The event leads, the balance lags." >&2
    exit 1 ;;
  *)
    echo "STILL IN FLIGHT after 20 attempts (status: $STATUS)." >&2
    echo "       'pending' is a legitimate resting state — re-read payout $PAYOUT_ID later." >&2
    exit 1 ;;
esac
