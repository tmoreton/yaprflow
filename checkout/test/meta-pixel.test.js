import assert from 'node:assert/strict';
import test from 'node:test';
import { createMetaPixel, MARKETING_CONSENT_KEY, META_PIXEL_ID } from '../meta-pixel.js';
import { createAnalytics, CONSENT_KEY } from '../analytics.js';

const purchase = { paid: true, mode: 'live', analytics: {
  transaction_id: 'a'.repeat(64), currency: 'USD', value: 7.99, tax: 0.71,
} };
const config = { enabled: true, mode: 'live', price: { amount: 799, currency: 'usd' } };
function fixture({ url = 'https://yaprflow.com/', referrer = '', marketing, analytics, storage } = {}) {
  const values = storage || new Map([[MARKETING_CONSENT_KEY, marketing], [CONSENT_KEY, analytics]].filter(([, value]) => value !== undefined));
  const scripts = [], deletedCookies = [], reloads = [];
  const window = {
    location: Object.assign(new URL(url), { reload: () => reloads.push(new Map(values)) }),
    localStorage: { getItem: key => values.has(key) ? values.get(key) : null, setItem: (key, value) => values.set(key, value) },
  };
  const document = {
    referrer, createElement: () => ({}), head: { append: script => scripts.push(script) },
    get cookie() { return '_fbp=private; _fbc=private; _ga=private; necessary=keep; __Host-yaprflow-purchase=private'; },
    set cookie(value) { deletedCookies.push(value); },
  };
  const commands = () => (window.fbq?.queue || []).map(args => [...args]);
  return { window, document, scripts, values, deletedCookies, reloads, commands,
    events: () => commands().filter(args => args[0] === 'trackSingle') };
}

test('new production visitors get both providers without recording a consent choice in storage', () => {
  const f = fixture();
  const analytics = createAnalytics(f.window, f.document);
  assert.equal(analytics.consent, 'granted');
  assert.equal(analytics.marketingConsent, 'granted');
  assert.equal(f.scripts.filter(script => script.src === 'https://connect.facebook.net/en_US/fbevents.js').length, 1);
  assert.equal(f.scripts.filter(script => script.src.includes('googletagmanager.com/gtag/js')).length, 1);
  assert.deepEqual(f.events().map(args => args[2]), ['PageView', 'ViewContent']);
  assert.equal(f.window.dataLayer.filter(args => args[0] === 'event' && args[1] === 'page_view').length, 1);
  assert.equal(f.values.size, 0);
});

test('stored provider choices remain independent when the other provider has no saved choice', () => {
  for (const [options, googleCount, metaCount] of [
    [{ marketing: 'denied' }, 1, 0],
    [{ analytics: 'denied' }, 0, 1],
    [{ marketing: 'denied', analytics: 'denied' }, 0, 0],
    [{ marketing: 'unexpected', analytics: '' }, 0, 0],
  ]) {
    const f = fixture(options);
    const storedBefore = new Map(f.values);
    createAnalytics(f.window, f.document);
    assert.equal(f.scripts.filter(script => script.src.includes('googletagmanager.com')).length, googleCount);
    assert.equal(f.scripts.filter(script => script.src.includes('facebook.net')).length, metaCount);
    assert.deepEqual(f.values, storedBefore);
  }
});

test('Meta respects stored opt-outs and invalid choices, and excludes local, preview and private URLs', () => {
  const cases = [
    { marketing: 'denied' }, { marketing: 'unexpected' }, { marketing: '' },
    { analytics: 'granted', marketing: 'denied' },
    ...['http://127.0.0.1:4173/', 'https://yaprflow-checkout-preview.vercel.app/',
      'https://yaprflow.com.attacker.test/', 'http://yaprflow.com/', 'https://yaprflow.com/support.html',
      'https://yaprflow.com/confirmation.html?session_id=cs_live_private',
      'https://yaprflow.com/?%73ession_id=private', 'https://yaprflow.com/#client_secret=private',
      'https://yaprflow.com/?redirect=cs%255Flive%255Fprivate',
      'https://yaprflow.com/?token=private'].flatMap(url => [{ url }, { url, marketing: 'granted' }]),
    { marketing: 'granted', referrer: 'https://checkout.stripe.com/c/pay/cs_live_private' },
  ];
  for (const options of cases) {
    const f = fixture(options), pixel = createMetaPixel(f.window, f.document);
    pixel.checkout(config); pixel.purchase(purchase);
    assert.equal(f.scripts.length, 0, JSON.stringify(options));
    assert.equal(f.commands().length, 0);
  }
});

test('landing opt-in initializes the supplied pixel once and sends only page and content views', () => {
  const f = fixture({ url: 'https://yaprflow.com/?utm_source=meta&fbclid=public-ad-click', marketing: 'denied' });
  const pixel = createMetaPixel(f.window, f.document);
  pixel.choose('granted'); pixel.choose('granted');
  assert.deepEqual(f.scripts.map(script => script.src), ['https://connect.facebook.net/en_US/fbevents.js']);
  assert.equal(f.scripts[0].referrerPolicy, 'no-referrer');
  assert.deepEqual(f.commands().find(args => args[0] === 'init'), ['init', '1391229936449100']);
  assert.deepEqual(f.commands().find(args => args[0] === 'set'), ['set', 'autoConfig', false, META_PIXEL_ID]);
  assert.equal(f.window.fbq.disablePushState, true);
  assert.deepEqual(f.events().map(args => args[2]), ['PageView', 'ViewContent']);
  assert.ok(f.events().every(args => args[1] === META_PIXEL_ID));
  assert.equal(f.values.get(MARKETING_CONSENT_KEY), 'granted');
});

test('checkout counts only enabled live checkout attempts', () => {
  const f = fixture({ marketing: 'granted' }), pixel = createMetaPixel(f.window, f.document);
  for (const value of [null, {}, { ...config, enabled: false }, { ...config, enabled: 'true' }, { ...config, mode: 'test' }]) pixel.checkout(value);
  assert.equal(f.events().length, 2);
  pixel.checkout(config);
  assert.deepEqual(f.events().map(args => args[2]), ['PageView', 'ViewContent', 'InitiateCheckout']);
});

test('verified purchase uses actual value and currency, filters private fields, and suppresses polling duplicates', () => {
  const f = fixture({ url: 'https://yaprflow.com/confirmation.html', marketing: 'granted' });
  const pixel = createMetaPixel(f.window, f.document);
  pixel.purchase({ ...purchase, email: 'buyer@example.com', analytics: { ...purchase.analytics,
    session_id: 'cs_live_private', email: 'buyer@example.com', items: [{ name: 'private transcript' }] } });
  pixel.purchase(purchase); pixel.purchase(purchase);
  assert.deepEqual(f.events().map(args => args[2]), ['PageView', 'Purchase']);
  assert.deepEqual(f.events()[1], ['trackSingle', META_PIXEL_ID, 'Purchase', {
    value: 7.99, currency: 'USD', content_ids: ['yaprflow-mac'], content_type: 'product', num_items: 1,
  }, { eventID: `yaprflow-purchase-${purchase.analytics.transaction_id}` }]);
  assert.doesNotMatch(JSON.stringify(f.commands()), /cs_live|buyer@|session_id|private transcript/);
  const revisit = fixture({ url: 'https://yaprflow.com/confirmation.html', storage: f.values });
  createMetaPixel(revisit.window, revisit.document).purchase(purchase);
  assert.deepEqual(revisit.events()[1][4], f.events()[1][4]);
});

test('unpaid, sandbox and malformed purchases never convert; verified purchase can wait for consent', () => {
  const f = fixture({ url: 'https://yaprflow.com/confirmation.html', marketing: 'denied' });
  const pixel = createMetaPixel(f.window, f.document);
  for (const value of [null, {}, { ...purchase, mode: 'test' }, { ...purchase, paid: false },
    { ...purchase, analytics: { ...purchase.analytics, transaction_id: 'cs_live_private' } },
    { ...purchase, analytics: { ...purchase.analytics, value: NaN } },
    { ...purchase, analytics: { ...purchase.analytics, currency: 'usd' } }]) pixel.purchase(value);
  pixel.choose('granted');
  assert.deepEqual(f.events().map(args => args[2]), ['PageView']);
  const waiting = fixture({ url: 'https://yaprflow.com/confirmation.html', marketing: 'denied' });
  const pending = createMetaPixel(waiting.window, waiting.document);
  pending.purchase(purchase);
  assert.equal(waiting.events().length, 0);
  pending.choose('granted');
  assert.deepEqual(waiting.events().map(args => args[2]), ['PageView', 'Purchase']);
});

test('shared choices keep analytics separate and save both preferences before revocation reload', () => {
  const f = fixture({ analytics: 'granted', marketing: 'denied' }), analytics = createAnalytics(f.window, f.document);
  assert.equal(f.window.fbq, undefined);
  assert.equal(analytics.marketingConsent, 'denied');
  analytics.choosePreferences('analytics');
  assert.equal(f.values.get(MARKETING_CONSENT_KEY), 'denied');
  assert.equal(f.window.fbq, undefined);
  const revisit = fixture({ storage: f.values });
  createAnalytics(revisit.window, revisit.document);
  assert.equal(revisit.window.fbq, undefined);
  assert.equal(revisit.scripts.filter(script => script.src.includes('googletagmanager.com')).length, 1);
  analytics.choosePreferences('all');
  analytics.checkout(config); analytics.purchase(purchase);
  assert.deepEqual(f.events().map(args => args[2]), ['PageView', 'ViewContent', 'InitiateCheckout', 'Purchase']);
  analytics.choosePreferences('denied');
  assert.equal(f.reloads.length, 1);
  for (const key of [MARKETING_CONSENT_KEY, CONSENT_KEY]) assert.equal(f.reloads[0].get(key), 'denied');
  assert.ok(f.commands().some(args => args[0] === 'consent' && args[1] === 'revoke'));
  assert.ok(f.deletedCookies.some(value => value.startsWith('_fbp=')));
  assert.ok(f.deletedCookies.some(value => value.startsWith('_fbc=')));
  assert.ok(f.deletedCookies.every(value => !value.startsWith('necessary=')));
  const count = f.events().length;
  analytics.checkout(config); analytics.purchase(purchase);
  assert.equal(f.events().length, count);
});

test('restricted storage and a blocked advertising script cannot prevent Google measurement', () => {
  const f = fixture();
  Object.defineProperty(f.window, 'localStorage', { get() { throw new Error('Storage blocked'); } });
  const analytics = createAnalytics(f.window, f.document);
  assert.equal(analytics.consent, 'denied');
  assert.equal(analytics.marketingConsent, 'denied');
  assert.equal(f.scripts.length, 0, 'unreadable storage must not override an existing opt-out');
  analytics.choosePreferences('all');
  assert.equal(f.events().length, 2);
  const blocked = fixture({ marketing: 'granted', analytics: 'granted' });
  blocked.document.head.append = script => {
    if (script.src.includes('facebook.net')) throw new Error('Advertising blocked');
    blocked.scripts.push(script);
  };
  const other = createAnalytics(blocked.window, blocked.document);
  other.checkout(config); other.purchase(purchase);
  assert.equal(blocked.scripts.length, 1);
  assert.ok(blocked.window.dataLayer.some(args => args[0] === 'event' && args[1] === 'purchase'));
});

test('a failed Meta revoke still removes advertising cookies and reloads with both choices saved', () => {
  const f = fixture({ marketing: 'granted', analytics: 'granted' });
  const analytics = createAnalytics(f.window, f.document);
  f.window.fbq.callMethod = (command, value) => {
    if (command === 'consent' && value === 'revoke') throw new Error('Pixel broken');
  };
  analytics.choosePreferences('analytics');
  assert.equal(f.reloads.length, 1);
  assert.equal(f.reloads[0].get(MARKETING_CONSENT_KEY), 'denied');
  assert.equal(f.reloads[0].get(CONSENT_KEY), 'granted');
  assert.ok(f.deletedCookies.some(value => value.startsWith('_fbp=')));
  assert.ok(f.deletedCookies.some(value => value.startsWith('_fbc=')));
  assert.ok(f.deletedCookies.every(value => /^_fb[pc]=/.test(value)));
});
