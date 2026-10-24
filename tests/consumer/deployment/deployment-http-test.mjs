import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { createHttpClient } from '../../../verification/public/lib/http.mjs';

async function fixture(t, handler) {
  const server = http.createServer(handler);
  let connections = 0;
  server.on('connection', () => connections++);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => { server.closeAllConnections(); server.close(); });
  return { client: createHttpClient({ baseUrl: `http://127.0.0.1:${server.address().port}`, timeoutMs: 300 }), connections: () => connections };
}

test('repeated HEAD probes reuse a connection and retain response metadata', async t => {
  const f = await fixture(t, (req, res) => {
    assert.equal(req.method, 'HEAD');
    res.writeHead(200, { 'Content-Type': 'application/javascript', 'Content-Length': '125', 'Cache-Control': 'public, immutable' });
    res.end();
  });
  for (let i = 0; i < 24; i++) {
    const result = await f.client.head(`/chunk-${i}.js`);
    assert.equal(result.status, 200);
    assert.equal(result.headers['content-length'], '125');
    assert.equal(result.headers['cache-control'], 'public, immutable');
    assert.equal(result.bytes.length, 0);
  }
  assert.equal(f.connections(), 1, 'HEAD asset probes must not create a TLS connection per file');
});

test('HEAD redirects preserve the method, final URL and existing origin guard', async t => {
  const f = await fixture(t, (req, res) => {
    assert.equal(req.method, 'HEAD');
    if (req.url === '/redirect') res.writeHead(302, { Location: '/asset.js' });
    else if (req.url === '/outside') res.writeHead(302, { Location: 'http://example.invalid/asset.js' });
    else res.writeHead(200, { 'Content-Type': 'application/javascript' });
    res.end();
  });
  const result = await f.client.head('/redirect');
  assert.equal(result.status, 200);
  assert.equal(result.redirected, true);
  assert.ok(result.responseUrl.endsWith('/asset.js'));
  assert.equal(result.redirects.length, 1);
  const manual = await f.client.head('/redirect', { redirect: 'manual' });
  assert.equal(manual.status, 302);
  await assert.rejects(f.client.head('/outside'), /refused a cross-host redirect/);
});

test('HEAD timeouts and missing assets remain observable without retries', async t => {
  let hangingRequests = 0;
  const f = await fixture(t, (req, res) => {
    if (req.url === '/hang') { hangingRequests++; return; }
    res.writeHead(404); res.end();
  });
  assert.equal((await f.client.head('/missing.js')).status, 404);
  await assert.rejects(f.client.head('/hang'), /timed out after 300 ms/);
  assert.equal(hangingRequests, 1);
});
