import assert from 'node:assert/strict';
import test from 'node:test';
import {
  allowedPriceIds,
  isPaidMacPurchase,
  loadPaidMacPurchase,
} from '../lib/purchase.js';

const sessionId = 'cs_test_1234567890abcdef';
const prices = new Set(['price_current123']);
const paidSession = {
  mode: 'payment',
  status: 'complete',
  payment_status: 'paid',
  metadata: { product: 'yaprflow-mac' },
  line_items: { data: [{ quantity: 1, price: { id: 'price_current123' } }] },
};

test('download access requires a completed paid Mac checkout for the configured price', () => {
  assert.equal(isPaidMacPurchase(paidSession, prices), true);
  assert.equal(isPaidMacPurchase({ ...paidSession, payment_status: 'unpaid' }, prices), false);
  assert.equal(isPaidMacPurchase({ ...paidSession, status: 'open' }, prices), false);
  assert.equal(isPaidMacPurchase({ ...paidSession, mode: 'subscription' }, prices), false);
  assert.equal(isPaidMacPurchase({ ...paidSession, metadata: { product: 'other' } }, prices), false);
  assert.equal(isPaidMacPurchase({ ...paidSession, line_items: { data: [{ quantity: 1, price: { id: 'price_other' } }] } }, prices), false);
  assert.equal(isPaidMacPurchase({ ...paidSession, line_items: { data: [{ quantity: 2, price: { id: 'price_current123' } }] } }, prices), false);
});

test('download access checks Stripe using a valid session ID', async () => {
  let called = 0;
  const stripe = {
    checkout: {
      sessions: {
        async retrieve(id, options) {
          called += 1;
          assert.equal(id, sessionId);
          assert.deepEqual(options, { expand: ['line_items'] });
          return paidSession;
        },
      },
    },
  };
  assert.equal(await loadPaidMacPurchase(stripe, 'invalid', prices), null);
  assert.equal(called, 0);
  assert.equal(await loadPaidMacPurchase(stripe, sessionId, prices), paidSession);
  assert.equal(called, 1);
});

test('current and previous prices remain eligible after a price change', () => {
  assert.deepEqual(
    allowedPriceIds({
      STRIPE_PRICE_ID: 'price_current123',
      STRIPE_ALLOWED_PRICE_IDS: 'price_previous456, invalid',
    }),
    new Set(['price_current123', 'price_previous456']),
  );
});
