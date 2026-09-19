import { reportAnalytics } from './analytics.js';

export const isValidSessionId = (value) => typeof value === 'string' && /^cs_(?:test|live)_[A-Za-z0-9]{10,}$/.test(value);

export function purchasePresentation(result, httpStatus) {
  const test = result?.mode === 'test';
  if (httpStatus === 200 && result?.paid === true) {
    return { state: 'ready', test, message: test
      ? 'Test payment confirmed. Your Mac download is ready. No real charge was made.'
      : 'Payment confirmed. Your Mac download is ready.' };
  }
  if (httpStatus === 202 && result?.pending === true) {
    return { state: 'pending', test, message: 'Your payment is still being confirmed. We’ll check again in a moment.' };
  }
  if (httpStatus === 400 || httpStatus === 403 || httpStatus === 404) {
    return { state: 'invalid', test, message: 'We could not confirm this purchase. Use the confirmation page from your completed checkout or contact support.' };
  }
  return { state: 'error', test, message: 'We could not check your payment right now. Please try again.' };
}

export function mountConfirmation(document, window, request = window.fetch.bind(window)) {
  const status = document.getElementById('status');
  const ready = document.getElementById('ready');
  const help = document.getElementById('help');
  const download = document.getElementById('download');
  const retry = document.getElementById('retry');
  const testBadge = document.getElementById('test-badge');
  const sessionId = new URLSearchParams(window.location.search).get('session_id');
  let attempts = 0;
  let timer;
  let checking = false;
  let disposed = false;
  let paidMode = null;
  // New checkouts use an HttpOnly cookie established before this page loads.
  // Explicit queries remain a compatibility fallback; the host redirects those before serving HTML.
  const valid = sessionId === null || isValidSessionId(sessionId);
  const sessionQuery = sessionId === null ? '' : `?session_id=${encodeURIComponent(sessionId)}`;
  testBadge.hidden = !valid || !sessionId?.startsWith('cs_test_');

  async function checkPurchase() {
    if (checking || disposed) return;
    window.clearTimeout(timer);
    ready.hidden = true;
    retry.hidden = true;
    help.hidden = true;
    if (!valid) {
      status.textContent = 'No valid checkout session was found. Return here using the confirmation page from your completed checkout.';
      help.hidden = false;
      return;
    }
    checking = true;
    paidMode = null;
    status.textContent = 'Checking your payment with Stripe…';
    try {
      const response = await request(`/api/status${sessionQuery}`, {
        cache: 'no-store', credentials: 'same-origin', signal: AbortSignal.timeout(12000),
      });
      const payload = await response.json();
      const result = purchasePresentation(payload, response.status);
      if (disposed) return;
      status.textContent = result.message;
      testBadge.hidden = !result.test;
      if (result.state === 'ready') {
        download.href = `/api/download${sessionQuery}`;
        ready.hidden = false;
        paidMode = payload.mode;
        reportAnalytics(window, document, 'purchase', payload);
      } else if (result.state === 'pending' && ++attempts < 6) {
        timer = window.setTimeout(checkPurchase, Math.min(2000 * attempts, 8000));
      } else {
        help.hidden = false;
        retry.hidden = result.state === 'invalid';
        if (result.state === 'pending') status.textContent = 'Your payment is taking a little longer to confirm. Check again shortly or contact support.';
      }
    } catch {
      if (!disposed) {
        status.textContent = 'We could not check your payment right now. Please try again.';
        help.hidden = false;
        retry.hidden = false;
      }
    } finally {
      checking = false;
    }
  }

  download.addEventListener('click', () => {
    if (!ready.hidden && paidMode === 'live') reportAnalytics(window, document, 'download', paidMode);
  });
  retry.addEventListener('click', () => { attempts = 0; checkPurchase(); });
  window.addEventListener('pagehide', () => { disposed = true; window.clearTimeout(timer); });
  window.addEventListener('pageshow', (event) => { if (event.persisted) { disposed = false; checkPurchase(); } });
  const loaded = checkPurchase();
  return { ready: loaded, retry: checkPurchase };
}

if (typeof document !== 'undefined') mountConfirmation(document, window);
