import { reportAnalytics } from './analytics.js';

export function checkoutPresentation(config) {
  const mode = config?.mode === 'test' || config?.mode === 'live' ? config.mode : null;
  const price = config?.price;
  const validPrice = Number.isSafeInteger(price?.amount) && price.amount > 0
    && typeof price.currency === 'string' && /^[a-z]{3}$/i.test(price.currency)
    && typeof price.formatted === 'string' && price.formatted.length > 0;
  const enabled = config?.enabled === true && config?.downloadReady === true && !!mode && validPrice;
  return {
    enabled, mode, price: validPrice ? price : null,
    button: enabled ? (mode === 'test' ? 'Try test checkout' : `Buy Yaprflow — ${price.formatted}`) : 'Checkout temporarily unavailable',
    status: enabled
      ? (mode === 'test'
        ? 'Test mode · No real charge. Use Stripe test payment details to try checkout and the Mac download.'
        : 'One payment. Secure checkout by Stripe. Your download follows payment confirmation.')
      : 'Checkout is not available right now. Please check again or contact hello@yaprflow.com.',
  };
}

export function updateDisplayedPrices(document, price) {
  if (!price) return;
  document.querySelectorAll('[data-price]').forEach((node) => { node.textContent = price.formatted; });
  try {
    const format = new Intl.NumberFormat('en-US', { style: 'currency', currency: price.currency.toUpperCase() });
    const minorDigits = ['isk', 'ugx'].includes(price.currency.toLowerCase()) ? 2 : format.resolvedOptions().maximumFractionDigits;
    const value = price.amount / (10 ** minorDigits);
    const parts = format.formatToParts(value);
    const currency = parts.find((part) => part.type === 'currency')?.value || price.currency.toUpperCase();
    const number = parts.filter((part) => ['integer', 'group', 'decimal', 'fraction'].includes(part.type)).map((part) => part.value).join('');
    document.querySelectorAll('[data-price-currency]').forEach((node) => { node.textContent = currency; });
    document.querySelectorAll('[data-price-number]').forEach((node) => { node.textContent = number; });
    const comparison = document.getElementById('price-comparison');
    if (comparison) comparison.hidden = price.currency.toLowerCase() !== 'usd' || value >= 120;
    document.querySelectorAll('[data-savings-amount]').forEach((node) => {
      node.textContent = format.format(120 * Number(node.dataset.savingsAmount) - value);
    });
    document.querySelectorAll('[data-savings-percent]').forEach((node) => {
      node.textContent = `Save ${Math.floor((1 - value / (120 * Number(node.dataset.savingsPercent))) * 100)}%`;
    });
  } catch { /* A server-formatted price is still available if the currency is unsupported. */ }
}

export function updateVoiceDemoAvailability(document, available) {
  const button = document.getElementById('live-transcribe-button');
  const status = document.getElementById('live-transcribe-status');
  const transcript = document.getElementById('live-transcript');
  if (!button || !status || !transcript) return;
  const previous = button.dataset.demoAvailability;
  button.dataset.demoAvailability = available === true ? 'available' : available === false ? 'unavailable' : 'checking';
  // Keep an active session's Stop control and transcript intact during a config refresh.
  if (document.getElementById('live-transcriber')?.dataset.active === 'true') return;
  button.disabled = available !== true;
  if (available === true) {
    if (previous !== 'available') {
      status.textContent = 'Ready when you are';
      transcript.textContent = 'Your words will appear here as you speak.';
      transcript.dataset.empty = 'true';
    }
    return;
  }
  const message = available === false
    ? 'Live microphone demo is temporarily unavailable. Watch the app demonstration above.'
    : 'Checking live microphone demo availability…';
  status.textContent = message;
  transcript.textContent = message;
  transcript.dataset.empty = 'true';
}

export function mountCheckout(document, window, request = window.fetch.bind(window)) {
  const form = document.getElementById('checkout-form');
  const button = document.getElementById('checkout-button');
  const status = document.getElementById('checkout-status');
  const notice = document.getElementById('checkout-notice');
  const retry = document.getElementById('checkout-retry');
  if (!form || !button || !status || !notice || !retry) return;
  const cancelled = new URLSearchParams(window.location.search).get('checkout') === 'cancelled';
  let current = checkoutPresentation(null);
  let submitting = false;
  let loading = false;

  function showNotice(mode) {
    const messages = [];
    if (cancelled) messages.push('Checkout cancelled. You can return to the offer whenever you’re ready.');
    if (mode === 'test') messages.push('Test mode: no real payments. Test checkout uses Stripe’s test payment details.');
    notice.textContent = messages.join(' ');
    notice.hidden = messages.length === 0;
    notice.dataset.mode = mode || 'unavailable';
  }

  async function loadAvailability() {
    if (loading) return;
    loading = true;
    submitting = false;
    button.disabled = true;
    button.textContent = 'Checking availability…';
    status.textContent = 'Checking secure checkout availability…';
    retry.hidden = true;
    let voiceDemoAvailable = false;
    try {
      const response = await request('/api/config', {
        cache: 'no-store', credentials: 'same-origin', signal: AbortSignal.timeout(12000),
      });
      const config = await response.json();
      voiceDemoAvailable = config?.voiceDemoAvailable === true;
      if (!response.ok) throw new Error('Checkout configuration unavailable');
      current = checkoutPresentation(config);
    } catch {
      current = checkoutPresentation(null);
    }
    updateVoiceDemoAvailability(document, voiceDemoAvailable);
    updateDisplayedPrices(document, current.price);
    button.disabled = !current.enabled;
    button.textContent = current.button;
    status.textContent = current.status;
    retry.hidden = current.enabled;
    showNotice(current.mode);
    loading = false;
  }

  form.addEventListener('submit', (event) => {
    if (!current.enabled || submitting) {
      event.preventDefault();
      return;
    }
    reportAnalytics(window, document, 'checkout', current);
    submitting = true;
    button.disabled = true;
    button.textContent = 'Opening secure checkout…';
    status.textContent = current.mode === 'test'
      ? 'Opening Stripe test checkout. No real charge will be made.'
      : 'Opening your secure Stripe checkout…';
  });
  retry.addEventListener('click', loadAvailability);
  window.addEventListener('pageshow', (event) => {
    if (event.persisted) loadAvailability();
  });
  showNotice(null);
  updateVoiceDemoAvailability(document, null);
  const ready = loadAvailability();
  return { ready, reload: loadAvailability };
}

if (typeof document !== 'undefined') mountCheckout(document, window);
