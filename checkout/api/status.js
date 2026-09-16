import { allowedPriceIds, loadPaidMacPurchase, privateResponse } from '../lib/purchase.js';
import { stripeClient } from '../lib/stripe.js';

export async function GET(request) {
  const sessionId = new URL(request.url).searchParams.get('session_id');
  try {
    const session = await loadPaidMacPurchase(
      stripeClient(), sessionId, allowedPriceIds(),
    );
    if (!session) {
      return privateResponse(JSON.stringify({ paid: false }), {
        status: 403,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    return privateResponse(JSON.stringify({ paid: true }), {
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (error) {
    console.error('Purchase status check failed:', error?.type || error?.name || 'unknown');
    return privateResponse(JSON.stringify({ paid: false }), {
      status: 502,
      headers: { 'Content-Type': 'application/json' },
    });
  }
}
