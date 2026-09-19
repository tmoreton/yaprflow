import { createMetaPixel, hasPrivatePageReference, readTrackingPreference } from './meta-pixel.js';

// Restored from the original website (git commit 7931bd7).
export const MEASUREMENT_ID = 'G-0FTBJXMCSM';
export const CONSENT_KEY = 'yaprflow.analytics-consent.v1';
const allowedHosts = new Set(['yaprflow.com', 'www.yaprflow.com']);
const pageTitles = {
  '/': 'Yaprflow for Mac', '/index.html': 'Yaprflow for Mac',
  '/confirmation.html': 'Your Yaprflow download',
  '/support.html': 'Yaprflow support', '/policies/': 'Yaprflow policies',
  '/policies/index.html': 'Yaprflow policies',
};
const clients = new WeakMap();

function writeStorage(window, key, value) {
  try { window.localStorage?.setItem(key, value); } catch { /* Consent still applies to this page. */ }
}

export function safePage(location) {
  const path = Object.hasOwn(pageTitles, location?.pathname) ? location.pathname : '/';
  return { page_location: `https://yaprflow.com${path === '/index.html' ? '/' : path}`,
    page_title: pageTitles[path], page_referrer: '' };
}

function priceEvent(price) {
  if (!Number.isSafeInteger(price?.amount) || price.amount <= 0 || !/^[a-z]{3}$/i.test(price.currency || '')) return null;
  try {
    const currency = price.currency.toUpperCase();
    const digits = ['ISK', 'UGX'].includes(currency) ? 2
      : new Intl.NumberFormat('en-US', { style: 'currency', currency }).resolvedOptions().maximumFractionDigits;
    const value = price.amount / 10 ** digits;
    return { currency, value, items: [{ item_id: 'yaprflow-mac', item_name: 'Yaprflow for Mac', price: value, quantity: 1 }] };
  } catch { return null; }
}

export function safePurchase(value) {
  if (!/^[a-f0-9]{64}$/.test(value?.transaction_id || '') || !/^[A-Z]{3}$/.test(value.currency || '') ||
      !Number.isFinite(value.value) || value.value < 0 || !Number.isFinite(value.tax) || value.tax < 0) return null;
  // Reconstruct the schema; never spread Stripe, URLs, or arbitrary event data.
  return { transaction_id: value.transaction_id, currency: value.currency, value: value.value, tax: value.tax,
    items: [{ item_id: 'yaprflow-mac', item_name: 'Yaprflow for Mac', price: value.value, quantity: 1 }] };
}

export function createAnalytics(window, document) {
  // Keep each provider independent; a blocked advertising script must not break analytics or payment.
  let pixel;
  try { pixel = createMetaPixel(window, document); } catch { /* Best-effort advertising measurement. */ }
  const eligible = window.location?.protocol === 'https:' && allowedHosts.has(window.location?.hostname)
    && !hasPrivatePageReference(window, document);
  let consent = readTrackingPreference(window, CONSENT_KEY);
  let started = false;
  let verifiedPurchase = null;
  const sentPurchases = new Set();
  const page = safePage(window.location);
  function gtag() { window.dataLayer.push(arguments); }

  function event(name, values = {}) {
    if (!started || consent !== 'granted' || !eligible) return false;
    gtag('event', name, { ...values, ...page, send_to: MEASUREMENT_ID, transport_type: 'beacon' });
    return true;
  }
  function sendPurchase() {
    if (!verifiedPurchase || sentPurchases.has(verifiedPurchase.transaction_id)) return;
    if (event('purchase', verifiedPurchase)) {
      sentPurchases.add(verifiedPurchase.transaction_id);
    }
  }
  function start() {
    if (started || !eligible || consent !== 'granted') return;
    window.dataLayer ||= [];
    window[`ga-disable-${MEASUREMENT_ID}`] = false;
    gtag('consent', 'default', { analytics_storage: 'granted', ad_storage: 'denied',
      ad_user_data: 'denied', ad_personalization: 'denied' });
    gtag('js', new Date());
    // Use only a canonical page path in Google event URL fields.
    gtag('set', { ...page, allow_google_signals: false, allow_ad_personalization_signals: false });
    gtag('config', MEASUREMENT_ID, { ...page, send_page_view: false,
      allow_google_signals: false, allow_ad_personalization_signals: false,
      cookie_domain: 'yaprflow.com', cookie_flags: 'SameSite=Lax;Secure', cookie_expires: 60 * 60 * 24 * 365,
    });
    const script = document.createElement('script');
    script.async = true;
    script.referrerPolicy = 'no-referrer';
    script.src = `https://www.googletagmanager.com/gtag/js?id=${MEASUREMENT_ID}`;
    document.head.append(script);
    started = true;
    event('page_view');
    sendPurchase();
  }
  function choose(value, { reload = true } = {}) {
    if (value !== 'granted' && value !== 'denied') return;
    consent = value;
    writeStorage(window, CONSENT_KEY, value);
    if (value === 'granted') start();
    else {
      window[`ga-disable-${MEASUREMENT_ID}`] = true;
      for (const entry of (document.cookie || '').split(';')) {
        const name = entry.split('=')[0].trim();
        if (!/^_ga(?:_|$)/.test(name)) continue;
        for (const domain of ['', '; Domain=yaprflow.com', '; Domain=.yaprflow.com', `; Domain=${window.location.hostname}`]) {
          document.cookie = `${name}=; Max-Age=0; Path=/${domain}; SameSite=Lax; Secure`;
        }
      }
      sentPurchases.clear();
      if (started && reload) window.location.reload();
    }
    return started && value === 'denied';
  }
  start();
  return {
    get consent() { return consent; }, choose,
    get marketingConsent() { return pixel?.consent; },
    choosePreferences(selection) {
      if (!['denied', 'analytics', 'all'].includes(selection)) return;
      let reloadPixel = false;
      try { reloadPixel = pixel?.choose(selection === 'all' ? 'granted' : 'denied'); } catch { /* Independent provider. */ }
      const reloadAnalytics = choose(selection === 'denied' ? 'denied' : 'granted', { reload: false });
      if (reloadPixel || reloadAnalytics) window.location.reload();
    },
    offer(placement) { if (['nav', 'hero', 'features', 'mobile'].includes(placement)) event('offer_click', { placement }); },
    video(completed = false) { event(completed ? 'demo_video_complete' : 'demo_video_start'); },
    checkout(config) {
      const values = priceEvent(config?.price);
      if (config?.enabled === true && config.mode === 'live' && values) event('begin_checkout', values);
      try { pixel?.checkout(config); } catch { /* Advertising must never block checkout. */ }
    },
    purchase(result) {
      verifiedPurchase = result?.paid === true && result.mode === 'live' ? safePurchase(result.analytics) : null;
      sendPurchase();
      try { pixel?.purchase(result); } catch { /* Advertising must never block a paid download. */ }
    },
    download(mode) { if (mode === 'live') event('download_click', { item_id: 'yaprflow-mac' }); },
  };
}

export function getAnalytics(window, document) {
  if (!clients.has(window)) clients.set(window, createAnalytics(window, document));
  return clients.get(window);
}

// Analytics must never interrupt checkout, verified payment state, or a download.
export function reportAnalytics(window, document, action, value) {
  try { getAnalytics(window, document)[action](value); } catch { /* Best-effort measurement. */ }
}

export function mountAnalytics(document, window) {
  const analytics = getAnalytics(window, document);
  const banner = document.createElement('section');
  banner.className = 'analytics-choice';
  banner.setAttribute('role', 'region');
  banner.setAttribute('aria-label', 'Cookie preferences');
  banner.hidden = true;
  banner.innerHTML = `<div><strong>Your cookie choices</strong><p>Google Analytics measures site use. Meta advertising cookies help measure ads and purchases. Both are enabled by default; you can turn tracking off or allow analytics only. Your recordings and transcripts stay out of tracking. <a href="/policies/#website-analytics">Learn more</a></p></div><div class="analytics-choice-actions"><button type="button" data-analytics-choice="denied">Turn off tracking</button><button type="button" data-analytics-choice="analytics">Analytics only</button><button type="button" data-analytics-choice="all">Allow all</button></div>`;
  document.body.append(banner);
  let returnFocus;
  banner.querySelectorAll('[data-analytics-choice]').forEach(button => button.addEventListener('click', () => {
    analytics.choosePreferences(button.dataset.analyticsChoice);
    banner.hidden = true;
    returnFocus?.focus();
  }));
  document.querySelectorAll('[data-analytics-settings]').forEach(button => button.addEventListener('click', () => {
    returnFocus = button;
    banner.hidden = false;
    banner.querySelector('button').focus();
  }));
  document.querySelectorAll('a.button[href="#founding-offer"]').forEach(link => link.addEventListener('click', () => {
    const placement = link.classList.contains('mobile-cta') ? 'mobile'
      : link.closest('header') ? 'nav' : link.closest('.hero-actions') ? 'hero' : 'features';
    analytics.offer(placement);
  }));
  let videoStarted = false;
  document.getElementById('product-video')?.addEventListener('play', () => {
    if (!videoStarted) { analytics.video(); videoStarted = true; }
  });
  document.getElementById('product-video')?.addEventListener('ended', () => analytics.video(true));
  return analytics;
}

if (typeof document !== 'undefined') mountAnalytics(document, window);
