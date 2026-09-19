export const META_PIXEL_ID = '1391229936449100';
export const MARKETING_CONSENT_KEY = 'yaprflow.marketing-consent.v1';
const hosts = new Set(['yaprflow.com', 'www.yaprflow.com']);
const pages = new Set(['/', '/index.html', '/confirmation.html']);
const privateReference = /(?:cs_(?:test|live)_|session_id|client_secret|vercel-blob|payment_intent|(?:^|[?&])(?:token|signature)=)/i;

export function readTrackingPreference(window, key) {
  try {
    const saved = window.localStorage?.getItem(key);
    // The site default is not a recorded visitor choice. Keep explicit opt-outs.
    return saved == null || saved === 'granted' ? 'granted' : 'denied';
  } catch {
    // If saved choices cannot be read, avoid overriding a possible opt-out.
    return 'denied';
  }
}

function containsPrivateReference(value) {
  // URLs may encode query keys or a referring checkout URL more than once.
  for (let depth = 0; depth < 3; depth++) {
    if (privateReference.test(value)) return true;
    try {
      const decoded = decodeURIComponent(value);
      if (decoded === value) return false;
      value = decoded;
    } catch { return true; }
  }
  return privateReference.test(value);
}

export function hasPrivatePageReference(window, document) {
  const location = window.location;
  return containsPrivateReference(`${location?.search || ''}${location?.hash || ''}`)
    || containsPrivateReference(document.referrer || '');
}

export function isPixelPageSafe(window, document) {
  const location = window.location;
  if (location?.protocol !== 'https:' || !hosts.has(location.hostname) || !pages.has(location.pathname)) return false;
  // The completion endpoint removes private session references before this document exists.
  // Fail closed for old/raw links or a private referring URL if a hosting redirect is misconfigured.
  return !hasPrivatePageReference(window, document);
}

export function createMetaPixel(window, document) {
  let consent = readTrackingPreference(window, MARKETING_CONSENT_KEY);
  let started = false;
  let purchase = null;
  const sent = new Set();
  const eligible = isPixelPageSafe(window, document);
  function track(name, parameters = {}, options) {
    if (!started || consent !== 'granted' || !eligible) return false;
    window.fbq('trackSingle', META_PIXEL_ID, name, parameters, ...(options ? [options] : []));
    return true;
  }
  function sendPurchase() {
    if (!purchase || sent.has(purchase.transaction_id)) return;
    if (track('Purchase', { value: purchase.value, currency: purchase.currency,
      content_ids: ['yaprflow-mac'], content_type: 'product', num_items: 1 },
    { eventID: `yaprflow-purchase-${purchase.transaction_id}` })) sent.add(purchase.transaction_id);
  }
  function start() {
    if (started || consent !== 'granted' || !eligible) return;
    if (!window.fbq) {
      const fbq = function () {
        if (fbq.callMethod) fbq.callMethod.apply(fbq, arguments);
        else fbq.queue.push(arguments);
      };
      fbq.push = fbq;
      fbq.loaded = true;
      fbq.version = '2.0';
      fbq.queue = [];
      window.fbq = fbq;
      window._fbq ||= fbq;
    }
    window.fbq('consent', 'grant');
    window.fbq('set', 'autoConfig', false, META_PIXEL_ID);
    window.fbq.disablePushState = true;
    // No email, phone, user data, automatic matching, or Conversions API opt-in.
    window.fbq('init', META_PIXEL_ID);
    const script = document.createElement('script');
    script.async = true;
    script.referrerPolicy = 'no-referrer';
    script.src = 'https://connect.facebook.net/en_US/fbevents.js';
    document.head.append(script);
    started = true;
    track('PageView');
    if (['/', '/index.html'].includes(window.location.pathname)) {
      track('ViewContent', { content_ids: ['yaprflow-mac'], content_type: 'product', content_name: 'Yaprflow for Mac' });
    }
    sendPurchase();
  }
  function choose(value) {
    if (!['granted', 'denied'].includes(value)) return false;
    consent = value;
    try { window.localStorage?.setItem(MARKETING_CONSENT_KEY, value); } catch { /* Page-local consent still works. */ }
    if (value === 'granted') { start(); return false; }
    if (started) {
      try { window.fbq('consent', 'revoke'); } catch { /* Cleanup and reload must still run. */ }
    }
    for (const entry of (document.cookie || '').split(';')) {
      const name = entry.split('=')[0].trim();
      if (!['_fbp', '_fbc'].includes(name)) continue;
      for (const domain of ['', '; Domain=yaprflow.com', '; Domain=.yaprflow.com', `; Domain=${window.location?.hostname}`]) {
        document.cookie = `${name}=; Max-Age=0; Path=/${domain}; SameSite=Lax; Secure`;
      }
    }
    return started; // The shared preference controller reloads after both choices are saved.
  }
  start();
  return {
    get consent() { return consent; }, choose,
    checkout(config) {
      if (config?.enabled === true && config.mode === 'live') track('InitiateCheckout', {
        content_ids: ['yaprflow-mac'], content_type: 'product', num_items: 1,
      });
    },
    purchase(result) {
      const value = result?.analytics;
      purchase = result?.paid === true && result.mode === 'live' &&
        /^[a-f0-9]{64}$/.test(value?.transaction_id || '') && /^[A-Z]{3}$/.test(value?.currency || '') &&
        Number.isFinite(value?.value) && value.value >= 0
        ? { transaction_id: value.transaction_id, currency: value.currency, value: value.value } : null;
      sendPurchase();
    },
  };
}
