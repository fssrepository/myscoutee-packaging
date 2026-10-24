# MyScoutee packaging

Shared npm package for the backend and template operator clients and client
archive builder, plus the existing release-signing and archive-audit mechanisms.
The eight client scripts and their [documentation](client-tools/README.md) have
one source owner here. Product identity, deployment paths, service selections,
client manifests and local environment files remain under each application's
`config/packaging/`. Local credential files are never npm or release payloads.

Both applications pin a packed version with an integrity-checked lockfile, using
the same local tarball pattern as the E2E package. From an application root:

```sh
npm --prefix config/packaging ci --ignore-scripts
npm --prefix config/packaging run client -- install --help
MYSCOUTEE_VERSION=1.4.0 npm --prefix config/packaging run client-tools
```

From this repository, create the local dependency artifact with
`npm pack --pack-destination build/repository`. `npm test` verifies the packed
package independently for both product configurations. Publishing is separate.

Product compatibility history stays in each project's
`config/packaging/release/update-compatibility-policy.json`. The existing
release-project policy remains a project input; the external verifier is shared.

From the selected application root:

```sh
python3 ../myscoutee-packaging/release/signing/prepare-release.py --help
bash ../myscoutee-packaging/tests/integration/release-signing-test.sh
python3 ../myscoutee-packaging/tests/integration/release-bundle-test.py
```

The bundle/signing CLIs require `--project-root`; the catalog signer requires
`--compatibility-policy`. Select a trusted source checkout, never policy from
the candidate artifact. Supply an existing protected signing key explicitly.
These tools do not generate deployment keys, install packages or publish a
release. Signing domains, validation and key custody retain the existing
implementation. Archive helpers retain their original checks; audit policy data is selected from configuration.

Applications locate this checkout with `MYSCOUTEE_PACKAGING_SOURCE` or the sibling
default. Shared tests select the application with `MYSCOUTEE_PACKAGING_PROJECT`
or the current directory. The source manifest and exact verification boundary
are in [EXTRACTION.json](EXTRACTION.json).

The four Debian maintainer scripts and control template have one source in
`debian/`. Applications supply `config/packaging/debian/control.json` (description
and optional metadata overrides) and `purge-policy.json` (selected external
volumes). Identity, runtime UID/GID and managed images reuse `release-project.json`.
Shared `debian/defaults.json` contains the original control metadata, bootstrap
TLS settings, Mongo database name and prerequisite-image defaults. A product may
override selected lifecycle fields in `config/packaging/debian/lifecycle.json`
with `schemaVersion: 1`; omitted fields retain the common values. Configuration
is validated and embedded when assembling the package. Hooks remain self-contained,
including before unpack and after removal of `/opt`.

```sh
python3 config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/render-debian.py \
  packaging build/deb-root/DEBIAN --hook all --version 1.4.0 --architecture amd64
```

Project migration scripts and their pinned inputs stay under each application's
`config/packaging/migrations/`; packages retain the existing installed migration
paths. Image assembly, remaining runtime payloads and Registry integration still
retain the installed application contracts. Release assembly is owned by this
package, including the selected host-tool payload.

Release scripts read shared `release/lib/defaults.json` and project overrides from
`config/packaging/release/settings.json`. These select build tasks, the pinned
nginx image, publication registry, Mongo seed directory names and audit URL
exceptions. Existing environment overrides retain precedence. The release image
inventory remains in `release-project.json`, and official-image defaults reuse
the Debian lifecycle configuration.

Project runtime selections are in `config/packaging/release/runtime-scripts.json`.
Seed-audit selection and the original jq predicates live in `seed-audits.json`
and `seed-audits/`; `release/audit/audit-project-seeds.sh` owns their common runner.
Backend partial-release and qualification settings stay in its `settings.json`.
Partial archives carry the selected `partial-data.json` and release identity,
so applying them requires no npm dependency on the target host. Signature
domains, key validation and credential-rejection mechanisms remain code.

Build, package, audit, publish, rebuild and artifact-qualification scripts have
one source in this package's `release/` directory. Both applications invoke the
locked dependency, without local release script copies or forwarding files:

```sh
npm --prefix config/packaging run release -- build-production
BUILD_ARTIFACTS=false npm --prefix config/packaging run release -- package-production
npm --prefix config/packaging run release -- audit-package-credentials /path/to/deb-root
```

The CLI binds `MYSCOUTEE_PACKAGING_PROJECT_ROOT` for source/configuration inputs;
peer tools are resolved from the dependency itself. Project-specific release
history and instructions remain in each application's guides.

Runtime tools are grouped by responsibility: `runtime/host`, `runtime/update`,
`runtime/data` and `runtime/recovery`. Release tools use `release/build`,
`release/signing`, `release/audit` and `release/lib`. Compose execution and host
verification retain their existing `compose` and `verification` owners.

`config/packaging/runtime-inputs.json` selects the installed basenames and any
project inputs. Available shared tools do not have to be selected by every
application: the template excludes Registry tools. Its no-op Registry recovery
hook remains an explicit selection. Both products use the same migration runner;
the media migration is selected by the existing release settings.

Project host checks, seed selection and the backend Facebook patch input remain
under `config/packaging`. `release-project.json.hostTools` configures Registry
paths, startup fallback version and TLS URL settings.
Runtime UID/GID reuse the existing identity fields. Existing environment
variables keep precedence. Protocol identifiers, cryptographic domains, input
validation and the fixed demo-reset database guard remain implementation rules.

```sh
npm --prefix config/packaging run prepare-runtime
npm --prefix config/packaging run runtime -- status-production.sh
```

The source view is generated under `build/scripts`; it contains exact selected
source bytes rather than forwarding scripts. Prepare it before standalone host
unit tests. Debian packages retain their existing `/opt/<package>/packaging/scripts`
paths, and partial archives remain self-contained.

The nine systemd units and sysusers account definition have shared templates in
`systemd/` and `sysusers/`. Applications supply `config/packaging/systemd.json`
for the display name; package name and numeric identity reuse `release-project.json`.
The existing renderer handles `--component systemd` and `--component sysusers`.
All twenty original product files render byte-identically, including their
installed names and non-executable modes.

Compose definitions are project data under `config/packaging/compose`. The
builder preserves the existing installed server filenames and replica override.
The backend's STUN symlink follows its existing server owner from the new location.

The runtime migration runner reads `migration-settings.json`, assembled from
the existing `release/settings.json` owner. Full and partial packages carry the
same configuration. Partial application validates and installs this input before
future startup use; it also preserves an existing copy with the prior package
inputs. The runner works with an older installed release identity/helper and
requires no change to their policy schema.

Deployment environment/secret placeholders, install policy and key instructions
live in each application's `config/packaging/templates`. The renderer's
`--component templates` selects the four original package inputs. Other assets,
such as the backend Facebook patch input, retain their own selected runtime
location. Moving this directory preserves all installed payload bytes and modes.

The entire consumer test selection lives in `config/packaging/tests/selection.json`.
Shared mechanisms are grouped under `tests/consumer/{client,debian,deployment,mongo,release,runtime}`
(only populated categories exist), with isolated source tests under `tests/unit`
and packed-package/signing tests under `tests/integration`. Product-specific
migration/data assertions remain in each application's `tests/packaging/` categories.
`config/packaging/tests/release-project.json` owns native expected identity and
image/client cases. No source forwarding files remain under application packaging.

```sh
npm --prefix config/packaging test -- --list
npm --prefix config/packaging test -- install-policy-test.py
npm --prefix config/packaging run verify -- --list
npm --prefix config/packaging run verify -- --url https://deployment.example
```

The manual public verifier and optional browser smoke have one implementation in
[verification/public](verification/public/README.md). `config/packaging/verification.json`
selects the existing public content contract and JS/CSS cache policy. Client
archives carry that selected configuration beside the verifier and run outside
the checkout. Neither command runs automatically during packaging, installation,
CI, aggregate tests or manual QA. Tests exercise local fixtures and parser/help
paths without starting an application or contacting a deployed target.

Shared [host operations](docs/production.md) and [update progress](docs/update-progress.md)
documentation live with these mechanisms. Product release evidence and Registry
composition stay in the application's existing development guides. Checkout
release outputs and backups use `build/packaging/dist`; existing output trees
were moved intact. Installed `/opt/<package>/packaging` paths are unchanged.

Standalone provisioned container stacks select `myscouteePackaging.profile:
"container-stack"` in their consuming `config/packaging/package.json`. This
selects the existing install/start/retention workflow, independently of the
application language. `container-stack.json` owns public identity, UID/GID,
image names and signature domains. `build-contexts.json` supplies the exact
filesystem inputs for each Docker context; the Dockerfiles stay project data.
`release/build/render-container-stack.py` binds the preserved lifecycle/client
mechanisms to that metadata under `build/`. Original maintainer scripts,
systemd unit, host qualification/Compose tools and signature verifier render
byte-identically for the Registry configuration.

The Registry uses the common SSH transport, image fingerprint and forwarding
implementation. Its `client-tools/forward.json` retains high-port defaults,
privileged-port refusal and its original start behavior. Its explicit first-start
TLS provisioning, no-automatic-start installation, retained SQLite/key state,
plain-version rule and signature domains remain intact. Its public Registry
protocol verifier stays under `tests/deployment/verify`, selected as a project
input; it is independent from application manual QA and automated E2E flows.

The common static seed parity audit lives in
`release/audit/check-seed-parity.py`. From an application root, run
`npm --prefix config/packaging run seed-parity -- [--packaged-root PATH]`.
Applications invoke the package command directly. Collection classifications,
declarative parity rules and their expected values live in each application's
`config/packaging/tests/release-seeds.json`.
The audit reads source files only.

Shared test runners are selected explicitly by each consumer. Public expected
counts, collection selections, index/TTL cases, artifact inventories and build
contracts live under `config/packaging/tests`. The common Mongo adapter has one
source under `tests/lib`. Migration, data and host contracts live under the
shared `tests/consumer`, selected explicitly by each project. Input locations,
expected counts, selected languages and host policy values live in project JSON
configuration. The consumers have no local packaging test implementations. Ordinary tests do
not start application containers, databases or VMs; runtime/image cases remain
explicit selections.

Shared checkout utilities are invoked directly through the same packaging CLI:

```sh
npm --prefix config/packaging run development -- purge-local-datastores --dry-run
npm --prefix config/packaging run qa-release -- reversion-qa-artifacts --help
npm --prefix config/packaging run qa-release -- sign-qa-release --help
npm --prefix config/packaging run qualification -- measure-runtime --help
npm --prefix config/packaging run seed-image-variants -- --source /path/to/image --kind profile --key selected
npm --prefix config/packaging run synchronize-seed-profile-details -- --check
```

The implementations live in `runtime/development`, `release/qa`,
`verification/qualification` and `release/seeds`. Qualification names, paths,
ports and probe cases are data in `qualification.json`;
image variants are selected by `seed-images.json`; historical QA release
selection lives in `release/qa.json`. Operational tools remain explicit manual
commands. Merely installing the dependency executes none of them.

`release/seeds` also owns configurable e-mail assignment, deterministic distance
filling and profile-detail synchronization. Their file selections, identity fields,
counts, domains and builder selections are project JSON data. The backend's event
image pools, event-chat repair, community counter projection and screen-specific
help illustrations remain application implementations under
`config/packaging/seeds/scripts`, with project data under `seeds/data`. Its npm scripts invoke each owner directly.
