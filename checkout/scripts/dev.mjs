import { createServer } from 'node:http';
import { createReadStream } from 'node:fs';
import { stat, realpath } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, extname, sep } from 'node:path';
import sessionHandler from '../api/session.mjs';

const root = resolve(fileURLToPath(new URL('../', import.meta.url)));
const port = Number(process.env.PORT || 4173);
const host = '127.0.0.1';
process.env.NODE_ENV ||= 'development';
process.env.CHECKOUT_BASE_URL ||= `http://${host}:${port}`;
const routes = {
  '/api/config': ['GET', () => import('../api/config.js')],
  '/api/checkout': ['POST', () => import('../api/checkout.js')],
  '/api/complete': ['GET', () => import('../api/complete.js')],
  '/api/status': ['GET', () => import('../api/status.js')],
  '/api/download': ['GET', () => import('../api/download.js')],
};
const publicPages = new Set([
  'index.html', 'confirmation.html', 'confirmation.js', 'checkout.js',
  'analytics.js', 'meta-pixel.js', 'analytics.css', 'styles.css', 'support.html', 'robots.txt', 'sitemap.xml',
]);
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png',
  '.jpg': 'image/jpeg', '.mp4': 'video/mp4', '.txt': 'text/plain', '.xml': 'application/xml' };

function finish(response, status, body = '') {
  response.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' });
  response.end(body);
}

export const server = createServer(async (request, response) => {
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('Referrer-Policy', 'no-referrer');
  try {
    const url = new URL(request.url, `http://${host}:${port}`);
    if (url.pathname === '/confirmation.html' && url.searchParams.has('session_id')) {
      response.writeHead(303, { Location: `/api/complete${url.search}`, 'Cache-Control': 'private, no-store' });
      return response.end();
    }
    if (url.pathname === '/api/session') return await sessionHandler(request, response);
    const route = routes[url.pathname];
    if (route) {
      const [method, load] = route;
      if (request.method !== method) {
        response.setHeader('Allow', method);
        return finish(response, 405, 'Method not allowed.');
      }
      const handler = (await load())[method];
      const result = await handler(new Request(url, { method, headers: request.headers }));
      response.writeHead(result.status, Object.fromEntries(result.headers));
      return response.end(Buffer.from(await result.arrayBuffer()));
    }
    if (url.pathname === '/privacy.html') {
      response.writeHead(302, { Location: '/policies/#privacy' });
      return response.end();
    }
    if (!['GET', 'HEAD'].includes(request.method)) return finish(response, 405, 'Method not allowed.');
    let pathname = decodeURIComponent(url.pathname).replace(/^\/+/, '');
    if (pathname.includes('\\') || pathname.split('/').some((part) => part === '..' || part === '.' || part.startsWith('.'))) {
      return finish(response, 404, 'Not found.');
    }
    if (!pathname) pathname = 'index.html';
    if (pathname === 'policies' || pathname === 'policies/') pathname = 'policies/index.html';
    const filename = resolve(root, pathname);
    if (!filename.startsWith(root + sep) ||
        (!publicPages.has(pathname) && !pathname.startsWith('assets/') && pathname !== 'policies/index.html')) {
      return finish(response, 404, 'Not found.');
    }
    if (await realpath(filename) !== filename ||
        (pathname.startsWith('assets/') && !['.svg', '.png', '.jpg', '.mp4'].includes(extname(filename)))) {
      return finish(response, 404, 'Not found.');
    }
    const { size } = await stat(filename);
    let start = 0;
    let end = size - 1;
    const range = request.headers.range;
    if (range) {
      const match = /^bytes=(\d*)-(\d*)$/.exec(range);
      if (match && (match[1] || match[2])) {
        start = match[1] ? Number(match[1]) : Math.max(0, size - Number(match[2]));
        end = match[1] && match[2] ? Math.min(Number(match[2]), end) : end;
      } else start = -1;
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || start > end || start >= size) {
        response.setHeader('Content-Range', `bytes */${size}`);
        return finish(response, 416);
      }
    }
    response.writeHead(range ? 206 : 200, {
      'Content-Type': types[extname(filename)] || 'application/octet-stream',
      'Content-Length': end - start + 1,
      'Accept-Ranges': 'bytes',
      'Cache-Control': pathname === 'confirmation.html' ? 'private, no-store' : 'no-cache',
      ...(range ? { 'Content-Range': `bytes ${start}-${end}/${size}` } : {}),
    });
    if (request.method === 'HEAD') return response.end();
    const stream = createReadStream(filename, { start, end });
    stream.on('error', () => response.destroy());
    response.on('close', () => stream.destroy());
    stream.pipe(response);
  } catch (error) {
    if (!response.headersSent) finish(response, error.code === 'ENOENT' ? 404 : 500, 'This request could not be completed.');
    else response.destroy();
  }
});
server.listen(port, host, () => console.log(`Yaprflow website: http://${host}:${port}`));
