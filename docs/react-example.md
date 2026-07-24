# React Example: Stripe Elements Card Form

This example shows a React component for collecting payment details using Stripe Elements.
Use this when you need a custom card form instead of Stripe's hosted Checkout page.

> **Note:** For most use cases, Stripe Checkout (via `Belt::Pay.create_checkout`) is simpler
> and handles card input, validation, and 3D Secure automatically with no frontend code.
> Use Elements only when you need full control over the payment UI.

## Prerequisites

```bash
npm install @stripe/react-stripe-js @stripe/stripe-js
```

## Setup Intent Flow (Saving a Card)

```jsx
import { useState } from 'react';
import { Elements, CardElement, useStripe, useElements } from '@stripe/react-stripe-js';
import { loadStripe } from '@stripe/stripe-js';

const stripePromise = loadStripe(process.env.REACT_APP_STRIPE_PUBLISHABLE_KEY);

function SaveCardForm({ onSuccess }) {
  const stripe = useStripe();
  const elements = useElements();
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e) => {
    e.preventDefault();
    setLoading(true);
    setError(null);

    // 1. Get the setup intent client_secret from your Belt API
    const response = await fetch('/api/payment-methods/setup', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${getToken()}`, 'Content-Type': 'application/json' }
    });
    const { client_secret } = await response.json();

    // 2. Confirm the setup intent with Stripe
    const { error: stripeError, setupIntent } = await stripe.confirmCardSetup(client_secret, {
      payment_method: { card: elements.getElement(CardElement) }
    });

    if (stripeError) {
      setError(stripeError.message);
      setLoading(false);
      return;
    }

    // 3. Tell your Belt API about the payment method
    await fetch('/api/payment-methods/confirm', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${getToken()}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ payment_method_id: setupIntent.payment_method })
    });

    setLoading(false);
    onSuccess?.();
  };

  return (
    <form onSubmit={handleSubmit}>
      <CardElement options={{
        style: {
          base: { fontSize: '16px', color: '#424770', '::placeholder': { color: '#aab7c4' } },
          invalid: { color: '#9e2146' }
        }
      }} />
      {error && <p className="error">{error}</p>}
      <button type="submit" disabled={!stripe || loading}>
        {loading ? 'Saving...' : 'Save Card'}
      </button>
    </form>
  );
}

// Wrap with Elements provider
export default function SaveCard({ onSuccess }) {
  return (
    <Elements stripe={stripePromise}>
      <SaveCardForm onSuccess={onSuccess} />
    </Elements>
  );
}
```

## Corresponding Belt Controller

```ruby
class PaymentMethodsController < BeltController::Base
  # POST /payment-methods/setup
  def setup
    result = current_customer.create_setup_intent
    success_response(client_secret: result.client_secret)
  end

  # POST /payment-methods/confirm
  def confirm
    pm_id = params.require(:payment_method_id)
    current_customer.attach_payment_method(pm_id)
    success_response(message: 'Payment method saved')
  end
end
```

## Subscription Checkout (Redirect to Stripe)

For subscriptions, the simpler approach is Stripe Checkout — no Elements needed:

```jsx
async function handleSubscribe(priceId) {
  const response = await fetch('/api/subscriptions/checkout', {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${getToken()}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ price_id: priceId })
  });
  const { checkout_url } = await response.json();
  window.location.href = checkout_url;  // Redirect to Stripe Checkout
}
```

```ruby
# Belt controller
class SubscriptionsController < BeltController::Base
  def checkout
    result = Belt::Pay.create_checkout(current_customer,
      line_items: [{ price: params['price_id'], quantity: 1 }],
      mode: 'subscription',
      success_url: "#{ENV['FRONTEND_URL']}/subscription/success",
      cancel_url: "#{ENV['FRONTEND_URL']}/pricing")
    success_response(checkout_url: result[:url])
  end
end
```

## Billing Portal Link

Let customers manage their own subscription and payment methods:

```jsx
async function openBillingPortal() {
  const response = await fetch('/api/billing/portal', {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${getToken()}`, 'Content-Type': 'application/json' }
  });
  const { url } = await response.json();
  window.location.href = url;  // Redirect to Stripe Billing Portal
}
```

This is the recommended approach for most apps — zero custom UI needed for managing subscriptions,
updating cards, viewing invoices, or canceling.
