# Changelog

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
