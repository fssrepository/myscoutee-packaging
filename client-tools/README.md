# MyScoutee Operator client tools

These release-packaged tools manage a Debian deployment. The normal DEB
wrappers delegate installation policy, host qualification and diagnostics to
the installed package. The partial image helper below separately persists a
service image selection, without rebuilding or reinstalling the DEB.

## Configure

In a source checkout, install the pinned dependency with
`npm --prefix config/packaging ci --ignore-scripts`. Run a client through
`npm --prefix config/packaging run client -- install PACKAGE.deb` (or `purge`,
`forward-localhost`, `verify-release`, `install-temporary-image`). The source
configuration lives in
`config/packaging/release-project.json`, and the client configuration lives in
`config/packaging/client-tools/`. Copy that directory's `install.env.example`
to `install.env` and restrict it to mode `0600`. The scripts use it by default;
`CONFIG_FILE` can select another target. Local Netcup/VMware environment files
stay in the same ignored configuration directory.

In a downloaded client-tools archive, configuration stays beside the scripts:

```bash
cp install.env.example install.env
chmod 0600 install.env
```

Set `REMOTE_HOST`, `REMOTE_USER`, and either `REMOTE_KEY_FILE` or
`REMOTE_PASSWORD`. `install.env` is local secret input and must never be
committed or included in a release.

## Prepare a Debian 13 minimal host

Run the separate `prepare-debian13-minimal.sh` before installing the application
DEB on a fresh Debian 13 AMD64 server. Copy it to the target and execute it there
as root (replace `SERVER_IP` with the verified SSH target):

```bash
scp prepare-debian13-minimal.sh root@SERVER_IP:/root/
ssh root@SERVER_IP 'bash /root/prepare-debian13-minimal.sh'
```

This explicit preparation step installs the required system packages and Docker
CE with its Compose plugin from Docker's official Debian repository. It checks
the OS and architecture, refuses conflicting container-runtime packages without
removing them, and can be rerun after completion. It does not install MyScoutee,
configure its domain, alter SSH access, or enable a firewall. With a non-root
SSH user, copy the script to that user's home directory and run it with `sudo`.

The regular `install.sh` and DEB hooks never invoke this preparation script.
After it succeeds, continue with the normal installation below.

From a source checkout, rebuild only this small helper archive with:

```bash
MYSCOUTEE_VERSION=1.0.0 npm --prefix config/packaging run client-tools
```

This does not build or modify a DEB or any container image. A helper-only
release may be newer than the client-tools copy embedded in an existing DEB;
use the separately downloaded, signed helper archive for the latest host
preparation script.

## Partial update from GHCR, run on the server

`install-temporary-image.sh` is an opt-in persistent partial image update for an existing
running DEB deployment. Run it **on the deployment server**, from the separately
downloaded and signature-verified client-tools archive. It does not replace the
normal `install.sh` or DEB lifecycle, reset demo data, or record a different
installed DEB. It changes only the selected service image key in the existing
deployment environment (`/etc/myscoutee/myscoutee.env` on a packaged host). Do not run it concurrently with a
normal package installation or HTTPS configuration operation.

First authenticate Docker on the server for private images:

```bash
sudo docker login ghcr.io -u YOUR_GITHUB_USERNAME
```

Paste a GitHub classic token with `read:packages` at the password prompt. The
account must have access to the selected Package, including any required
organization authorization. Keep the token in a password manager, outside this
archive, shell command arguments, Git and logs. If no Docker credential helper
is configured, Docker stores the login in the invoking user's Docker config;
use a dedicated read-only token on the server. Publishing uses a different
credential with `write:packages`. Public GHCR images do not require login.

After rotating or revoking a token, repeat the server-side `sudo docker login`
and verify a digest pull in a fresh login session. A registry `denied` response
can be an invalid saved credential, independently of Compose. This host login
is not embedded in the DEB or replaced by a package upgrade. Application images
inside the normal DEB are loaded from its verified image archive; partial GHCR
updates use the server-side Docker login.

Select one compatible service image and its exact digest from the trusted
publisher. For example, on the server:

```bash
sudo bash install-temporary-image.sh install nginx   ghcr.io/fssrepository/myscoutee-nginx@sha256:REPLACE_WITH_VERIFIED_DIGEST
sudo bash install-temporary-image.sh status nginx
sudo bash install-temporary-image.sh rollback nginx

# Separate backend update, using its own verified digest:
sudo bash install-temporary-image.sh install profilemanagement   ghcr.io/fssrepository/myscoutee-api@sha256:REPLACE_WITH_VERIFIED_DIGEST
```

| Service argument | Container image | GitHub repository association |
| --- | --- | --- |
| `nginx` | `ghcr.io/fssrepository/myscoutee-nginx` | `fssrepository/myscoutee` |
| `profilemanagement` | `ghcr.io/fssrepository/myscoutee-api` | private `fssrepository/myscoutee-backend` |
| `registry` | `ghcr.io/fssrepository/myscoutee-registry` | private `fssrepository/myscoutee-registry` |
| `payment-simulator` | `ghcr.io/fssrepository/myscoutee-payment-simulator` | See the Package's repository association |
| `minio` | `ghcr.io/fssrepository/myscoutee-minio` | See the Package's repository association |
| `mongodb` | `ghcr.io/fssrepository/myscoutee-mongodb` | See the Package's repository association |
| `redis` | `ghcr.io/fssrepository/myscoutee-redis` | See the Package's repository association |

The separately published `myscoutee-nginx-base` is a build dependency, not a
running service; it has no standalone container to restart. The Registry in
this table is the MyScoutee Registry application. GHCR is the image registry.
Images are GitHub Packages associated with repositories, not Git files or DEB
Release attachments. Repository association and Package visibility are separate.

The helper pulls before replacing anything, checks the current Compose owner,
platform, publisher service/package-version labels, and frontend content version
when applicable. For MongoDB and Redis it also requires the installed upstream
image version: this command is not a database migration tool. Keep application
and database changes compatible with the existing configuration and data; health
checks do not prove schema compatibility. A single invocation updates exactly
one service using the existing Compose files and replica-set overlay, with
`--no-deps --no-build --pull never`, then waits for health.

Mutable tags are refused: even when the application stays `1.0.0`, a new digest
selects new content. The helper atomically saves that digest in the canonical
environment file before Compose recreates the container. It retains the file
owner, mode and `.env` symlink, and leaves unrelated keys unchanged. No
force-version switch is needed. On failure it attempts to restore both the
previous image setting and the previous local image.
State is root-only at `/var/lib/myscoutee/temporary-images/SERVICE/state.json`;
nginx retains `/var/lib/myscoutee/temporary-frontend/state.json`. Inspect `status`
to check both the running image and its persistent selection.
A later patch can be installed directly without first rolling back; explicit
`rollback` restores the immediately preceding selection. Reapplying the same
healthy digest is a no-op. Rollback refuses to overwrite a container or image
setting replaced by another deployment. Keep the previous image locally; do not prune it. If an interrupted Docker operation
leaves the container absent, use the normal deployment recovery procedure.

`install-temporary-frontend.sh` is a convenience wrapper selecting the frontend
service from the project configuration (`nginx` for this project);
keep it beside `install-temporary-image.sh` when copying the helpers.

The project manifest selects which helpers are included in its release. The
service/image examples below describe the backend configuration; only services
selected by the current project are available.

The `clientTools` section of `release-project.json` selects deployment paths,
Compose files, supported service mappings and the frontend/database/stopped-API
checks. Managed service mappings refer to the existing `images` inventory;
MongoDB and Redis have explicit mappings because they are not bundled application
images. This configuration is included beside the helpers in a release archive.
The helper performs no database migration or seed synchronization.

The selected image survives normal MyScoutee service restarts and host reboots,
including patches that retain application version `1.0.0`. The historical
`install-temporary-*.sh` filenames are retained for compatibility; successful
updates are now persistent. For an update made with the earlier runtime-only
helper, run `install` again with the currently running digest to persist it.

A subsequent normal DEB installation may intentionally replace the image
selection with its packaged version. Partial updates leave the recorded DEB
hash and bundled-image manifest unchanged. Verify public HTTPS after the update:

```bash
node verify-deployment/run.mjs \
  --url https://YOUR_DOMAIN --expected-version 1.0.0 --demo-session
```

For a frontend replacement, reload the browser after its service worker has
received the new bundle. An open tab may still show the previous UI even though
the server already runs the new digest. Check `/app-version.json` and the loaded
UI, not just the unchanged `1.0.0` version string.

## Install or reinstall

For a trusted local source build on a QA host, transfer a checksum-verified
`docker save` archive, load it, then run
`install-temporary-image.sh install-local SERVICE sha256:IMAGE_ID` with the exact
image ID reported by `docker image inspect` on that target host. This uses the same compatibility, health, persistent-selection
and rollback checks without a registry pull. Mutable local tags are refused.
Keep the source revision/worktree and artifact checksums with the QA receipt.

```bash
./install.sh /path/to/myscoutee_1.0.0_amd64.deb
```

The wrapper validates the package name and version, uploads it, then calls the
package-provided `qualify-deployment.sh`. Fresh installs and version changes
use APT. An already installed copy of the same version is unpacked over the
existing payload, then configured with APT dependency repair and
`--no-remove`; it is never removed first.

For a GitHub Release, download the DEB, `myscoutee-release_<version>.json`, and
the release public key. Configure `RELEASE_MANIFEST_PATH`,
`RELEASE_PUBLIC_KEY_PATH`, and the complete
`RELEASE_PUBLIC_KEY_FINGERPRINT=sha256:<64 hex>` obtained through an
independent channel. `install.sh` verifies the size, SHA-256, canonical
Ed25519 signatures, key ID, package identity, and full trusted-key fingerprint
before uploading anything.

The release public key shipped next to an artifact does not establish its own
trust. Do not copy the fingerprint from the same GitHub Release page as the
only verification step.

A package built directly from a trusted local checkout has no release
signature. It can be installed only with the explicit local configuration:

```text
ALLOW_UNSIGNED_LOCAL_PACKAGE=true
```

Never use that override for a downloaded or published artifact.

## Verify the deployment

Deployment transport and browser-facing integrity must be tested from the
client, after installation:

```bash
node verify-deployment/run.mjs \
  --url https://deployment.example \
  --expected-version 1.0.0
```

The helper archive published beside the DEB includes this read-only deployment
verifier. It validates normal TLS trust and has no insecure mode.

## SSH tunnel

```bash
sudo -E ./forward-localhost.sh
```

The default forwards bind only local loopback:

```text
127.0.0.1:80  -> remote 127.0.0.1:80
127.0.0.1:443 -> remote 127.0.0.1:443
```

To avoid privileged local ports, use an explicit one-shot mapping:

```bash
LOCAL_FORWARD_PORTS_OVERRIDE=18080:80,18443:443 \
  ./forward-localhost.sh
```

Then deployment verification can run through the high-port tunnel:

```bash
NODE_EXTRA_CA_CERTS=/path/to/deployment-bootstrap-ca.pem \
  node verify-deployment/run.mjs \
    --url https://localhost:18443 \
    --expected-version 1.0.0
```

The custom HTTPS port intentionally leaves out `--http-url`: the production
HTTP redirect targets the deployment's canonical HTTPS origin, not the
client-side remapped port. The HTTPS, frontend, backend, i18n, and anonymous
Operator-boundary checks still run; the three HTTP-listener checks are skipped.

## Explicit purge

```bash
./purge.sh
```

This invokes `apt-get purge myscoutee` remotely. Package lifecycle scripts own
the scoped Compose, volume, image, configuration, and state cleanup. Backups
under `/var/backups/myscoutee` remain outside the purge contract.

## Installed host commands

The Debian package installs operational commands under:

```text
/opt/myscoutee/packaging/scripts/
```

The main entry points are:

- `status-production.sh`
- `doctor-production.sh`
- `qualify-deployment.sh`
- `deployment-diagnostics.sh`
- `backup-production.sh`
- `restore-production.sh`
- `start-production.sh`
- `stop-production.sh`

The package `postinst` never runs deployment qualification or public smoke
automatically.

### Cross-version container-only updates

An image from a newer application release is accepted only when its publisher
labels explicitly list the installed host package in
`io.myscoutee.compatible-package-versions` (comma-separated exact versions).
`io.myscoutee.package-version` and frontend `app-version.json` must describe the
new image release. The installed DEB version remains unchanged. Complete and
verify that release's documented data migrations/system-seed synchronization
before applying images; this helper performs neither operation automatically.

## Template: upgrading the initial 1.0.0 template

Use the signed client installer for the one-time move to 1.4.0. It stops the old
stack before replacing its files, migrates the template runtime account from
10001 to 10002, and preserves file contents, modes, secrets and data. A conflicting
foreign account is rejected. After this host migration, use the normal in-app
updater. The old worker cannot safely change its own running numeric identity.
