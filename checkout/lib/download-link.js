import { createHmac, timingSafeEqual } from 'node:crypto';

const SESSION_ID = /^cs_(?:test|live)_[A-Za-z0-9]{10,}$/;
const TOKEN_DOMAIN = 'yaprflow:purchase-download:v1\0';

function secretBuffer(secret) {
  if (typeof secret !== 'string' || Buffer.byteLength(secret, 'utf8') < 32) return null;
  return Buffer.from(secret, 'utf8');
}

function validSessionId(sessionId, mode) {
  return typeof sessionId === 'string' && SESSION_ID.test(sessionId) &&
    (!mode || sessionId.startsWith(`cs_${mode}_`));
}

function signature(sessionId, secret) {
  return createHmac('sha256', secret).update(TOKEN_DOMAIN).update(sessionId).digest();
}

export function issueDownloadLinkToken(sessionId, secret) {
  const key = secretBuffer(secret);
  if (!key || !validSessionId(sessionId)) throw new Error('Download link signing is not configured.');
  return `${sessionId}.${signature(sessionId, key).toString('base64url')}`;
}

export function verifyDownloadLinkToken(token, secret, mode) {
  const key = secretBuffer(secret);
  if (!key || typeof token !== 'string' || token.length > 256) return null;
  const separator = token.lastIndexOf('.');
  if (separator < 1 || separator === token.length - 1) return null;
  const sessionId = token.slice(0, separator);
  const encodedSignature = token.slice(separator + 1);
  if (!/^[A-Za-z0-9_-]{43}$/.test(encodedSignature)) return null;
  if (!validSessionId(sessionId, mode)) return null;
  let received;
  try {
    received = Buffer.from(encodedSignature, 'base64url');
  } catch {
    return null;
  }
  const expected = signature(sessionId, key);
  return received.length === expected.length && timingSafeEqual(received, expected) ? sessionId : null;
}
