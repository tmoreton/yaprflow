import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createReadStream } from 'node:fs';
import { mkdtemp, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { head, issueSignedToken, presignUrl, put } from '@vercel/blob';

const [filePath, pathname, mode] = process.argv.slice(2);
const token = process.env.BLOB_READ_WRITE_TOKEN?.trim();
const verifyOnly = mode === '--verify-only';

if (!filePath || !/^releases\/yaprflow-[0-9]+\.[0-9]+\.[0-9]+\.dmg$/.test(pathname || '') ||
    (mode && !verifyOnly)) {
  throw new Error('usage: node scripts/upload-private-release.mjs path/to/yaprflow-X.Y.Z.dmg releases/yaprflow-X.Y.Z.dmg [--verify-only]');
}
if (!token) throw new Error('BLOB_READ_WRITE_TOKEN is required');

const local = await stat(filePath);
if (!local.isFile() || local.size < 1) throw new Error('release file is missing or empty');

async function sha256(stream) {
  const hash = createHash('sha256');
  for await (const chunk of stream) hash.update(chunk);
  return hash.digest('hex');
}

const localHash = await sha256(createReadStream(filePath));
if (!verifyOnly) {
  await put(pathname, createReadStream(filePath), {
    access: 'private',
    addRandomSuffix: false,
    allowOverwrite: false,
    contentType: 'application/x-apple-diskimage',
    multipart: true,
    token,
  });
}

const metadata = await head(pathname, { token });
if (metadata.pathname !== pathname || metadata.size !== local.size) {
  throw new Error('uploaded release metadata does not match the local file');
}

const validUntil = Date.now() + 60 * 60 * 1000;
const delegation = await issueSignedToken({
  pathname, operations: ['get'], validUntil, token,
});
const { presignedUrl } = await presignUrl(delegation, {
  pathname, operation: 'get', access: 'private', validUntil,
});
const privateUrl = new URL(presignedUrl);
if (privateUrl.protocol !== 'https:' || !privateUrl.hostname.endsWith('.private.blob.vercel-storage.com')) {
  throw new Error('storage returned an unexpected private download URL');
}

function curlQuoted(value) {
  if (/\r|\n/.test(value)) throw new Error('unsafe value in download configuration');
  return `"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`;
}

const verificationDirectory = await mkdtemp(join(tmpdir(), 'yaprflow-release-verify-'));
const verificationFile = join(verificationDirectory, 'download.dmg');
const curlConfig = join(verificationDirectory, 'curl.conf');
try {
  await writeFile(curlConfig, [
    `url = ${curlQuoted(privateUrl.href)}`,
    `output = ${curlQuoted(verificationFile)}`,
    'fail', 'location', 'silent', 'show-error', 'http1.1',
    'retry = 5', 'retry-all-errors', 'continue-at = "-"', 'connect-timeout = 30',
  ].join('\n'), { mode: 0o600 });
  const curlStatus = await new Promise((resolve, reject) => {
    const curl = spawn('/usr/bin/curl', ['--config', curlConfig], {
      stdio: ['ignore', 'ignore', 'inherit'],
    });
    curl.once('error', reject);
    curl.once('close', resolve);
  });
  if (curlStatus !== 0) throw new Error(`private release verification download failed (${curlStatus})`);
  const verificationStat = await stat(verificationFile);
  if (verificationStat.size !== local.size) throw new Error('verified download size does not match');
  const uploadedHash = await sha256(createReadStream(verificationFile));
  if (uploadedHash !== localHash) throw new Error('uploaded release checksum does not match');
} finally {
  await rm(verificationDirectory, { recursive: true, force: true });
}

console.log(JSON.stringify({ pathname, size: local.size, sha256: localHash }));
