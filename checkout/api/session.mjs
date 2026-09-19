import { createTranscriptionSessionConfig } from '../transcription-session.mjs';

const sessionWindowMs = 10 * 60 * 1000;
const sessionLimit = 8;
const sessionsByAddress = new Map();

function sendJson(response, status, payload) {
  response.statusCode = status;
  response.setHeader('Content-Type', 'application/json; charset=utf-8');
  response.setHeader('Cache-Control', 'no-store');
  response.end(JSON.stringify(payload));
}

function isExpectedOrigin(request) {
  const origin = request.headers.origin;
  const authority = request.headers.host;
  if (!origin || !authority) return false;
  return origin === `https://${authority}` || origin === `http://${authority}`;
}

function withinRateLimit(request) {
  const forwarded = request.headers['x-forwarded-for'];
  const address = String(forwarded || request.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  const now = Date.now();
  const recent = (sessionsByAddress.get(address) || []).filter((time) => now - time < sessionWindowMs);
  if (recent.length >= sessionLimit) return false;
  recent.push(now);
  sessionsByAddress.set(address, recent);
  return true;
}

async function readBody(request) {
  if (typeof request.body === 'string') return request.body;
  if (Buffer.isBuffer(request.body)) return request.body.toString('utf8');

  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 128 * 1024) throw new Error('REQUEST_TOO_LARGE');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

export default async function handler(request, response) {
  if (request.method !== 'POST') {
    response.setHeader('Allow', 'POST');
    sendJson(response, 405, { error: 'Method not allowed.' });
    return;
  }

  if (!isExpectedOrigin(request)) {
    sendJson(response, 403, { error: 'Unexpected request origin.' });
    return;
  }

  if (!process.env.OPENAI_API_KEY) {
    console.warn('Voice demo unavailable: its server credential is not configured.');
    sendJson(response, 503, { error: 'The voice demo is temporarily unavailable.' });
    return;
  }

  if (!withinRateLimit(request)) {
    sendJson(response, 429, { error: 'Too many live tests. Please wait a few minutes and try again.' });
    return;
  }

  let sdp;
  try {
    sdp = await readBody(request);
  } catch (error) {
    sendJson(response, 413, { error: 'The browser session request was too large.' });
    return;
  }

  if (!sdp.trim()) {
    sendJson(response, 400, { error: 'A browser audio session is required.' });
    return;
  }

  const url = new URL(request.url || '/api/session', `https://${request.headers.host || 'localhost'}`);
  const session = JSON.stringify(createTranscriptionSessionConfig(url.searchParams.get('language')));

  const form = new FormData();
  form.set('sdp', sdp);
  form.set('session', session);

  try {
    const upstream = await fetch('https://api.openai.com/v1/realtime/calls', {
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.OPENAI_API_KEY}` },
      body: form,
      signal: AbortSignal.timeout(25000)
    });

    if (!upstream.ok) {
      let detail = 'unknown upstream error';
      try {
        const payload = await upstream.json();
        const error = payload?.error;
        detail = [error?.type, error?.code, error?.param, error?.message]
          .filter((value) => typeof value === 'string' && value.length)
          .join(' · ')
          .slice(0, 500) || detail;
      } catch { /* Keep a safe generic detail for non-JSON responses. */ }
      console.error(`Realtime session creation failed with status ${upstream.status}: ${detail}`);
      sendJson(response, 502, { error: 'The transcription service could not start a session.' });
      return;
    }

    response.statusCode = 201;
    response.setHeader('Content-Type', 'application/sdp');
    response.setHeader('Cache-Control', 'no-store');
    response.end(await upstream.text());
  } catch (error) {
    console.error('Realtime session creation failed before a response was received.');
    sendJson(response, 502, { error: 'The transcription service is temporarily unavailable.' });
  }
}
