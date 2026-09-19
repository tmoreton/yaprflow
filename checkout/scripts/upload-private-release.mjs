import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { Readable } from 'node:stream';
import { get, head, put } from '@vercel/blob';

const [filePath, pathname] = process.argv.slice(2);
const token = process.env.BLOB_READ_WRITE_TOKEN?.trim();

if (!filePath || !/^releases\/yaprflow-[0-9]+\.[0-9]+\.[0-9]+\.dmg$/.test(pathname || '')) {
  throw new Error('usage: node scripts/upload-private-release.mjs path/to/yaprflow-X.Y.Z.dmg releases/yaprflow-X.Y.Z.dmg');
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
await put(pathname, createReadStream(filePath), {
  access: 'private',
  addRandomSuffix: false,
  allowOverwrite: false,
  contentType: 'application/x-apple-diskimage',
  multipart: true,
  token,
});

const metadata = await head(pathname, { token });
if (metadata.pathname !== pathname || metadata.size !== local.size) {
  throw new Error('uploaded release metadata does not match the local file');
}

const downloaded = await get(pathname, { access: 'private', useCache: false, token });
if (!downloaded || downloaded.statusCode !== 200 || !downloaded.stream) {
  throw new Error('uploaded release could not be downloaded for verification');
}
const uploadedHash = await sha256(Readable.fromWeb(downloaded.stream));
if (uploadedHash !== localHash) throw new Error('uploaded release checksum does not match');

console.log(JSON.stringify({ pathname, size: local.size, sha256: localHash }));
