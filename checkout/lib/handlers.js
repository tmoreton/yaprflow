import { issueSignedToken, presignUrl } from '@vercel/blob';
import { allowedPriceIds, checkoutProductMarker, isPaidMacPurchase, loadMacPurchase, loadPaidMacPurchase, privateResponse } from './purchase.js';
import { checkoutSettings, loadCheckoutPrice } from './settings.js';
import { stripeClient } from './stripe.js';
import { purchaseAnalytics } from './purchase-analytics.js';
import { purchaseCookieHeader, requestedPurchaseSessionId } from './purchase-identity.js';

function json(body, status = 200, headers = {}) {
  return privateResponse(JSON.stringify(body), {
    status, headers: { 'Content-Type': 'application/json', ...headers },
  });
}

export function createHandlers({
  environment = () => process.env,
  stripeFactory = stripeClient,
  signToken = issueSignedToken,
  signUrl = presignUrl,
  now = Date.now,
  logger = console,
} = {}) {
  const report = (message, error) => logger.error(message, error?.type || error?.name || 'unknown');

  return {
    async config() {
      const env = environment();
      const settings = checkoutSettings(env);
      const body = {
        enabled: false, mode: settings.mode, price: null, downloadReady: settings.downloadReady,
        voiceDemoAvailable: Boolean(env.OPENAI_API_KEY?.trim()),
      };
      const headers = { 'Access-Control-Allow-Origin': '*' };
      if (!settings.mode || !settings.priceId) return json(body, 200, headers);
      try {
        body.price = await loadCheckoutPrice(stripeFactory(env), settings);
        body.enabled = settings.enabled && Boolean(body.price);
        return json(body, 200, headers);
      } catch (error) {
        report('Checkout configuration check failed:', error);
        return json(body, 503, headers);
      }
    },

    async checkout() {
      const env = environment();
      const settings = checkoutSettings(env);
      if (!settings.enabled) return privateResponse('Checkout is not ready.', { status: 503 });
      try {
        const stripe = stripeFactory(env);
        if (!await loadCheckoutPrice(stripe, settings)) {
          return privateResponse('Checkout is not ready.', { status: 503 });
        }
        const session = await stripe.checkout.sessions.create({
          mode: 'payment',
          line_items: [{ price: settings.priceId, quantity: 1 }],
          customer_creation: 'always',
          success_url: new URL('/api/complete?session_id={CHECKOUT_SESSION_ID}', settings.baseUrl).href,
          cancel_url: new URL('/?checkout=cancelled', settings.baseUrl).href,
          metadata: { product: checkoutProductMarker() },
        });
        const url = new URL(session.url);
        if (url.protocol !== 'https:' || url.hostname !== 'checkout.stripe.com' ||
            url.username || url.password || (url.port && url.port !== '443')) {
          throw new Error('Stripe returned an invalid checkout URL');
        }
        return privateResponse(null, { status: 303, headers: { Location: url.href } });
      } catch (error) {
        report('Checkout session creation failed:', error);
        return privateResponse('Checkout is temporarily unavailable.', { status: 502 });
      }
    },

    async complete(request) {
      const env = environment();
      const { mode } = checkoutSettings(env);
      if (!mode) return privateResponse('Purchase confirmation is not ready.', { status: 503 });
      if (!new URL(request.url).searchParams.has('session_id')) {
        return privateResponse('Purchase link could not be verified.', { status: 403 });
      }
      const sessionId = requestedPurchaseSessionId(request, mode, env);
      const cookie = purchaseCookieHeader(request, sessionId, mode, env);
      if (!cookie) return privateResponse('Purchase link could not be verified.', { status: 403 });
      // This handoff only removes the bearer from the browser URL. Every status/download
      // request still verifies payment and the purchased product directly with Stripe.
      return privateResponse(null, {
        status: 303,
        headers: { Location: '/confirmation.html', 'Set-Cookie': cookie },
      });
    },

    async status(request) {
      const env = environment();
      const { mode } = checkoutSettings(env);
      const denied = { paid: false, pending: false, mode };
      if (!mode || allowedPriceIds(env).size === 0) return json(denied, 503);
      try {
        const prices = allowedPriceIds(env);
        const sessionId = requestedPurchaseSessionId(request, mode, env);
        const session = await loadMacPurchase(stripeFactory(env), sessionId, prices, mode);
        if (isPaidMacPurchase(session, prices)) {
          const analytics = mode === 'live' ? purchaseAnalytics(session) : null;
          return json({ paid: true, pending: false, mode, ...(analytics ? { analytics } : {}) });
        }
        if (session && (session.status === 'open' ||
            (session.status === 'complete' && session.payment_status === 'unpaid'))) {
          return json({ paid: false, pending: true, mode }, 202);
        }
        return json(denied, 403);
      } catch (error) {
        report('Purchase status check failed:', error);
        return json(denied, 502);
      }
    },

    async download(request) {
      const env = environment();
      const { mode, pathname, downloadReady } = checkoutSettings(env);
      if (!mode || !downloadReady || allowedPriceIds(env).size === 0) {
        return privateResponse('The download is not ready.', { status: 503 });
      }
      try {
        const sessionId = requestedPurchaseSessionId(request, mode, env);
        const session = await loadPaidMacPurchase(stripeFactory(env), sessionId, allowedPriceIds(env), mode);
        if (!session) return privateResponse('Purchase could not be verified.', { status: 403 });
        const expires = now() + 5 * 60 * 1000;
        const token = await signToken({
          pathname, operations: ['get'], validUntil: expires, token: env.BLOB_READ_WRITE_TOKEN,
        });
        const { presignedUrl } = await signUrl(token, {
          pathname, operation: 'get', access: 'private', validUntil: expires,
        });
        const url = new URL(presignedUrl);
        if (url.protocol !== 'https:' || !url.hostname.endsWith('.private.blob.vercel-storage.com') ||
            url.username || url.password || (url.port && url.port !== '443')) {
          throw new Error('Blob returned an invalid private download URL');
        }
        return privateResponse(null, { status: 303, headers: { Location: url.href } });
      } catch (error) {
        report('Private download failed:', error);
        return privateResponse('The download is temporarily unavailable.', { status: 502 });
      }
    },
  };
}
