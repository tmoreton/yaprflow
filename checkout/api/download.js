import { issueSignedToken, presignUrl } from '@vercel/blob';
import { allowedPriceIds, loadPaidMacPurchase, privateResponse } from '../lib/purchase.js';
import { stripeClient } from '../lib/stripe.js';

export async function GET(request) {
  const sessionId = new URL(request.url).searchParams.get('session_id');
  const pathname = process.env.BLOB_PATHNAME;
  if (!pathname || pathname.startsWith('/') || pathname.includes('..')) {
    return privateResponse('The download is not ready.', { status: 503 });
  }

  try {
    const session = await loadPaidMacPurchase(
      stripeClient(), sessionId, allowedPriceIds(),
    );
    if (!session) {
      return privateResponse('Purchase could not be verified.', { status: 403 });
    }

    const expires = Date.now() + 5 * 60 * 1000;
    const token = await issueSignedToken({
      pathname,
      operations: ['get'],
      validUntil: expires,
    });
    const { presignedUrl } = await presignUrl(token, {
      pathname,
      operation: 'get',
      access: 'private',
      validUntil: expires,
    });
    const downloadUrl = new URL(presignedUrl);
    if (downloadUrl.protocol !== 'https:' ||
        !downloadUrl.hostname.endsWith('.private.blob.vercel-storage.com')) {
      throw new Error('Blob returned an invalid private download URL');
    }
    return privateResponse(null, {
      status: 303,
      headers: { Location: downloadUrl.href },
    });
  } catch (error) {
    console.error('Private download failed:', error?.type || error?.name || 'unknown');
    return privateResponse('The download is temporarily unavailable.', { status: 502 });
  }
}
