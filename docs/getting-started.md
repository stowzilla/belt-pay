# Getting Started with Belt Pay

This guide walks you through adding payments to your Belt application from scratch.
By the end, you'll have a working subscription system with Stripe.

## Overview

Belt Pay handles the heavy lifting of payment integration:

- **Stripe customer provisioning** — automatically creates and links Stripe customers
- **Checkout sessions** — hosted payment pages for one-time and subscription purchases
- **Subscription management** — subscribe, check status, cancel
- **Billing portal** — customer self-service for updating cards and viewing invoices
- **Webhook handling** — automatic transaction recording and status updates
- **Transaction history** — audit log of all payment activity

## Prerequisites

Before you begin:

1. A [Stripe account](https://dashboard.stripe.com/register) (test mode is fine for development)
2. A Belt application with a Customer/User model
3. AWS credentials configured for deployment

## Step 1: Install the Gem

Add Belt Pay to your Gemfile:

```ruby
gem 'belt-pay'
```

Then install and run the generator:

```bash
bundle install
belt generate pay
```

The generator creates:

- Terraform module for Secrets Manager and IAM policies
- Lambda entry point for webhook handling
- Lambda config at `config/lambda/pay_webhooks.yml`
- DynamoDB schema updates for transaction logging
- Route injection for `/pay/webhooks`

## Step 2: Configure Your Customer Model

Include the `Billable` module in your customer model:

```ruby
class Customer < ActiveItem::Base
  include Belt::Pay::Billable
end
```

This adds payment methods to your model:

| Method | Description |
|--------|-------------|
| `ensure_pay_customer!` | Creates a Stripe customer if needed |
| `subscribe!(price_id:)` | Subscribe to a plan |
| `active_subscription?` | Check if subscription is active |
| `cancel_subscription!` | Cancel at period end |
| `billing_portal_url(return_url:)` | Generate self-service portal URL |
| `create_setup_intent` | Collect payment details (for Elements) |
| `attach_payment_method(pm_id)` | Attach a saved payment method |
| `payment_method_details` | Get card last4, brand, expiry |
| `transactions` | List all transactions |

## Step 3: Set Up Stripe

### Create a Product and Price

1. Go to [Stripe Dashboard → Products](https://dashboard.stripe.com/products)
2. Click **Add product**
3. Fill in name and description
4. Add a price (e.g., $99/year for a Pro subscription)
5. Copy the Price ID (starts with `price_`)

### Get Your API Keys

1. Go to [Stripe Dashboard → Developers → API Keys](https://dashboard.stripe.com/apikeys)
2. Copy your **Secret key** (starts with `sk_test_` or `sk_live_`)
3. Keep this safe — you'll add it to Secrets Manager

## Step 4: Deploy Infrastructure

Add the pay module to your environment's Terraform:

```hcl
# environments/dev/main.tf (or staging/prod)
module "pay" {
  source      = "../modules/pay"
  app_name    = var.app_name
  environment = var.environment
}
```

Deploy:

```bash
cd environments/dev
terraform init
terraform apply
```

### Add Stripe Keys to Secrets Manager

After deployment, add your Stripe credentials to the secret created by Terraform:

```bash
aws secretsmanager put-secret-value \
  --secret-id myapp-dev-stripe \
  --secret-string '{
    "stripe_secret_key": "sk_test_...",
    "stripe_webhook_secret": "whsec_..."
  }'
```

> **Note:** You'll get the webhook secret in Step 5.

## Step 5: Configure Stripe Webhooks

1. Go to [Stripe Dashboard → Developers → Webhooks](https://dashboard.stripe.com/webhooks)
2. Click **Add endpoint**
3. Enter your endpoint URL: `https://<your-api-domain>/pay/webhooks`
4. Select these events:
   - `checkout.session.completed`
   - `checkout.session.expired`
   - `invoice.paid`
   - `invoice.payment_failed`
   - `customer.subscription.deleted`
   - `customer.subscription.updated`
5. Click **Add endpoint**
6. Reveal and copy the **Signing secret** (starts with `whsec_`)
7. Update your Secrets Manager secret with this value

## Step 6: Build Your Subscription Flow

Here's a minimal subscription implementation:

### Controller

```ruby
class SubscriptionsController < BeltController::Base
  # POST /subscriptions
  def create
    # Ensure Stripe customer exists
    current_customer.ensure_pay_customer!

    # Create checkout session
    result = Belt::Pay.create_checkout(current_customer,
      line_items: [{ price: ENV['STRIPE_PRICE_ID'], quantity: 1 }],
      mode: 'subscription',
      success_url: "#{ENV['FRONTEND_URL']}/subscription/success?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: "#{ENV['FRONTEND_URL']}/pricing")

    success_response(checkout_url: result[:url])
  end

  # GET /subscriptions/status
  def status
    success_response(
      active: current_customer.active_subscription?,
      subscription_id: current_customer.pay_subscription_id
    )
  end

  # POST /subscriptions/cancel
  def cancel
    current_customer.cancel_subscription!
    success_response(message: 'Subscription will cancel at end of billing period')
  end

  # POST /subscriptions/portal
  def portal
    result = current_customer.billing_portal_url(
      return_url: "#{ENV['FRONTEND_URL']}/settings"
    )
    success_response(url: result[:url])
  end
end
```

### Routes

```ruby
# config/routes.rb
Belt.application.routes.draw do
  post   '/subscriptions',        to: 'subscriptions#create'
  get    '/subscriptions/status', to: 'subscriptions#status'
  post   '/subscriptions/cancel', to: 'subscriptions#cancel'
  post   '/subscriptions/portal', to: 'subscriptions#portal'
end
```

### Frontend Integration

```javascript
// Redirect to Stripe Checkout
async function subscribe() {
  const response = await fetch('/subscriptions', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json'
    }
  });
  const { checkout_url } = await response.json();
  window.location.href = checkout_url;
}

// Check subscription status
async function checkSubscription() {
  const response = await fetch('/subscriptions/status', {
    headers: { 'Authorization': `Bearer ${token}` }
  });
  const { active } = await response.json();
  return active;
}

// Open billing portal
async function openBillingPortal() {
  const response = await fetch('/subscriptions/portal', {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${token}` }
  });
  const { url } = await response.json();
  window.location.href = url;
}
```

## Step 7: Test Your Integration

### Test Card Numbers

Stripe provides test cards for development:

| Card Number | Scenario |
|-------------|----------|
| `4242424242424242` | Successful payment |
| `4000000000000002` | Card declined |
| `4000002500003155` | Requires 3D Secure |

Use any future expiry date and any 3-digit CVC.

### Verify the Flow

1. Call `POST /subscriptions` to get a checkout URL
2. Complete checkout with test card `4242424242424242`
3. Verify `GET /subscriptions/status` returns `active: true`
4. Check your DynamoDB transactions table for the recorded payment
5. Verify Stripe Dashboard shows the subscription

### Webhook Testing

Use the Stripe CLI to forward webhooks to your local environment:

```bash
stripe listen --forward-to localhost:3000/pay/webhooks
```

## Step 8: Gate Features by Subscription

Use a before_action to protect premium features:

```ruby
class ProFeaturesController < BeltController::Base
  before_action :require_subscription!

  def dashboard
    # Only accessible to subscribers
    success_response(message: 'Welcome to Pro!')
  end

  private

  def require_subscription!
    unless current_customer.active_subscription?
      error_response('Pro subscription required', 403)
    end
  end
end
```

## Environment Variables

| Variable | Purpose | Example |
|----------|---------|---------|
| `BELT_PAY_SECRET_NAME` | Secrets Manager secret name | `myapp-dev-stripe` |
| `STRIPE_PRICE_ID` | Your subscription price ID | `price_1234...` |
| `FRONTEND_URL` | Your frontend domain | `https://app.example.com` |

## What's Next?

- **[React Example](react-example.md)** — Custom card forms with Stripe Elements
- **One-time payments** — Use `mode: 'payment'` for product purchases
- **Multiple plans** — Pass different `price_id` values for different tiers
- **Metered billing** — Use Stripe's usage-based pricing with Belt Pay

## Troubleshooting

### "No such customer" errors

Ensure you call `ensure_pay_customer!` before any payment operations:

```ruby
current_customer.ensure_pay_customer!
Belt::Pay.create_checkout(current_customer, ...)
```

### Webhooks not arriving

1. Verify your endpoint URL is publicly accessible
2. Check Stripe Dashboard → Webhooks for failed delivery attempts
3. Ensure the webhook secret in Secrets Manager matches Stripe

### Subscription shows inactive after payment

Webhooks update subscription status. If webhooks aren't configured:

1. Check Stripe Dashboard → Webhooks for errors
2. Verify the webhook secret matches
3. Check Lambda logs for the webhook handler

### Test mode vs Live mode

Set `BELT_PAY_MODE=test` for development, `BELT_PAY_MODE=live` for production.
Use separate Secrets Manager secrets for each environment.
