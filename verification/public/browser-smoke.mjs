#!/usr/bin/env node
// MANUAL ONLY: a short, read-only browser render check for an already running
// deployment. It never clicks, submits forms, writes application state, or
// attaches to an operator's existing browser profile.

import { access, mkdtemp, readFile, rm } from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';

const EXIT_FAILURE = 1;
const EXIT_USAGE = 2;

async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
    if (options.help) {
      printHelp();
      return;
    }
    options.url = parseDeploymentUrl(options.url);
    options.timeoutMs = parseTimeout(options.timeoutMs);
    validateTlsOverride(options);
  } catch (error) {
    usageError(error);
    return;
  }

  let profileDirectory;
  let chrome;
  let cdp;
  try {
    const chromeBinary = await findChrome(options.chromeBin);
    profileDirectory = await mkdtemp(join(tmpdir(), 'myscoutee-browser-smoke-'));
    const chromeResult = launchChrome(chromeBinary, profileDirectory, options);
    chrome = chromeResult.process;
    const browserWebSocketUrl = await waitForDevTools(
      profileDirectory,
      chrome,
      chromeResult.stderr,
      options.timeoutMs
    );
    cdp = await CdpConnection.connect(browserWebSocketUrl, options.timeoutMs);
    const result = await inspectDeployment(cdp, options);
    printResult(result, options);
    if (!result.passed) {
      process.exitCode = EXIT_FAILURE;
    }
  } catch (error) {
    console.error(`browser deployment smoke failed: ${error.message}`);
    process.exitCode = EXIT_FAILURE;
  } finally {
    cdp?.close();
    if (chrome) {
      await stopOwnedProcess(chrome);
    }
    if (profileDirectory) {
      await removeOwnedProfile(profileDirectory);
    }
  }
}

async function inspectDeployment(cdp, options) {
  const target = await cdp.send('Target.createTarget', { url: 'about:blank' });
  const attached = await cdp.send('Target.attachToTarget', {
    targetId: target.targetId,
    flatten: true
  });
  const sessionId = attached.sessionId;
  const exceptions = [];
  const consoleErrors = [];
  const logErrors = [];
  const documentResponses = [];
  const documentFailures = [];

  cdp.onEvent(message => {
    if (message.sessionId !== sessionId) {
      return;
    }
    if (message.method === 'Runtime.exceptionThrown') {
      exceptions.push(compactException(message.params?.exceptionDetails));
    } else if (
      message.method === 'Runtime.consoleAPICalled'
      && message.params?.type === 'error'
    ) {
      consoleErrors.push(compactConsole(message.params));
    } else if (
      message.method === 'Log.entryAdded'
      && message.params?.entry?.level === 'error'
    ) {
      const entry = message.params.entry;
      logErrors.push(compactText(
        `${entry.text}${entry.url ? ` (${entry.url})` : ''}`
      ));
    } else if (
      message.method === 'Network.responseReceived'
      && message.params?.type === 'Document'
    ) {
      documentResponses.push({
        loaderId: message.params.loaderId,
        status: message.params.response?.status,
        url: message.params.response?.url
      });
    } else if (
      message.method === 'Network.loadingFailed'
      && message.params?.type === 'Document'
    ) {
      documentFailures.push({
        errorText: message.params.errorText,
        loaderId: message.params.loaderId
      });
    }
  });

  await Promise.all([
    cdp.send('Page.enable', {}, sessionId),
    cdp.send('Runtime.enable', {}, sessionId),
    cdp.send('Network.enable', {}, sessionId),
    cdp.send('Log.enable', {}, sessionId)
  ]);
  if (options.demoSession) {
    await cdp.send('Network.setExtraHTTPHeaders', {
      headers: { 'X-App-Session-Kind': 'demo' }
    }, sessionId);
  }

  const loaded = cdp.waitForEvent(
    'Page.loadEventFired',
    message => message.sessionId === sessionId,
    options.timeoutMs
  );
  const navigation = await cdp.send('Page.navigate', {
    url: options.url.toString()
  }, sessionId);
  if (navigation.errorText) {
    throw new Error(`navigation failed: ${navigation.errorText}`);
  }
  await loaded;

  const page = await waitForAngular(cdp, sessionId, options.timeoutMs);
  const mainDocument = documentResponses
    .filter(response => response.loaderId === navigation.loaderId)
    .at(-1) ?? documentResponses.at(-1);
  const mainFailure = documentFailures
    .find(failure => failure.loaderId === navigation.loaderId);
  const expectedVersion = `${options.expectedVersion ?? ''}`.trim();
  const problems = [];

  if (!mainDocument || mainDocument.status < 200 || mainDocument.status >= 300) {
    problems.push(`main document status was ${mainDocument?.status ?? 'not observed'}`);
  }
  if (mainFailure) {
    problems.push(`main document load failed: ${mainFailure.errorText}`);
  }
  if (page.readyState !== 'complete') {
    problems.push(`document.readyState was ${page.readyState}`);
  }
  if (
    !page.hasAppRoot
    || page.appRootChildCount < 1
    || page.appRootTextLength < 20
    || !page.bootstrapped
    || page.visibleWarmup
  ) {
    problems.push('Angular did not finish rendering inside app-root');
  }
  if (page.warmupFailure) {
    problems.push('the startup fallback reports a browser load failure');
  }
  if (!page.buildId) {
    problems.push('myscoutee-build-id is missing');
  }
  if (page.versionStatus !== 200) {
    problems.push(`app-version.json returned ${page.versionStatus}`);
  }
  if (!page.version?.buildId || page.version.buildId !== page.buildId) {
    problems.push('app-version.json and index.html build IDs do not match');
  }
  if (expectedVersion && page.version?.version !== expectedVersion) {
    problems.push(
      `app version ${page.version?.version ?? 'missing'} does not match ${expectedVersion}`
    );
  }
  if (exceptions.length > 0) {
    problems.push(`${exceptions.length} uncaught browser exception(s)`);
  }
  const observedErrors = [...consoleErrors, ...logErrors];
  const expectedDiagnostics = observedErrors.filter(error =>
    isExpectedDiagnostic(error, options)
  );
  const unexpectedErrors = observedErrors.filter(error =>
    !isExpectedDiagnostic(error, options)
  );
  if (unexpectedErrors.length > 0) {
    problems.push(`${unexpectedErrors.length} unexpected browser error(s)`);
  }

  return {
    passed: problems.length === 0,
    url: page.url,
    status: mainDocument?.status ?? null,
    title: page.title,
    buildId: page.buildId,
    version: page.version?.version ?? null,
    bootstrapped: page.bootstrapped,
    bodyTextLength: page.bodyTextLength,
    appRootTextLength: page.appRootTextLength,
    exceptions,
    expectedDiagnostics,
    unexpectedErrors,
    problems
  };
}

async function waitForAngular(cdp, sessionId, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let page;
  do {
    page = await evaluatePage(cdp, sessionId);
    if (
      page.readyState === 'complete'
      && page.hasAppRoot
      && page.appRootChildCount > 0
      && page.appRootTextLength >= 20
      && page.bootstrapped
      && !page.visibleWarmup
    ) {
      return page;
    }
    await delay(100);
  } while (Date.now() < deadline);
  return page;
}

async function evaluatePage(cdp, sessionId) {
  const expression = `(() => {
    const appRoot = document.querySelector('app-root');
    const warmup = document.querySelector('.app-warmup-fallback');
    const buildId = document.querySelector(
      'meta[name="myscoutee-build-id"]'
    )?.getAttribute('content')?.trim() || '';
    return fetch(new URL('/app-version.json', location.origin), {
      cache: 'no-store',
      credentials: 'omit'
    }).then(async response => ({
      readyState: document.readyState,
      url: location.href,
      title: document.title,
      bodyTextLength: (document.body?.innerText || '').trim().length,
      hasAppRoot: Boolean(appRoot),
      appRootChildCount: appRoot?.childElementCount || 0,
      appRootTextLength: (appRoot?.innerText || '').trim().length,
      bootstrapped: document.documentElement.classList.contains('app-bootstrapped'),
      warmupFailure: document.documentElement.classList.contains('app-warmup-offline'),
      visibleWarmup: Boolean(warmup) && getComputedStyle(warmup).display !== 'none',
      buildId,
      versionStatus: response.status,
      version: response.ok ? await response.json() : null
    }));
  })()`;
  const result = await cdp.send('Runtime.evaluate', {
    expression,
    awaitPromise: true,
    returnByValue: true
  }, sessionId);
  if (result.exceptionDetails) {
    throw new Error(compactException(result.exceptionDetails));
  }
  return result.result?.value ?? {};
}

function launchChrome(binary, profileDirectory, options) {
  const args = [
    '--headless=new',
    '--remote-debugging-address=127.0.0.1',
    '--remote-debugging-port=0',
    `--user-data-dir=${profileDirectory}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    '--disable-component-update',
    '--disable-default-apps',
    '--disable-extensions',
    '--disable-gpu',
    '--disable-sync',
    '--metrics-recording-only',
    '--password-store=basic',
    '--use-mock-keychain',
    ...(options.allowInsecureLocalhost ? ['--allow-insecure-localhost'] : []),
    'about:blank'
  ];
  const child = spawn(binary, args, {
    stdio: ['ignore', 'ignore', 'pipe']
  });
  const stderr = [];
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', chunk => {
    stderr.push(chunk);
    if (stderr.join('').length > 8192) {
      stderr.splice(0, stderr.length - 2);
    }
  });
  return { process: child, stderr };
}

async function waitForDevTools(profileDirectory, chrome, stderr, timeoutMs) {
  const activePortFile = join(profileDirectory, 'DevToolsActivePort');
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (chrome.exitCode !== null) {
      throw new Error(
        `Chrome exited with ${chrome.exitCode}: ${compactText(stderr.join(''))}`
      );
    }
    try {
      const lines = (await readFile(activePortFile, 'utf8')).trim().split(/\r?\n/);
      if (/^\d+$/.test(lines[0]) && lines[1]?.startsWith('/devtools/browser/')) {
        return `ws://127.0.0.1:${lines[0]}${lines[1]}`;
      }
    } catch (error) {
      if (error.code !== 'ENOENT') {
        throw error;
      }
    }
    await delay(50);
  }
  throw new Error(`Chrome DevTools did not start within ${timeoutMs} ms`);
}

class CdpConnection {
  constructor(socket, timeoutMs) {
    this.socket = socket;
    this.timeoutMs = timeoutMs;
    this.nextId = 1;
    this.pending = new Map();
    this.eventListeners = new Set();
    socket.addEventListener('message', event => this.receive(event.data));
    socket.addEventListener('close', () => this.rejectPending('CDP connection closed'));
    socket.addEventListener('error', () => this.rejectPending('CDP connection failed'));
  }

  static async connect(url, timeoutMs) {
    const socket = new WebSocket(url);
    await new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`CDP connection timed out after ${timeoutMs} ms`)),
        timeoutMs
      );
      socket.addEventListener('open', () => {
        clearTimeout(timer);
        resolve();
      }, { once: true });
      socket.addEventListener('error', () => {
        clearTimeout(timer);
        reject(new Error('CDP WebSocket connection failed'));
      }, { once: true });
    });
    return new CdpConnection(socket, timeoutMs);
  }

  send(method, params = {}, sessionId = undefined) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timed out after ${this.timeoutMs} ms`));
      }, this.timeoutMs);
      this.pending.set(id, { method, resolve, reject, timer });
      this.socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  }

  waitForEvent(method, predicate, timeoutMs = this.timeoutMs) {
    return new Promise((resolve, reject) => {
      const listener = message => {
        if (message.method === method && predicate(message)) {
          clearTimeout(timer);
          this.eventListeners.delete(listener);
          resolve(message.params);
        }
      };
      const timer = setTimeout(() => {
        this.eventListeners.delete(listener);
        reject(new Error(`${method} was not received within ${timeoutMs} ms`));
      }, timeoutMs);
      this.eventListeners.add(listener);
    });
  }

  onEvent(listener) {
    this.eventListeners.add(listener);
  }

  receive(raw) {
    let message;
    try {
      message = JSON.parse(raw);
    } catch {
      return;
    }
    if (message.id) {
      const pending = this.pending.get(message.id);
      if (!pending) {
        return;
      }
      clearTimeout(pending.timer);
      this.pending.delete(message.id);
      if (message.error) {
        pending.reject(new Error(`${pending.method}: ${message.error.message}`));
      } else {
        pending.resolve(message.result ?? {});
      }
      return;
    }
    for (const listener of this.eventListeners) {
      listener(message);
    }
  }

  rejectPending(reason) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error(reason));
    }
    this.pending.clear();
  }

  close() {
    this.socket.close();
  }
}

async function findChrome(explicit) {
  const candidates = [
    explicit,
    process.env.CHROME_BIN,
    '/opt/google/chrome/chrome',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser'
  ].filter(Boolean);
  for (const candidate of [...new Set(candidates)]) {
    try {
      await access(candidate, fsConstants.X_OK);
      return candidate;
    } catch {
      // Try the next known browser binary.
    }
  }
  throw new Error('Chrome/Chromium was not found; pass --chrome-bin PATH');
}

async function stopOwnedProcess(child) {
  if (child.exitCode !== null) {
    return;
  }
  child.kill('SIGTERM');
  const exited = await Promise.race([
    new Promise(resolve => child.once('exit', () => resolve(true))),
    delay(2000).then(() => false)
  ]);
  if (!exited && child.exitCode === null) {
    child.kill('SIGKILL');
    await Promise.race([
      new Promise(resolve => child.once('exit', resolve)),
      delay(2000)
    ]);
  }
}

async function removeOwnedProfile(profileDirectory) {
  for (let attempt = 1; attempt <= 5; attempt += 1) {
    try {
      await rm(profileDirectory, { recursive: true, force: true, maxRetries: 2 });
      return;
    } catch (error) {
      if (attempt === 5 || !['EBUSY', 'ENOTEMPTY', 'EPERM'].includes(error.code)) {
        throw error;
      }
      await delay(attempt * 100);
    }
  }
}

function parseArgs(argv) {
  const options = {
    allowInsecureLocalhost: false,
    chromeBin: '',
    demoSession: false,
    expectedVersion: '',
    help: false,
    timeoutMs: '10000',
    url: ''
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--help' || argument === '-h') {
      options.help = true;
    } else if (argument === '--allow-insecure-localhost') {
      options.allowInsecureLocalhost = true;
    } else if (argument === '--demo-session') {
      options.demoSession = true;
    } else if (argument === '--url') {
      options.url = requiredValue(argv, ++index, '--url');
    } else if (argument.startsWith('--url=')) {
      options.url = argument.slice('--url='.length);
    } else if (argument === '--expected-version') {
      options.expectedVersion = requiredValue(argv, ++index, '--expected-version');
    } else if (argument.startsWith('--expected-version=')) {
      options.expectedVersion = argument.slice('--expected-version='.length);
    } else if (argument === '--timeout-ms') {
      options.timeoutMs = requiredValue(argv, ++index, '--timeout-ms');
    } else if (argument.startsWith('--timeout-ms=')) {
      options.timeoutMs = argument.slice('--timeout-ms='.length);
    } else if (argument === '--chrome-bin') {
      options.chromeBin = requiredValue(argv, ++index, '--chrome-bin');
    } else if (argument.startsWith('--chrome-bin=')) {
      options.chromeBin = argument.slice('--chrome-bin='.length);
    } else if (argument.startsWith('-')) {
      throw new Error(`unknown option: ${argument}`);
    } else if (!options.url) {
      options.url = argument;
    } else {
      throw new Error(`unexpected positional argument: ${argument}`);
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

function parseDeploymentUrl(value) {
  if (!value) {
    throw new Error('a deployment URL is required');
  }
  const url = new URL(value);
  if (!['http:', 'https:'].includes(url.protocol)) {
    throw new Error('deployment URL must use HTTP or HTTPS');
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new Error('deployment URL must not contain credentials, a query, or a fragment');
  }
  if (url.pathname !== '/' && url.pathname !== '') {
    throw new Error('deployment URL must point to the origin root');
  }
  url.pathname = '/';
  return url;
}

function parseTimeout(value) {
  const timeoutMs = Number(value);
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1000 || timeoutMs > 30000) {
    throw new Error('timeout must be an integer between 1000 and 30000 ms');
  }
  return timeoutMs;
}

function validateTlsOverride(options) {
  if (!options.allowInsecureLocalhost) {
    return;
  }
  const hostname = options.url.hostname.toLowerCase();
  if (!['localhost', '127.0.0.1', '::1'].includes(hostname)) {
    throw new Error('--allow-insecure-localhost is restricted to loopback targets');
  }
}

function printResult(result, options) {
  console.log('Read-only browser deployment smoke');
  console.log(`target: ${options.url}`);
  if (options.demoSession) {
    console.log('data route: Explore/demo');
  }
  console.log(`main document: ${result.status}`);
  console.log(`Angular bootstrapped: ${result.bootstrapped ? 'yes' : 'no'}`);
  console.log(`build: ${result.buildId || 'missing'} (${result.version || 'unknown'})`);
  console.log(`rendered text: ${result.bodyTextLength} characters`);
  console.log(`uncaught exceptions: ${result.exceptions.length}`);
  console.log(`expected local diagnostics: ${result.expectedDiagnostics.length}`);
  for (const observed of result.expectedDiagnostics.slice(0, 5)) {
    console.log(`- EXPECTED ${observed}`);
  }
  console.log(`unexpected browser errors: ${result.unexpectedErrors.length}`);
  for (const observed of result.unexpectedErrors.slice(0, 5)) {
    console.error(`- UNEXPECTED ${observed}`);
  }
  for (const problem of result.problems) {
    console.error(`- FAIL ${problem}`);
  }
  if (result.passed) {
    console.log('browser deployment smoke: PASS');
  }
}

function compactException(details) {
  return compactText(
    details?.exception?.description
      || details?.text
      || 'unknown browser exception'
  );
}

function compactConsole(params) {
  return compactText(
    (params?.args ?? [])
      .map(argument => argument.value ?? argument.description ?? argument.type)
      .join(' ')
  );
}

function isExpectedDiagnostic(message, options) {
  const value = `${message ?? ''}`;
  if (
    options.allowInsecureLocalhost
    && /(?:ServiceWorker.*SSL certificate error|An SSL certificate error occurred)/i.test(value)
  ) {
    return true;
  }
  return options.demoSession
    && /404/.test(value)
    && value.includes('/api/deployment/configuration/firebase-config');
}

function compactText(value) {
  return `${value ?? ''}`.replace(/\s+/g, ' ').trim().slice(0, 500);
}

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function usageError(error) {
  console.error(`browser deployment smoke usage error: ${error.message}`);
  console.error(`Run node ${JSON.stringify(process.argv[1])} --help for usage.`);
  process.exitCode = EXIT_USAGE;
}

function printHelp() {
  console.log(`Read-only browser smoke for an installed deployment

Usage:
  node ${JSON.stringify(process.argv[1])} --url https://deployment.example [options]

Options:
  --url URL                    Deployment origin root
  --expected-version X.Y.Z     Require app-version.json to match
  --demo-session               Route public API reads to Explore/demo data
  --timeout-ms MS              Browser startup/load timeout (default: 10000)
  --chrome-bin PATH            Explicit Chrome/Chromium executable
  --allow-insecure-localhost   Accept only a loopback bootstrap certificate
  --help                       Show this help

The command starts its own temporary headless profile and performs no clicks,
form submissions, application writes, or attachment to an existing browser.`);
}

await main();
