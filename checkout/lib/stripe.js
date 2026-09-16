import Stripe from 'stripe';

export function stripeClient() {
  const key = process.env.STRIPE_SECRET_KEY;
  if (!key || !/^sk_(test|live)_/.test(key)) {
    throw new Error('Stripe is not configured');
  }
  return new Stripe(key, { maxNetworkRetries: 2 });
}
