# Changelog

## 0.0.7 — 2026-11-15

Security release for the Stripe webhook. **Read "Upgrading from 0.0.6 or earlier" below
before deploying**: the steps marked Required are not optional.

### Fixed

- **The webhook no longer accepts events signed with the placeholder secret.** The
  generated Terraform seeded the secret with `whsec_PLACEHOLDER` / `sk_test_PLACEHOLDER`,
  and the webhook verified against whatever it found, so on a deploy whose secret was
  never replaced anyone could sign a made-up event. `verify_webhook` now raises
  `Belt::Pay::ConfigurationError` unless the signing secret is a real `whsec_` secret,
  `ensure_api_key!` refuses a missing or placeholder API key, and the Terraform template
  creates the secret empty. `belt pay:setup` warns while either value is unset.
- **`checkout.session.completed` no longer means paid.** A transaction is completed only
  when the session's `payment_status` is `paid` or `no_payment_required`. A session paid
  by a delayed method (bank debit, voucher) stays `pending` until
  `checkout.session.async_payment_succeeded` completes it or `_failed` fails it.
- **Refunds and disputes reach the transaction.** `charge.refunded` records
  `amount_refunded_cents` and marks a fully refunded transaction `refunded`;
  `charge.dispute.created` marks it `disputed`; `charge.dispute.closed` returns it to
  `completed` (won) or `refunded` (lost).
- **A redelivered event changes nothing.** Rows the webhook creates are keyed on the
  Checkout Session / invoice id with a conditional put, and only a `pending` transaction
  can be completed, so Stripe's retries and Dashboard resends no longer add duplicate
  rows or revive a refunded purchase.
- **`Billable#subscribe!` no longer grants the plan before anything is paid.** `pay_plan`
  is recorded only when the subscription is `active` or `trialing`. The webhook sets it
  when Stripe reports the subscription active and clears it when the subscription is
  `canceled`, `unpaid` or `incomplete_expired` (it asks Stripe for the subscription's
  current status rather than trusting the event). This needs the new
  `Belt::Pay.configuration.customer_class`. The subscription's own transaction is
  `pending` until active. `cancel_subscription!(immediately: true)` clears `pay_plan`
  along with the subscription id.
- **Events missing a field no longer crash the webhook.** Stripe objects raise on a
  field the event doesn't carry (for example metadata without `app_customer_id`, or
  `invoice.subscription` on API versions from 2025-03-31), which made such events fail
  with a 500 on every retry. Fields are now read defensively.
- **Secrets are read without an app patch.** `fetch_api_key` / `fetch_webhook_secret`
  relied on a `SecretsHelper` Belt doesn't ship and returned nil without one. They now
  read the configured secret from AWS Secrets Manager directly (a `::SecretsHelper`
  defined by the app is still used when present).
- The webhook controller decodes a base64-encoded body (`isBase64Encoded`). Belt itself
  still rejects such a body before the controller runs, so this only takes effect once
  Belt passes it through.
- `Checkout.create` no longer records every pending transaction as `usd`: the currency
  comes from the request when it names one, and from the session when it is paid.

### Added

- **`Belt::Pay.on(*event_types) { |event, transaction| ... }`** runs your code when the
  webhook receives an event, after the gem's bookkeeping. See "Acting on Events" in the
  README.
- `Belt::Pay::WebhookHandler::EVENTS` gains `checkout.session.async_payment_succeeded`,
  `checkout.session.async_payment_failed`, `customer.subscription.created`,
  `charge.refunded`, `charge.dispute.created` and `charge.dispute.closed`.
- `belt pay:setup` offers to add missing events to an existing Stripe endpoint in place,
  keeping its signing secret.
- `Belt::Pay.configuration.customer_class`, transaction status `disputed`, and the
  transaction fields `amount_refunded_cents` and `provider_payment_intent_id` (now filled
  in). No table or index change is needed.

### Known limits

- A refund or dispute is matched to a checkout through its Checkout Session, and to a
  renewal through the charge's `invoice`. Stripe API versions from 2025-03-31 no longer
  put `invoice` on a charge, so on an endpoint using one of those a refunded renewal is
  not marked; use a `Belt::Pay.on('charge.refunded')` hook for those.
- A part refund has no row of its own: the running total is `amount_refunded_cents` on
  the original transaction.

### Upgrading from 0.0.6 or earlier

Do these in order, for every environment (`dev`, `prod`, ...).

1. **Bump the gem.** In the app's `Gemfile` (and `lambda/Gemfile` if it has one) allow
   `belt-pay` 0.0.7 (`gem 'belt-pay', '~> 0.0.7'`), then `bundle update belt-pay`.

2. **Required: run `belt 'pay:setup[<env>]'` once per environment.** It does two things
   this release needs: it subscribes the existing Stripe endpoint to the new events, and
   it tells you if the stored secret is still unset. Do not use `pay:show` for this; it
   prints live credentials. Answer the prompts in this order:

   | Prompt | Answer |
   |--------|--------|
   | `Stripe secret key [blank keeps existing]` | blank (Enter) |
   | `Create the <mode>-mode webhook endpoint in Stripe now? [y/N]` | `y` |
   | `Stripe <mode> secret key, or restricted key with Webhook Endpoints write [not stored]` | Only appears when the stored key is a restricted key that can't manage endpoints. Needs a person: paste an `sk_` key or a restricted key with Webhook Endpoints: Write. It is used once and not stored |
   | `Add them to this endpoint? (its signing secret stays the same) [Y/n]` | `y` |
   | `Replace it? [y/N]` | `n` |
   | `Stripe webhook signing secret [blank keeps existing]` | blank (Enter) |

   The output should include `Endpoint we_... now receives 12 events.` (Or do this part
   in the Stripe Dashboard: Developers -> Webhooks -> the endpoint -> add the six events
   listed under "Added".) **Do not skip this**: once this version is deployed, a checkout
   paid by a delayed method stays `pending` until
   `checkout.session.async_payment_succeeded` arrives, and refunds and disputes are only
   seen if the endpoint sends them.

3. **Required: if that run printed `Warning: ... not set in <secret>`**, or said
   `No Stripe secret key stored yet`, the environment still holds the placeholder (or
   nothing). Run `belt 'pay:setup[<env>]'` again and this time give it the real Stripe
   key and let it create the endpoint. Until then, by design, that environment answers
   every webhook with 500 and refuses Stripe calls.

4. **Required if the app uses `subscribe!(plan:)` or reads `pay_plan` / `plan` /
   `plan_allows?` / `within_limit?`:** set the customer model where the app and the
   webhook Lambda boot, and make sure that model is loaded in the webhook Lambda
   (`lambda/pay_webhooks.rb`):

   ```ruby
   Belt::Pay.configure { |config| config.customer_class = 'Customer' } # your Billable model
   ```

   Without it `pay_plan` is never set for a subscription that starts unpaid (the webhook
   logs `customer_class is not configured` on each subscription event). Code that relied
   on `pay_plan` being set immediately after `subscribe!` must wait for the webhook, or
   check `result[:status]`.

5. **Check what the webhook Lambda is allowed to do.** Belt Pay does not generate this
   IAM; it is in the app's Terraform (look for the policy attached to the `pay_webhooks`
   Lambda). A missing permission makes the affected events answer 500.
   - On the `<app>-<env>-pay-transactions` table and its indexes: `dynamodb:GetItem`,
     `dynamodb:Query`, `dynamodb:PutItem` and `dynamodb:UpdateItem`. `GetItem` is new in
     this release.
   - If you set `customer_class` (step 4): `dynamodb:GetItem`, `dynamodb:PutItem` and
     `dynamodb:UpdateItem` on that model's table.
   - `secretsmanager:GetSecretValue` on the Stripe secret (the generated
     `read_secrets_policy_arn`).
   - If the runtime Stripe key is a restricted key (`rk_`): at least Read on Checkout
     Sessions (to find the purchase behind a refund or dispute) and on Subscriptions.

6. **Check code that reads transactions.** `checkout`/`subscription` rows can now be
   `pending` after checkout completes, and `refunded` or `disputed` later. Treat only
   `status == 'completed'` as paid. Rows written by the webhook use the Stripe id
   (`cs_...`, `in_...`, `sub_...`) as `id` instead of a UUID. `Transaction.record_checkout`,
   `record_subscription` and `record_renewal` return nil when the row already exists.

7. **Remove app patches this release replaces** (optional, they keep working): a
   `prepend` over `fetch_api_key` / `fetch_webhook_secret` that reads Secrets Manager,
   and controller overrides that only check `payment_status`, refuse the placeholder
   secret or de-duplicate events. An overridden controller that calls
   `Belt::Pay.provider.verify_webhook` and `WebhookHandler.send(:dispatch, event)` keeps
   working; `dispatch` now also runs `Belt::Pay.on` hooks.

8. **Stop seeding placeholders in Terraform (optional hygiene).** In the app's generated
   `infrastructure/modules/pay/variables.tf`, change the defaults of `stripe_secret_key`
   and `stripe_webhook_secret` from `"sk_test_PLACEHOLDER"` / `"whsec_PLACEHOLDER"` to
   `""`. Edit those two lines by hand; do not regenerate with `belt g pay --force`,
   which would also overwrite `lambda/pay_webhooks.rb` and the Lambda config. Existing
   secrets are not touched (`ignore_changes`); this only affects environments created
   later.

9. Deploy (`belt apply <env>` / your usual deploy), then send a test event from the
   Stripe Dashboard and confirm the endpoint answers 200.

## 0.0.6 — 2026-11-02

- **`pay:setup` works with a restricted runtime key.** The stored key is what the app
  runs with, so it should be a restricted key (`rk_`) holding only what checkout and the
  portal need. Setup used to manage the webhook endpoint with that same key, so a
  restricted key without Webhook Endpoints access failed with a Stripe permission error.
  When Stripe refuses the stored key, setup now asks once for a key that can manage
  endpoints (an `sk_` secret key, or a restricted key with Webhook Endpoints: Write),
  uses it for the endpoint list/create/delete calls in that run only, and never stores
  it. A key from the other Stripe mode is refused. Leaving the prompt blank, or a second
  refusal, falls back to the Dashboard steps; the stored key is still saved either way.

## 0.0.5 — 2026-10-31

- **`create_checkout` no longer drops Checkout Session options.** The Stripe provider used
  to copy only `line_items`, `mode`, `success_url`, `cancel_url`, `metadata` and
  `subscription_data` into `Stripe::Checkout::Session.create` and silently discard
  everything else. It now forwards every option in
  `Belt::Pay::Providers::Stripe::CHECKOUT_SESSION_OPTIONS` — including
  `allow_promotion_codes`, `discounts`, `automatic_tax`, `payment_intent_data`,
  `setup_intent_data`, `tax_id_collection`, `customer_update`, `locale`, `expires_at`,
  `ui_mode`/`return_url` and the rest of the documented Checkout Session params.
  - Unknown keys raise `ArgumentError` naming the offending option, so the next missing
    param fails loudly instead of vanishing.
  - `extra: { ... }` merges any additional params in unvalidated, for Stripe options the
    list doesn't know about yet.
  - Options given as `nil` are omitted from the request.

## 0.0.4 — 2026-10-20

- **`belt pay:setup` creates the Stripe webhook endpoint for you.** After the secret-key
  prompt it reads `api_url` from `terraform output`, offers to create
  `<api_url>/pay/webhooks` in Stripe (subscribed to every event Belt Pay handles), and
  stores the returned `whsec_` signing secret directly. No Dashboard clicking.
  - Shows whether the key is test or live mode before creating anything.
  - If Stripe already has an endpoint for that URL, offers to replace it (the old one
    is deleted only after the new secret is saved) or links to it in the Dashboard.
  - Declining, or missing terraform output, prints step-by-step Dashboard instructions
    with the exact URL and events, then prompts for the secret as before.
  - `--webhook-url` / `BELT_PAY_WEBHOOK_URL` and `--webhook-events` /
    `BELT_PAY_WEBHOOK_EVENTS` override the defaults.
- `Belt::Pay::WebhookHandler::EVENTS` lists the Stripe events the handler acts on.

## 0.0.3 — 2026-10-02

- Add Belt-native `pay:setup`, `pay:show`, and `pay:edit` tasks through Belt's
  gem Rake-task extension mechanism. Select an environment with `BELT_ENV` or standard
  task-argument syntax such as `belt 'pay:setup[dev]'`.
- Make `belt pay:setup` the happy path: it prompts without echo for Stripe's API and
  webhook signing secrets, preserves either existing value when left blank, and writes
  directly through the AWS SDK.
- Add `belt pay:show` and `belt pay:edit` for inspecting and securely editing each
  environment's Stripe JSON secret in AWS Secrets Manager.
- Detect the Belt app name, AWS profile, and region from the selected environment,
  with environment-variable and explicit overrides for custom setups.
- Retain the packaged `belt-pay secrets:*` executable as a backward-compatible alias,
  pin the AWS Secrets Manager SDK, and include the pinned Rake runtime required for
  task dispatch in fresh Belt apps.

## 0.0.2 — 2026-09-05

- **Plan DSL (convention over configuration).** Declare subscription plans, their
  prices (per interval), limits, and feature flags once via `Belt::Pay.plans do ... end`,
  then look them up by symbolic key everywhere. Inspired by how popular Ruby billing
  gems keep plan definitions in code.
  - `Belt::Pay::Plan` — a plan's marketing copy, per-interval Stripe prices, named
    `limit`s (with `:unlimited`), and boolean `feature`s.
  - `Belt::Pay::PlanRegistry` — `Belt::Pay.plans`, `Belt::Pay.plan(:key)`,
    `Belt::Pay.plan_for_price(price_id)`.
  - `Belt::Pay.subscribe` / `Billable#subscribe!` now accept a `plan:` key (resolving
    the right Stripe price for the `interval:`) in addition to a raw `price_id:`.
  - `Billable` gains `#plan`, `#on_plan?`, `#plan_allows?(feature)`,
    `#within_limit?(name, usage)`, and a `pay_plan` attribute.

## 0.0.1 — 2026-09-01

- Initial release
- Stripe provider with customer provisioning, payment methods, checkout sessions
- Subscription management (create, cancel, billing portal)
- Transaction model for audit logging (DynamoDB)
- Billable concern for customer models
- Webhook handler with signature verification
- Generator: `belt g pay` (Terraform module, webhook Lambda, config, schema)
- Getting started guide
