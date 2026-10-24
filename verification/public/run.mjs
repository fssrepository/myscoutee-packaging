#!/usr/bin/env node
// MANUAL ONLY: this runner is intentionally not registered in E2E, packaging,
// post-install, CI, or aggregate test commands.

import { buildChecks, CHECK_CATALOG } from './checks.mjs';
import { compactSnippet } from './lib/assertions.mjs';
import { createHttpClient, parseRootUrl, SmokeRequestError } from './lib/http.mjs';

const EXIT_FAILURE = 1;
const EXIT_USAGE = 2;

await main();

async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (error) {
    printUsageError(error);
    return;
  }

  if (options.help) {
    printHelp();
    return;
  }
  if (options.list) {
    for (const [id, name] of CHECK_CATALOG) {
      console.log(`${id.padEnd(38)} ${name}`);
    }
    return;
  }
  if (!options.url) {
    printUsageError(new Error(
      'A deployment URL is required. This manual suite does not choose or start a target automatically.'
    ));
    return;
  }
  if (typeof fetch !== 'function') {
    printUsageError(new Error('Node.js with built-in fetch support is required (Node 20+ recommended).'));
    return;
  }
  if (process.env.NODE_TLS_REJECT_UNAUTHORIZED === '0') {
    printUsageError(new Error(
      'Refusing to run with NODE_TLS_REJECT_UNAUTHORIZED=0; use NODE_EXTRA_CA_CERTS for a private CA.'
    ));
    return;
  }

  let context;
  try {
    context = createContext(options);
  } catch (error) {
    printUsageError(error);
    return;
  }

  const checks = buildChecks(context);
  const selected = checks.filter(check => matchesFilter(check, options.caseFilter));
  if (selected.length === 0) {
    printUsageError(new Error(`No deployment check matched --case ${options.caseFilter}`));
    return;
  }

  console.log('Verify deployment');
  console.log(`target: ${context.baseUrl}`);
  if (options.demoSession) {
    console.log('data route: Explore/demo');
  }
  if (context.expectedVersion) {
    console.log(`expected version: ${context.expectedVersion}`);
  }
  console.log(`checks: ${selected.length}, request timeout: ${context.timeoutMs}ms, retries: 0`);

  const startedAt = performance.now();
  const outcomes = await Promise.all(selected.map(runCheck));
  let passed = 0;
  let failed = 0;
  let skipped = 0;

  for (const outcome of outcomes) {
    if (outcome.status === 'passed') {
      passed += 1;
      console.log(`- PASS ${outcome.id} ${Math.round(outcome.durationMs)}ms`);
    } else if (outcome.status === 'skipped') {
      skipped += 1;
      console.log(`- SKIP ${outcome.id} (${outcome.reason})`);
    } else {
      failed += 1;
      console.error(`- FAIL ${outcome.id}`);
      console.error(`  ${outcome.message}`);
      if (outcome.details !== undefined) {
        console.error(`  details: ${compactSnippet(safeJson(outcome.details), 900)}`);
      }
    }
  }

  const summary = `installed deployment verification: ${passed} passed, ${failed} failed, ${skipped} skipped `
    + `in ${Math.round(performance.now() - startedAt)}ms`;
  if (failed > 0) {
    console.error(`\n${summary}`);
    process.exitCode = EXIT_FAILURE;
  } else {
    console.log(`\n${summary}`);
  }

  async function runCheck(check) {
    const checkStartedAt = performance.now();
    try {
      const result = await check.run();
      if (result?.skipped) {
        return {
          id: check.id,
          status: 'skipped',
          reason: result.skipped,
          durationMs: performance.now() - checkStartedAt
        };
      }
      return {
        id: check.id,
        status: 'passed',
        durationMs: performance.now() - checkStartedAt
      };
    } catch (error) {
      return {
        id: check.id,
        status: 'failed',
        message: error?.message ?? `${error}`,
        details: error?.details,
        durationMs: performance.now() - checkStartedAt
      };
    }
  }
}

function createContext(options) {
  const baseUrl = parseRootUrl(options.url);
  const timeoutMs = numericTimeout(options.timeoutMs);
  const client = createHttpClient({
    baseUrl,
    timeoutMs,
    headers: options.demoSession
      ? { 'X-App-Session-Kind': 'demo' }
      : undefined
  });
  const rawRoot = () => client.getCached('/', { maxBodyBytes: 4 * 1024 * 1024 });
  let effectiveOriginPromise;
  const effectiveOrigin = () => {
    if (!effectiveOriginPromise) {
      effectiveOriginPromise = rawRoot().then(result => {
        const configured = baseUrl;
        const effective = new URL(result.responseUrl);
        if (effective.hostname.toLowerCase() !== configured.hostname.toLowerCase()) {
          throw new SmokeRequestError(
            'deployment entrypoint redirected to a different hostname',
            { configured: configured.toString(), effective: effective.toString() }
          );
        }
        if (!options.allowHttp && effective.protocol !== 'https:') {
          throw new SmokeRequestError(
            'deployment entrypoint did not finish on HTTPS',
            { configured: configured.toString(), effective: effective.toString() }
          );
        }
        return effective.origin;
      });
    }
    return effectiveOriginPromise;
  };
  const root = async () => {
    const [result, expectedOrigin] = await Promise.all([rawRoot(), effectiveOrigin()]);
    const actualOrigin = new URL(result.responseUrl).origin;
    if (actualOrigin !== expectedOrigin) {
      throw new SmokeRequestError(
        'deployment root finished on an unexpected origin',
        { expectedOrigin, actualOrigin, responseUrl: result.responseUrl }
      );
    }
    return result;
  };
  const requestApplication = async (method, path, requestOptions = {}) => {
    const expectedOrigin = await effectiveOrigin();
    const target = new URL(
      path instanceof URL ? path.toString() : `${path ?? ''}`,
      `${expectedOrigin}/`
    );
    if (target.origin !== expectedOrigin) {
      throw new SmokeRequestError(
        `${method} application target is outside the effective deployment origin`,
        { expectedOrigin, target: target.toString() }
      );
    }
    const result = method === 'HEAD'
      ? await client.head(target, requestOptions)
      : await client.get(target, requestOptions);
    const actualOrigin = new URL(result.responseUrl).origin;
    if (actualOrigin !== expectedOrigin) {
      throw new SmokeRequestError(
        `${method} ${result.requestUrl} finished on an unexpected origin`,
        { expectedOrigin, actualOrigin, responseUrl: result.responseUrl }
      );
    }
    return result;
  };
  const httpBaseUrl = resolveHttpBaseUrl(baseUrl, options.httpUrl);
  const httpProbe = httpBaseUrl
    ? createHttpClient({ baseUrl: httpBaseUrl, timeoutMs, maxBodyBytes: 1024 * 1024 })
    : null;

  return {
    allowHttp: options.allowHttp,
    baseUrl,
    expectedVersion: `${options.expectedVersion ?? ''}`.trim(),
    get: (path, requestOptions) => requestApplication('GET', path, requestOptions),
    head: (path, requestOptions) => requestApplication('HEAD', path, requestOptions),
    httpBaseUrl,
    httpProbe,
    root,
    timeoutMs
  };
}

function resolveHttpBaseUrl(baseUrl, explicitHttpUrl) {
  if (explicitHttpUrl) {
    const url = parseRootUrl(explicitHttpUrl, 'HTTP listener URL');
    if (url.protocol !== 'http:') {
      throw new SmokeRequestError('HTTP listener URL must use http://');
    }
    if (url.hostname.toLowerCase() !== baseUrl.hostname.toLowerCase()) {
      throw new SmokeRequestError(
        'HTTP listener URL must use the same hostname as the deployment URL'
      );
    }
    return url;
  }
  if (baseUrl.protocol === 'http:') {
    return new URL(baseUrl);
  }
  if (baseUrl.protocol === 'https:' && (!baseUrl.port || baseUrl.port === '443')) {
    const url = new URL(baseUrl);
    url.protocol = 'http:';
    url.port = '';
    return url;
  }
  return null;
}

function numericTimeout(value) {
  const timeoutMs = Number(value);
  if (!Number.isInteger(timeoutMs) || timeoutMs < 250 || timeoutMs > 30000) {
    throw new SmokeRequestError('timeout must be an integer between 250 and 30000 ms');
  }
  return timeoutMs;
}

function matchesFilter(check, filter) {
  if (!filter) {
    return true;
  }
  const normalized = filter.toLowerCase();
  return check.id.toLowerCase().includes(normalized)
    || check.name.toLowerCase().includes(normalized);
}

function parseArgs(argv) {
  const options = {
    allowHttp: process.env.VERIFY_DEPLOYMENT_ALLOW_HTTP === 'true',
    caseFilter: '',
    demoSession: process.env.VERIFY_DEPLOYMENT_DEMO_SESSION === 'true',
    expectedVersion: process.env.VERIFY_DEPLOYMENT_EXPECTED_VERSION ?? '',
    help: false,
    httpUrl: process.env.VERIFY_DEPLOYMENT_HTTP_URL ?? '',
    list: false,
    timeoutMs: process.env.VERIFY_DEPLOYMENT_TIMEOUT_MS ?? '5000',
    url: process.env.VERIFY_DEPLOYMENT_URL ?? ''
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--help' || argument === '-h') {
      options.help = true;
    } else if (argument === '--list') {
      options.list = true;
    } else if (argument === '--allow-http') {
      options.allowHttp = true;
    } else if (argument === '--demo-session') {
      options.demoSession = true;
    } else if (argument === '--url') {
      options.url = requiredValue(argv, ++index, '--url');
    } else if (argument.startsWith('--url=')) {
      options.url = argument.slice('--url='.length);
    } else if (argument === '--http-url') {
      options.httpUrl = requiredValue(argv, ++index, '--http-url');
    } else if (argument.startsWith('--http-url=')) {
      options.httpUrl = argument.slice('--http-url='.length);
    } else if (argument === '--expected-version') {
      options.expectedVersion = requiredValue(argv, ++index, '--expected-version');
    } else if (argument.startsWith('--expected-version=')) {
      options.expectedVersion = argument.slice('--expected-version='.length);
    } else if (argument === '--timeout-ms') {
      options.timeoutMs = requiredValue(argv, ++index, '--timeout-ms');
    } else if (argument.startsWith('--timeout-ms=')) {
      options.timeoutMs = argument.slice('--timeout-ms='.length);
    } else if (argument === '--case') {
      options.caseFilter = requiredValue(argv, ++index, '--case');
    } else if (argument.startsWith('--case=')) {
      options.caseFilter = argument.slice('--case='.length);
    } else if (argument.startsWith('-')) {
      throw new Error(`Unknown option: ${argument}`);
    } else if (!options.url) {
      options.url = argument;
    } else {
      throw new Error(`Unexpected positional argument: ${argument}`);
    }
  }
  return options;
}

function requiredValue(argv, index, option) {
  const value = argv[index];
  if (!value || value.startsWith('-')) {
    throw new Error(`${option} requires a value`);
  }
  return value;
}

function runnerCommand() {
  const runnerPath = process.argv[1] || 'verify-deployment/run.mjs';
  return `node ${JSON.stringify(runnerPath)}`;
}

function printUsageError(error) {
  console.error(`installed deployment verification error: ${error.message}`);
  console.error(`Run ${runnerCommand()} --help for usage.`);
  process.exitCode = EXIT_USAGE;
}

function printHelp() {
  console.log(`Verify an installed deployment (never run automatically)

Usage:
  ${runnerCommand()} --url https://deployment.example [options]
  ${runnerCommand()} https://deployment.example [options]

Options:
  --url URL                 Deployment root URL (or VERIFY_DEPLOYMENT_URL)
  --http-url URL            Explicit HTTP listener for redirect/health checks
  --expected-version X.Y.Z  Require app-version.json to match the package version
  --timeout-ms MS           Per-request timeout, 250-30000 (default: 5000)
  --case FILTER             Run checks whose id or name contains FILTER
  --demo-session            Verify public data through the Explore/demo route
  --allow-http              Local-only: permit a final HTTP application URL
  --list                    List checks without requiring a URL
  --help                    Show this help

TLS certificates are validated normally. For a private CA, set
NODE_EXTRA_CA_CERTS=/path/to/ca.pem. Insecure TLS bypass is not supported.`);
}

function safeJson(value) {
  try {
    return JSON.stringify(value);
  } catch {
    return `${value}`;
  }
}
