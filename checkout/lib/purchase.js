const SESSION_ID = /^cs_(?:test|live)_[A-Za-z0-9]{10,}$/;
const PRODUCT_MARKER = 'yaprflow-mac';

export function allowedPriceIds(environment = process.env) {
  return new Set(
    [environment.STRIPE_PRICE_ID || '', environment.STRIPE_ALLOWED_PRICE_IDS || '']
      .join(',')
      .split(',')
      .map((id) => id.trim())
      .filter((id) => /^price_[A-Za-z0-9]+$/.test(id)),
  );
}

export function isMacPurchase(session, prices) {
  if (!session || session.mode !== 'payment' ||
      session.metadata?.product !== PRODUCT_MARKER ||
      prices.size === 0) {
    return false;
  }

  const items = session.line_items?.data;
  return Array.isArray(items) && !session.line_items.has_more && items.length === 1 &&
    items[0].quantity === 1 && prices.has(items[0].price?.id);
}

export function isPaidMacPurchase(session, prices) {
  return isMacPurchase(session, prices) && session.status === 'complete' &&
    session.payment_status === 'paid';
}

export async function loadMacPurchase(stripe, sessionId, prices, mode) {
  if (typeof sessionId !== 'string' || !SESSION_ID.test(sessionId)) return null;
  if (prices.size === 0 || (mode && !sessionId.startsWith(`cs_${mode}_`))) return null;
  try {
    const session = await stripe.checkout.sessions.retrieve(sessionId, {
      expand: ['line_items'],
    });
    if (mode && session.livemode !== (mode === 'live')) return null;
    return isMacPurchase(session, prices) ? session : null;
  } catch (error) {
    if (error?.code === 'resource_missing') return null;
    throw error;
  }
}

export async function loadPaidMacPurchase(stripe, sessionId, prices, mode) {
  const session = await loadMacPurchase(stripe, sessionId, prices, mode);
  return isPaidMacPurchase(session, prices) ? session : null;
}

export function checkoutProductMarker() {
  return PRODUCT_MARKER;
}

export function privateResponse(body, init = {}) {
  const headers = new Headers(init.headers);
  headers.set('Cache-Control', 'private, no-store, max-age=0');
  headers.set('Referrer-Policy', 'no-referrer');
  return new Response(body, { ...init, headers });
}
