import assert from 'node:assert/strict';
import test from 'node:test';
import { createAnalytics, CONSENT_KEY, MEASUREMENT_ID, safePurchase } from '../analytics.js';
import { MARKETING_CONSENT_KEY } from '../meta-pixel.js';

const purchase = { paid: true, mode: 'live', analytics: {
  transaction_id: 'a'.repeat(64), currency: 'USD', value: 7.99, tax: 0.71,
} };
const config = { enabled: true, mode: 'live', price: { amount: 799, currency: 'usd' } };
function fixture({ url = 'https://yaprflow.com/confirmation.html?utm_source=example#private', consent, storage } = {}) {
  const values = storage || new Map([
    [MARKETING_CONSENT_KEY, 'denied'],
    ...(consent === undefined ? [] : [[CONSENT_KEY, consent]]),
  ]);
  const scripts = [];
  const deletedCookies = [];
  let reloads = 0;
  const window = {
    location: Object.assign(new URL(url), { reload() { reloads++; } }),
    localStorage: {
      getItem: key => values.has(key) ? values.get(key) : null,
      setItem: (key, value) => values.set(key, value), removeItem: key => values.delete(key),
    },
  };
  const document = {
    referrer: '',
    createElement: () => ({}), head: { append: script => scripts.push(script) },
    get cookie() { return '_ga=secret-cookie; _ga_0FTBJXMCSM=other; necessary=keep'; },
    set cookie(value) { deletedCookies.push(value); },
  };
  const analytics = createAnalytics(window, document);
  const commands = () => (window.dataLayer || []).map(args => [...args]);
  return { analytics, window, document, scripts, values, deletedCookies, reloads: () => reloads,
    commands, events: () => commands().filter(args => args[0] === 'event') };
}

test('new production visitors get Google measurement without saving an explicit choice', () => {
  const f = fixture();
  assert.equal(f.analytics.consent, 'granted');
  assert.deepEqual(f.scripts.map(script => script.src), [`https://www.googletagmanager.com/gtag/js?id=${MEASUREMENT_ID}`]);
  assert.deepEqual(f.events().map(args => args[1]), ['page_view']);
  assert.equal(f.values.has(CONSENT_KEY), false);
});

test('Google respects stored opt-outs and invalid choices, and excludes local/preview/private URLs', () => {
  for (const consent of ['denied', 'unexpected', '']) {
    const f = fixture({ consent });
    f.analytics.offer('hero'); f.analytics.checkout(config); f.analytics.purchase(purchase); f.analytics.download('live');
    assert.equal(f.scripts.length, 0);
    assert.equal(f.commands().length, 0);
  }
  for (const url of ['http://127.0.0.1:4173/', 'https://yaprflow-checkout-example.vercel.app/', 'https://yaprflow.com.attacker.test/', 'http://yaprflow.com/',
    'https://yaprflow.com/?session_id=cs_live_private', 'https://yaprflow.com/?client%5Fsecret=private']) {
    for (const consent of [undefined, 'granted']) {
      const f = fixture({ url, consent });
      f.analytics.checkout(config); f.analytics.purchase(purchase);
      assert.equal(f.scripts.length, 0);
      assert.equal(f.commands().length, 0);
    }
  }
});

test('opt-in loads the historical tag once with sanitized URL defaults and ads denied', () => {
  const f = fixture({ consent: 'denied' });
  f.analytics.choose('granted'); f.analytics.choose('granted');
  assert.equal(f.scripts.length, 1);
  assert.equal(f.scripts[0].src, `https://www.googletagmanager.com/gtag/js?id=${MEASUREMENT_ID}`);
  assert.equal(f.scripts[0].referrerPolicy, 'no-referrer');
  const [, , consent] = f.commands().find(args => args[0] === 'consent');
  assert.equal(consent.analytics_storage, 'granted');
  for (const name of ['ad_storage', 'ad_user_data', 'ad_personalization']) assert.equal(consent[name], 'denied');
  const settings = f.commands().find(args => args[0] === 'config')[2];
  assert.equal(settings.send_page_view, false);
  assert.equal(settings.allow_google_signals, false);
  assert.equal(settings.page_location, 'https://yaprflow.com/confirmation.html');
  assert.equal(settings.page_referrer, '');
  assert.equal(f.events().filter(args => args[1] === 'page_view').length, 1);
  assert.equal(f.values.get(CONSENT_KEY), 'granted');
  assert.doesNotMatch(JSON.stringify(f.commands()), /cs_live|session_id|checkout\.stripe|#private/);
});

test('live funnel events preserve verified values and omit arbitrary sensitive fields', () => {
  const f = fixture({ consent: 'granted' });
  const contaminated = { ...purchase, analytics: { ...purchase.analytics,
    email: 'buyer@example.com', session_id: 'cs_live_secret', page_location: 'https://private.test/?token=secret',
    items: [{ item_name: 'private transcript', price: 100 }],
  } };
  f.analytics.checkout({ ...config, email: 'buyer@example.com' });
  f.analytics.purchase(contaminated); f.analytics.download('live');
  assert.deepEqual(f.events().map(args => args[1]), ['page_view', 'begin_checkout', 'purchase', 'download_click']);
  const payload = f.events().find(args => args[1] === 'purchase')[2];
  assert.equal(payload.value, 7.99);
  assert.equal(payload.tax, 0.71);
  assert.deepEqual(payload.items, [{ item_id: 'yaprflow-mac', item_name: 'Yaprflow for Mac', price: 7.99, quantity: 1 }]);
  assert.doesNotMatch(JSON.stringify(f.commands()), /buyer@|cs_live|secret|private transcript|session_id/);
});

test('sandbox, unavailable, unpaid and malformed purchases never count as conversions', () => {
  const f = fixture({ consent: 'granted' });
  f.analytics.checkout({ ...config, mode: 'test' });
  f.analytics.checkout({ ...config, enabled: false });
  f.analytics.checkout({ ...config, price: { amount: '799', currency: 'usd' } });
  f.analytics.purchase({ ...purchase, mode: 'test' });
  f.analytics.purchase({ ...purchase, paid: false });
  f.analytics.purchase({ ...purchase, analytics: { ...purchase.analytics, transaction_id: 'cs_live_bearer' } });
  f.analytics.download('test');
  assert.deepEqual(f.events().map(args => args[1]), ['page_view']);
  assert.equal(safePurchase({ ...purchase.analytics, value: NaN }), null);
});

test('verified purchases count once per page and retry with the same GA deduplication ID on reload', () => {
  const f = fixture({ consent: 'denied' });
  f.analytics.purchase(purchase);
  assert.equal(f.events().length, 0);
  f.analytics.choose('granted');
  f.analytics.purchase(purchase); f.analytics.purchase(purchase);
  assert.equal(f.events().filter(args => args[1] === 'purchase').length, 1);
  const reloaded = fixture({ storage: f.values });
  reloaded.analytics.purchase(purchase);
  const retried = reloaded.events().filter(args => args[1] === 'purchase');
  assert.equal(retried.length, 1);
  assert.equal(retried[0][2].transaction_id, purchase.analytics.transaction_id);
});

test('revoking consent disables events, deletes only GA cookies and reloads the page', () => {
  const f = fixture({ consent: 'granted' });
  f.analytics.purchase(purchase);
  const count = f.events().length;
  f.analytics.choose('denied');
  f.analytics.checkout(config); f.analytics.download('live');
  assert.equal(f.events().length, count);
  assert.equal(f.window[`ga-disable-${MEASUREMENT_ID}`], true);
  assert.equal(f.values.get(CONSENT_KEY), 'denied');
  assert.equal(f.values.has('yaprflow.analytics-purchases.v1'), false);
  assert.ok(f.deletedCookies.some(cookie => cookie.startsWith('_ga=')));
  assert.ok(f.deletedCookies.some(cookie => cookie.startsWith('_ga_0FTBJXMCSM=')));
  assert.ok(f.deletedCookies.every(cookie => !cookie.startsWith('necessary=')));
  assert.equal(f.reloads(), 1);
});

test('storage restrictions do not break consent or paid checkout events', () => {
  const f = fixture({ consent: 'denied' });
  Object.defineProperty(f.window, 'localStorage', { get() { throw new Error('Storage blocked'); } });
  const analytics = createAnalytics(f.window, f.document);
  assert.equal(analytics.consent, 'denied');
  assert.equal(f.scripts.length, 0);
  analytics.choose('granted'); analytics.checkout(config); analytics.purchase(purchase);
  assert.equal(f.events().filter(args => args[1] === 'purchase').length, 1);
});
