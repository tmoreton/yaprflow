import Stripe from 'stripe';

export function stripeMode(environment = process.env) {
  return /^(?:sk|rk)_(test|live)_[A-Za-z0-9]+$/.exec(environment.STRIPE_SECRET_KEY || '')?.[1] || null;
}

export function stripeClient(environment = process.env) {
  const key = environment.STRIPE_SECRET_KEY;
  if (!stripeMode(environment)) {
    throw new Error('Stripe is not configured');
  }
  return new Stripe(key, { maxNetworkRetries: 2 });
}
