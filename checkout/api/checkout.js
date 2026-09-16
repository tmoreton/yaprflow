import { checkoutProductMarker, privateResponse } from '../lib/purchase.js';
import { stripeClient } from '../lib/stripe.js';

export async function POST(request) {
  const price = process.env.STRIPE_PRICE_ID;
  const base = process.env.CHECKOUT_BASE_URL;
  if (!/^price_[A-Za-z0-9]+$/.test(price || '') || !base) {
    return privateResponse('Checkout is not ready.', { status: 503 });
  }

  let baseUrl;
  try {
    baseUrl = new URL(base);
    if (baseUrl.protocol !== 'https:' || baseUrl.pathname !== '/' ||
        baseUrl.search || baseUrl.hash) throw new Error('Invalid checkout URL');
  } catch {
    return privateResponse('Checkout is not ready.', { status: 503 });
  }

  try {
    const stripe = stripeClient();
    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      payment_method_types: ['card'],
      line_items: [{ price, quantity: 1 }],
      customer_creation: 'always',
      success_url: new URL('/confirmation.html?session_id={CHECKOUT_SESSION_ID}', baseUrl).href,
      cancel_url: new URL('/', baseUrl).href,
      metadata: { product: checkoutProductMarker() },
    });
    if (!session.url || new URL(session.url).hostname !== 'checkout.stripe.com') {
      throw new Error('Stripe returned an invalid checkout URL');
    }
    return privateResponse(null, {
      status: 303,
      headers: { Location: session.url },
    });
  } catch (error) {
    console.error('Checkout session creation failed:', error?.type || error?.name || 'unknown');
    return privateResponse('Checkout is temporarily unavailable.', { status: 502 });
  }
}
