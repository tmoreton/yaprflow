import { createHash } from 'node:crypto';
import { checkoutProductMarker } from './purchase.js';

const isMinorAmount = (amount) => Number.isSafeInteger(amount) && amount >= 0;

// Only call after verifying the product and allowed Price ID with Stripe.
// Missing reporting fields must never prevent access to an otherwise paid purchase.
export function purchaseAnalytics(session) {
  if (!session || session.livemode !== true || session.mode !== 'payment' ||
      session.status !== 'complete' || session.payment_status !== 'paid' ||
      session.metadata?.product !== checkoutProductMarker() ||
      !/^cs_live_[A-Za-z0-9]{10,}$/.test(session.id || '')) return null;

  const items = session.line_items?.data;
  if (!Array.isArray(items) || items.length !== 1 || session.line_items.has_more ||
      items[0]?.quantity !== 1) return null;
  const item = items[0];
  const total = session.amount_total;
  const tax = session.total_details?.amount_tax;
  const currency = session.currency;
  if (!isMinorAmount(total) || total === 0 || !isMinorAmount(tax) || tax > total ||
      session.total_details?.amount_shipping !== 0 ||
      typeof currency !== 'string' || !/^[a-z]{3}$/.test(currency) ||
      item.currency !== currency || item.amount_total !== total || item.amount_tax !== tax) return null;

  try {
    const format = new Intl.NumberFormat('en-US', { style: 'currency', currency });
    // Stripe uses hundredths for ISK and UGX, despite their zero-decimal display.
    const minorDigits = ['isk', 'ugx'].includes(currency)
      ? 2 : format.resolvedOptions().maximumFractionDigits;
    const divisor = 10 ** minorDigits;
    const value = (total - tax) / divisor;
    const taxValue = tax / divisor;
    if (!Number.isFinite(value) || !Number.isFinite(taxValue)) return null;
    return {
      transaction_id: createHash('sha256').update('yaprflow:ga4-purchase:v1\0').update(session.id).digest('hex'),
      currency: currency.toUpperCase(),
      value,
      tax: taxValue,
      items: [{ item_id: 'yaprflow-mac', item_name: 'Yaprflow for Mac', price: value, quantity: 1 }],
    };
  } catch {
    return null;
  }
}
