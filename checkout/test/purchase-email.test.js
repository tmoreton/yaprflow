import assert from 'node:assert/strict';
import test from 'node:test';
import { fulfillPaidPurchase, fulfillmentMetadata, purchaseEmailContent } from '../lib/purchase-email.js';
import { verifyDownloadLinkToken } from '../lib/download-link.js';

const sessionId = 'cs_test_1234567890abcdef';
const environment = {
  CHECKOUT_BASE_URL: 'https://checkout.example.com',
  DOWNLOAD_LINK_SECRET: 'test-download-link-secret-at-least-32-bytes',
  PURCHASE_EMAIL_FROM: 'Yaprflow <downloads@yaprflow.com>',
  PURCHASE_EMAIL_REPLY_TO: 'support@yaprflow.com',
  RESEND_NEWSLETTER_SEGMENT_ID: 'newsletter-buyers',
};

function fixture(options = {}) {
  const {
    metadata = { product: 'yaprflow-mac' }, emailResult = { data: { id: 'email_1' }, error: null },
    contactResult = { data: { id: 'contact_1' }, error: null }, segmentResult = { data: { id: 'segment_1' }, error: null },
    customerDetails = { email: 'buyer@example.com', name: 'Taylor Buyer' },
  } = options;
  const consent = Object.hasOwn(options, 'consent') ? options.consent : 'opt_in';
  const session = {
    id: sessionId, livemode: false,
    metadata: { ...metadata, newsletter_opt_in: String(consent === 'opt_in') },
    customer_details: customerDetails,
  };
  const calls = { emails: [], contacts: [], segments: [], updates: [] };
  const resend = {
    emails: { send: async (...args) => { calls.emails.push(args); return emailResult; } },
    contacts: {
      create: async (...args) => { calls.contacts.push(args); return contactResult; },
      segments: { add: async (...args) => { calls.segments.push(args); return segmentResult; } },
    },
  };
  const stripe = { checkout: { sessions: { update: async (...args) => { calls.updates.push(args); return session; } } } };
  const resendFactory = () => resend;
  return { session, calls, stripe, resendFactory };
}

test('paid fulfillment emails a cross-device recovery link and stores explicit newsletter consent', async () => {
  const item = fixture();
  const result = await fulfillPaidPurchase({ ...item, environment });
  assert.deepEqual(result, { emailSent: true, newsletterSaved: true });
  assert.equal(item.calls.emails.length, 1);
  const [message, options] = item.calls.emails[0];
  assert.equal(message.from, environment.PURCHASE_EMAIL_FROM);
  assert.equal(message.to, 'buyer@example.com');
  assert.equal(message.replyTo, environment.PURCHASE_EMAIL_REPLY_TO);
  assert.equal(message.subject, '[Test] Your Yaprflow download');
  assert.match(message.text, /support@yaprflow\.com/);
  assert.match(message.html, /mailto:support@yaprflow\.com/);
  assert.equal(options.idempotencyKey, `yaprflow-download-${sessionId}`);
  const link = new URL(message.text.match(/https:\/\/\S+/)[0]);
  assert.equal(link.origin, environment.CHECKOUT_BASE_URL);
  assert.equal(link.pathname, '/api/redeem');
  assert.equal(verifyDownloadLinkToken(link.searchParams.get('token'), environment.DOWNLOAD_LINK_SECRET, 'test'), sessionId);
  assert.doesNotMatch(message.text, /private\.blob\.vercel-storage/);
  assert.deepEqual(item.calls.contacts, [[{
    email: 'buyer@example.com', unsubscribed: false, firstName: 'Taylor', lastName: 'Buyer',
    segments: [{ id: 'newsletter-buyers' }],
  }]]);
  assert.deepEqual(item.calls.updates, [
    [sessionId, { metadata: { [fulfillmentMetadata.emailSent]: 'true' } }],
    [sessionId, { metadata: { [fulfillmentMetadata.newsletterSaved]: 'true' } }],
  ]);
});

test('purchasers who do not opt in still get the download but are not subscribed', async () => {
  for (const consent of ['opt_out', undefined]) {
    const item = fixture({ consent });
    const result = await fulfillPaidPurchase({ ...item, environment });
    assert.deepEqual(result, { emailSent: true, newsletterSaved: false });
    assert.equal(item.calls.emails.length, 1);
    assert.equal(item.calls.contacts.length, 0);
    assert.equal(item.calls.segments.length, 0);
    assert.equal(item.calls.updates.length, 1);
  }
});

test('fulfillment markers prevent repeat email and newsletter delivery across webhook retries', async () => {
  const item = fixture({ metadata: {
    product: 'yaprflow-mac',
    [fulfillmentMetadata.emailSent]: 'true',
    [fulfillmentMetadata.newsletterSaved]: 'true',
  } });
  const result = await fulfillPaidPurchase({ ...item, environment, resendFactory: () => { throw new Error('should not construct'); } });
  assert.deepEqual(result, { emailSent: false, newsletterSaved: false });
  assert.deepEqual(item.calls, { emails: [], contacts: [], segments: [], updates: [] });
});

test('an existing newsletter contact is attached without resetting its unsubscribe state', async () => {
  const item = fixture({
    metadata: { product: 'yaprflow-mac', [fulfillmentMetadata.emailSent]: 'true' },
    contactResult: { data: null, error: { statusCode: 409, name: 'validation_error', message: 'already exists' } },
  });
  const result = await fulfillPaidPurchase({ ...item, environment });
  assert.deepEqual(result, { emailSent: false, newsletterSaved: true });
  assert.equal(item.calls.contacts.length, 1);
  assert.deepEqual(item.calls.segments, [[{ email: 'buyer@example.com', segmentId: 'newsletter-buyers' }]]);
  assert.equal(item.calls.updates.length, 1);
});

test('email and contact provider errors fail safely for webhook retry', async () => {
  const emailFailure = fixture({ emailResult: {
    data: null, error: { statusCode: 503, name: 'application_error', message: 'unavailable' },
  } });
  await assert.rejects(fulfillPaidPurchase({ ...emailFailure, environment }), /could not be sent/i);
  assert.equal(emailFailure.calls.updates.length, 0);
  assert.equal(emailFailure.calls.contacts.length, 0);

  const contactFailure = fixture({
    metadata: { product: 'yaprflow-mac', [fulfillmentMetadata.emailSent]: 'true' },
    contactResult: { data: null, error: { statusCode: 503, name: 'application_error', message: 'unavailable' } },
    segmentResult: { data: null, error: { statusCode: 503, name: 'application_error', message: 'unavailable' } },
  });
  await assert.rejects(fulfillPaidPurchase({ ...contactFailure, environment }), /could not be saved/i);
  assert.equal(contactFailure.calls.updates.length, 0);
});

test('fulfillment requires a valid purchaser email and complete delivery configuration', async () => {
  const noEmail = fixture({ customerDetails: { email: 'invalid', name: 'Buyer' } });
  await assert.rejects(fulfillPaidPurchase({ ...noEmail, environment }), /valid customer email/i);
  const noSecret = fixture();
  await assert.rejects(fulfillPaidPurchase({ ...noSecret, environment: { ...environment, DOWNLOAD_LINK_SECRET: '' } }), /not configured/i);
  const noSegment = fixture({ metadata: { product: 'yaprflow-mac', [fulfillmentMetadata.emailSent]: 'true' } });
  await assert.rejects(fulfillPaidPurchase({ ...noSegment, environment: { ...environment, RESEND_NEWSLETTER_SEGMENT_ID: '' } }), /segment is not configured/i);
});

test('purchase email links use the validated deployment origin in Vercel Preview', async () => {
  const item = fixture({ consent: 'opt_out' });
  await fulfillPaidPurchase({
    ...item,
    environment: {
      ...environment,
      CHECKOUT_BASE_URL: '',
      NODE_ENV: 'production',
      VERCEL_ENV: 'preview',
      VERCEL_URL: 'yaprflow-preview-123.vercel.app',
    },
  });
  assert.match(item.calls.emails[0][0].text, /https:\/\/yaprflow-preview-123\.vercel\.app\/api\/redeem\?token=/);
});

test('the purchase email escapes its recovery URL in HTML while preserving the exact text URL', () => {
  const content = purchaseEmailContent({ downloadUrl: 'https://example.com/api/redeem?token=a&next=<unsafe>' });
  assert.match(content.text, /token=a&next=<unsafe>/);
  assert.match(content.html, /token=a&amp;next=&lt;unsafe&gt;/);
  assert.doesNotMatch(content.html, /token=a&next=<unsafe>/);
});
