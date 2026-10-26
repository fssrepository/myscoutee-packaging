import { verification } from './configuration.mjs';
import { buildProjectChecks, PROJECT_CHECK_CATALOG } from './project-checks.mjs';
// Checks for the release-packaged deployment verifier.
import {
  assert,
  expectArray,
  expectContentType,
  expectInteger,
  expectJson,
  expectObject,
  expectSameHostname,
  expectStatus,
  expectString,
  isObject,
  responseDetails
} from './lib/assertions.mjs';

export const CHECK_CATALOG = [
  ['transport/http-health', 'Nginx HTTP health exception'],
  ['transport/http-to-https', 'production HTTP to HTTPS redirect'],
  ['transport/http-host-boundary', 'forged Host cannot control the HTTPS redirect'],
  ['transport/https-policy', 'validated HTTPS entrypoint and HSTS'],
  ['frontend/shell-assets', 'Angular shell and referenced build assets'],
  ['frontend/routing', 'SPA deep link and missing-asset routing'],
  ['frontend/build-pwa', 'matching build metadata and PWA artifacts'],
  ['frontend/precache-assets', 'complete service-worker precache artifact set'],
  ['backend/health', 'Spring and dependency health'],
  ['backend/runtime-readiness', 'browser readiness endpoint and embedded shell status'],
  ['backend/public-configuration', 'public-only deployment configuration'],
  ['backend/i18n', 'seeded English translation bundle'],
  ...PROJECT_CHECK_CATALOG,
  ['security/operator-boundary', 'anonymous Operator and TLS access boundary']
];

export function buildChecks(ctx) {
  return [
    check('transport/http-health', 'Nginx HTTP health exception', async () => {
      const skipReason = httpPolicySkipReason(ctx);
      if (skipReason) {
        return skipped(skipReason);
      }
      const result = await ctx.httpProbe.get('/nginx-health', {
        redirect: 'manual',
        maxBodyBytes: 4096
      });
      expectStatus(result, 200, 'HTTP /nginx-health');
      expectContentType(result, 'text/plain', 'HTTP /nginx-health');
      assert(result.text.trim() === 'UP', 'HTTP /nginx-health should return UP', responseDetails(result));
    }),

    check('transport/http-to-https', 'production HTTP to HTTPS redirect', async () => {
      const skipReason = httpPolicySkipReason(ctx);
      if (skipReason) {
        return skipped(skipReason);
      }
      const result = await ctx.httpProbe.get('/api/health?installed-deployment-verification=1', {
        redirect: 'manual',
        maxBodyBytes: 8192
      });
      expectStatus(result, 308, 'HTTP application request');
      const location = result.headers.location;
      expectString(location, 'HTTP redirect Location');
      const redirected = new URL(location, result.requestUrl);
      const requested = new URL(result.requestUrl);
      assert(redirected.protocol === 'https:', 'HTTP redirect should upgrade to HTTPS', {
        location
      });
      expectSameHostname(requested, redirected, 'HTTP redirect');
      const effectiveApplicationOrigin = new URL((await ctx.root()).responseUrl).origin;
      assert(
        redirected.origin === effectiveApplicationOrigin,
        'HTTP redirect should target the effective HTTPS application origin',
        { redirectedOrigin: redirected.origin, effectiveApplicationOrigin }
      );
      assert(
        redirected.pathname === requested.pathname && redirected.search === requested.search,
        'HTTP redirect should preserve the application path and query',
        { requested: requested.toString(), redirected: redirected.toString() }
      );
    }),

    check('transport/http-host-boundary', 'forged Host cannot control the HTTPS redirect', async () => {
      const skipReason = httpPolicySkipReason(ctx);
      if (skipReason) {
        return skipped(skipReason);
      }
      const result = await ctx.httpProbe.get('/api/health?installed-deployment-host-check=1', {
        redirect: 'manual',
        headers: {
          Host: 'forged-host.installed-deployment.invalid'
        },
        maxBodyBytes: 8192
      });
      expectStatus(result, 308, 'HTTP request with a forged Host header');
      const location = result.headers.location;
      expectString(location, 'forged-Host redirect Location');
      const redirected = new URL(location, result.requestUrl);
      const effectiveApplicationOrigin = new URL((await ctx.root()).responseUrl).origin;
      assert(
        redirected.origin === effectiveApplicationOrigin,
        'a forged Host header must not control the HTTPS redirect target',
        {
          redirectedOrigin: redirected.origin,
          effectiveApplicationOrigin
        }
      );
    }),

    check('transport/https-policy', 'validated HTTPS entrypoint and HSTS', async () => {
      const root = await ctx.root();
      expectStatus(root, 200, 'deployment root');
      const configured = ctx.baseUrl;
      const effective = new URL(root.responseUrl);
      expectSameHostname(configured, effective, 'deployment entrypoint');
      if (!ctx.allowHttp) {
        assert(
          effective.protocol === 'https:',
          'deployment entrypoint should finish on HTTPS; use --allow-http only for local non-production checks',
          { configured: configured.toString(), effective: effective.toString() }
        );
      }
      if (effective.protocol === 'https:') {
        assertHsts(root, 'deployment root');
      }
    }),

    check('frontend/shell-assets', 'Angular shell and referenced build assets', async () => {
      const root = await ctx.root();
      assertAngularShell(root, 'deployment root');
      const references = extractBuildReferences(root.text, root.responseUrl);
      assert(references.length > 0, 'index.html should reference build assets');
      assert(references.length <= 64, 'index.html references unexpectedly many build assets', {
        count: references.length
      });
      assert(
        references.some(reference => /^main-[A-Za-z0-9_-]+\.js$/i.test(reference.basename)),
        'index.html should reference a hashed main-*.js entrypoint',
        { references: references.map(reference => reference.basename) }
      );
      assert(
        references.some(reference => /^styles-[A-Za-z0-9_-]+\.css$/i.test(reference.basename)),
        'index.html should reference a hashed styles-*.css bundle',
        { references: references.map(reference => reference.basename) }
      );

      const rootOrigin = new URL(root.responseUrl).origin;
      const assets = await Promise.all(references.map(async reference => {
        assert(
          reference.url.origin === rootOrigin,
          'index.html build assets should remain on the deployment origin',
          { asset: reference.url.toString(), rootOrigin }
        );
        const result = await ctx.get(reference.url);
        expectStatus(result, 200, reference.basename);
        assert(
          result.bytes.byteLength > 64,
          `${reference.basename} should not be empty`,
          responseDetails(result)
        );
        assert(
          !`${result.headers['content-type'] ?? ''}`.toLowerCase().includes('text/html'),
          `${reference.basename} should not be an HTML fallback`,
          responseDetails(result)
        );
        if (reference.kind === 'css') {
          expectContentType(result, 'text/css', reference.basename);
        } else {
          expectContentType(result, ['javascript', 'ecmascript'], reference.basename);
        }
        assertJavascriptOrCssCache(result, reference.url, reference.basename);
        return result;
      }));
      assert(assets.length === references.length, 'every referenced build asset should be checked');
    }),

    check('frontend/routing', 'SPA deep link and missing-asset routing', async () => {
      const [deepLink, missingAsset, root] = await Promise.all([
        ctx.get('/privacy-policy'),
        ctx.get('/main-DEPLOYMENT-SMOKE-MISSING.js', { maxBodyBytes: 16384 }),
        ctx.root()
      ]);
      assertAngularShell(deepLink, 'SPA privacy-policy deep link');
      assert(
        extractBuildId(deepLink.text) === extractBuildId(root.text),
        'SPA deep link should serve the same frontend build as /'
      );
      expectStatus(missingAsset, 404, 'missing hashed asset');
      assert(
        !missingAsset.text.includes('<app-root'),
        'missing hashed asset should not fall back to index.html',
        responseDetails(missingAsset)
      );
    }),

    check('frontend/build-pwa', 'matching build metadata and PWA artifacts', async () => {
      const nonce = Date.now().toString(36);
      const [versionResult, manifestResult, serviceWorkerResult, root] = await Promise.all([
        ctx.get(`/app-version.json?installed-deployment-verification=${nonce}`, {
          maxBodyBytes: 32768
        }),
        ctx.get('/manifest.webmanifest', { maxBodyBytes: 131072 }),
        ctx.get('/app-sw.js', { maxBodyBytes: 1024 * 1024 }),
        ctx.root()
      ]);

      expectStatus(versionResult, 200, 'app-version.json');
      expectContentType(versionResult, 'json', 'app-version.json');
      const version = expectObject(expectJson(versionResult, 'app-version.json'), 'app-version.json');
      expectString(version.version, 'app-version.json.version');
      assert(
        /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(version.version),
        'app-version.json.version should be SemVer',
        { version: version.version }
      );
      const buildId = expectString(version.buildId, 'app-version.json.buildId');
      const builtAt = expectString(version.builtAt, 'app-version.json.builtAt');
      assert(!Number.isNaN(Date.parse(builtAt)), 'app-version.json.builtAt should be an ISO timestamp', {
        builtAt
      });
      if (version.gitSha !== null) {
        assert(
          typeof version.gitSha === 'string' && /^[0-9a-f]{7,40}$/i.test(version.gitSha),
          'app-version.json.gitSha should be null or a hexadecimal Git revision',
          { gitSha: version.gitSha }
        );
      }
      assert(
        buildId === extractBuildId(root.text),
        'index.html and app-version.json should identify the same frontend build',
        { indexBuildId: extractBuildId(root.text), versionBuildId: buildId }
      );
      // The public shell can remain in bfcache; update metadata and workers cannot.
      assertFrontendEntryRevalidates(root, 'index.html', { requireNoStore: false });
      assertFrontendEntryRevalidates(versionResult, 'app-version.json');
      if (ctx.expectedVersion) {
        assert(
          version.version === ctx.expectedVersion,
          `deployed frontend version should be ${ctx.expectedVersion}, got ${version.version}`
        );
      }

      expectStatus(serviceWorkerResult, 200, 'app-sw.js');
      expectContentType(serviceWorkerResult, ['javascript', 'ecmascript'], 'app-sw.js');
      assert(serviceWorkerResult.bytes.byteLength > 512, 'app-sw.js should not be empty');
      assert(
        serviceWorkerResult.text.includes(buildId),
        'app-sw.js should be stamped with the same frontend build ID',
        { buildId }
      );
      assertFrontendEntryRevalidates(serviceWorkerResult, 'app-sw.js');

      expectStatus(manifestResult, 200, 'manifest.webmanifest');
      expectContentType(manifestResult, ['json', 'manifest'], 'manifest.webmanifest');
      const manifest = expectObject(
        expectJson(manifestResult, 'manifest.webmanifest'),
        'manifest.webmanifest'
      );
      expectString(manifest.name, 'manifest.webmanifest.name');
      const startUrl = new URL(
        expectString(manifest.start_url, 'manifest.webmanifest.start_url'),
        manifestResult.responseUrl
      );
      const scopeUrl = new URL(
        expectString(manifest.scope, 'manifest.webmanifest.scope'),
        manifestResult.responseUrl
      );
      const applicationOrigin = new URL(root.responseUrl).origin;
      assert(
        startUrl.origin === applicationOrigin && startUrl.pathname === '/',
        'manifest.webmanifest.start_url should resolve to the deployment root',
        { startUrl: startUrl.toString(), applicationOrigin }
      );
      assert(
        scopeUrl.origin === applicationOrigin && scopeUrl.pathname === '/',
        'manifest.webmanifest.scope should resolve to the deployment root',
        { scope: scopeUrl.toString(), applicationOrigin }
      );
      const icons = expectArray(manifest.icons, 'manifest.webmanifest.icons');
      assert(icons.length > 0, 'manifest.webmanifest should contain at least one icon');
      await Promise.all(icons.map(async (iconValue, index) => {
        const icon = expectObject(iconValue, `manifest.webmanifest.icons[${index}]`);
        const iconSource = expectString(
          icon.src,
          `manifest.webmanifest.icons[${index}].src`
        );
        expectString(icon.sizes, `manifest.webmanifest.icons[${index}].sizes`);
        expectString(icon.type, `manifest.webmanifest.icons[${index}].type`);
        const iconUrl = new URL(iconSource, manifestResult.responseUrl);
        assert(
          iconUrl.origin === applicationOrigin,
          'PWA icon should remain on the deployment origin',
          { iconUrl: iconUrl.toString() }
        );
        const iconResult = await ctx.get(iconUrl, { maxBodyBytes: 2 * 1024 * 1024 });
        expectStatus(iconResult, 200, `PWA icon ${index}`);
        expectContentType(iconResult, 'image/', `PWA icon ${index}`);
        assert(iconResult.bytes.byteLength > 128, `PWA icon ${index} should not be empty`);
      }));
    }),

    check('frontend/precache-assets', 'complete service-worker precache artifact set', async () => {
      const serviceWorker = await ctx.get('/app-sw.js', { maxBodyBytes: 1024 * 1024 });
      expectStatus(serviceWorker, 200, 'app-sw.js');
      expectContentType(serviceWorker, ['javascript', 'ecmascript'], 'app-sw.js');
      const coreUrls = extractPrecacheUrls(serviceWorker.text, 'PRECACHE_CORE_URLS');
      const buildUrls = extractPrecacheUrls(serviceWorker.text, 'PRECACHE_BUILD_URLS');
      assert(coreUrls.length > 0, 'app-sw.js should declare core precache assets');
      assert(buildUrls.length > 0, 'app-sw.js should declare build precache assets');

      const applicationOrigin = new URL(serviceWorker.responseUrl).origin;
      const references = new Map();
      for (const [listName, values] of [
        ['PRECACHE_CORE_URLS', coreUrls],
        ['PRECACHE_BUILD_URLS', buildUrls]
      ]) {
        for (const [index, value] of values.entries()) {
          expectString(value, `${listName}[${index}]`);
          const url = new URL(value, serviceWorker.responseUrl);
          assert(
            url.origin === applicationOrigin,
            `${listName}[${index}] should remain on the deployment origin`,
            { url: url.toString(), applicationOrigin }
          );
          references.set(url.toString(), {
            url,
            build: listName === 'PRECACHE_BUILD_URLS'
          });
        }
      }
      assert(
        references.size <= 512,
        'app-sw.js references unexpectedly many precache assets',
        { count: references.size }
      );

      await mapWithConcurrency([...references.values()], 12, async (reference, remainingMs) => {
        const result = await ctx.head(reference.url, {
          headers: { 'Accept-Encoding': 'identity' },
          maxBodyBytes: 4096,
          timeoutMs: Math.max(250, Math.min(ctx.timeoutMs, remainingMs))
        });
        const label = reference.url.pathname || '/';
        expectStatus(result, 200, `precache ${label}`);
        assertPrecacheContentType(result, reference.url, label);
        const contentLength = result.headers['content-length'];
        if (!reference.build && contentLength !== undefined) {
          assert(
            Number(contentLength) > 0,
            `precache ${label} should not be empty`,
            { contentLength }
          );
        }
        if (
          reference.build
          && /\.(?:js|css)$/i.test(reference.url.pathname)
        ) {
          assertJavascriptOrCssCache(result, reference.url, `precache ${label}`);
        }
      }, {
        maxMs: Math.max(5000, Math.min(15000, ctx.timeoutMs * 2)),
        label: 'service-worker precache verification'
      });
    }),

    check('backend/health', 'Spring and dependency health', async () => {
      const result = await ctx.get('/api/health', { maxBodyBytes: 32768 });
      expectStatus(result, 200, 'Spring health');
      expectContentType(result, 'json', 'Spring health');
      const health = expectObject(expectJson(result, 'Spring health'), 'Spring health');
      assert(health.status === 'UP', 'Spring health status should be exactly UP', health);
      if (new URL(result.responseUrl).protocol === 'https:') {
        assertHsts(result, 'Spring health');
      }
      assertHeaderEquals(result, 'x-content-type-options', 'nosniff', 'Spring health');
      assertHeaderEquals(result, 'x-frame-options', 'DENY', 'Spring health');
      assertHeaderIncludes(
        result,
        'referrer-policy',
        'strict-origin-when-cross-origin',
        'Spring health'
      );
    }),

    check('backend/runtime-readiness', 'browser readiness endpoint and embedded shell status', async () => {
      const [result, shell] = await Promise.all([
        ctx.get('/api/runtime-status', { maxBodyBytes: 8192 }), ctx.root()
      ]);
      expectStatus(result, 200, 'browser runtime status');
      expectContentType(result, 'json', 'browser runtime status');
      const status = expectObject(expectJson(result, 'browser runtime status'), 'browser runtime status');
      assert(status.known === true && status.ready === true,
        'browser runtime status must be known and ready', status);
      const embedded = shell.text.match(/<script\b[^>]*\bid=["']myscoutee-runtime-status["'][^>]*>([\s\S]*?)<\/script>/i);
      assert(embedded, 'frontend shell must embed browser runtime status');
      let bootstrap;
      try { bootstrap = JSON.parse(embedded[1]); } catch { assert(false, 'embedded runtime status must be valid JSON'); }
      assert(bootstrap?.known === true && bootstrap?.ready === true,
        'embedded browser runtime status must be known and ready', bootstrap);
    }),

    check('backend/public-configuration', 'public-only deployment configuration', async () => {
      const result = await ctx.get('/api/deployment/configuration', {
        maxBodyBytes: 256 * 1024
      });
      expectStatus(result, 200, 'public deployment configuration');
      expectContentType(result, 'json', 'public deployment configuration');
      const configuration = expectObject(
        expectJson(result, 'public deployment configuration'),
        'public deployment configuration'
      );
      expectString(configuration.productName, 'public configuration.productName');
      assert(
        configuration.logoCharacterIndex === null
          || Number.isInteger(configuration.logoCharacterIndex),
        'public configuration.logoCharacterIndex should be null or an integer',
        { value: configuration.logoCharacterIndex }
      );
      expectString(configuration.homeLabel, 'public configuration.homeLabel');
      expectString(configuration.logoUrl, 'public configuration.logoUrl', { allowEmpty: true });
      assert(typeof configuration.firebaseMessagingConfigured === 'boolean',
        'public configuration.firebaseMessagingConfigured should be boolean');
      expectInteger(configuration.revision, 'public configuration.revision', { min: 0 });
      expectArray(configuration.socialLinks, 'public configuration.socialLinks');
      const privacyContact = expectObject(
        configuration.privacyContact,
        'public configuration.privacyContact'
      );
      assert(
        typeof privacyContact.configured === 'boolean',
        'public configuration.privacyContact.configured should be boolean'
      );
      expectString(
        privacyContact.dataControllerName,
        'public configuration.privacyContact.dataControllerName',
        { allowEmpty: true }
      );
      expectString(
        privacyContact.privacyContactEmail,
        'public configuration.privacyContact.privacyContactEmail',
        { allowEmpty: true }
      );
      assertNoSensitiveConfiguration(configuration);
      assert(
        !/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/.test(result.text),
        'public deployment configuration should not contain a private key'
      );

      if (configuration.logoUrl.trim()) {
        const logoUrl = new URL(
          configuration.logoUrl,
          new URL('/', result.responseUrl)
        );
        if (logoUrl.origin === new URL(result.responseUrl).origin) {
          const logo = await ctx.get(logoUrl, { maxBodyBytes: 4 * 1024 * 1024 });
          expectStatus(logo, 200, 'deployment logo');
          expectContentType(logo, 'image/', 'deployment logo');
          assert(logo.bytes.byteLength > 64, 'deployment logo should not be empty');
        }
      }
    }),

    check('backend/i18n', 'seeded English translation bundle', async () => {
      const result = await ctx.get('/api/i18n/bundle?lang=en', {
        maxBodyBytes: 4 * 1024 * 1024
      });
      expectStatus(result, 200, 'English i18n bundle');
      expectContentType(result, 'json', 'English i18n bundle');
      const bundle = expectObject(expectJson(result, 'English i18n bundle'), 'English i18n bundle');
      assert(bundle.lang === 'en', 'English i18n bundle should resolve lang=en', {
        lang: bundle.lang
      });
      expectString(bundle.version, 'English i18n bundle.version');
      const data = expectObject(bundle.data, 'English i18n bundle.data');
      assert(
        Object.keys(data).length > 10,
        'English i18n bundle should contain packaged translations',
        { keyCount: Object.keys(data).length }
      );
      assertHeaderIncludes(result, 'cache-control', 'no-store', 'English i18n bundle');
    }),

    ...buildProjectChecks(ctx),

    check('security/operator-boundary', 'anonymous Operator and TLS access boundary', async () => {
      const [configuration, tls] = await Promise.all([
        ctx.get('/api/operator/configuration', { maxBodyBytes: 65536 }),
        ctx.get('/api/operator/configuration/tls', { maxBodyBytes: 65536 })
      ]);
      expectStatus(configuration, 401, 'anonymous Operator configuration');
      expectStatus(tls, 401, 'anonymous Operator TLS configuration');
      for (const result of [configuration, tls]) {
        assert(
          !/credentialMask|privateKey|certificatePem|masterKey|adminEmails/i.test(result.text),
          'anonymous Operator rejection should not expose configuration data',
          responseDetails(result)
        );
      }
    })
  ];
}

function check(id, name, run) {
  return { id, name, run };
}

function skipped(reason) {
  return { skipped: reason };
}

function httpPolicySkipReason(ctx) {
  if (ctx.allowHttp) {
    return 'production transport policy disabled by explicit --allow-http';
  }
  if (!ctx.httpProbe) {
    return 'HTTP listener is unknown for a custom HTTPS port; pass --http-url to check it';
  }
  return '';
}

function assertAngularShell(result, label) {
  expectStatus(result, 200, label);
  expectContentType(result, 'text/html', label);
  assert(result.bytes.byteLength > 512, `${label} should not be an empty HTML page`);
  assert(/<base\s+href=["']\/["']/i.test(result.text), `${label} should use the production root base href`);
  assert(/<app-root(?:\s|>)/i.test(result.text), `${label} should contain the Angular app root`);
  extractBuildId(result.text);
}

function extractBuildId(html) {
  const match = html.match(
    /<meta\s+[^>]*name=["']myscoutee-build-id["'][^>]*content=["']([^"']+)["'][^>]*>/i
  ) ?? html.match(
    /<meta\s+[^>]*content=["']([^"']+)["'][^>]*name=["']myscoutee-build-id["'][^>]*>/i
  );
  assert(match?.[1]?.trim(), 'index.html should contain a non-empty myscoutee-build-id');
  return match[1].trim();
}

function extractBuildReferences(html, responseUrl) {
  const result = new Map();
  const tags = html.match(/<(?:script|link)\b[^>]*>/gi) ?? [];
  for (const tag of tags) {
    const isScript = /^<script\b/i.test(tag);
    const relation = attribute(tag, 'rel').toLowerCase().split(/\s+/);
    if (!isScript && !relation.includes('stylesheet') && !relation.includes('modulepreload')) {
      continue;
    }
    const value = attribute(tag, isScript ? 'src' : 'href');
    if (!value || !/\.(?:js|css)(?:[?#].*)?$/i.test(value)) {
      continue;
    }
    const url = new URL(value, responseUrl);
    const basename = url.pathname.split('/').pop() ?? '';
    result.set(url.toString(), {
      url,
      basename,
      kind: /\.css$/i.test(url.pathname) ? 'css' : 'js'
    });
  }
  return [...result.values()];
}

function extractPrecacheUrls(source, variableName) {
  const match = source.match(
    new RegExp(`const\\s+${variableName}\\s*=\\s*(\\[[\\s\\S]*?\\]);`)
  );
  assert(match?.[1], `app-sw.js should declare ${variableName}`);
  return parseJavaScriptStringArray(match[1], `app-sw.js ${variableName}`);
}

function parseJavaScriptStringArray(source, label) {
  const values = [];
  let index = 0;
  skipWhitespace();
  assert(source[index] === '[', `${label} should start with [`);
  index += 1;

  while (true) {
    skipWhitespace();
    if (source[index] === ']') {
      index += 1;
      break;
    }
    if (values.length > 0) {
      assert(source[index] === ',', `${label} should contain only string entries`);
      index += 1;
      skipWhitespace();
    }

    const quote = source[index];
    assert(quote === '"' || quote === "'", `${label} should contain only string literals`);
    index += 1;
    let value = '';
    let closed = false;
    while (index < source.length) {
      const character = source[index++];
      if (character === quote) {
        closed = true;
        break;
      }
      if (character !== '\\') {
        value += character;
        continue;
      }
      assert(index < source.length, `${label} contains an incomplete escape`);
      value += decodeJavaScriptEscape(source, () => index, next => {
        index = next;
      });
    }
    assert(closed, `${label} contains an unterminated string literal`);
    values.push(value);
  }

  skipWhitespace();
  assert(index === source.length, `${label} should contain only an array literal`);
  return values;

  function skipWhitespace() {
    while (index < source.length && /\s/.test(source[index])) {
      index += 1;
    }
  }
}

function decodeJavaScriptEscape(source, getIndex, setIndex) {
  let index = getIndex();
  const escaped = source[index++];
  const simple = {
    b: '\b',
    f: '\f',
    n: '\n',
    r: '\r',
    t: '\t',
    v: '\v',
    '0': '\0'
  };
  if (Object.prototype.hasOwnProperty.call(simple, escaped)) {
    setIndex(index);
    return simple[escaped];
  }
  if (escaped === 'x' || escaped === 'u') {
    const length = escaped === 'x' ? 2 : 4;
    const digits = source.slice(index, index + length);
    assert(
      new RegExp(`^[0-9a-fA-F]{${length}}$`).test(digits),
      'service-worker precache URL contains an invalid hexadecimal escape'
    );
    setIndex(index + length);
    return String.fromCharCode(Number.parseInt(digits, 16));
  }
  setIndex(index);
  return escaped;
}

function attribute(tag, name) {
  const match = tag.match(new RegExp(`\\b${name}\\s*=\\s*["']([^"']*)["']`, 'i'));
  return match?.[1]?.trim() ?? '';
}

function assertPrecacheContentType(result, url, label) {
  const pathname = url.pathname.toLowerCase();
  if (pathname === '/' || pathname.endsWith('.html')) {
    expectContentType(result, 'text/html', `precache ${label}`);
    return;
  }
  if (pathname.endsWith('.js')) {
    expectContentType(result, ['javascript', 'ecmascript'], `precache ${label}`);
    return;
  }
  if (pathname.endsWith('.css')) {
    expectContentType(result, 'text/css', `precache ${label}`);
    return;
  }
  if (pathname.endsWith('.json')) {
    expectContentType(result, 'json', `precache ${label}`);
    return;
  }
  if (pathname.endsWith('.webmanifest')) {
    expectContentType(result, ['json', 'manifest'], `precache ${label}`);
    return;
  }
  if (/\.(?:ico|png|webp|svg)$/.test(pathname)) {
    expectContentType(result, 'image/', `precache ${label}`);
    return;
  }
  const contentType = `${result.headers['content-type'] ?? ''}`.toLowerCase();
  assert(
    !contentType.includes('text/html'),
    `precache ${label} should not be an HTML fallback`,
    responseDetails(result)
  );
}

function assertJavascriptOrCssCache(result, url, label) {
  if (verification.assetCache === 'immutable') {
    assertImmutableAsset(result, label);
    return;
  }
  if (/^\/.+-[A-Za-z0-9_-]+\.(?:js|css)$/i.test(url.pathname)) {
    assertImmutableAsset(result, label);
    return;
  }
  const cacheControl = `${result.headers['cache-control'] ?? ''}`.toLowerCase();
  assert(cacheControl.includes('no-cache') && !cacheControl.includes('immutable'),
    `${label} has no content hash and should revalidate instead of using immutable caching`, { cacheControl });
}

function assertImmutableAsset(result, label) {
  const cacheControl = `${result.headers['cache-control'] ?? ''}`.toLowerCase();
  assert(
    cacheControl.includes('max-age=31536000') && cacheControl.includes('immutable'),
    `${label} should use the immutable one-year build-asset cache policy`,
    { cacheControl }
  );
}

function assertFrontendEntryRevalidates(result, label, { requireNoStore = true } = {}) {
  const cacheControl = `${result.headers['cache-control'] ?? ''}`.toLowerCase();
  assert(
    cacheControl.includes('no-cache') && !cacheControl.includes('immutable')
      && (!requireNoStore || (cacheControl.includes('no-store') && cacheControl.includes('must-revalidate'))),
    `${label} should always revalidate and must never use immutable caching`,
    { cacheControl }
  );
}

function assertHsts(result, label) {
  const value = `${result.headers['strict-transport-security'] ?? ''}`;
  const maxAge = value.match(/(?:^|[;,\s])max-age\s*=\s*(\d+)/i);
  assert(maxAge, `${label} should include Strict-Transport-Security`, {
    strictTransportSecurity: value
  });
  assert(
    Number(maxAge[1]) >= 31536000,
    `${label} HSTS max-age should be at least one year`,
    { strictTransportSecurity: value }
  );
}

function assertHeaderEquals(result, name, expected, label) {
  const value = `${result.headers[name] ?? ''}`;
  assert(
    value.toLowerCase() === expected.toLowerCase(),
    `${label} should include ${name}: ${expected}`,
    { [name]: value }
  );
}

function assertHeaderIncludes(result, name, expected, label) {
  const value = `${result.headers[name] ?? ''}`;
  assert(
    value.toLowerCase().includes(expected.toLowerCase()),
    `${label} should include ${name} containing ${expected}`,
    { [name]: value }
  );
}

function assertNoSensitiveConfiguration(value, path = 'public configuration') {
  const forbiddenTopLevel = new Set([
    'capability',
    'unavailableReason',
    'adminEmails',
    'payment',
    'firebase',
    'updatedAt'
  ]);
  const forbiddenKey = /(password|secret|credential|private.?key|master.?key|service.?account|certificate)/i;

  if (Array.isArray(value)) {
    value.forEach((entry, index) => assertNoSensitiveConfiguration(entry, `${path}[${index}]`));
    return;
  }
  if (!isObject(value)) {
    return;
  }
  for (const [key, entry] of Object.entries(value)) {
    assert(
      !forbiddenTopLevel.has(key) && !forbiddenKey.test(key),
      `${path} exposed forbidden field ${key}`
    );
    assertNoSensitiveConfiguration(entry, `${path}.${key}`);
  }
}

async function mapWithConcurrency(values, concurrency, worker, options) {
  const startedAt = performance.now();
  let nextIndex = 0;
  let firstError = null;

  const workers = Array.from(
    { length: Math.min(concurrency, values.length) },
    async () => {
      while (!firstError) {
        const index = nextIndex++;
        if (index >= values.length) {
          return;
        }
        const remainingMs = options.maxMs - (performance.now() - startedAt);
        if (remainingMs < 250) {
          firstError = new Error(
            `${options.label} exceeded its ${options.maxMs}ms total timeout`
          );
          return;
        }
        try {
          await worker(values[index], remainingMs);
        } catch (error) {
          firstError ??= error;
          return;
        }
      }
    }
  );
  await Promise.all(workers);
  if (firstError) {
    throw firstError;
  }
}
