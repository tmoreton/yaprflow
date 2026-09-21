import { Resend } from 'resend';
import { issueDownloadLinkToken } from './download-link.js';
import { checkoutSettings } from './settings.js';

const EMAIL_SENT = 'download_email_sent';
const NEWSLETTER_SAVED = 'newsletter_contact_saved';
const NEWSLETTER_OPT_IN = 'newsletter_opt_in';

function configuredValue(value, maximum = 320) {
  return typeof value === 'string' && value.trim() && value.length <= maximum && !/[\r\n]/.test(value)
    ? value.trim() : null;
}

function validEmail(value) {
  const email = configuredValue(value, 254);
  return email && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ? email : null;
}

function purchaserEmail(session) {
  return validEmail(session?.customer_details?.email) || validEmail(session?.customer_email);
}

function splitName(value) {
  const name = configuredValue(value, 160);
  if (!name) return {};
  const parts = name.split(/\s+/);
  if (parts.length === 1) return { firstName: parts[0] };
  return { firstName: parts.shift(), lastName: parts.join(' ') };
}

function htmlEscape(value) {
  return String(value).replace(/[&<>"']/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[character]);
}

function resendError(message, error) {
  const failure = new Error(message);
  failure.cause = error || undefined;
  return failure;
}

export function resendClient(environment = process.env) {
  const apiKey = configuredValue(environment.RESEND_API_KEY, 500);
  return apiKey?.startsWith('re_') ? new Resend(apiKey) : null;
}

export function purchaseEmailContent({ downloadUrl, testMode = false }) {
  const safeUrl = htmlEscape(downloadUrl);
  const modeNote = testMode
    ? '\nThis was a Stripe test purchase, so it does not grant a live product license.\n'
    : '';
  return {
    subject: `${testMode ? '[Test] ' : ''}Your Yaprflow download`,
    text: [
      'Thanks for purchasing Yaprflow.',
      modeNote.trim(),
      'Open your private download link on the Mac where you want to install Yaprflow:',
      downloadUrl,
      '',
      'The link verifies your purchase before making the latest Mac installer available. Keep it private and do not forward it.',
      '',
      'Need help? Reply to this email or contact tim@yaprflow.com.',
    ].filter(Boolean).join('\n\n'),
    html: `<!doctype html><html><body style="margin:0;background:#f5f1e8;color:#171714;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif"><div style="max-width:560px;margin:0 auto;padding:40px 24px"><div style="font-size:28px;font-weight:800;letter-spacing:-.03em">Yaprflow</div><h1 style="font-size:32px;line-height:1.05;margin:28px 0 14px">Your Mac download is ready.</h1><p style="font-size:17px;line-height:1.55;margin:0 0 24px">Thanks for purchasing Yaprflow. Open this private link on the Mac where you want to install it.</p>${testMode ? '<p style="padding:12px 14px;background:#fff3c4;border:1px solid #c99700">This was a Stripe test purchase and does not grant a live product license.</p>' : ''}<p style="margin:28px 0"><a href="${safeUrl}" style="display:inline-block;background:#ff4f38;color:#171714;text-decoration:none;font-weight:800;padding:15px 22px;border:2px solid #171714">Download Yaprflow for Mac</a></p><p style="font-size:14px;line-height:1.55;color:#5d5b55">This link verifies your purchase before making the latest installer available. Keep it private and do not forward it.</p><p style="font-size:14px;line-height:1.55;color:#5d5b55">Need help? Reply to this email or contact <a href="mailto:tim@yaprflow.com" style="color:#171714">tim@yaprflow.com</a>.</p></div></body></html>`,
  };
}

async function markFulfilled(stripe, sessionId, key) {
  await stripe.checkout.sessions.update(sessionId, { metadata: { [key]: 'true' } });
}

async function saveNewsletterContact(resend, session, email, segmentId) {
  const name = splitName(session.customer_details?.name);
  const created = await resend.contacts.create({
    email,
    unsubscribed: false,
    ...name,
    segments: [{ id: segmentId }],
  });
  if (!created.error) return;

  // Existing contacts are attached to the buyer segment without changing their
  // global unsubscribe state. Other failures will also fail this call and retry.
  const attached = await resend.contacts.segments.add({ email, segmentId });
  if (attached.error && attached.error.statusCode !== 409) {
    throw resendError('Newsletter contact could not be saved.', attached.error);
  }
}

export async function fulfillPaidPurchase({
  session,
  stripe,
  environment = process.env,
  resendFactory = resendClient,
}) {
  const email = purchaserEmail(session);
  if (!email) throw new Error('The paid checkout session does not contain a valid customer email.');

  const sendEmail = session.metadata?.[EMAIL_SENT] !== 'true';
  const saveNewsletter = session.metadata?.[NEWSLETTER_OPT_IN] === 'true' &&
    session.metadata?.[NEWSLETTER_SAVED] !== 'true';
  if (!sendEmail && !saveNewsletter) return { emailSent: false, newsletterSaved: false };

  const resend = resendFactory(environment);
  if (!resend) throw new Error('Purchase email delivery is not configured.');

  let emailSent = false;
  let newsletterSaved = false;
  if (sendEmail) {
    const from = configuredValue(environment.PURCHASE_EMAIL_FROM);
    const replyTo = validEmail(environment.PURCHASE_EMAIL_REPLY_TO) || 'tim@yaprflow.com';
    const secret = environment.DOWNLOAD_LINK_SECRET;
    if (!from || !from.includes('@')) throw new Error('The purchase email sender is not configured.');
    const token = issueDownloadLinkToken(session.id, secret);
    const baseUrl = checkoutSettings(environment).baseUrl;
    if (!baseUrl) throw new Error('The checkout origin is not configured.');
    const recoveryUrl = new URL('/api/redeem', baseUrl);
    recoveryUrl.searchParams.set('token', token);
    const content = purchaseEmailContent({ downloadUrl: recoveryUrl.href, testMode: !session.livemode });
    const result = await resend.emails.send({
      from,
      to: email,
      replyTo,
      subject: content.subject,
      text: content.text,
      html: content.html,
    }, { idempotencyKey: `yaprflow-download-${session.id}` });
    if (result.error) throw resendError('Purchase email could not be sent.', result.error);
    await markFulfilled(stripe, session.id, EMAIL_SENT);
    emailSent = true;
  }

  if (saveNewsletter) {
    const segmentId = configuredValue(environment.RESEND_NEWSLETTER_SEGMENT_ID, 160);
    if (!segmentId) throw new Error('The newsletter buyer segment is not configured.');
    await saveNewsletterContact(resend, session, email, segmentId);
    await markFulfilled(stripe, session.id, NEWSLETTER_SAVED);
    newsletterSaved = true;
  }

  return { emailSent, newsletterSaved };
}

export const fulfillmentMetadata = Object.freeze({ emailSent: EMAIL_SENT, newsletterSaved: NEWSLETTER_SAVED });
