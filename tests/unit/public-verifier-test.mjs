import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const fixture = mkdtempSync(join(tmpdir(), 'public-verifier-'));
mkdirSync(join(fixture, 'config/packaging'), { recursive: true });
writeFileSync(join(fixture, 'config/packaging/verification.json'), JSON.stringify({
  schemaVersion: 1, assetCache: 'hashed', publicContent: 'landing'
}));
process.env.MYSCOUTEE_PACKAGING_PROJECT_ROOT = fixture;
const { buildChecks } = await import('../../verification/public/checks.mjs');
after(() => rmSync(fixture, { recursive: true, force: true }));

const buildId = 'abc1234-20261025140403';
const strictCache = 'no-cache, no-store, must-revalidate';

function check(id, overrides = {}) {
  const fixtures = {
    '/': {
      text: `<base href="/"><meta name="myscoutee-build-id" content="${buildId}"><script id="myscoutee-runtime-status" type="application/json">{"known":true,"ready":true}</script><app-root></app-root>${' '.repeat(600)}`,
      type: 'text/html', cache: 'no-cache'
    },
    '/app-version.json': {
      text: JSON.stringify({ version: '1.5.0', buildId, builtAt: '2026-10-25T14:04:03Z', gitSha: 'abc1234' }),
      type: 'application/json', cache: strictCache
    },
    '/app-sw.js': {
      text: `const BUILD_ID = '${buildId}';${' '.repeat(600)}`,
      type: 'application/javascript', cache: strictCache
    },
    '/manifest.webmanifest': {
      text: JSON.stringify({ name: 'Test application', start_url: './', scope: './',
        icons: [{ src: 'icon.webp', sizes: '192x192', type: 'image/webp' }] }),
      type: 'application/manifest+json', cache: 'no-cache'
    },
    '/icon.webp': { text: 'x'.repeat(256), type: 'image/webp', cache: 'public, max-age=2592000' },
    '/api/runtime-status': { text: '{"known":true,"ready":true}', type: 'application/json' },
    '/api/operator/configuration': { status: 401, text: 'Unauthorized', type: 'text/plain' },
    '/api/operator/configuration/tls': { status: 401, text: 'Unauthorized', type: 'text/plain' }
  };
  async function get(value) {
    const url = new URL(value, 'https://example.test/');
    assert.ok(fixtures[url.pathname], `Unexpected request: ${url.pathname}`);
    const fixture = { ...fixtures[url.pathname], ...overrides[url.pathname] };
    return { status: fixture.status ?? 200, responseUrl: url.href,
      text: fixture.text, bytes: Buffer.from(fixture.text),
      data: fixture.type.includes('json') ? JSON.parse(fixture.text) : undefined,
      jsonError: null,
      headers: { 'content-type': fixture.type, 'cache-control': fixture.cache ?? 'no-store' } };
  }
  return buildChecks({ get, root: () => get('/'), expectedVersion: '1.5.0', timeoutMs: 5000 })
    .find(candidate => candidate.id === id);
}

test('PWA verification accepts the revalidated shell and strictly uncached update files', async () => {
  await check('frontend/build-pwa').run();
});

for (const cache of ['public, max-age=3600', 'no-cache, immutable']) {
  test(`PWA verification rejects an unsafe shell cache: ${cache}`, async () => {
    await assert.rejects(check('frontend/build-pwa', { '/': { cache } }).run(), /index.html should always revalidate/);
  });
}

for (const path of ['/app-version.json', '/app-sw.js']) {
  test(`PWA verification still requires no-store and must-revalidate for ${path}`, async () => {
    for (const cache of ['no-cache', 'no-cache, no-store', 'no-cache, must-revalidate', `${strictCache}, immutable`]) {
      await assert.rejects(check('frontend/build-pwa', { [path]: { cache } }).run(), /should always revalidate/);
    }
  });
}

test('PWA verification still rejects mismatched service-worker builds', async () => {
  await assert.rejects(check('frontend/build-pwa', {
    '/app-sw.js': { text: `const BUILD_ID = 'outdated';${' '.repeat(600)}` }
  }).run(), /same frontend build ID/);
});

test('anonymous Operator configuration and TLS endpoints require HTTP 401', async () => {
  await check('security/operator-boundary').run();
});

for (const path of ['/api/operator/configuration', '/api/operator/configuration/tls']) {
  test(`Operator verification rejects HTTP 200 and the obsolete 403 response at ${path}`, async () => {
    for (const status of [200, 403]) {
      await assert.rejects(check('security/operator-boundary', { [path]: { status } }).run(), /expected HTTP 401/);
    }
  });
  test(`Operator verification rejects sensitive data even with HTTP 401 at ${path}`, async () => {
    await assert.rejects(check('security/operator-boundary', {
      [path]: { text: '{"privateKey":"must-not-be-public"}' }
    }).run(), /should not expose configuration data/);
  });
}


test('runtime readiness requires both the public endpoint and the initial browser snapshot', async () => {
  await check('backend/runtime-readiness').run();
  for (const status of [{ known: true, ready: false }, { known: false, ready: true }]) {
    await assert.rejects(check('backend/runtime-readiness', {
      '/api/runtime-status': { text: JSON.stringify(status) }
    }).run(), /must be known and ready/);
    await assert.rejects(check('backend/runtime-readiness', {
      '/': { text: `<script id="myscoutee-runtime-status">${JSON.stringify(status)}</script>` }
    }).run(), /must be known and ready/);
  }
  for (const text of ['<html></html>', '<script id="myscoutee-runtime-status">invalid</script>']) {
    await assert.rejects(check('backend/runtime-readiness', { '/': { text } }).run(), /runtime status/);
  }
});
