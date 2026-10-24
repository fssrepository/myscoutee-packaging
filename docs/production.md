# Production packaging and host operations

The implementation belongs to `@fssrepository/myscoutee-packaging`; each consuming
application owns `config/packaging/`. The commands below run from the selected
application checkout. Paths and image names using `myscoutee` are examples of the
backend policy; the template selects its own package identity, image inventory,
Compose files and migration/seed inputs. Registry/payment helpers run only when
selected by the consuming application.

The source configuration `config/packaging/release-project.json` owns the Debian package identity and
managed-image inventory, including historical image introductions. The updater
loads this package-owned policy, never a policy supplied by the browser or an
incoming release. It must be a regular, root-owned file without group/other write
permission. `release/lib/release-project.sh` validates that policy and the exact
candidate image manifest. Signature contexts and update request schemas remain
unchanged. Run `bash config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/consumer/release/release-project-test.sh` and the existing
`config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/unit/update-worker-test.sh` after changing this boundary.

The same JSON now contains the client-tools deployment paths and service
selections. Client environment files, the safe example, archive selection and
site-specific network policy live in `config/packaging/client-tools/`; scripts
are supplied by the pinned `@fssrepository/myscoutee-packaging` dependency.
Install it with `npm --prefix config/packaging ci --ignore-scripts`; run helpers
with `npm --prefix config/packaging run client -- SCRIPT ARGS`, and build the
archive with `npm --prefix config/packaging run client-tools`. Builders place the trusted JSON at the
existing installed `packaging/scripts/release-project.json` path and beside the
standalone client helpers. Installed paths and signature formats are unchanged.

## Runtime and source tools

`config/packaging/runtime-inputs.json` selects deployment-host tools from the
locked packaging dependency and project inputs. The builder copies them
into the Debian package. The packaging dependency contains checkout-only build,
audit, qualification, rebuild, package, and signing helpers and is deliberately
excluded from the DEB.

Run from the repo root:

```bash
npm --prefix config/packaging run release -- build-debian-release
npm --prefix config/packaging run release -- rebuild-production-services --build-only
npm --prefix config/packaging run release -- build-production
npm --prefix config/packaging run runtime -- start-production.sh
npm --prefix config/packaging run runtime -- status-production.sh
npm --prefix config/packaging run runtime -- stop-production.sh
npm --prefix config/packaging run runtime -- backup-production.sh
npm --prefix config/packaging run release -- package-production
npm --prefix config/packaging run runtime -- smoke-mongo-compatibility.sh
```

Useful overrides:

```bash
MYSCOUTEE_VERSION=1.0.0 npm --prefix config/packaging run release -- build-production
BUILD_FRONTEND=false npm --prefix config/packaging run release -- build-production
BUILD_BACKEND=false npm --prefix config/packaging run release -- build-production
BUILD_IMAGES=false npm --prefix config/packaging run release -- build-production
BUILD_ARTIFACTS=false PACKAGE_IMAGES=false \
  ALLOW_UNBUNDLED_IMAGES_FOR_TESTS=true \
  npm --prefix config/packaging run release -- package-production
```

`package-production.sh` creates `build/packaging/dist/myscoutee_<version>_amd64.deb`. By default it builds production artifacts and bundles the MyScoutee Nginx, API, MinIO, Explore Registry, and Explore payment-simulator images. During install, `postinst` checks Docker and prepares MongoDB and Redis images by pulling them if they are missing. Set `PACKAGE_OFFICIAL_IMAGES=true` only when you want a larger offline-style bundle that also includes those official service image archives.

The same build also creates
`build/packaging/dist/myscoutee-client-tools_<version>.tar.gz`. It contains only
Operator-facing client wrappers, a secret-free configuration example, and the
external read-only deployment verifier. Its canonical source is
`verification/public/` in the packaging dependency; release artifacts expose it at
`verify-deployment` beside the client wrappers. A byte-identical copy of that
single archive is installed by the DEB as
`/usr/share/myscoutee/myscoutee-client-tools_<version>.tar.gz`;
the client-side scripts are not unpacked on the deployment host.
Development-only checkout and datastore-reset helpers are deliberately
excluded.

The convenience `build-debian-release.sh` wrapper also writes
`myscoutee_<version>_<architecture>.deb.sha256` and
`myscoutee-client-tools_<version>.tar.gz.sha256` beside the two artifacts for
separate release attachment.

That verifier directory also contains an optional, isolated read-only Chrome
render smoke. It is a manual post-install check and never drives the pair-QA
browser session.

`MYSCOUTEE_VERSION` is always the plain SemVer core (`1.0.0`). Image purpose
is expressed once in the derived tags (`1.0.0-base`, `1.0.0-dev`, and
`1.0.0-prod`); do not use `1.0.0-prod` as the package/base version.

MongoDB is pinned to `mongo:8.0.4` for the packaged and dev stacks. Run `smoke-mongo-compatibility.sh` against a running stack to confirm the configured image, running Mongo version, feature compatibility version, backend health, landing content query, and a temporary app-user CRUD round trip all work on Mongo 8.0.

Every package configure marks the disposable Explore state for a clean rebuild.
On the next service start, `reset-demo-state.sh` accepts only the literal
`demo_db` target, rejects a production database with the same name, rebuilds
the database from the package's current demo seed and refreshes only the
package-owned `images/demo-assets`, `images/demo-events` and
`images/demo-profiles` MinIO prefixes. The retry marker is removed only after
the Mongo import, MinIO seed and demo oracle succeed. This applies to fresh
install, upgrade and same-version reinstall, so an older Explore database
cannot retain obsolete or external media URLs.

Production is deliberately excluded from that lifecycle. Package installation
preserves the production database, operator state and user uploads; only an
explicit versioned migration or a documented allow-listed system-seed sync may
change them. The demo reset helper is not a general database-drop command and
never clears the complete MinIO volume.

Install the local deb with `apt`, not `dpkg`, so Docker Engine and Docker Compose dependencies are installed before MyScoutee is configured:

```bash
sudo apt install ./build/packaging/dist/myscoutee_1.0.0_amd64.deb
```

## Production TLS

The production Nginx image always renders `DOMAIN` into both virtual servers
before validating its complete configuration. It supports two explicit
certificate sources:

- `LETSENCRYPT_ENABLED=false` selects the operator-managed paths
  `NGINX_TLS_CERTIFICATE_PATH` and `NGINX_TLS_CERTIFICATE_KEY_PATH`. Their
  defaults are `/etc/nginx/keys/nginx.crt` and
  `/etc/nginx/keys/nginx-nopass.key`, backed by
  `/opt/myscoutee/server/docker/conf/nginx/keys` on the host.
- `LETSENCRYPT_ENABLED=true` selects
  `/etc/letsencrypt/live/<DOMAIN>/fullchain.pem` and `privkey.pem`, backed by
  `/var/lib/myscoutee/data/certbot/conf` on an installed host.

Nginx fails startup if the selected files are absent, empty, mismatched, or
otherwise invalid. `postinst` creates a localhost self-signed pair only so a
new node can be inspected locally before public TLS is configured. That pair
is not a valid Internet-facing certificate and must not be treated as one.
Normal package removal, deconfiguration, upgrade, and same-version reinstall
preserve the operator-managed certificate and private key. If exactly one of
the two files exists, package configuration fails closed and leaves that file
unchanged; restore its counterpart or explicitly remove it before retrying if
you intentionally want a new localhost bootstrap pair.

For a first Let's Encrypt certificate, point the domain's public DNS at the
deployment, make TCP port 80 reachable, stop MyScoutee so Certbot can bind that
port, and provision the mounted certificate directory:

```bash
sudo systemctl stop myscoutee
sudo install -d -m 0755 /var/lib/myscoutee/data/certbot/conf
sudo docker run --rm --name myscoutee-certbot-bootstrap \
  -p 80:80 \
  -v /var/lib/myscoutee/data/certbot/conf:/etc/letsencrypt \
  certbot/certbot:v5.4.0 certonly --standalone \
  --non-interactive --agree-tos --no-eff-email \
  --email operator@example.com -d app.example.com
```

Then set the exact issued name in `/etc/myscoutee/myscoutee.env` and start the
service:

```bash
sudo sed -i \
  -e 's/^DOMAIN=.*/DOMAIN=app.example.com/' \
  -e 's/^LETSENCRYPT_ENABLED=.*/LETSENCRYPT_ENABLED=true/' \
  /etc/myscoutee/myscoutee.env
sudo systemctl start myscoutee
```

Renewal can be managed from the authenticated Operator Configuration screen.
Enable **Manage HTTPS**, choose **Automatic certificate**, enter the public
domain and certificate contact e-mail, and use the domain and certificate test
buttons before saving. The **Automatic renewal** toggle controls whether the
packaged daily renewal check acts on that certificate; changing a toggle is
only a draft until the block's Save button is used.

The equivalent manual renewal command remains available for recovery:

```bash
sudo systemctl stop myscoutee
sudo docker run --rm --name myscoutee-certbot-renew \
  -p 80:80 \
  -v /var/lib/myscoutee/data/certbot/conf:/etc/letsencrypt \
  certbot/certbot:v5.4.0 renew --standalone
sudo systemctl start myscoutee
```

Directly setting `LETSENCRYPT_ENABLED=true` still only activates an already
provisioned certificate. The Operator workflow obtains a certificate through
its separate, fixed-format privileged TLS worker.

For an operator-managed CA certificate instead, install the full chain and
unencrypted private key at the configured host-mounted paths, restrict the
private key to root, leave `LETSENCRYPT_ENABLED=false`, and restart the service.
The production entrypoint checks the pair with `nginx -t` before serving.

## Operator-approved package updates

An `UPDATE` announcement only tells the authenticated Operator workspace that
a release is available. It never installs anything automatically. The
operator must open the update action, review the version, channel, artifact
URL, size, SHA-256 digest, and signing-key ID, and explicitly approve the
download and installation.

The Java backend is the unprivileged control plane. It downloads the exact
HTTPS artifact named by the registry-signed manifest, enforces the configured
size limit, verifies its SHA-256 digest and separately pinned Ed25519 package
signature, and stages it under:

```text
/var/lib/myscoutee/update/staging/<job-id>/
```

Java records the `CHECKING` and `DOWNLOADING` states in that staging directory,
then atomically publishes a fixed-schema JSON request under:

```text
/var/lib/myscoutee/update/requests/
```

Those are the container paths. They map to the fixed host inbox paths
`/var/lib/myscoutee/update/inbox/staging` and
`/var/lib/myscoutee/update/inbox/requests`. The JSON contains only the fixed
relative artifact name `myscoutee.deb`; it cannot supply a host path.

The local `myscoutee-update.path` unit watches whether the request directory is
non-empty and starts the root-only `myscoutee-update.service` for any entry,
including malformed names and hidden files. This worker accepts no URL and no
shell command. It first atomically claims every inbox entry into a root-only
processing directory, quarantining anything that is not a valid request. A
packaged Python helper opens each source path component with directory file
descriptors and `O_NOFOLLOW`, then performs a bounded, mutation-detecting copy.
The worker independently checks the package name, plain SemVer, architecture,
size, digest, release-signing key ID, signature, bundled-image manifest, and
cache capacity before requiring a complete production backup and calling
`apt-get install` on the local `.deb`. Managed compose services use
`pull_policy: never`; after restart the worker verifies every running managed
container has the exact packaged image reference and image ID and reports
healthy.

Install the vendor release-signing public key only after checking its full
SPKI DER fingerprint through an independent channel:

```bash
sudo install -o root -g 10001 -m 0640 release-public-key.pem \
  /etc/myscoutee/update/release-public-key.pem
```

Then set the host execution gate in `/etc/myscoutee/myscoutee.env`:

```bash
MYSCOUTEE_UPDATE_ENABLED=true
```

`MYSCOUTEE_UPDATE_STAGING_SAFETY_RESERVE_BYTES` is the free-space reserve Java
requires before downloading into the shared staging directory.
`MYSCOUTEE_UPDATE_MIN_FREE_BYTES` is the independent reserve the privileged
worker requires before copying into its root-owned cache. Both default to
512 MiB in addition to the signed artifact size.
`MYSCOUTEE_UPDATE_CACHE_RETENTION_JOBS` bounds retained package caches and
defaults to two jobs.

Restart the path watcher after changing host update configuration:

```bash
sudo systemctl restart myscoutee-update.path
```

The package-signature message is deliberately independent from the
announcement and registry signing keys. It is the following UTF-8 text,
including the final newline:

```text
myscoutee-release-package-v1
<release-version>
<channel>
<artifact-size-as-base-10>
<artifact-sha256-with-sha256-prefix>
```

The package key ID is
`pkey_<first 32 lowercase hex characters of SHA-256(complete Ed25519 SPKI DER)>`.
The detached signature is canonical padded RFC 4648 base64. The release
private key must never be installed on an application deployment or registry
server.

After building the DEB and matching client-tools archive, create the GitHub
Release metadata with an externally stored, pre-existing Ed25519 PKCS#8 key:

```bash
../myscoutee-packaging/release/signing/sign-release-artifacts.sh \
  --project-root "$PWD" \
  --private-key /secure/release-private-key.pem \
  --deb build/packaging/dist/myscoutee_1.0.0_amd64.deb \
  --client-tools build/packaging/dist/myscoutee-client-tools_1.0.0.tar.gz \
  --channel stable \
  --output-dir build/packaging/dist
```

The GitHub Release assets may expose the DEB, its byte-identical client-tools
archive, and generated
`myscoutee-release_<version>.json`; the public key may also be published for
convenience. Its complete printed SPKI SHA-256 fingerprint must be pinned
through an independent channel. Neither the public key downloaded beside the
artifacts nor a key embedded in the first package can establish its own trust.
The signer never creates, copies, or packages the private key.

The release manifest separately signs the standalone client-tools archive
with the domain `myscoutee-release-client-tools-v1`. Its embedded copy is also
covered transitively by the DEB signature. The packaged
`verify-release.sh` checks either downloaded artifact, both metadata
signatures, the complete trusted-key fingerprint, and the selected artifact's
size and SHA-256. `install.sh` refuses unsigned downloads by default; only a
trusted locally built package may use the explicit
`ALLOW_UNSIGNED_LOCAL_PACKAGE=true` development override.

Progress is durable and reconnectable. Once the privileged worker accepts a
request, its state supersedes the Java staging state and is available at:

```text
/var/lib/myscoutee/update/runtime/jobs/<job-id>/status.json
/var/lib/myscoutee/update/runtime/jobs/<job-id>/events.ndjson
/var/lib/myscoutee/update/runtime/jobs/<job-id>/install.log
```

Accepted request evidence is copied to
`/var/log/myscoutee/update/<job-id>/request.json`. Completed, failed, and
rejected request files are retained under the corresponding root-only
subdirectory of `/var/lib/myscoutee/update/archive/`. A crash never leaves an
accepted job indefinitely nonterminal: it is reconciled only when the exact
requested package and images can be proved active, otherwise it ends as
`RECOVERY_REQUIRED`. A failed install does not silently restore old data;
recovery remains an explicit audited operator action:

```bash
sudo journalctl -u myscoutee-update.service
sudo cat /var/lib/myscoutee/update/runtime/jobs/<job-id>/status.json
sudo cat /var/lib/myscoutee/update/runtime/jobs/<job-id>/install.log
sudo CONFIRM_RESTORE=true \
  /opt/myscoutee/packaging/scripts/restore-production.sh \
  /var/backups/myscoutee/<recorded-backup>.tar.gz
```

The worker contract, signature verification, progress journal, unsafe path
rejection, and tamper rejection can be tested without starting the dev stack:

```bash
bash config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/consumer/debian/operator-bootstrap-test.sh
bash tests/packaging/deployment/nginx-transport-policy-test.sh
bash config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/consumer/debian/debian-tls-lifecycle-test.sh
bash config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/consumer/deployment/deployment-qualification-test.sh
bash config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/consumer/client/client-tools-test.sh
bash config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/consumer/debian/numeric-ownership-policy-test.sh
bash config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/unit/update-worker-test.sh
bash config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/unit/image-content-fingerprint-test.sh
bash tests/packaging/release/package-content-test.sh
bash config/packaging/node_modules/@fssrepository/myscoutee-packaging/tests/consumer/debian/debian-removal-contract-test.sh
bash ../myscoutee-packaging/tests/integration/release-signing-test.sh
```

Before a release drill, bind the evidence to the exact candidate package,
oldest-supported package, and production registry image:

```bash
MYSCOUTEE_QUALIFICATION_EVIDENCE_DIR=/absolute/evidence/1.2.0 \
  npm --prefix config/packaging run release -- qualify-release-artifacts \
    /absolute/myscoutee_1.2.0_amd64.deb \
    /absolute/myscoutee_1.0.0_amd64.deb \
    myscoutee-registry:1.2.0-prod
```

This is a read-only artifact preflight, not an upgrade or restore. The complete
oldest-supported upgrade, interruption, clean-host restore, multi-registry,
load, and security procedures are documented in
the consuming application’s production qualification guide.

Bundled managed images are bound both to their saved archive configuration
digest and to a portable content fingerprint covering the platform, runtime
configuration, and root filesystem layer digests. Installation and update
health checks use the portable fingerprint because Docker daemon image IDs can
change when the same archive is loaded through a different storage backend.
Actual image content changes still fail closed.

The package separates locally generated deployment secrets from external
provider credentials:

- Mongo and MinIO passwords, payment-simulator control/webhook credentials, the
  deployment configuration encryption key, and local node/demo-registry signing keys are internal. They are generated on the
  installed host or first runtime and are never shipped as reusable fixed
  secrets.
- Firebase service accounts, payment-provider tokens, email/social/community
  credentials, and remote-provider client secrets are external. The `.deb` and
  its managed images contain only empty templates or examples; the operator
  supplies real values after installation.
- Provider endpoints, fingerprints, public verification keys, and public
  release metadata are not credentials and may be packaged. Firebase web-client
  identifiers (including its browser API key) and the VAPID public key are also
  public client bootstrap data; they grant no server authority and are separate
  from the Firebase service-account private key and provider tokens. MyScoutee
  stores those public Firebase fields with deployment configuration and serves
  them from the backend only after the Operator explicitly activates a
  successfully tested Firebase revision; the frontend does not load a packaged
  live Firebase configuration.
- Payment API endpoints supplied by the provider may be part of the product,
  but the deployment's public success/cancel/callback origin and a
  provider-required merchant account belong to the deployment. They are saved
  by the Operator with the selected payment provider; the package and runtime
  processors contain no vendor-owned MyScoutee return URL or merchant fallback.
- Operator and administrator email addresses are authorization identifiers,
  not secrets. They are nevertheless deployment-owner data, so the generic
  package does not nominate any real operator or administrator. The initial
  operator allow-list is supplied at runtime or generated locally by the
  installer as an `operator-<random>@deployment.invalid` identity;
  administrator emails are then maintained as mutable deployment configuration
  through the authenticated Operator workspace.
- The deployment-local bootstrap password is a 256-bit random printable value,
  shown once by `postinst`. “Shown once” describes disclosure only: the same
  password remains valid for later local Operator logins until the deployment
  owner deliberately replaces or disables that bootstrap access. Its generated
  subject and lowercase SHA-256 digest are written together to root-only
  `/etc/myscoutee/myscoutee.secrets.env`; Java accepts the digest only when that
  subject exactly equals the sole `OPERATOR_USER`. SHA-256 is appropriate for
  this narrow bootstrap because the input is generated with full cryptographic
  entropy rather than chosen by a person. MyScoutee never embeds or deliberately
  persists the plaintext in configuration, images, process arguments, or
  outbound traffic. The explicitly requested terminal print can nevertheless
  be retained by package-manager, terminal, or automation logs, so those logs
  must be protected. Activating operator-supplied Firebase does not silently
  disable this recovery login. Re-running the installer preserves the subject
  and digest and prints nothing.

`package-production.sh` fails closed if an external credential file, a
non-empty external-provider value, or private-key material appears in the
staged Debian payload or any bundled managed-image configuration/layer.
`package-content-test.sh` independently checks the resulting archive, both
Docker build-context exclusion policies, and any local Firebase
service-account identity without printing that identity.

The production package also stages Mongo data through an explicit collection
allow-list. It contains only system/configuration bootstrap collections for the
real database: no users, privileged users, personal names, activity/chat
records, payment records, E2E database, administrator email list, or
deployment-specific social-page URLs. Explore keeps a separate server-side
`demo_db`; its identities use visibly synthetic `.local`/`.invalid` or example
addresses, and its public provider links are demonstration data only. The
fixed report-issue destination remains a MyScoutee product/support concern,
not an operator social identity.

Node registration uses no package-wide shared secret. After the operator has
inspected and confirmed the registry identity, Java generates an Ed25519
deployment key pair locally, sends only its public key in the signed
registration request, and verifies the registry-signed receipt against the
pinned registry public key. The deployment private key and the internal
Explore registry signing key are persistent runtime-volume data, not `.deb`
content.

`restore-production.sh` is intentionally guarded:

```bash
CONFIRM_RESTORE=true npm --prefix config/packaging run runtime -- restore-production.sh /path/to/myscoutee-backup.tar.gz
```

Set `RESTORE_MINIO=true` to restore MinIO files and `RESTORE_CONFIG=true` to restore `.env` files.
Set `RESTORE_REGISTRY=true` only when the deployment identity and its verified
registry state and receipts must also be restored. A key-only backup is
rejected because it cannot safely recover the enrollment history. Restoring
that directory transfers
control of the registered deployment, so do not restore one deployment's
identity onto a different independent installation. If the backend is running,
the restore briefly stops and recreates `profilemanagement` around the
identity/state replacement so its registry retry worker cannot race the
restore.

Production backups contain database credentials and, when present, the
deployment private key. The backup script creates the archive with mode
`0600`; store and transfer it as a secret. Package installations write backups
to `/var/backups/myscoutee` by default so `apt purge` does not remove the
archive along with `/opt/myscoutee`.

Operator-managed deployment credentials use a separate at-rest encryption key:

```text
/etc/myscoutee/configuration/deployment-master-key
```

`postinst` generates it once as 32 random bytes encoded by 64 lowercase
hexadecimal characters. The directory is `root:10001` mode `0750`; the key is
`root:10001` mode `0640` and is mounted read-only into the API container.
Package upgrades validate and preserve it. Production backup/restore treats
the key and MongoDB snapshot as one recovery set because encrypted deployment
credentials cannot be decrypted with a different key. Replacing or rotating
this file without atomically re-encrypting every stored credential is invalid
and will make those credentials unreadable.

Restore validates and stages the backup key, stops the API, restores MongoDB,
and activates the key only after `mongorestore` succeeds. If MongoDB/key or
registry identity/state replacement is incomplete, the API deliberately
remains stopped for operator recovery instead of restarting with mismatched
cryptographic state.

`apt remove myscoutee` stops and removes the Compose containers but preserves
deployment configuration, bind-mounted data, the two isolated Explore
registry volumes, the Explore payment-simulator volume, and the package-managed
image tags for a later reinstall.
`apt purge myscoutee` deliberately removes `/etc/myscoutee`,
`/var/lib/myscoutee`, `/var/log/myscoutee`, the Explore registry and
payment-simulator volumes, and the MyScoutee-managed API, Nginx, MinIO,
demo-registry, and payment-simulator image tags. It does
not delete shared upstream MongoDB or Redis images, and it preserves
`/var/backups/myscoutee`. Back up the deployment identity and registry state
before purging; without that backup, the deployment cannot recover its signing
control and accepted receipt history.

## Debian installation

The Debian package installs a prepared bundle under `/opt/myscoutee`, with configuration under `/etc/myscoutee` and persistent data linked through `/var/lib/myscoutee`. The package declares Docker Engine and Docker Compose v2 as dependencies.

On first install, `postinst` creates `/etc/myscoutee/myscoutee.secrets.env` with generated values for `MONGO_INITDB_ROOT_PASSWORD`, `MONGO_APP_PASSWORD`, `MINIO_ROOT_PASSWORD`, and the internal payment-simulator credentials, and generates the dedicated operator-configuration master key. It does not create a deployment identity or contact a registry. Existing secrets, configuration keys, and deployment keys are never overwritten, so package upgrades do not rotate live credentials or change the registered deployment by surprise.

The package should avoid aggressive system upgrades. Server convenience tools should be installed only when missing, and only in the smallest useful set.

Target helper tools:

- curl
- jq
- gnupg
- ufw
- ncdu
- iotop
- redis-tools
- mongosh

Systemd units come from the packaging dependency. `config/packaging/systemd.json` selects the display name; the existing release project policy supplies package identity and numeric ownership. Compose definitions live in `config/packaging/compose`.

## Native nginx policy

Implementation, configuration and container tests live in the pinned
[shared nginx repository](https://github.com/fssrepository/myscoutee-nginx).

| State | Location | Update |
| --- | --- | --- |
| Operator IP/message list | `/etc/myscoutee/nginx/nginx-blocked-ips.json` | Native nginx background refresh, no reload |
| Scanner findings and basic traffic stats | `myscoutee-nginx-state-v1` Docker volume | Native background persistence |
| Allowed coordinates and endpoint inventory | nginx image | Rebuilt from application source |

Each exact IPv4/IPv6 address maps to its own nonempty single-line 403 message
(up to 1000 UTF-8 bytes). Generic installations start with `{}`. Operator edits
and the state volume survive package upgrades and normal removal; purge removes
the package-owned volume. Updates retire the previous Python worker/timer.

100 unknown-route attempts within ten minutes permanently block that source IP.
Removing its entry from `scanner-blocked-ips.json` in the state volume clears the
automatic ban without an nginx reload. Manual bans take message precedence.
Initial operator policy is supplied by the consuming application configuration.
