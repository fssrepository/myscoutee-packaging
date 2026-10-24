# Update progress during application restart

The shared Operator popup remains in the loaded frontend. After explicit Apply
or Rollback, the authenticated API returns a random, job-scoped read capability
with the accepted job. Only its SHA-256 digest and one-hour expiry are stored
beside that job's staging status. The bearer stays in browser memory; it is never
put in a URL, persistent browser storage, worker request, status or event log.

Production nginx serves `/operator-update-status/{jobId}` through a Unix socket
to `myscoutee-update-status.service`. This small Python standard-library service
runs as the non-login account and numeric identity selected by
`config/packaging/release-project.json` (`myscoutee-runtime`, UID/GID10001
for the backend),
created by the package through systemd-sysusers. Two read-only filesystem binds
expose only staging and worker status directories inside its private namespace;
the protected parent directories keep their original permissions. It runs under
systemd filesystem/capability restrictions. It has no
database, Docker, package-manager or application-API dependency. It verifies the
capability and reads bounded regular JSON files, refusing symlink components.
Worker status takes precedence over API staging status. Only progress/version
fields and the public rollback identity are returned; actor identity, internal
errors and install logs are omitted. The worker includes its retained recovery
point so the popup can display recovery immediately even while the API is down.
The service supports no mutation. Invalid/expired capabilities receive404.
It opens no TCP port and does not create another public origin or TLS identity.

During a signed update, `restart-update-stack.sh` stops the application, refreshes
the existing package-owned demo/static seeds and updates the dependent services.
The existing nginx stays up while the backend starts. Once the backend is healthy,
the bundled nginx is replaced last. Requests retry the brief ingress replacement
gap with the same job and capability; they never repeat Apply. A failed backend
start leaves the previous ingress and independent progress route available.
The worker declares100% only after exact bundled-image and health verification.
No database/media backup or restore is introduced.

The package and restart helper emit fixed milestones for configuration, image
loading/verification, data preparation, service startup, health checks and the
ingress switch. The worker records each milestone as durable progress; these
percentages describe phases, not measured completion of each individual command.

The capability is issued before staging starts, so an accepted action can be
followed without requesting another credential from a restarting API. After a
full browser reload, ordinary Operator authentication/status loading applies;
this capability is intentionally not retained. Non-production stacks without
the independent reader keep the existing authenticated API progress path.

The status service is socket-activated and separately updated in package
configuration. Package removal stops its socket/service. No versioned package
is complete unless it contains both units, the reader, nginx route and rolling
restart helper. Tests cover source/worker status precedence, live file changes,
terminal state, capability scope/expiry, rejected mutations/symlinks, and ingress
retention on backend failure. Live update/rollback remains a separate release gate.
