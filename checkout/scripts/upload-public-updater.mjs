import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createReadStream } from 'node:fs';
import { mkdtemp, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { put } from '@vercel/blob';

const [filePath, version] = process.argv.slice(2);
const token = process.env.BLOB_READ_WRITE_TOKEN?.trim();

if (!filePath || !/^\d+\.\d+\.\d+$/.test(version || '')) {
  throw new Error('usage: node scripts/upload-public-updater.mjs path/to/yaprflow-X.Y.Z.dmg X.Y.Z');
}
if (basename(filePath) !== `yaprflow-${version}.dmg`) {
  throw new Error('the archive filename must match the release version');
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
const pathname = `updates/${version}/${localHash.slice(0, 20)}/yaprflow-${version}.dmg`;
const blob = await put(pathname, createReadStream(filePath), {
  access: 'public',
  addRandomSuffix: true,
  allowOverwrite: false,
  contentType: 'application/x-apple-diskimage',
  multipart: true,
  token,
});

const publicUrl = new URL(blob.url);
const expectedPath = new RegExp(
  `^/updates/${version.replaceAll('.', '\\.')}/${localHash.slice(0, 20)}/` +
  `yaprflow-${version.replaceAll('.', '\\.')}-[A-Za-z0-9]+\\.dmg$`,
);
if (publicUrl.protocol !== 'https:' ||
    !publicUrl.hostname.endsWith('.public.blob.vercel-storage.com') ||
    !expectedPath.test(publicUrl.pathname)) {
  throw new Error('storage returned an unexpected public updater URL');
}

function curlQuoted(value) {
  if (/\r|\n/.test(value)) throw new Error('unsafe download value');
  return `"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`;
}

const verificationDirectory = await mkdtemp(join(tmpdir(), 'yaprflow-updater-verify-'));
const verificationFile = join(verificationDirectory, 'download.dmg');
const curlConfig = join(verificationDirectory, 'curl.conf');
try {
  await writeFile(curlConfig, [
    `url = ${curlQuoted(publicUrl.href)}`,
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
  if (curlStatus !== 0) throw new Error(`public updater verification download failed (${curlStatus})`);
  const verificationStat = await stat(verificationFile);
  if (verificationStat.size !== local.size) throw new Error('verified updater size does not match');
  const uploadedHash = await sha256(createReadStream(verificationFile));
  if (uploadedHash !== localHash) throw new Error('verified updater checksum does not match');
} finally {
  await rm(verificationDirectory, { recursive: true, force: true });
}

console.log(JSON.stringify({
  url: publicUrl.href,
  pathname: blob.pathname,
  size: local.size,
  sha256: localHash,
}));
