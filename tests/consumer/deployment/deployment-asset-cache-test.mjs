import test from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
process.env.MYSCOUTEE_PACKAGING_PROJECT_ROOT ??= process.cwd();
const { buildChecks } = await import('../../../verification/public/checks.mjs');

function checks(override = {}) {
  const html = `<base href="/"><meta name="myscoutee-build-id" content="test"><app-root></app-root>
    <script src="assets/diagnostics/landing.js"></script><script src="main-abc.js"></script>
    <link rel="stylesheet" href="styles-abc.css">${' '.repeat(600)}`;
  const worker = `const PRECACHE_CORE_URLS = ['/']; const PRECACHE_BUILD_URLS = ['/assets/diagnostics/landing.js', '/main-abc.js', '/styles-abc.css'];`;
  function response(value) {
    const url = new URL(value, 'https://example.test/');
    const root = url.pathname === '/';
    const text = root ? html : url.pathname === '/app-sw.js' ? worker : 'x'.repeat(100);
    return { status: 200, responseUrl: url.href, text, bytes: Buffer.from(text), headers: {
      'content-type': root ? 'text/html' : url.pathname.endsWith('.css') ? 'text/css' : 'application/javascript',
      'content-length': String(text.length),
      'cache-control': override[url.pathname] ?? (/-(?:abc)\./.test(url.pathname) ? 'public, max-age=31536000, immutable' : 'no-cache')
    }};
  }
  return buildChecks({ root: async () => response('/'), get: async u => response(u), head: async u => response(u), timeoutMs: 5000 })
    .filter(c => ['frontend/shell-assets', 'frontend/precache-assets'].includes(c.id));
}

test('shell and precache accept revalidated named scripts alongside immutable hashed bundles', async () => {
  for (const check of checks()) await check.run();
});
test('hashed bundles still require immutable caching in both checks', async () => {
  for (const check of checks({ '/main-abc.js': 'no-cache' })) await assert.rejects(check.run(), /immutable one-year/);
});
test('named scripts cannot accidentally become immutable in either check', async () => {
  for (const check of checks({ '/assets/diagnostics/landing.js': 'public, max-age=31536000, immutable' }))
    await assert.rejects(check.run(), /has no content hash and should revalidate/);
});
