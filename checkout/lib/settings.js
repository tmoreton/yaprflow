import { stripeMode } from './stripe.js';

export function checkoutSettings(environment = process.env) {
  let baseUrl = null;
  let configuredBase = environment.CHECKOUT_BASE_URL;
  if (!configuredBase && environment.VERCEL_ENV === 'preview' &&
      /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.vercel\.app$/i.test(environment.VERCEL_URL || '')) {
    configuredBase = `https://${environment.VERCEL_URL}`;
  }
  try {
    const candidate = new URL(configuredBase);
    const local = ['development', 'test'].includes(environment.NODE_ENV) &&
      environment.VERCEL_ENV !== 'production' &&
      ['localhost', '127.0.0.1', '[::1]'].includes(candidate.hostname);
    if ((candidate.protocol === 'https:' || (local && candidate.protocol === 'http:')) &&
        candidate.pathname === '/' && !candidate.search && !candidate.hash &&
        !candidate.username && !candidate.password) baseUrl = candidate;
  } catch { /* A missing or invalid origin keeps checkout disabled. */ }

  const pathname = environment.BLOB_PATHNAME;
  const downloadReady = typeof pathname === 'string' && pathname.length > 0 &&
    !pathname.startsWith('/') && !pathname.includes('..') && !/[\x00-\x1f]/.test(pathname) &&
    Boolean(environment.BLOB_READ_WRITE_TOKEN?.trim());
  const priceId = /^price_[A-Za-z0-9]+$/.test(environment.STRIPE_PRICE_ID || '')
    ? environment.STRIPE_PRICE_ID : null;
  const mode = stripeMode(environment);
  return {
    baseUrl, priceId, mode, pathname, downloadReady,
    enabled: environment.CHECKOUT_ENABLED === 'true' && Boolean(baseUrl && priceId && mode && downloadReady),
  };
}

export async function loadCheckoutPrice(stripe, settings) {
  const price = await stripe.prices.retrieve(settings.priceId, { expand: ['product'] });
  if (price.id !== settings.priceId || !price.active || price.type !== 'one_time' ||
      price.billing_scheme !== 'per_unit' || price.recurring || price.custom_unit_amount ||
      price.transform_quantity || price.livemode !== (settings.mode === 'live') ||
      !Number.isSafeInteger(price.unit_amount) || price.unit_amount <= 0 ||
      !/^[a-z]{3}$/.test(price.currency || '') || !price.product?.active) {
    return null;
  }

  const formatter = new Intl.NumberFormat('en-US', { style: 'currency', currency: price.currency });
  // Stripe keeps ISK and UGX in hundredths for backwards compatibility.
  const decimals = ['isk', 'ugx'].includes(price.currency)
    ? 2 : formatter.resolvedOptions().maximumFractionDigits;
  return {
    amount: price.unit_amount,
    currency: price.currency,
    formatted: formatter.format(price.unit_amount / (10 ** decimals)),
  };
}
