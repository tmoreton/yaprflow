import assert from 'node:assert/strict';
import test from 'node:test';
import { issueDownloadLinkToken, verifyDownloadLinkToken } from '../lib/download-link.js';

const secret = 'test-download-link-secret-at-least-32-bytes';
const testSession = 'cs_test_1234567890abcdef';
const liveSession = 'cs_live_1234567890abcdef';

test('download-link tokens are deterministic, URL-safe and mode-bound when verified', () => {
  const token = issueDownloadLinkToken(testSession, secret);
  assert.equal(token, issueDownloadLinkToken(testSession, secret));
  assert.match(token, /^cs_test_[A-Za-z0-9]+\.[A-Za-z0-9_-]{43}$/);
  assert.equal(verifyDownloadLinkToken(token, secret, 'test'), testSession);
  assert.equal(verifyDownloadLinkToken(token, secret, 'live'), null);
  assert.equal(verifyDownloadLinkToken(issueDownloadLinkToken(liveSession, secret), secret, 'live'), liveSession);
});

test('download-link verification rejects tampering, malformed tokens and the wrong secret', () => {
  const token = issueDownloadLinkToken(testSession, secret);
  for (const candidate of [
    null, '', `${token}x`, token.replace('1234', '1235'), token.replace('.', '..'),
    `${testSession}.${'a'.repeat(42)}`, `${testSession}.${'a'.repeat(44)}`,
  ]) assert.equal(verifyDownloadLinkToken(candidate, secret, 'test'), null);
  assert.equal(verifyDownloadLinkToken(token, 'different-secret-that-is-at-least-32-bytes', 'test'), null);
});

test('download-link issuance requires a valid session and a sufficiently strong secret', () => {
  assert.throws(() => issueDownloadLinkToken('invalid', secret), /not configured/i);
  assert.throws(() => issueDownloadLinkToken(testSession, 'too-short'), /not configured/i);
  assert.equal(verifyDownloadLinkToken('anything', 'too-short', 'test'), null);
});
