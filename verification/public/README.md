# Verify an installed deployment

> **MANUAL OPERATOR COMMAND — not an automated E2E or post-install test.**

This command verifies a freshly installed, already running deployment from
the outside using an Operator-supplied URL. Its source lives under
`verification/public/` in the packaging dependency so release builds can bundle it beside the client tools, but no
installer, package hook, CI task, or aggregate test runner invokes it.

The verifier is read-only. It sends unauthenticated `GET` and `HEAD` requests
only, does not start a stack, connect over SSH, seed data, or reset a database.

## Run

Node.js 20 or newer is recommended.

From an extracted `myscoutee-client-tools` release archive:

```bash
node verify-deployment/run.mjs --url https://deployment.example
```

From a source checkout:

```bash
npm --prefix config/packaging run verify -- --url https://deployment.example
```

The URL can also be positional or supplied through the environment. These
examples use the source-checkout path:

```bash
npm --prefix config/packaging run verify -- https://deployment.example

VERIFY_DEPLOYMENT_URL=https://deployment.example \
npm --prefix config/packaging run verify --
```

For release qualification, also pin the expected Debian package version:

```bash
npm --prefix config/packaging run verify -- \
  --url https://deployment.example \
  --expected-version 1.2.3
```

For a newly installed, not-yet-configured node, verify the packaged Explore
data route instead of expecting a production deployment configuration seed:

```bash
npm --prefix config/packaging run verify -- \
  --url https://deployment.example \
  --expected-version 1.2.3 \
  --demo-session
```

Useful commands:

```bash
npm --prefix config/packaging run verify -- --list
npm --prefix config/packaging run verify -- --url https://deployment.example --case backend
npm --prefix config/packaging run verify -- --help
```

The target is mandatory for a real run. Without it the command exits
immediately, before any network operation.

## What it checks

- HTTP `/nginx-health` remains available and application traffic receives
  the production `308` HTTPS redirect without allowing a forged `Host` header
  to control its destination;
- the supplied target completes a normally validated TLS handshake and HTTPS
  responses carry HSTS;
- Nginx serves the Angular shell, SPA deep links, PWA metadata, matching build
  metadata, every JS/CSS file referenced by `index.html`, and the complete
  service-worker core/build precache set (including lazy chunks and fonts);
- a missing hashed asset is a real `404`, not an HTML fallback;
- Spring reports `UP`, including its configured health contributors;
- public deployment configuration has the expected public-only shape and its
  same-origin logo is readable;
- the English i18n bundle and the configured public content contract
  (landing content or active help/privacy/terms/guide documents) can be read from MongoDB;
- anonymous callers cannot access the Operator configuration or managed-TLS
  configuration endpoints.

Independent checks run concurrently, have no retries, and use a five-second
request timeout by default. This keeps the result bounded to a few seconds
when a deployment is broken.

HEAD asset probes use the native Node HTTP/HTTPS client with a bounded keep-alive
pool. Node fetch/Undici otherwise closes the connection after each HEAD request,
which can turn one precache check into hundreds of TCP/TLS connections. GET
requests retain fetch. Both paths share the existing redirect policy and request
deadline; normal certificate verification and all asset assertions remain enabled.
No retry is used. Focused transport regression checks:

```bash
npm --prefix config/packaging test -- deployment-http-test.mjs
```

## TLS and non-standard ports

Certificate-chain, hostname, and expiration validation are never disabled.
For a private CA, use Node's standard trust extension:

```bash
NODE_EXTRA_CA_CERTS=/path/to/private-ca.pem \
npm --prefix config/packaging run verify -- --url https://deployment.example
```

The runner intentionally has no `--insecure` option and refuses to run when
`NODE_TLS_REJECT_UNAUTHORIZED=0`.

## Short browser render check

`browser-smoke.mjs` complements the HTTP verifier with one isolated,
read-only Chrome render. It starts a temporary headless profile, loads only
the deployment root, checks that Angular boots, compares `index.html` and
`app-version.json` build metadata, and reports uncaught browser exceptions.
It never attaches to an existing browser, clicks, submits a form, or changes
application state.

```bash
npm --prefix config/packaging run verify-browser -- \
  --url https://deployment.example \
  --expected-version 1.2.3
```

On an uninitialized QA node, add `--demo-session`. The locally generated
bootstrap certificate may be accepted only for a loopback URL and only with
the explicit local flag:

```bash
npm --prefix config/packaging run verify-browser -- \
  --url https://localhost \
  --expected-version 1.2.3 \
  --demo-session \
  --allow-insecure-localhost
```

This browser check is manual and is not called by package installation, CI,
the HTTP verifier, or any manual-QA checkpoint.

## Repeatable prerelease qualification

The signed installation, update, rollback and HTTPS acceptance checklist is in
the consuming application’s Operator QA case.
This directory owns only the external HTTP verifier and isolated browser-render
steps of that method. Do not reuse their results for a rebuilt candidate.

For a custom HTTPS port, provide the separate public HTTP listener if the
redirect and Nginx health exceptions should also be checked. It must use the
same hostname:

```bash
npm --prefix config/packaging run verify -- \
  --url https://deployment.example:8443 \
  --http-url http://deployment.example:8080
```

`--allow-http` exists only for an intentional local non-production target. It
permits the final application URL to remain HTTP and skips the production HTTP
redirect/health probes. If the target does finish on HTTPS, HSTS is still
checked.

## Scope boundary

This is an external black-box check. It cannot prove `dpkg`/systemd state,
filesystem permissions, bundled image IDs, or the health of an internal
container that has no public route. In particular, the Debian package's demo
registry is intentionally internal and is not invented as a public endpoint
here. The separately deployed Go registry keeps its own black-box E2E suite
in the registry repository.
