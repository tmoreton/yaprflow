import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  createTranscriptionSessionConfig,
  normalizeTranscriptionLanguage,
  supportedTranscriptionLanguages
} from '../transcription-session.mjs';
import sessionHandler from '../api/session.mjs';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const languages = [
  ['en', 'English'],
  ['es', 'Spanish'],
  ['zh', 'Mandarin Chinese'],
  ['hi', 'Hindi'],
  ['ar', 'Arabic'],
  ['pt', 'Portuguese'],
  ['fr', 'French'],
  ['de', 'German'],
  ['ja', 'Japanese'],
  ['ko', 'Korean']
];

test('transcription languages default to English and reject unsupported values', () => {
  assert.deepEqual(supportedTranscriptionLanguages, languages.map(([code]) => code));
  assert.equal(normalizeTranscriptionLanguage(), 'en');
  assert.equal(normalizeTranscriptionLanguage('ES'), 'es');
  assert.equal(normalizeTranscriptionLanguage('unsupported'), 'en');
  assert.equal(createTranscriptionSessionConfig().audio.input.transcription.language, 'en');
  assert.equal(createTranscriptionSessionConfig('ja').audio.input.transcription.language, 'ja');
  assert.equal(createTranscriptionSessionConfig().audio.input.transcription.model, 'gpt-4o-transcribe');
});

test('landing-page picker defaults to EN and offers exactly the supported languages', async () => {
  const page = await readFile(join(root, 'index.html'), 'utf8');
  const options = [...page.matchAll(/data-language="([a-z]{2})" data-language-name="([^"]+)"/g)]
    .map((match) => [match[1], match[2]]);

  assert.match(page, /id="language-picker-button"[^>]*data-language="en"/);
  assert.deepEqual(options, languages);
  assert.match(page, /\/api\/session\?language=\$\{encodeURIComponent\(selectedLanguage\)\}/);
  assert.match(page, /setTimeout\(stopLiveTranscription, 10000\)/);
});

test('file previews stay on the landing page and explain the server requirement', async () => {
  const page = await readFile(join(root, 'index.html'), 'utf8');
  const fileGuard = page.indexOf("if (isFilePreview)");
  const microphoneRequest = page.indexOf('navigator.mediaDevices.getUserMedia');

  assert.match(page, /const isFilePreview = location\.protocol === 'file:';/);
  assert.match(page, /The microphone demo is unavailable in this preview\./);
  assert.doesNotMatch(page, /location\.assign\(/);
  assert.doesNotMatch(page, /const hostedPreviewUrl/);
  assert.ok(fileGuard !== -1 && fileGuard < microphoneRequest);
  assert.doesNotMatch(page, /liveTranscript\.textContent = error\?\.message/);
  assert.doesNotMatch(page, /return error\?\.message/);
  assert.doesNotMatch(page, /throw new Error\(payload\.error/);
});

test('voice demo setup failures never expose provider configuration', async () => {
  const originalApiKey = process.env.OPENAI_API_KEY;
  const page = await readFile(join(root, 'index.html'), 'utf8');
  const localServer = await readFile(join(root, 'scripts/dev.mjs'), 'utf8');
  const response = {
    headers: {},
    setHeader(name, value) { this.headers[name] = value; },
    end(body) { this.body = body; }
  };

  delete process.env.OPENAI_API_KEY;

  try {
    await sessionHandler({
      method: 'POST',
      url: '/api/session?language=en',
      body: 'offer-sdp',
      headers: { host: 'localhost', origin: 'http://localhost' },
      socket: { remoteAddress: 'missing-config-test' }
    }, response);

    assert.equal(response.statusCode, 503);
    assert.equal(JSON.parse(response.body).error, 'The voice demo is temporarily unavailable.');
    assert.doesNotMatch(response.body, /openai|api.?key/i);
    assert.doesNotMatch(localServer, /Add OPENAI_API_KEY to \.env\.local/);
    assert.match(page, /The voice demo is taking a quick break\./);
  } finally {
    if (originalApiKey === undefined) delete process.env.OPENAI_API_KEY;
    else process.env.OPENAI_API_KEY = originalApiKey;
  }
});

test('deployed session endpoint sends the selected language and safely defaults to English', async () => {
  const originalApiKey = process.env.OPENAI_API_KEY;
  const originalFetch = globalThis.fetch;
  const sessions = [];
  process.env.OPENAI_API_KEY = 'test-key';
  globalThis.fetch = async (_url, init) => {
    assert.equal(init.body.get('sdp'), 'offer-sdp');
    sessions.push(JSON.parse(init.body.get('session')));
    return { ok: true, text: async () => 'answer-sdp' };
  };

  const createResponse = () => ({
    headers: {},
    setHeader(name, value) { this.headers[name] = value; },
    end(body) { this.body = body; }
  });

  try {
    for (const [url, address] of [
      ['/api/session?language=pt', 'test-1'],
      ['/api/session', 'test-2'],
      ['/api/session?language=xx', 'test-3']
    ]) {
      const response = createResponse();
      await sessionHandler({
        method: 'POST',
        url,
        body: 'offer-sdp',
        headers: { host: 'localhost', origin: 'http://localhost' },
        socket: { remoteAddress: address }
      }, response);
      assert.equal(response.statusCode, 201);
    }

    assert.deepEqual(
      sessions.map((session) => session.audio.input.transcription.language),
      ['pt', 'en', 'en']
    );
  } finally {
    globalThis.fetch = originalFetch;
    if (originalApiKey === undefined) delete process.env.OPENAI_API_KEY;
    else process.env.OPENAI_API_KEY = originalApiKey;
  }
});

test('provider session failures remain generic to visitors while retaining safe diagnostics', async () => {
  const originalApiKey = process.env.OPENAI_API_KEY;
  const originalFetch = globalThis.fetch;
  const errors = [];
  process.env.OPENAI_API_KEY = 'test-key';
  globalThis.fetch = async () => ({
    ok: false,
    status: 400,
    json: async () => ({ error: { type: 'invalid_request_error', code: 'bad_session', param: 'session', message: 'Unsupported test configuration.' } })
  });
  const response = {
    headers: {},
    setHeader(name, value) { this.headers[name] = value; },
    end(body) { this.body = body; }
  };
  const originalError = console.error;
  console.error = (message) => errors.push(message);
  try {
    await sessionHandler({
      method: 'POST',
      url: '/api/session?language=en',
      body: 'offer-sdp',
      headers: { host: 'localhost', origin: 'http://localhost' },
      socket: { remoteAddress: 'provider-error-test' }
    }, response);
    assert.equal(response.statusCode, 502);
    assert.deepEqual(JSON.parse(response.body), { error: 'The transcription service could not start a session.' });
    assert.doesNotMatch(response.body, /Unsupported|bad_session|invalid_request_error/);
    assert.match(errors[0], /invalid_request_error · bad_session · session · Unsupported test configuration/);
  } finally {
    console.error = originalError;
    globalThis.fetch = originalFetch;
    if (originalApiKey === undefined) delete process.env.OPENAI_API_KEY;
    else process.env.OPENAI_API_KEY = originalApiKey;
  }
});
