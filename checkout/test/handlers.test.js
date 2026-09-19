import assert from 'node:assert/strict';
import test from 'node:test';
import { createHash } from 'node:crypto';
import { createHandlers } from '../lib/handlers.js';
import { checkoutSettings } from '../lib/settings.js';

const sessionId = 'cs_test_1234567890abcdef';
const privateUrl = 'https://example.private.blob.vercel-storage.com/releases/yaprflow.dmg?signature=private';
const environment = {
  STRIPE_SECRET_KEY: 'sk_test_notARealSecret',
  STRIPE_PRICE_ID: 'price_current123',
  CHECKOUT_ENABLED: 'true',
  CHECKOUT_BASE_URL: 'https://checkout.example.com',
  BLOB_PATHNAME: 'releases/yaprflow.dmg',
  BLOB_READ_WRITE_TOKEN: 'not-a-real-blob-token',
};
const paidSession = {
  id: sessionId, livemode: false, mode: 'payment', status: 'complete', payment_status: 'paid',
  metadata: { product: 'yaprflow-mac' },
  line_items: { data: [{ quantity: 1, price: { id: 'price_current123' } }], has_more: false },
};
const currentPrice = {
  id: 'price_current123', active: true, type: 'one_time', billing_scheme: 'per_unit',
  recurring: null, livemode: false, unit_amount: 2900, currency: 'usd', product: { active: true },
};

const liveSessionId = 'cs_live_1234567890abcdef';
function livePaidSession({ currency = 'usd', total = 864, tax = 65, discount = 0, ...changes } = {}) {
  return {
    ...paidSession,
    id: liveSessionId, livemode: true, currency, amount_total: total,
    total_details: { amount_tax: tax, amount_shipping: 0, amount_discount: discount },
    line_items: {
      data: [{ ...paidSession.line_items.data[0], currency, amount_total: total, amount_tax: tax, amount_discount: discount }],
      has_more: false,
    },
    ...changes,
  };
}

function fixture({ env = {}, session = paidSession, price = currentPrice, checkoutUrl, retrieveError, priceError, downloadUrl = privateUrl } = {}) {
  const calls = { prices: [], sessions: [], creates: [], tokens: [], urls: [] };
  const configured = { ...environment, ...env };
  const handlers = createHandlers({
    environment: () => configured,
    stripeFactory: (passed) => {
      assert.equal(passed, configured);
      return {
        prices: { retrieve: async (...args) => {
          calls.prices.push(args);
          if (priceError) throw priceError;
          return price;
        } },
        checkout: { sessions: {
          create: async (options) => {
            calls.creates.push(options);
            return { url: checkoutUrl ?? `https://checkout.stripe.com/c/pay/${sessionId}` };
          },
          retrieve: async (...args) => {
            calls.sessions.push(args);
            if (retrieveError) throw retrieveError;
            return session;
          },
        } },
      };
    },
    signToken: async (options) => { calls.tokens.push(options); return 'signed-token'; },
    signUrl: async (...args) => { calls.urls.push(args); return { presignedUrl: downloadUrl }; },
    now: () => 1000,
    logger: { error() {} },
  });
  return { ...handlers, calls };
}

function request(path, id = sessionId) {
  return new Request(`https://checkout.example.com/api/${path}?session_id=${id}`);
}

function assertPrivate(response) {
  assert.match(response.headers.get('Cache-Control'), /no-store/);
  assert.equal(response.headers.get('Referrer-Policy'), 'no-referrer');
}

test('public config publishes the actual Stripe price and mode without secrets', async () => {
  const api = fixture();
  const response = await api.config();
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), '*');
  assertPrivate(response);
  assert.deepEqual(await response.json(), {
    enabled: true, mode: 'test', price: { amount: 2900, currency: 'usd', formatted: '$29.00' }, downloadReady: true, voiceDemoAvailable: false,
  });
  assert.deepEqual(api.calls.prices, [['price_current123', { expand: ['product'] }]]);
});

test('missing configuration stays closed without making a Stripe request', async () => {
  const api = fixture({ env: { STRIPE_SECRET_KEY: '', STRIPE_PRICE_ID: '', BLOB_READ_WRITE_TOKEN: '' } });
  assert.deepEqual(await (await api.config()).json(), { enabled: false, mode: null, price: null, downloadReady: false, voiceDemoAvailable: false });
  assert.equal((await api.checkout()).status, 503);
  assert.equal((await api.download(request('download'))).status, 503);
  assert.equal(api.calls.prices.length + api.calls.creates.length + api.calls.tokens.length, 0);
});

test('voice demo availability exposes only a boolean and remains independent of Stripe setup', async () => {
  for (const [key, expected] of [[undefined, false], ['', false], ['   ', false], ['secret-provider-credential', true]]) {
    const api = fixture({ env: { STRIPE_SECRET_KEY: '', OPENAI_API_KEY: key } });
    const response = await api.config();
    const body = await response.json();
    assert.equal(body.voiceDemoAvailable, expected);
    assert.equal(body.enabled, false);
    assert.doesNotMatch(JSON.stringify(body), /secret-provider-credential|OPENAI_API_KEY/);
    assert.equal(api.calls.prices.length, 0);
  }
  const outage = fixture({ env: { OPENAI_API_KEY: 'secret-provider-credential' }, priceError: new Error('Stripe unavailable') });
  const response = await outage.config();
  assert.equal(response.status, 503);
  assert.equal((await response.json()).voiceDemoAvailable, true);
});

test('sales require an available private download and an explicit enable switch', async () => {
  for (const env of [{ CHECKOUT_ENABLED: 'false' }, { BLOB_READ_WRITE_TOKEN: '' }, { BLOB_PATHNAME: '../private.dmg' }]) {
    const api = fixture({ env });
    assert.equal((await (await api.config()).json()).enabled, false);
    assert.equal((await api.checkout()).status, 503);
    assert.equal(api.calls.creates.length, 0);
  }
});

test('inactive, recurring, flexible, zero, wrong-mode and missing-product prices never open checkout', async () => {
  for (const change of [
    { active: false }, { type: 'recurring' }, { unit_amount: null }, { unit_amount: 0 },
    { livemode: true }, { product: { active: false } }, { id: 'price_other' },
    { custom_unit_amount: { enabled: true } }, { transform_quantity: { divide_by: 10 } },
  ]) {
    const api = fixture({ price: { ...currentPrice, ...change } });
    const config = await (await api.config()).json();
    assert.equal(config.enabled, false);
    assert.equal(config.price, null);
    assert.equal((await api.checkout()).status, 503);
    assert.equal(api.calls.creates.length, 0);
  }
});

test('Stripe price failures return a safe retryable response', async () => {
  const api = fixture({ priceError: new Error('SECRET upstream details') });
  const config = await api.config();
  assert.equal(config.status, 503);
  assert.equal((await config.json()).enabled, false);
  const checkout = await api.checkout();
  assert.equal(checkout.status, 502);
  assert.doesNotMatch(await checkout.text(), /SECRET/);
});

test('the displayed price respects zero-decimal and Stripe legacy currencies', async () => {
  for (const [currency, unit_amount, formatted] of [['jpy', 2900, '¥2,900'], ['isk', 290000, 'ISK 2,900']]) {
    const api = fixture({ price: { ...currentPrice, currency, unit_amount } });
    assert.equal((await (await api.config()).json()).price.formatted, formatted);
  }
});

test('checkout redirects only to Stripe and uses the configured one-time price and origin', async () => {
  const api = fixture();
  const response = await api.checkout();
  assert.equal(response.status, 303);
  assertPrivate(response);
  assert.equal(new URL(response.headers.get('Location')).hostname, 'checkout.stripe.com');
  assert.deepEqual(api.calls.creates[0], {
    mode: 'payment', line_items: [{ price: 'price_current123', quantity: 1 }],
    customer_creation: 'always',
    success_url: 'https://checkout.example.com/api/complete?session_id={CHECKOUT_SESSION_ID}',
    cancel_url: 'https://checkout.example.com/?checkout=cancelled',
    metadata: { product: 'yaprflow-mac' },
  });
  assert.equal('payment_method_types' in api.calls.creates[0], false, 'Stripe controls payment methods, including Managed Payments');
  assert.equal('managed_payments' in api.calls.creates[0], false, 'preserve the account default');
});

test('checkout rejects unsafe redirect targets', async () => {
  for (const checkoutUrl of ['http://checkout.stripe.com/pay', 'https://stripe.example.com/pay', 'https://user:pass@checkout.stripe.com/pay']) {
    assert.equal((await fixture({ checkoutUrl }).checkout()).status, 502);
  }
});

test('localhost checkout origins are accepted only in development or test', () => {
  for (const base of ['http://localhost:8787', 'http://127.0.0.1:8787', 'http://[::1]:8787']) {
    assert.equal(checkoutSettings({ ...environment, CHECKOUT_BASE_URL: base, NODE_ENV: 'development' }).enabled, true);
    assert.equal(checkoutSettings({ ...environment, CHECKOUT_BASE_URL: base, NODE_ENV: 'production' }).enabled, false);
    assert.equal(checkoutSettings({ ...environment, CHECKOUT_BASE_URL: base, NODE_ENV: 'test', VERCEL_ENV: 'production' }).enabled, false);
  }
  for (const base of ['http://example.com', 'https://checkout.example.com/path', 'https://user:pass@checkout.example.com', 'https://checkout.example.com/?query=1']) {
    assert.equal(checkoutSettings({ ...environment, CHECKOUT_BASE_URL: base, NODE_ENV: 'test' }).enabled, false);
  }
});

test('only trusted Vercel preview hostnames can supply an omitted checkout origin', async () => {
  const preview = {
    CHECKOUT_BASE_URL: '', VERCEL_ENV: 'preview', VERCEL_URL: 'yaprflow-preview-123.vercel.app',
  };
  assert.equal(checkoutSettings({ ...environment, ...preview }).baseUrl.href, 'https://yaprflow-preview-123.vercel.app/');
  const api = fixture({ env: preview });
  assert.equal((await api.checkout()).status, 303);
  assert.equal(api.calls.creates[0].success_url, 'https://yaprflow-preview-123.vercel.app/api/complete?session_id={CHECKOUT_SESSION_ID}');
  assert.equal(api.calls.creates[0].cancel_url, 'https://yaprflow-preview-123.vercel.app/?checkout=cancelled');
  assert.equal(checkoutSettings({ ...environment, ...preview, CHECKOUT_BASE_URL: 'https://canonical.example.com' }).baseUrl.origin, 'https://canonical.example.com');
  for (const VERCEL_URL of [
    'https://yaprflow.vercel.app', 'yaprflow.vercel.app/path', 'yaprflow.vercel.app:443',
    'yaprflow.vercel.app.evil.example', 'user@yaprflow.vercel.app', '-invalid.vercel.app',
    'invalid-.vercel.app', 'nested.yaprflow.vercel.app', 'vercel.app', 'localhost',
  ]) {
    assert.equal(checkoutSettings({ ...environment, ...preview, VERCEL_URL }).enabled, false, VERCEL_URL);
  }
  for (const VERCEL_ENV of ['production', 'development', undefined]) {
    assert.equal(checkoutSettings({ ...environment, ...preview, VERCEL_ENV }).enabled, false);
  }
  assert.equal(checkoutSettings({ ...environment, ...preview, CHECKOUT_BASE_URL: 'invalid' }).enabled, false);
});

test('verified paid status contains only entitlement and mode', async () => {
  const response = await fixture().status(request('status'));
  assert.equal(response.status, 200);
  assertPrivate(response);
  assert.deepEqual(await response.json(), { paid: true, pending: false, mode: 'test' });
});

test('pending sessions are retryable but cannot download', async () => {
  for (const status of ['open', 'complete']) {
    const api = fixture({ session: { ...paidSession, status, payment_status: 'unpaid' } });
    const response = await api.status(request('status'));
    assert.equal(response.status, 202);
    assert.deepEqual(await response.json(), { paid: false, pending: true, mode: 'test' });
    assert.equal((await api.download(request('download'))).status, 403);
    assert.equal(api.calls.tokens.length, 0);
  }
});

test('expired, wrong-product, wrong-price and mismatched-mode sessions cannot download', async () => {
  for (const change of [
    { status: 'expired' }, { payment_status: 'no_payment_required' }, { metadata: { product: 'other' } }, { livemode: true },
    { line_items: { data: [{ quantity: 1, price: { id: 'price_other' } }] } },
    { line_items: { ...paidSession.line_items, has_more: true } },
  ]) {
    const api = fixture({ session: { ...paidSession, ...change } });
    assert.equal((await api.status(request('status'))).status, 403);
    assert.equal((await api.download(request('download'))).status, 403);
    assert.equal(api.calls.tokens.length, 0);
  }
});

test('invalid and wrong-mode session IDs never reach Stripe', async () => {
  for (const id of ['invalid', 'cs_live_1234567890abcdef']) {
    const api = fixture();
    assert.equal((await api.status(request('status', id))).status, 403);
    assert.equal((await api.download(request('download', id))).status, 403);
    assert.equal(api.calls.sessions.length, 0);
    assert.equal(api.calls.tokens.length, 0);
  }
});

test('missing Stripe sessions are denied, while transient failures remain retryable', async () => {
  const missing = fixture({ retrieveError: { code: 'resource_missing' } });
  assert.equal((await missing.status(request('status'))).status, 403);
  assert.equal((await missing.download(request('download'))).status, 403);
  const outage = fixture({ retrieveError: new Error('network unavailable') });
  assert.equal((await outage.status(request('status'))).status, 502);
  assert.equal((await outage.download(request('download'))).status, 502);
});

test('paid download re-verifies with Stripe and signs only the configured file for five minutes', async () => {
  const api = fixture();
  await api.status(request('status'));
  const response = await api.download(request('download'));
  assert.equal(response.status, 303);
  assertPrivate(response);
  assert.equal(response.headers.get('Location'), privateUrl);
  assert.equal(api.calls.sessions.length, 2);
  assert.deepEqual(api.calls.tokens, [{ pathname: 'releases/yaprflow.dmg', operations: ['get'], validUntil: 301000, token: environment.BLOB_READ_WRITE_TOKEN }]);
  assert.deepEqual(api.calls.urls, [['signed-token', { pathname: 'releases/yaprflow.dmg', operation: 'get', access: 'private', validUntil: 301000 }]]);
});

test('closing sales does not revoke an existing paid download', async () => {
  assert.equal((await fixture({ env: { CHECKOUT_ENABLED: 'false' } }).download(request('download'))).status, 303);
});

test('previous allowed prices keep download access', async () => {
  const api = fixture({
    env: { STRIPE_PRICE_ID: 'price_new', STRIPE_ALLOWED_PRICE_IDS: 'price_current123' },
  });
  assert.equal((await api.download(request('download'))).status, 303);
});

test('public Blob and unexpected download hosts are rejected', async () => {
  for (const downloadUrl of ['https://example.public.blob.vercel-storage.com/app.dmg', 'https://example.com/app.dmg', 'http://example.private.blob.vercel-storage.com/app.dmg']) {
    assert.equal((await fixture({ downloadUrl }).download(request('download'))).status, 502);
  }
});

test('verified live purchases expose only anonymous analytics with a stable domain-separated transaction hash', async () => {
  const session = livePaidSession({
    customer_email: 'buyer@example.com', customer_details: { name: 'Buyer Name', email: 'buyer@example.com' },
    customer: 'cus_privateCustomer', payment_intent: 'pi_privatePayment',
  });
  const api = fixture({ env: { STRIPE_SECRET_KEY: 'sk_live_notARealSecret' }, session });
  const response = await api.status(request('status', liveSessionId));
  assert.equal(response.status, 200);
  assertPrivate(response);
  const payload = await response.json();
  assert.deepEqual(payload, {
    paid: true, pending: false, mode: 'live',
    analytics: {
      transaction_id: createHash('sha256').update('yaprflow:ga4-purchase:v1\0').update(liveSessionId).digest('hex'),
      currency: 'USD', value: 7.99, tax: 0.65,
      items: [{ item_id: 'yaprflow-mac', item_name: 'Yaprflow for Mac', price: 7.99, quantity: 1 }],
    },
  });
  assert.notEqual(payload.analytics.transaction_id, createHash('sha256').update(liveSessionId).digest('hex'));
  assert.doesNotMatch(JSON.stringify(payload), /cs_live_|cs_test_|pi_private|cus_private|buyer@example|Buyer Name/);
  assert.equal((await (await api.status(request('status', liveSessionId))).json()).analytics.transaction_id, payload.analytics.transaction_id);
  const otherId = 'cs_live_different1234567890';
  const other = fixture({ env: { STRIPE_SECRET_KEY: 'sk_live_notARealSecret' }, session: { ...session, id: otherId } });
  assert.notEqual((await (await other.status(request('status', otherId))).json()).analytics.transaction_id, payload.analytics.transaction_id);
});

test('purchase revenue excludes inclusive or exclusive taxes and uses discounted settled totals', async () => {
  for (const [session, value, tax] of [
    [livePaidSession({ total: 864, tax: 65 }), 7.99, 0.65],
    [livePaidSession({ total: 799, tax: 60 }), 7.39, 0.60],
    [livePaidSession({ total: 648, tax: 49, discount: 200 }), 5.99, 0.49],
    [livePaidSession({ total: 799, tax: 0 }), 7.99, 0],
  ]) {
    const api = fixture({ env: { STRIPE_SECRET_KEY: 'sk_live_notARealSecret' }, session });
    const analytics = (await (await api.status(request('status', liveSessionId))).json()).analytics;
    assert.equal(analytics.value, value);
    assert.equal(analytics.tax, tax);
    assert.equal(analytics.items[0].price, value);
  }
});

test('purchase analytics converts Stripe zero-decimal, legacy and three-decimal currency amounts', async () => {
  for (const [currency, total, tax, expectedValue, expectedTax] of [
    ['jpy', 900, 100, 800, 100],
    ['isk', 90000, 10000, 800, 100],
    ['ugx', 90000, 10000, 800, 100],
    ['bhd', 1234, 34, 1.2, 0.034],
  ]) {
    const api = fixture({ env: { STRIPE_SECRET_KEY: 'sk_live_notARealSecret' }, session: livePaidSession({ currency, total, tax }) });
    const analytics = (await (await api.status(request('status', liveSessionId))).json()).analytics;
    assert.equal(analytics.currency, currency.toUpperCase());
    assert.equal(analytics.value, expectedValue);
    assert.equal(analytics.tax, expectedTax);
  }
});

test('incomplete or inconsistent reporting totals never block paid download access', async () => {
  const base = livePaidSession();
  for (const session of [
    { ...base, amount_total: undefined }, { ...base, amount_total: Number.NaN },
    { ...base, amount_total: Infinity }, { ...base, amount_total: Number.MAX_SAFE_INTEGER + 1 },
    { ...base, amount_total: -1 }, { ...base, total_details: undefined },
    { ...base, total_details: { amount_tax: -1, amount_shipping: 0 } },
    { ...base, total_details: { amount_tax: 99999, amount_shipping: 0 } },
    { ...base, total_details: { amount_tax: 65, amount_shipping: 100 } },
    { ...base, currency: 'invalid' },
    { ...base, line_items: { data: [{ ...base.line_items.data[0], currency: 'eur' }] } },
    { ...base, line_items: { data: [{ ...base.line_items.data[0], amount_total: 863 }] } },
    { ...base, line_items: { data: [{ ...base.line_items.data[0], amount_tax: undefined }] } },
  ]) {
    const api = fixture({ env: { STRIPE_SECRET_KEY: 'sk_live_notARealSecret' }, session });
    const status = await api.status(request('status', liveSessionId));
    assert.equal(status.status, 200);
    assert.deepEqual(await status.json(), { paid: true, pending: false, mode: 'live' });
    assert.equal((await api.download(request('download', liveSessionId))).status, 303);
  }
});

test('test purchases, pending purchases and verification failures never produce purchase analytics', async () => {
  const testMode = fixture({ session: { ...livePaidSession(), id: sessionId, livemode: false } });
  const testPayload = await (await testMode.status(request('status'))).json();
  assert.equal(testPayload.paid, true);
  assert.equal('analytics' in testPayload, false);
  for (const [session, expectedStatus] of [
    [livePaidSession({ payment_status: 'unpaid' }), 202],
    [livePaidSession({ status: 'expired' }), 403],
    [livePaidSession({ metadata: { product: 'other' } }), 403],
  ]) {
    const api = fixture({ env: { STRIPE_SECRET_KEY: 'sk_live_notARealSecret' }, session });
    const response = await api.status(request('status', liveSessionId));
    assert.equal(response.status, expectedStatus);
    assert.equal('analytics' in await response.json(), false);
  }
  const failed = fixture({ env: { STRIPE_SECRET_KEY: 'sk_live_notARealSecret' }, retrieveError: new Error('Stripe unavailable') });
  const response = await failed.status(request('status', liveSessionId));
  assert.equal(response.status, 502);
  assert.equal('analytics' in await response.json(), false);
});

test('checkout completion captures a host-only private cookie before redirecting to a clean confirmation URL', async () => {
  const api = fixture();
  const response = await api.complete(new Request(`https://checkout.example.com/api/complete?session_id=${sessionId}&email=private@example.com`));
  assert.equal(response.status, 303);
  assert.equal(response.headers.get('Location'), '/confirmation.html');
  assertPrivate(response);
  const cookie = response.headers.get('Set-Cookie');
  assert.equal(cookie, `__Host-yaprflow-purchase=${sessionId}; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax; Secure`);
  assert.doesNotMatch(cookie, /Domain=|email|private@example/i);
  assert.equal(await response.text(), '');
  assert.equal(api.calls.sessions.length, 0, 'the handoff itself does not claim a paid entitlement');
});

test('clean confirmation and download requests use the cookie and independently verify Stripe', async () => {
  const api = fixture();
  const complete = await api.complete(request('complete'));
  const cookie = complete.headers.get('Set-Cookie').split(';')[0];
  const status = await api.status(new Request('https://checkout.example.com/api/status', { headers: { Cookie: cookie } }));
  assert.equal(status.status, 200);
  assert.deepEqual(await status.json(), { paid: true, pending: false, mode: 'test' });
  const download = await api.download(new Request('https://checkout.example.com/api/download', { headers: { Cookie: cookie } }));
  assert.equal(download.status, 303);
  assert.equal(download.headers.get('Location'), privateUrl);
  assert.deepEqual(api.calls.sessions, [
    [sessionId, { expand: ['line_items'] }],
    [sessionId, { expand: ['line_items'] }],
  ]);
});

test('cookie capture never grants download access to pending or unverified purchases', async () => {
  for (const session of [
    { ...paidSession, payment_status: 'unpaid' },
    { ...paidSession, metadata: { product: 'other' } },
  ]) {
    const api = fixture({ session });
    const complete = await api.complete(request('complete'));
    assert.equal(complete.status, 303);
    const cookie = complete.headers.get('Set-Cookie').split(';')[0];
    const response = await api.download(new Request('https://checkout.example.com/api/download', { headers: { Cookie: cookie } }));
    assert.equal(response.status, 403);
    assert.equal(api.calls.tokens.length, 0);
  }
});

test('an explicitly invalid or duplicate session query cannot fall back to a valid cookie', async () => {
  for (const query of [
    '?session_id=', '?session_id=invalid', `?session_id=${liveSessionId}`,
    `?session_id=${sessionId}&session_id=invalid`, `?session_id=invalid&session_id=${sessionId}`,
  ]) {
    const api = fixture();
    for (const endpoint of ['status', 'download']) {
      const response = await api[endpoint](new Request(`https://checkout.example.com/api/${endpoint}${query}`, {
        headers: { Cookie: `__Host-yaprflow-purchase=${sessionId}` },
      }));
      assert.equal(response.status, 403);
    }
    assert.equal(api.calls.sessions.length, 0);
    assert.equal(api.calls.tokens.length, 0);
  }
});

test('wrong-mode, duplicate and malformed purchase cookies do not reach Stripe', async () => {
  for (const cookie of [
    `__Host-yaprflow-purchase=${liveSessionId}`, '__Host-yaprflow-purchase=invalid',
    '__Host-yaprflow-purchase=%ZZ', '__Host-yaprflow-purchase=',
    `__Host-yaprflow-purchase=${sessionId}; __Host-yaprflow-purchase=${sessionId}`,
    `yaprflow-purchase-dev=${sessionId}`, `other=__Host-yaprflow-purchase=${sessionId}`,
  ]) {
    const api = fixture();
    const response = await api.status(new Request('https://checkout.example.com/api/status', { headers: { Cookie: cookie } }));
    assert.equal(response.status, 403);
    assert.equal(api.calls.sessions.length, 0);
  }
});

test('legacy explicit session queries remain usable and take precedence over unrelated cookies', async () => {
  const api = fixture();
  const response = await api.status(new Request(`https://checkout.example.com/api/status?session_id=${sessionId}`, {
    headers: { Cookie: `__Host-yaprflow-purchase=${liveSessionId}; another=unrelated` },
  }));
  assert.equal(response.status, 200);
  assert.equal(api.calls.sessions[0][0], sessionId);
});

test('completion rejects missing, malformed or wrong-mode session IDs without setting a cookie', async () => {
  for (const query of ['', '?session_id=', '?session_id=invalid', `?session_id=${liveSessionId}`, `?session_id=${sessionId}&session_id=${sessionId}`]) {
    const api = fixture();
    const response = await api.complete(new Request(`https://checkout.example.com/api/complete${query}`, {
      headers: { Cookie: `__Host-yaprflow-purchase=${sessionId}` },
    }));
    assert.equal(response.status, 403);
    assert.equal(response.headers.get('Set-Cookie'), null);
    assert.equal(response.headers.get('Location'), null);
    assertPrivate(response);
  }
  const live = fixture({ env: { STRIPE_SECRET_KEY: 'sk_live_notARealSecret' } });
  const response = await live.complete(request('complete', liveSessionId));
  assert.equal(response.status, 303);
  assert.match(response.headers.get('Set-Cookie'), new RegExp(`^__Host-yaprflow-purchase=${liveSessionId};`));
});

test('only local development can capture a non-Secure cookie, using a separate cookie name', async () => {
  const api = fixture({ env: { NODE_ENV: 'development' } });
  const response = await api.complete(new Request(`http://127.0.0.1:4173/api/complete?session_id=${sessionId}`));
  assert.equal(response.status, 303);
  assert.equal(response.headers.get('Set-Cookie'), `yaprflow-purchase-dev=${sessionId}; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax`);
  const status = await api.status(new Request('http://127.0.0.1:4173/api/status', {
    headers: { Cookie: response.headers.get('Set-Cookie').split(';')[0] },
  }));
  assert.equal(status.status, 200);
  for (const [origin, env] of [
    ['http://checkout.example.com', { NODE_ENV: 'development' }],
    ['http://localhost:4173', { NODE_ENV: 'production' }],
    ['http://localhost:4173', { NODE_ENV: 'test', VERCEL_ENV: 'production' }],
  ]) {
    const result = await fixture({ env }).complete(new Request(`${origin}/api/complete?session_id=${sessionId}`));
    assert.equal(result.status, 403);
    assert.equal(result.headers.get('Set-Cookie'), null);
  }
});
