# belt-pay

Payments and subscriptions for [Belt](https://github.com/stowzilla/belt) applications via Stripe.

> **New to Belt Pay?** Check out the [Getting Started Guide](docs/getting-started.md) for a complete walkthrough.

## Installation

Add to your Gemfile:

```ruby
gem 'belt-pay'
```

Then:

```bash
bundle install
belt generate pay
```

## Defining Plans (Convention over Configuration)

Declare your plans once — their prices, limits, and feature flags live in code, not
scattered across config. Look them up by a symbolic key everywhere else.

```ruby
# config/initializers/pay.rb (or wherever you boot)
Belt::Pay.plans do
  plan :free do
    name  'Free'
    description 'For small teams getting started'
    limit :projects, 1
    limit :seats,    3
  end

  plan :pro do
    name        'Pro'
    description 'For growing teams'
    featured                                   # highlight this plan in your UI
    price 49,  interval: :month, stripe_price: ENV['STRIPE_PRO_MONTH']
    price 490, interval: :year,  stripe_price: ENV['STRIPE_PRO_YEAR']
    limit :projects, :unlimited
    limit :seats,    :unlimited
    feature :sso, :audit_logs
  end
end
```

Then use the plans:

```ruby
# Subscribe by plan key — belt-pay resolves the Stripe price for the interval
customer.subscribe!(plan: :pro, interval: :year)

# Look plans up
Belt::Pay.plan(:pro).amount(interval: :month)   # => 49.0
Belt::Pay.plans.paid                             # => [pro, ...]
Belt::Pay.plans.featured                         # => the :pro plan
Belt::Pay.plans.to_a                             # => [{ key:, name:, prices:, limits:, ... }] for your frontend

# Gate features and enforce limits. The plan is granted once Stripe reports the
# subscription active (or trialing) and taken back when it ends; see
# "Plans follow the subscription" below.
customer.on_plan?(:pro)                          # => true
customer.plan_allows?(:sso)                      # => true
customer.within_limit?(:projects, current_count) # => false once the ceiling is hit
```

### Plan API

| Method | Description |
|--------|-------------|
| `Belt::Pay.plans { ... }` | Declare plans (block) or read the registry |
| `Belt::Pay.plan(:key)` | Look up one plan (nil if undeclared) |
| `Belt::Pay.plan_for_price(id)` | Find the plan owning a Stripe price ID |
| `plan.amount(interval:)` | Price in whole currency units |
| `plan.amount_cents(interval:)` | Price in cents |
| `plan.stripe_price_id(interval:)` | Stripe price ID for an interval |
| `plan.limit(:name)` | Read a limit (Integer, `:unlimited`, or nil) |
| `plan.allows?(:name, usage)` | Is `usage` under the limit? |
| `plan.includes_feature?(:name)` | Does the plan unlock a feature? |
| `plan.to_h` | Serialize for API/frontend |

## What You Get

### From the gem (no generation needed)

```ruby
# Include in your Customer/User model
class Customer < ActiveItem::Base
  include Belt::Pay::Billable
end

# Ensure a Stripe customer exists
customer.ensure_pay_customer!

# Create a checkout session (one-time or subscription)
Belt::Pay.create_checkout(customer,
  line_items: [{ price: 'price_xxx', quantity: 1 }],
  mode: 'subscription',
  success_url: 'https://app.example.com/success?session_id={CHECKOUT_SESSION_ID}',
  cancel_url: 'https://app.example.com/cancel')

# Any Stripe Checkout Session option passes straight through
Belt::Pay.create_checkout(customer,
  line_items: [{ price: 'price_xxx', quantity: 1 }],
  success_url: 'https://app.example.com/success?session_id={CHECKOUT_SESSION_ID}',
  cancel_url: 'https://app.example.com/cancel',
  allow_promotion_codes: true,                        # Dashboard coupons / promo codes
  automatic_tax: { enabled: true },                   # Stripe Tax
  payment_intent_data: { metadata: { pass_id: 42 } }) # carried onto the charge, so a
                                                      # Dashboard refund still knows the app record
# Unknown keys raise ArgumentError instead of being silently dropped.
# Use `extra: { ... }` to forward a Stripe param this gem doesn't list yet.

# Subscribe directly (when payment method is already attached)
customer.subscribe!(price_id: 'price_xxx')

# Check subscription status
customer.active_subscription?  # => true

# Customer self-service billing portal
customer.billing_portal_url(return_url: 'https://app.example.com/settings')
# => { url: "https://billing.stripe.com/p/session/..." }

# Collect payment method (returns client_secret for Stripe Elements)
result = customer.create_setup_intent
result.client_secret  # => "seti_xxx_secret_yyy"

# Attach a payment method
customer.attach_payment_method('pm_xxx')

# View payment details
customer.payment_method_details
# => { last4: "4242", brand: "visa", exp_month: 12, exp_year: 2027 }

# Transaction history
customer.transactions
# => [#<Belt::Pay::Transaction type="subscription" status="completed" ...>]
```

### From the generator (`belt g pay`)

- **Terraform module** — Secrets Manager for Stripe keys, IAM policies
- **Lambda entry point** — Dedicated webhook Lambda for Stripe events
- **Lambda config** — `config/lambda/pay_webhooks.yml`
- **Schema update** — DynamoDB table for transaction audit log
- **Route injection** — Adds `/pay/webhooks` endpoint

## Configuration

### Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `BELT_PAY_SECRET_NAME` | Secrets Manager secret name for Stripe keys | — |
| `BELT_PAY_WEBHOOK_SECRET_NAME` | Secret name for webhook signing (falls back to BELT_PAY_SECRET_NAME) | — |
| `BELT_PAY_MODE` | `test` or `live` | `test` |
| `APP_NAME` | App name for table naming | — |
| `ENVIRONMENT` | Environment for table naming | — |

### Programmatic Configuration

```ruby
Belt::Pay.configure do |config|
  config.provider = :stripe                    # Only :stripe for now
  config.secret_name = 'myapp-prod-stripe'     # Secrets Manager secret
  config.table_name_prefix = 'myapp-prod'      # DynamoDB table prefix
  config.customer_class = 'Customer'           # Your Billable model (class or name)
end
```

#### Plans follow the subscription

`customer_class` is the model that includes `Belt::Pay::Billable`. Set it wherever the
webhook Lambda boots (the model must be loadable there). The webhook uses it to find the
customer named by a subscription's `app_customer_id` and keep `pay_plan` /
`pay_subscription_id` in step with Stripe:

- `subscribe!(plan:)` records `pay_plan` only if the subscription is already `active` or
  `trialing`. One that still needs its first payment (`incomplete`, the usual case)
  grants nothing yet.
- When Stripe reports the subscription `active` or `trialing`, the webhook sets
  `pay_plan` (the plan declared for the subscription's price, else its `plan` metadata).
- When it becomes `canceled`, `unpaid` or `incomplete_expired`, the webhook clears
  `pay_plan`. `past_due` keeps it while Stripe retries the payment.

Without `customer_class` the webhook cannot do any of this: it logs an error on each
subscription event and `pay_plan` is never set for a subscription that starts unpaid.

### Secrets Manager Format

The Stripe secret should contain:

```json
{
  "stripe_secret_key": "sk_live_...",
  "stripe_webhook_secret": "whsec_..."
}
```

Belt Pay reads it straight from Secrets Manager (the webhook and API Lambdas need
`secretsmanager:GetSecretValue` on it, which the generated `read_secrets_policy_arn`
grants). The generated Terraform creates the secret with both values empty, and Belt Pay
refuses to work with a value that is missing or a placeholder: `verify_webhook` raises
`Belt::Pay::ConfigurationError` (the webhook answers 500) unless the signing secret is a
real `whsec_` secret, and no Stripe call is made without a real API key. Nothing is ever
verified against a secret someone else could know.

### Setting Up and Managing Secrets

Belt Pay hooks into Belt through its standard gem-provided Rake task mechanism. The
guided happy path uses `BELT_ENV` to select the environment:

```bash
BELT_ENV=dev belt pay:setup
```

It prompts without echo for the Stripe secret key, then offers to create the webhook
endpoint in Stripe for you: it reads `api_url` from `terraform output`, creates
`<api_url>/pay/webhooks` subscribed to every [handled event](#webhook-events), and stores
the `whsec_` signing secret Stripe returns. Everything goes directly through the Stripe
API and AWS SDK. Run it after `belt apply` so the URL is known.

Decline (or run it before the first apply) and it prints step-by-step Dashboard
instructions with the exact URL and events, then prompts for the signing secret. Leave
either prompt blank to preserve its existing value. Use `--webhook-url` /
`BELT_PAY_WEBHOOK_URL` or `--webhook-events` / `BELT_PAY_WEBHOOK_EVENTS` to override the
defaults. Test (`sk_test_`) and live (`sk_live_`) keys get separate endpoints and secrets.

If Stripe already has an endpoint for the URL and it lacks some handled events (one
created by an older Belt Pay, say), setup offers to add them to it in place, which keeps
its signing secret. Setup also warns when the key or signing secret is still unset.

Prefer a [restricted key](https://docs.stripe.com/keys#limit-access) (`rk_`) as the
stored key, scoped to what your app calls at runtime (typically Customers, Checkout
Sessions, Customer portal and Subscriptions). The webhook reads Checkout Sessions (to
find the purchase a refund or dispute belongs to) and Subscriptions (to check a
subscription's current status), so give those at least Read. It doesn't need Webhook
Endpoints access:
when Stripe refuses it for the endpoint step, setup asks once for a key that can manage
endpoints (your `sk_` secret key, or a restricted key with Webhook Endpoints: Write),
uses it for that step only, and doesn't store it.

You can also pass the environment with standard Rake task-argument syntax:

```bash
belt 'pay:setup[dev]'
```

Rails-like inspection and arbitrary JSON editing remain available for advanced use:

```bash
BELT_ENV=dev belt pay:show
EDITOR="code --wait" BELT_ENV=dev belt pay:edit
# Or: belt 'pay:show[dev]' / belt 'pay:edit[dev]'
```

`pay:show` prints the complete decrypted JSON to stdout. `pay:edit` opens it with
`$VISUAL` or `$EDITOR`, validates that the result is a JSON object, and writes a new
Secrets Manager version only when the content changed. Its temporary file is mode
`0600` and is removed when the editor closes. All write paths refuse to overwrite a
secret that changed while the command was open.

The tasks detect the application name from Terraform, the AWS profile from
`infrastructure/<env>/belt.rb`, and the region from Terraform or AWS environment
variables. Custom setups can override those values with `APP_NAME`,
`BELT_PAY_SECRET_NAME`, `AWS_PROFILE`, and `AWS_REGION`:

```bash
APP_NAME=my_app BELT_ENV=prod AWS_PROFILE=my-prod-profile belt pay:setup
BELT_PAY_SECRET_NAME=custom-stripe-secret BELT_ENV=prod belt pay:edit
```

Because `pay:show` intentionally reveals credentials, avoid redirecting its output to
logs or sharing it in chat. The packaged `belt-pay secrets:*` executable remains as a
backward-compatible alias, but the Belt-native tasks are the preferred interface.

## Common Patterns

### Annual Subscription (Feature Gating)

```ruby
# In your controller
class SubscriptionsController < BeltController::Base
  def create
    price_id = ENV['STRIPE_ANNUAL_PRICE_ID']  # Created in Stripe Dashboard
    result = current_customer.subscribe!(price_id: price_id, metadata: { plan: 'pro' })
    success_response(subscription_id: result[:subscription_id], status: result[:status])
  end

  def status
    success_response(active: current_customer.active_subscription?)
  end

  def cancel
    current_customer.cancel_subscription!  # Cancels at period end
    success_response(message: 'Subscription will cancel at end of billing period')
  end

  def portal
    result = current_customer.billing_portal_url(return_url: "#{ENV['FRONTEND_URL']}/settings")
    success_response(url: result[:url])
  end
end
```

### One-Time Payment (Product Purchase)

```ruby
class CheckoutController < BeltController::Base
  def create
    product = Product.find(params['product_id'])

    result = Belt::Pay.create_checkout(current_customer,
      line_items: [{
        price_data: {
          currency: 'usd',
          product_data: { name: product.name },
          unit_amount: product.price_cents
        },
        quantity: 1
      }],
      mode: 'payment',
      success_url: "#{ENV['FRONTEND_URL']}/checkout/success?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: "#{ENV['FRONTEND_URL']}/products")

    success_response(checkout_url: result[:url])
  end
end
```

### Checking Subscription Access (Middleware Pattern)

```ruby
class ProController < BeltController::Base
  before_action :require_subscription!

  private

  def require_subscription!
    unless current_customer.active_subscription?
      error_response('Pro subscription required', 403)
    end
  end
end
```

## Webhook Events

The gem automatically handles these Stripe webhook events
(`Belt::Pay::WebhookHandler::EVENTS`, which is what `belt pay:setup` subscribes the
endpoint to):

| Event | Behavior |
|-------|----------|
| `checkout.session.completed` | Completes the transaction if the session is paid (`payment_status` `paid` or `no_payment_required`). A session paid by a delayed method (bank debit, voucher) stays `pending` |
| `checkout.session.async_payment_succeeded` | Completes the pending transaction of a delayed payment |
| `checkout.session.async_payment_failed` | Marks it `failed` |
| `checkout.session.expired` | Marks pending transaction as `failed` |
| `invoice.paid` | Records a subscription renewal transaction (once per invoice) |
| `invoice.payment_failed` | Logs payment failure |
| `customer.subscription.created` / `.updated` / `.deleted` | Sets or clears the customer's `pay_plan` to match the subscription (see [Plans follow the subscription](#plans-follow-the-subscription)) and settles the subscription's transaction |
| `charge.refunded` | Records `amount_refunded_cents`; a full refund marks the transaction `refunded` |
| `charge.dispute.created` | Marks the transaction `disputed` |
| `charge.dispute.closed` | Won: `completed` again. Lost: `refunded` |

Stripe delivers events at least once, and anyone with Dashboard access can send one
again. Handling is safe to repeat: rows the webhook creates are keyed on the Checkout
Session or invoice id, and only a `pending` transaction can become `completed`, so a
redelivered event never adds a row or revives a refunded purchase.

**Only `completed` means the customer has paid.** If your app decides what someone owns
from `customer.transactions`, check `status == 'completed'`.

### Acting on Events

Register a hook to run your own code when an event arrives, after the gem's bookkeeping.
The block gets the Stripe event and the `Belt::Pay::Transaction` it touched (`nil` when
the event has none):

```ruby
# Wherever the webhook Lambda boots
Belt::Pay.on('checkout.session.completed', 'checkout.session.async_payment_succeeded') do |event, transaction|
  Orders.fulfil(transaction) if transaction&.status == 'completed'
end

Belt::Pay.on('charge.refunded', 'charge.dispute.created', 'charge.dispute.closed') do |event, transaction|
  Orders.revoke(transaction) if transaction && transaction.status != 'completed'
end
```

Hooks run on every delivery, including repeats, so make them safe to run twice and go by
`transaction.status` rather than the event alone. A hook that raises fails the webhook
(HTTP 500) and Stripe sends the event again later. A hook can be registered for any
event type, including ones the gem does nothing with; add those to the endpoint with
`--webhook-events` or in the Dashboard.

### Customizing Webhook Behavior

For anything a hook can't do, override the webhook controller:

```bash
belt g pay --controllers
```

This generates a controller in your app that inherits from the gem's default.

## Transaction Model

`Belt::Pay::Transaction` lives inside the gem and records all payment activity:

```ruby
customer.transactions.each do |txn|
  puts "#{txn.type}: #{txn.amount_cents} #{txn.currency} — #{txn.status}"
end
# subscription: 9900 usd — completed
# subscription_renewal: 9900 usd — completed
```

### Fields

| Field | Description |
|-------|-------------|
| `id` | Primary key: a UUID, or the Stripe id (Checkout Session, invoice, subscription) for rows that must exist only once |
| `customer_id` | Your app's customer/user ID |
| `provider` | Payment provider (`stripe`) |
| `provider_session_id` | Stripe checkout session ID |
| `provider_subscription_id` | Stripe subscription ID |
| `provider_payment_intent_id` | Stripe PaymentIntent ID of a paid checkout |
| `type` | `checkout`, `subscription`, `subscription_renewal`, `refund` |
| `status` | `pending` (not paid yet), `completed` (paid), `failed`, `refunded`, `disputed`, `canceled` |
| `amount_cents` | Amount in cents |
| `amount_refunded_cents` | How much of it has been refunded, if any |
| `currency` | ISO currency code |
| `metadata` | Free-form JSON metadata |
| `created_at` | ISO 8601 timestamp |

## Terraform Module

After running `belt g pay`, add the module to your environment's `main.tf`:

```hcl
module "pay" {
  source      = "../modules/pay"
  app_name    = var.app_name
  environment = var.environment

}
```

The secret is created empty. Store the real values with `belt pay:setup <env>` after
`belt apply`; until then Belt Pay refuses to call Stripe or accept a webhook.

## Stripe Dashboard Setup

`BELT_ENV=<env> belt pay:setup` creates the webhook endpoint and stores its signing
secret for you. To do it by hand instead:

1. Go to Stripe Dashboard → Developers → Webhooks
2. Add endpoint: `https://<your-api-domain>/pay/webhooks`
3. Select events:
   - `checkout.session.completed`
   - `checkout.session.async_payment_succeeded`
   - `checkout.session.async_payment_failed`
   - `checkout.session.expired`
   - `invoice.paid`
   - `invoice.payment_failed`
   - `customer.subscription.created`
   - `customer.subscription.updated`
   - `customer.subscription.deleted`
   - `charge.refunded`
   - `charge.dispute.created`
   - `charge.dispute.closed`
4. Copy the signing secret into your Secrets Manager secret

## Removing

```bash
belt destroy pay
```

Then remove the module reference from your environment `main.tf` files.

## License

MIT
