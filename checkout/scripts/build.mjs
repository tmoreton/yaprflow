import { cp, mkdir, rm, lstat, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { extname } from 'node:path';

const root = new URL('../', import.meta.url);
const output = new URL('public/', root);
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
// Explicit allowlist: never publish source, credentials, or private installers.
export const publicFiles = [
  'index.html', 'confirmation.html', 'confirmation.js', 'checkout.js',
  'analytics.js', 'meta-pixel.js', 'analytics.css', 'styles.css', 'assets', 'policies', 'support.html', 'robots.txt', 'sitemap.xml',
];
async function validateDirectory(url) {
  for (const entry of await readdir(url)) {
    const child = new URL(entry, url);
    const info = await lstat(child);
    if (entry.startsWith('.') || info.isSymbolicLink()) throw new Error(`Unexpected public asset: ${entry}`);
    if (info.isDirectory()) await validateDirectory(new URL(entry + '/', url));
    else if (!['.html', '.svg', '.png', '.jpg', '.mp4'].includes(extname(entry))) {
      throw new Error(`Unexpected public file: ${entry}`);
    }
  }
}
for (const name of publicFiles) {
  const source = new URL(name, root);
  const info = await lstat(source);
  if (info.isSymbolicLink()) throw new Error(`Unexpected public symlink: ${name}`);
  if (info.isDirectory()) await validateDirectory(new URL(name + '/', root));
  await cp(new URL(name, root), new URL(name, output), { recursive: true });
}
console.log(`Built public website in ${fileURLToPath(output)}`);
