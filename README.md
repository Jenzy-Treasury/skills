# skills
Custom skills that helps you integrate and send money even faster

<!-- BEGIN hermes-mwk — generated, do not edit by hand -->
## `hermes-mwk` — Hermes MWK payouts

Hand your coding agent the [Jenzy Hermes](https://docs.jenzy.com) integration: a payout API
for Malawi, where you prefund a kwacha balance and draw it down to Malawian bank
accounts and mobile money, one API call each.

The skill is the same set of rules Jenzy's own engineers work to — the money
model, idempotency, fee quoting, webhook signature verification, every error
code, and the traps that cost integrators a day.

```bash
npx skills add jenzy-treasury/skills --skill hermes-mwk
```

Add `-g` to install it for every project on your machine, and `--agent` to target
one agent explicitly:

```bash
npx skills add jenzy-treasury/skills --skill hermes-mwk -g --agent claude-code -y
```

Then ask your agent to integrate Jenzy payouts, or invoke it by name with
`/hermes-mwk`.

### What is in it

```
hermes-mwk/
  SKILL.md                    the integration itself: 7 steps, each ending on a
                              condition you can check
  reference/endpoints.md      every endpoint, the payout lifecycle, fees, limits,
                              sandbox test accounts
  reference/errors.md         every error code, and whether to retry it
  reference/webhooks.md       envelope, event catalog, signature verification
  scripts/smoke-sandbox.sh    ping → quote → simulated pay-in → payout → poll to
                              terminal, against the sandbox
```

Prove the whole loop before you write any code — with a sandbox key:

```bash
JENZY_API_KEY=jz_live_… .claude/skills/hermes-mwk/scripts/smoke-sandbox.sh
```

It refuses to run against any host that is not the sandbox, so it can only ever
spend test money.

Full API documentation: https://docs.jenzy.com
<!-- END hermes-mwk -->
