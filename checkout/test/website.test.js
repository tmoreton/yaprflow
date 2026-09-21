import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';
import { checkoutPresentation, mountCheckout, updateDisplayedPrices, updateVoiceDemoAvailability } from '../checkout.js';
import { isValidSessionId, mountConfirmation, purchasePresentation } from '../confirmation.js';

const testSessionId = 'cs_test_1234567890abcdef';
const config = {
  enabled: true, mode: 'live', downloadReady: true, voiceDemoAvailable: true,
  price: { amount: 799, currency: 'usd', formatted: '$7.99' },
};
const json = (body, status = 200) => new Response(JSON.stringify(body), { status });
const settle = () => new Promise((resolve) => setImmediate(resolve));

test('an analytics loading failure cannot interrupt checkout or a verified download', async () => {
  const ui = page(`?session_id=${testSessionId}`);
  Object.assign(ui.window.location, { protocol: 'https:', hostname: 'yaprflow.com', pathname: '/confirmation.html' });
  ui.window.localStorage = { getItem: () => 'granted' };
  ui.document.createElement = () => { throw new Error('Analytics script blocked'); };
  await mountCheckout(ui.document, ui.window, async () => json(config)).ready;
  assert.equal(ui.ids.get('checkout-form').dispatch('submit').defaultPrevented, false);
  assert.equal(ui.ids.get('checkout-button').textContent, 'Opening secure checkout…');
  await mountConfirmation(ui.document, ui.window, async () => json({ paid: true, mode: 'live' })).ready;
  assert.equal(ui.ids.get('ready').hidden, false);
  assert.equal(ui.ids.get('status').textContent, 'Payment confirmed. Your Mac download is ready.');
  assert.equal(ui.ids.get('download').dispatch('click').defaultPrevented, false);
});

function node(dataset = {}) {
  const listeners = new Map();
  return {
    dataset, hidden: true, disabled: false, checked: false, textContent: '', href: '', open: false,
    showModal() { this.open = true; },
    close() { this.open = false; },
    addEventListener(type, callback) { listeners.set(type, callback); },
    dispatch(type, extra = {}) {
      const event = { ...extra, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
      listeners.get(type)?.(event);
      return event;
    },
  };
}

function page(search = '') {
  const ids = new Map([
    'checkout-form', 'checkout-button', 'checkout-status', 'checkout-notice', 'checkout-retry',
    'price-comparison', 'status', 'ready', 'help', 'download', 'retry', 'test-badge',
    'live-transcriber', 'live-transcribe-button', 'live-transcribe-status', 'live-transcript',
  ].map((id) => [id, node()]));
  const prices = {
    '[data-price]': [node(), node()],
    '[data-price-currency]': [node()],
    '[data-price-number]': [node()],
    '[data-savings-amount]': [node({ savingsAmount: '1' }), node({ savingsAmount: '2' })],
    '[data-savings-percent]': [node({ savingsPercent: '1' })],
  };
  const timers = new Map();
  const window = node();
  let nextTimer = 1;
  window.location = { search };
  window.setTimeout = (callback, delay) => {
    const id = nextTimer++;
    timers.set(id, { callback, delay });
    return id;
  };
  window.clearTimeout = (id) => timers.delete(id);
  return {
    document: { getElementById: (id) => ids.get(id), querySelectorAll: (selector) => prices[selector] || [] },
    window, ids, prices, timers,
    async runTimer() {
      const [id, timer] = timers.entries().next().value;
      timers.delete(id);
      await timer.callback();
      return timer.delay;
    },
  };
}

test('checkout presentation requires enabled sales, private download readiness, valid price and explicit mode', () => {
  assert.equal(checkoutPresentation(config).enabled, true);
  assert.equal(checkoutPresentation(config).button, 'Buy Yaprflow — $7.99');
  for (const value of [
    null, {}, { ...config, enabled: false }, { ...config, enabled: 'true' },
    { ...config, downloadReady: false }, { ...config, mode: null }, { ...config, mode: 'demo' },
    { ...config, price: null }, { ...config, price: { ...config.price, amount: 0 } },
    { ...config, price: { ...config.price, amount: '799' } },
    { ...config, price: { ...config.price, currency: 'not-a-currency' } },
    { ...config, price: { ...config.price, formatted: '' } },
  ]) assert.equal(checkoutPresentation(value).enabled, false);
  const sandbox = checkoutPresentation({ ...config, mode: 'test' });
  assert.equal(sandbox.button, 'Try test checkout');
  assert.match(sandbox.status, /No real charge/);
});

test('checkout has no mandatory terms checkbox and keeps the offer terms available', async () => {
  const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
  assert.doesNotMatch(html, /id="purchase-terms"|class="purchase-consent"|name="terms"/);
  assert.match(html, /href="\/policies\/#offer">Offer terms<\/a>/);
  assert.match(html, /then download on the confirmation page or from the private link we email you/i);
  assert.match(html, /name="newsletter" value="opt_in"/);
  assert.match(html, /Optional; unsubscribe anytime/i);
  assert.match(html, /Can I buy on my phone and install it later\?/);
});

test('the customer-facing policy separates purchase delivery from optional newsletter consent', async () => {
  const policy = await readFile(new URL('../policies/index.html', import.meta.url), 'utf8');
  const confirmation = await readFile(new URL('../confirmation.html', import.meta.url), 'utf8');
  assert.match(policy, /That choice is recorded with the Stripe purchase/i);
  assert.match(policy, /Buying the app does not subscribe you/i);
  assert.match(policy, /Resend sends a private purchase-recovery link/i);
  assert.match(policy, /resend\.com\/legal\/privacy-policy/);
  assert.match(confirmation, /email a private download link/i);
});

test('the Sparkle feed publishes only the signed unlisted 5.2.8 updater asset', async () => {
  const appcast = await readFile(new URL('../appcast.xml', import.meta.url), 'utf8');
  assert.match(appcast, /<sparkle:version>21<\/sparkle:version>/);
  assert.match(appcast, /<sparkle:shortVersionString>5\.2\.8<\/sparkle:shortVersionString>/);
  assert.match(appcast, /https:\/\/[^/]+\.public\.blob\.vercel-storage\.com\/updates\/5\.2\.8\/[^"\s]+\.dmg/);
  assert.match(appcast, /<enclosure [^>]*sparkle:edSignature="[A-Za-z0-9+/=]+"\/>/);
  assert.match(appcast, /<!-- sparkle-signatures:[\s\S]*edSignature: [A-Za-z0-9+/=]+/);
  assert.doesNotMatch(appcast, /<sparkle:releaseNotesLink/);
  assert.equal((appcast.match(/<enclosure /g) || []).length, 1);
});

test('all displayed prices and illustrative savings update together from server pricing', () => {
  const ui = page();
  updateDisplayedPrices(ui.document, config.price);
  assert.deepEqual(ui.prices['[data-price]'].map((element) => element.textContent), ['$7.99', '$7.99']);
  assert.equal(ui.prices['[data-price-currency]'][0].textContent, '$');
  assert.equal(ui.prices['[data-price-number]'][0].textContent, '7.99');
  assert.equal(ui.ids.get('price-comparison').hidden, false);
  assert.deepEqual(ui.prices['[data-savings-amount]'].map((element) => element.textContent), ['$112.01', '$232.01']);
  assert.equal(ui.prices['[data-savings-percent]'][0].textContent, 'Save 93%');
  updateDisplayedPrices(ui.document, { amount: 1000, currency: 'eur', formatted: '€10.00' });
  assert.equal(ui.ids.get('price-comparison').hidden, true);
  updateDisplayedPrices(ui.document, { amount: 15000, currency: 'usd', formatted: '$150.00' });
  assert.equal(ui.ids.get('price-comparison').hidden, true);
  for (const currency of ['isk', 'ugx']) {
    updateDisplayedPrices(ui.document, { amount: 290000, currency, formatted: `${currency.toUpperCase()} 2,900` });
    assert.equal(ui.prices['[data-price-number]'][0].textContent, '2,900');
  }
});

test('microphone controls wait for configuration and explain missing server availability', async () => {
  const ui = page();
  let respond;
  const mounted = mountCheckout(ui.document, ui.window, () => new Promise((resolve) => { respond = resolve; }));
  assert.equal(ui.ids.get('live-transcribe-button').disabled, true);
  assert.equal(ui.ids.get('live-transcribe-button').dataset.demoAvailability, 'checking');
  respond(json({ ...config, voiceDemoAvailable: false }));
  await mounted.ready;
  assert.equal(ui.ids.get('live-transcribe-button').disabled, true);
  assert.equal(ui.ids.get('live-transcribe-button').dataset.demoAvailability, 'unavailable');
  const message = 'Live microphone demo is temporarily unavailable. Watch the app demonstration above.';
  assert.equal(ui.ids.get('live-transcribe-status').textContent, message);
  assert.equal(ui.ids.get('live-transcript').textContent, message);
  assert.equal(ui.ids.get('checkout-button').disabled, false, 'voice demo setup must not disable working checkout');
});

test('configured microphone demo works independently of Stripe and keeps active transcripts intact', async () => {
  const ui = page();
  await mountCheckout(ui.document, ui.window, async () => json({ voiceDemoAvailable: true }, 503)).ready;
  assert.equal(ui.ids.get('checkout-button').disabled, true);
  assert.equal(ui.ids.get('live-transcribe-button').disabled, false);
  assert.equal(ui.ids.get('live-transcribe-button').dataset.demoAvailability, 'available');
  assert.equal(ui.ids.get('live-transcribe-status').textContent, 'Ready when you are');
  assert.equal(ui.ids.get('live-transcript').textContent, 'Your words will appear here as you speak.');
  ui.ids.get('live-transcriber').dataset.active = 'true';
  ui.ids.get('live-transcribe-button').disabled = true;
  ui.ids.get('live-transcribe-status').textContent = 'Finishing your transcript';
  ui.ids.get('live-transcript').textContent = 'A thought in progress.';
  updateVoiceDemoAvailability(ui.document, true);
  assert.equal(ui.ids.get('live-transcribe-button').disabled, true, 'availability refresh must preserve the demo lifecycle');
  assert.equal(ui.ids.get('live-transcribe-status').textContent, 'Finishing your transcript');
  assert.equal(ui.ids.get('live-transcript').textContent, 'A thought in progress.');
});

test('unreachable configuration keeps microphone disabled and recovery restores the original demo', async () => {
  const ui = page();
  let calls = 0;
  const mounted = mountCheckout(ui.document, ui.window, async () => {
    if (++calls === 1) throw new Error('offline');
    return json(config);
  });
  await mounted.ready;
  assert.equal(ui.ids.get('live-transcribe-button').disabled, true);
  await mounted.reload();
  assert.equal(ui.ids.get('live-transcribe-button').disabled, false);
  assert.equal(ui.ids.get('live-transcribe-status').textContent, 'Ready when you are');
});

test('the actual microphone entrypoint never requests permission while server availability is unconfirmed', async () => {
  const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
  const source = html.slice(html.indexOf('const startLiveTranscription = async () => {'), html.indexOf("liveButton?.addEventListener('click'"));
  assert.ok(source.length > 0);
  for (const availability of [undefined, 'checking', 'unavailable']) {
    let microphoneRequests = 0;
    await runInNewContext(`${source}\nstartLiveTranscription();`, {
      isFilePreview: false,
      liveButton: { dataset: { demoAvailability: availability } },
      navigator: { mediaDevices: { getUserMedia() { microphoneRequests += 1; } } },
    });
    assert.equal(microphoneRequests, 0);
  }
});

test('checkout blocks submission until configuration arrives and then permits only one native form POST', async () => {
  const ui = page('?checkout=cancelled');
  let respond;
  const calls = [];
  const mounted = mountCheckout(ui.document, ui.window, (...args) => {
    calls.push(args);
    return new Promise((resolve) => { respond = resolve; });
  });
  assert.equal(ui.ids.get('checkout-button').disabled, true);
  assert.equal(ui.ids.get('checkout-form').dispatch('submit').defaultPrevented, true);
  respond(json({ ...config, mode: 'test' }));
  await mounted.ready;
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], '/api/config');
  assert.equal(calls[0][1].cache, 'no-store');
  assert.equal(calls[0][1].credentials, 'same-origin');
  assert.equal(ui.ids.get('checkout-button').disabled, false);
  assert.match(ui.ids.get('checkout-notice').textContent, /Checkout cancelled/);
  assert.match(ui.ids.get('checkout-notice').textContent, /Test mode: no real payments/);
  assert.equal(ui.ids.get('checkout-form').dispatch('submit').defaultPrevented, false);
  assert.equal(ui.ids.get('checkout-button').disabled, true);
  assert.equal(ui.ids.get('checkout-form').dispatch('submit').defaultPrevented, true);
  assert.equal(calls.length, 1, 'native submission must not call fetch across the Stripe redirect');
});

test('checkout errors stay closed and a retry can recover without reloading the page', async () => {
  const ui = page();
  let calls = 0;
  mountCheckout(ui.document, ui.window, async () => {
    calls += 1;
    return calls === 1 ? json({ enabled: true }, 503) : json(config);
  });
  await settle();
  assert.equal(ui.ids.get('checkout-button').disabled, true);
  assert.equal(ui.ids.get('checkout-retry').hidden, false);
  assert.equal(ui.ids.get('checkout-form').dispatch('submit').defaultPrevented, true);
  ui.ids.get('checkout-retry').dispatch('click');
  await settle();
  assert.equal(ui.ids.get('checkout-button').disabled, false);
  assert.equal(ui.ids.get('checkout-retry').hidden, true);
  assert.equal(ui.ids.get('checkout-notice').hidden, true);
});

test('returning to checkout through browser history refreshes availability after submission', async () => {
  const ui = page();
  let calls = 0;
  const mounted = mountCheckout(ui.document, ui.window, async () => {
    calls += 1;
    return json(calls === 1 ? config : { ...config, enabled: false });
  });
  await mounted.ready;
  ui.ids.get('checkout-form').dispatch('submit');
  ui.window.dispatch('pageshow', { persisted: true });
  await settle();
  assert.equal(calls, 2);
  assert.equal(ui.ids.get('checkout-button').disabled, true);
  assert.equal(ui.ids.get('checkout-retry').hidden, false);
});

test('a test session ID or mode alone never grants a download entitlement', () => {
  assert.equal(isValidSessionId(testSessionId), true);
  assert.equal(isValidSessionId('cs_test_short'), false);
  assert.equal(isValidSessionId('cs_test_1234567890abcdef<script>'), false);
  for (const [result, status] of [
    [{ mode: 'test', paid: false }, 200], [{ mode: 'test', paid: 'true' }, 200],
    [{ mode: 'test', paid: true }, 403], [{ mode: 'live', paid: true }, 502],
    [{ mode: 'test', pending: true }, 202],
  ]) assert.notEqual(purchasePresentation(result, status).state, 'ready');
  assert.equal(purchasePresentation({ mode: 'test', paid: true }, 200).state, 'ready');
  assert.match(purchasePresentation({ mode: 'test', paid: true }, 200).message, /No real charge/);
});

test('invalid confirmation links make no status request and show no download', async () => {
  const ui = page('?session_id=invalid');
  let calls = 0;
  await mountConfirmation(ui.document, ui.window, async () => { calls += 1; }).ready;
  assert.equal(calls, 0);
  assert.equal(ui.ids.get('ready').hidden, true);
  assert.equal(ui.ids.get('help').hidden, false);
  assert.equal(ui.ids.get('retry').hidden, true);
  assert.equal(ui.ids.get('download').href, '');
});

test('test confirmation rejects an unpaid purchase even when its URL looks valid', async () => {
  const ui = page(`?session_id=${testSessionId}`);
  await mountConfirmation(ui.document, ui.window, async () => json({ mode: 'test', paid: false, pending: false }, 403)).ready;
  assert.equal(ui.ids.get('test-badge').hidden, false);
  assert.equal(ui.ids.get('ready').hidden, true);
  assert.equal(ui.ids.get('download').href, '');
  assert.equal(ui.ids.get('retry').hidden, true);
});

test('server-confirmed purchases link only to the private download verification endpoint', async () => {
  const ui = page(`?session_id=${testSessionId}`);
  const calls = [];
  await mountConfirmation(ui.document, ui.window, async (...args) => {
    calls.push(args);
    return json({ mode: 'test', paid: true, pending: false });
  }).ready;
  assert.equal(calls[0][0], `/api/status?session_id=${testSessionId}`);
  assert.equal(calls[0][1].cache, 'no-store');
  assert.equal(calls[0][1].credentials, 'same-origin');
  assert.equal(ui.ids.get('ready').hidden, false);
  assert.equal(ui.ids.get('download').href, `/api/download?session_id=${testSessionId}`);
  assert.equal(ui.ids.get('test-badge').hidden, false);
  assert.match(ui.ids.get('status').textContent, /Test payment confirmed/);
});

test('clean confirmation uses the same-origin purchase cookie without exposing it in a URL', async () => {
  const ui = page();
  const calls = [];
  await mountConfirmation(ui.document, ui.window, async (...args) => {
    calls.push(args);
    return json({ mode: 'test', paid: true, pending: false });
  }).ready;
  assert.equal(calls[0][0], '/api/status');
  assert.equal(calls[0][1].credentials, 'same-origin');
  assert.equal(calls[0][1].cache, 'no-store');
  assert.equal(ui.ids.get('ready').hidden, false);
  assert.equal(ui.ids.get('download').href, '/api/download');
  const missing = page();
  await mountConfirmation(missing.document, missing.window, async () => json({ paid: false }, 403)).ready;
  assert.equal(missing.ids.get('ready').hidden, true);
  assert.equal(missing.ids.get('download').href, '');
});

test('pending payment polling is bounded and never exposes a download before verification', async () => {
  const ui = page(`?session_id=${testSessionId}`);
  let calls = 0;
  await mountConfirmation(ui.document, ui.window, async () => {
    calls += 1;
    return calls <= 6 ? json({ mode: 'test', paid: false, pending: true }, 202)
      : json({ mode: 'test', paid: true, pending: false });
  }).ready;
  assert.equal(ui.ids.get('ready').hidden, true);
  const delays = [];
  while (ui.timers.size) {
    delays.push(await ui.runTimer());
    assert.equal(ui.ids.get('ready').hidden, true);
    assert.equal(ui.ids.get('download').href, '');
  }
  assert.equal(calls, 6);
  assert.deepEqual(delays, [2000, 4000, 6000, 8000, 8000]);
  assert.equal(ui.ids.get('retry').hidden, false);
  assert.match(ui.ids.get('status').textContent, /taking a little longer/);
  ui.ids.get('retry').dispatch('click');
  await settle();
  assert.equal(calls, 7);
  assert.equal(ui.ids.get('ready').hidden, false);
});

test('confirmation network failures offer retry and page navigation cancels polling', async () => {
  const ui = page(`?session_id=${testSessionId}`);
  let calls = 0;
  await mountConfirmation(ui.document, ui.window, async () => {
    calls += 1;
    if (calls === 1) throw new Error('offline');
    return json({ mode: 'test', paid: false, pending: true }, 202);
  }).ready;
  assert.equal(ui.ids.get('ready').hidden, true);
  assert.equal(ui.ids.get('retry').hidden, false);
  ui.ids.get('retry').dispatch('click');
  await settle();
  assert.equal(ui.timers.size, 1);
  ui.window.dispatch('pagehide');
  assert.equal(ui.timers.size, 0);
  ui.window.dispatch('pageshow', { persisted: true });
  await settle();
  assert.equal(calls, 3);
  assert.equal(ui.timers.size, 1);
  ui.window.dispatch('pagehide');
});
