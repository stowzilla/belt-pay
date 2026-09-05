# Changelog

## 0.1.0 — 2026-09-05

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
