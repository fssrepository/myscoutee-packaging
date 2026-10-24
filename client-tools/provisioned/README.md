# MyScoutee Registry Operator client tools

These client-side wrappers manage the package-provided two-image Docker
deployment on a remote Debian host. They are distributed in
`myscoutee-registry-client-tools_<version>.tar.gz`; verify and extract that
archive on the administrative client before use. The Debian package carries
only the same versioned archive at
`/usr/share/myscoutee-registry/myscoutee-registry-client-tools_<version>.tar.gz`,
not expanded copies of these
scripts. Do not run the wrappers from the Registry host. Host qualification
remains a separate command shipped under the installed server payload.

## Configure

```bash
cp install.env.example install.env
chmod 0600 install.env
```

Set `REMOTE_HOST`, `REMOTE_USER`, and either `REMOTE_KEY_FILE` or
`REMOTE_PASSWORD`. `install.env` is local secret input. It is ignored by Git
and must never be committed or included in a release artifact.

## Install or reinstall

```bash
./install.sh /path/to/myscoutee-registry_1.3.0_amd64.deb
```

The wrapper validates the package identity and version, uploads it to a simple
`.deb` path directly under `/tmp`, and invokes package installation through
`sudo`. Fresh installs and version changes use APT. The same installed version
is refreshed with `dpkg --unpack`, then configured with APT dependency repair
and `--no-remove`; the package is not removed first. Installation defaults to
`START_SERVICE=false`, so it never starts or restarts a fresh Registry using
placeholder identity configuration.

For a signed release, configure `RELEASE_MANIFEST_PATH`,
`RELEASE_PUBLIC_KEY_PATH`, and the complete
`RELEASE_PUBLIC_KEY_FINGERPRINT=sha256:<64 hex>` obtained through an
independent channel. The installer verifies package identity, size, SHA-256,
canonical Ed25519 metadata, key ID, and the complete trusted-key fingerprint
before uploading anything.

A package built directly from a trusted local checkout has no release
signature. It can be installed only with this explicit local setting:

```text
ALLOW_UNSIGNED_LOCAL_PACKAGE=true
```

Never use that override for a downloaded or published artifact.

For a first start, copy and protect the deployment example, set the permanent
scope and public hostname, and provide the matching TLS inputs:

```bash
cp deployment.env.example deployment.env
chmod 0600 deployment.env

# In install.env:
START_SERVICE=true
DEPLOYMENT_ENV_FILE=/absolute/path/to/deployment.env
TLS_CERTIFICATE_FILE=/absolute/path/to/fullchain.pem
TLS_PRIVATE_KEY_FILE=/absolute/path/to/privkey.pem
```

The deployment env and TLS private key must be regular, non-symbolic-link
files with mode `0600` or `0400`. The wrapper rejects the example scope and
hostname, checks the package version and image references, validates
certificate validity, hostname coverage, and the certificate/key match, then
uploads all three inputs into a protected temporary directory. It installs
them as root-owned configuration before calling the package-provided
`qualify-deployment.sh restart-and-check`. Secret contents are never placed in
arguments or logs.

Without `START_SERVICE=true`, the package is installed and the next operator
command is printed, but the runtime is not started. A previously inactive
runtime is never started without the explicit provisioning inputs. An already
active, valid deployment may be restarted after a reinstall only with the
explicit `START_SERVICE=true` setting.

## External verification

The installer never invokes the browser-facing verifier. When
`VERIFY_DEPLOYMENT_URL` is configured, it only prints the separate command:

```bash
node verify-deployment/run.mjs \
  --url https://registry.example \
  --expected-version 1.3.0
```

Run it from the client after installation so it remains an external transport
check.

## Loopback tunnel

```bash
./forward-localhost.sh
```

The default high-port forwards bind only local loopback:

```text
127.0.0.1:18443 -> remote 127.0.0.1:443
127.0.0.1:18080 -> remote 127.0.0.1:80
```

For a deployment using custom remote public ports:

```bash
LOCAL_FORWARD_PORTS_OVERRIDE=19444:18444,19082:18082 \
  ./forward-localhost.sh
```

The Registry backend remains on the internal Docker network and is not a
tunnel target. Privileged local ports are refused.

## Explicit package purge

```bash
CONFIRM_PURGE_WITH_VERIFIED_BACKUP=true ./purge.sh
```

The wrapper requires explicit confirmation that an independently stored
recovery-unit backup has been verified. It invokes `apt-get purge
myscoutee-registry` and checks that the package is no longer installed; it
issues no direct data deletion command. The package purge lifecycle does
remove managed configuration, TLS material, SQLite state, signing/VOPRF keys,
and configured managed images. Independent backups are not touched.
