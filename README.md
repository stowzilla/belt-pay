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
end
```

### Secrets Manager Format

The Stripe secret should contain:

```json
{
  "stripe_secret_key": "sk_live_...",
  "stripe_webhook_secret": "whsec_..."
}
```

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

The gem automatically handles these Stripe webhook events:

| Event | Behavior |
|-------|----------|
| `checkout.session.completed` | Marks pending transaction as completed |
| `checkout.session.expired` | Marks pending transaction as failed |
| `invoice.paid` | Records subscription renewal transaction |
| `invoice.payment_failed` | Logs payment failure |
| `customer.subscription.deleted` | Logs subscription cancellation |
| `customer.subscription.updated` | Logs subscription status changes |

### Customizing Webhook Behavior

Override the webhook controller to add custom logic:

```bash
belt g pay --controllers
```

This generates a controller in your app that inherits from the gem's default. Override individual handler methods as needed.

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
| `id` | UUID primary key |
| `customer_id` | Your app's customer/user ID |
| `provider` | Payment provider (`stripe`) |
| `provider_session_id` | Stripe checkout session ID |
| `provider_subscription_id` | Stripe subscription ID |
| `type` | `checkout`, `subscription`, `subscription_renewal`, `refund` |
| `status` | `pending`, `completed`, `failed`, `refunded`, `canceled` |
| `amount_cents` | Amount in cents |
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

  # Set these or update secrets manually after apply
  # stripe_secret_key     = var.stripe_secret_key
  # stripe_webhook_secret = var.stripe_webhook_secret
}
```

## Stripe Dashboard Setup

After deploying, configure your Stripe webhook endpoint:

1. Go to Stripe Dashboard → Developers → Webhooks
2. Add endpoint: `https://<your-api-domain>/pay/webhooks`
3. Select events:
   - `checkout.session.completed`
   - `checkout.session.expired`
   - `invoice.paid`
   - `invoice.payment_failed`
   - `customer.subscription.deleted`
   - `customer.subscription.updated`
4. Copy the signing secret into your Secrets Manager secret

## Removing

```bash
belt destroy pay
```

Then remove the module reference from your environment `main.tf` files.

## License

MIT
