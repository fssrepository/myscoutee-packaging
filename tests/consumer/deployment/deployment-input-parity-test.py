#!/usr/bin/env python3
"""Compare installed inputs with the source/DEV owners, without starting services.

Use the builder's deb-root directory, optionally verify every actual DEB byte
against it and inspect the exact bundled images. Generated deployment secrets,
operator state and runtime volumes are not source files.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())).resolve()


def host_files(component):
    renderer = ROOT / 'config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/render-debian.py'
    values = json.loads(subprocess.check_output(['python3', str(renderer), str(ROOT / 'packaging'), '-', '--component', component]))
    return {name: text.encode() for name, text in values.items()}



def run(*args):
    return subprocess.check_output(args)


def digest(value):
    return hashlib.sha256(value).hexdigest()


def files(path):
    return {str(p.relative_to(path)): p.read_bytes() for p in path.rglob('*') if p.is_file()}


def equal_files(expected, actual, label):
    missing, extra = expected.keys() - actual.keys(), actual.keys() - expected.keys()
    changed = [name for name in expected.keys() & actual.keys() if expected[name] != actual[name]]
    assert not (missing or extra or changed), f'{label}: missing={sorted(missing)}, extra={sorted(extra)}, changed={sorted(changed)}'
    print(f'PASS: {label}: {len(expected)} files')


def image_files(container, path):
    archive = run('docker', 'cp', container + ':' + path, '-')
    with tarfile.open(fileobj=io.BytesIO(archive)) as stream:
        return {entry.name.split('/', 1)[-1]: stream.extractfile(entry).read()
                for entry in stream if entry.isfile()}


def audit_images(installed):
    manifest = json.loads((installed / 'packaging/IMAGE-MANIFEST.json').read_text())
    nginx_error_page = None
    nginx_shared_scripts = {}
    for row in manifest['images']:
        actual_id = run('docker', 'image', 'inspect', '--format', '{{.Id}}', row['reference']).decode().strip()
        assert actual_id == row['imageId'], f'image changed: {row["reference"]}'
        container = run('docker', 'create', row['imageId']).decode().strip()
        try:
            if row['service'] == 'nginx-base':
                nginx_error_page = next(iter(image_files(container, '/usr/share/nginx/html/50x.html').values()))
                nginx_shared_scripts = image_files(container, '/scripts/.')
            elif row['service'] == 'nginx':
                assert nginx_error_page is not None, 'base image must precede the frontend image'
                expected_frontend = {'50x.html': nginx_error_page, **files(ROOT / 'frontend/prod')}
                equal_files(expected_frontend, image_files(container, '/usr/share/nginx/html/.'), 'production frontend assets and unchanged base error page')
                nginx = ROOT / 'config/nginx'
                pairs = {'nginx.conf': '/etc/nginx/nginx.conf',
                         'http/spring.conf': '/etc/nginx/myscoutee-templates/spring.conf',
                         'stream/mongodb.conf': '/etc/nginx/stream_conf.d/mongodb.conf'}
                for path in ['runtime-status.conf', 'update-status.prod.conf', 'http-transport-policy.prod.conf', 'https-response-policy.prod.conf']:
                    pairs['http/' + path] = '/etc/nginx/conf.d/' + path.replace('-policy.prod', '-policy')
                for source, target in pairs.items():
                    assert list(image_files(container, target).values()) == [(nginx / source).read_bytes()], source
                routing = (nginx / 'http/routing.conf').read_bytes() + b'\ninclude /etc/nginx/conf.d/update-status.prod.conf;\n'
                assert list(image_files(container, '/etc/nginx/conf.d/routing.conf').values()) == [routing]
                equal_files(nginx_shared_scripts, image_files(container, '/scripts/.'), 'inherited common nginx scripts')
                print('PASS: Nginx project routes, transport policy and inherited shared scripts')
            elif row['service'] == 'minio':
                equal_files(files(ROOT / 'server/docker/conf/minio'), image_files(container, '/seed/.'), 'DEV media seed → production image')
                for name in ['bootstrap_minio_seed.sh', 'start_minio_with_seed.sh']:
                    assert list(image_files(container, '/scripts/' + name).values()) == [(ROOT / 'server/docker/scripts' / name).read_bytes()]
                print('PASS: MinIO bootstrap scripts')
            elif row['service'] == 'profilemanagement':
                identity = json.loads((ROOT / 'config/packaging/release-project.json').read_text())['runtimeIdentity']
                actual_user = run('docker', 'image', 'inspect', '--format', '{{.Config.User}}', row['imageId']).decode().strip()
                assert actual_user == f"{identity['uid']}:{identity['gid']}", 'API image and host runtime ownership disagree'
                jar = next(iter(image_files(container, '/app/spring-boot-application.jar').values()))
                expected = ROOT / ('server/projects/profile/build/libs/profile-' + manifest['releaseVersion'] + '.jar')
                assert digest(jar) == digest(expected.read_bytes()), 'API image has a stale JAR'
                with zipfile.ZipFile(io.BytesIO(jar)) as archive:
                    for name, content in files(ROOT / 'server/projects/profile/src/main/resources').items():
                        assert archive.read('BOOT-INF/classes/' + name) == content, 'JAR resource: ' + name
                print('PASS: exact built JAR and all source classpath resources (including DEV/PROD configuration)')
            else:
                entrypoint = json.loads(run('docker', 'image', 'inspect', '--format', '{{json .Config.Entrypoint}}', row['imageId']))
                if entrypoint and entrypoint[0].startswith('/'):
                    assert image_files(container, entrypoint[0]), 'missing image entrypoint'
            print('PASS: bundled image identity and input check: ' + row['service'])
        finally:
            subprocess.run(['docker', 'rm', '-v', container], check=True, stdout=subprocess.DEVNULL)


def audit_deb(deb, stage):
    # Read the full artifact, including the image archives. No deployment starts.
    expected = {str(p.relative_to(stage)): p for p in stage.rglob('*') if p.is_file() and 'DEBIAN' not in p.relative_to(stage).parts}
    checked = set()
    process = subprocess.Popen(['dpkg-deb', '--fsys-tarfile', str(deb)], stdout=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=process.stdout, mode='r|') as stream:
            for entry in stream:
                assert entry.uid == entry.gid == 0 and not entry.issym() and not entry.islnk(), entry.name
                if not entry.isfile():
                    continue
                name = entry.name.removeprefix('./')
                assert name in expected, 'unexpected DEB file: ' + name
                with stream.extractfile(entry) as source, expected[name].open('rb') as reference:
                    while chunk := source.read(1024 * 1024):
                        assert chunk == reference.read(len(chunk)), 'DEB bytes differ: ' + name
                    assert not reference.read(1), 'truncated DEB file: ' + name
                assert entry.mode == expected[name].stat().st_mode & 0o777, name
                checked.add(name)
        assert process.wait() == 0 and checked == expected.keys(), 'DEB inventory differs from verified stage'
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.terminate()
            process.wait()
    print(f'PASS: actual DEB bytes, modes, ownership and complete inventory: {len(checked)} files')
    with tempfile.TemporaryDirectory() as directory:
        subprocess.run(['dpkg-deb', '-e', str(deb), directory], check=True)
        equal_files(files(stage / 'DEBIAN'), files(Path(directory)), 'actual DEB control files')


def audit_environments():
    # Render each actual composition independently. E2E must never inherit DEV
    # services, credentials, source mounts or databases by layering the files.
    probe = dict(os.environ, MYSCOUTEE_VERSION='8.7.6', CHAT_CALL_STUN_PORT='34789',
                 CHAT_CALL_STUN_URLS='stun:fixture.invalid:34789',
                 MYSCOUTEE_UPDATE_TLS_CA_CERTIFICATE='/fixture/ca.pem')
    project = json.loads((ROOT / 'config/packaging/release-project.json').read_text())
    definitions = {
        'dev': ROOT / 'server/docker-compose-dev.yml',
        'prod': ROOT / 'server/docker-compose-prod.yml',
        'e2e': ROOT / 'server/docker-compose.e2e.yml',
        'installed': ROOT / 'config/packaging/compose/docker-compose.production.yml'
    }
    for mode, source in definitions.items():
        command = ['docker', 'compose', '-f', str(source)]
        if mode == 'installed':
            command += ['--env-file', str(ROOT / 'config/packaging/templates' / (project['packageName'] + '.env'))]
        result = subprocess.run(command + ['config', '--no-env-resolution', '--format', 'json'],
                                env=probe, text=True, capture_output=True, check=True)
        services = json.loads(result.stdout)['services']
        api = services['profilemanagement']
        environment = api['environment']
        assert services['mongodb']['ulimits']['nofile'] == {'soft': 64000, 'hard': 64000}, \
            mode + ': Mongo open-file limits must not depend on Docker host defaults'
        assert 'stun' in services, mode + ': missing STUN service'
        assert not any(key.startswith('CHAT_CALL_') for key in services['mongodb']['environment']), mode
        assert environment['SPRING_PROFILES_ACTIVE'] == ('dev' if mode == 'dev' else 'prod'), mode
        if mode != 'e2e':
            assert environment['CHAT_CALL_STUN_PORT'] == probe['CHAT_CALL_STUN_PORT'], mode
            assert environment['CHAT_CALL_STUN_URLS'] == probe['CHAT_CALL_STUN_URLS'], mode
        if mode == 'prod':
            for field in ('uid', 'gid'):
                assert str(api['build']['args']['MYSCOUTEE_API_' + field.upper()]) == str(project['runtimeIdentity'][field]), 'API build ownership differs from package policy'
        if mode in ('prod', 'e2e'):
            assert api['build']['args']['MYSCOUTEE_VERSION'] == '8.7.6', mode + ': release version not passed to Docker build'
        if mode in ('prod', 'installed'):
            assert environment['OPERATOR_UPDATE_TLS_CA_CERTIFICATE'] == '/fixture/ca.pem', mode + ': update CA ignored'
        if mode == 'e2e':
            mongo = services['mongodb']['environment']
            assert mongo['MONGO_SEED_DIRECTORY'] == 'e2e_db'
            assert environment['MONGODB_DATABASE'] == environment['MONGODB_DEMO_DATABASE'] == mongo['MONGO_E2E_DATABASE']
            assert all(volume['type'] != 'bind' for service in services.values() for volume in service.get('volumes', [])), 'E2E contains host/source bind mounts'
        for name, service in services.items():
            assert all(volume.get('target') != '/etc/timezone' for volume in service.get('volumes', [])), \
                mode + ': host /etc/timezone is not a portable file mount; use TZ and /etc/localtime'
            build = service.get('build')
            if build:
                context = Path(build['context'])
                assert context.is_dir(), mode + ': missing build context for ' + name
                assert (context / build.get('dockerfile', 'Dockerfile')).is_file(), mode + ': missing Dockerfile for ' + name
        print(f'PASS: {mode}: composed services, nondefault configuration wiring, version and deployment isolation')
    identity = project['runtimeIdentity']
    account = host_files('sysusers')[project['packageName'] + '.conf'].decode()
    assert re.search(r'^u ' + re.escape(project['packageName']) + r'-runtime '
                     + str(identity['uid']) + r'(?:[:]' + str(identity['gid']) + r')? ', account, re.M), 'sysusers ownership differs from package policy'
    assert identity['uid'] == identity['gid'] or ':' in account.splitlines()[-1], 'distinct group ID must be explicit'
    print('PASS: package policy, system account and production API build ownership agree')
    for profile in ('dev', 'prod'):
        resource = (ROOT / f'server/projects/profile/src/main/resources/application-{profile}.yaml').read_text()
        assert '${EMAIL_SENDGRID_API_KEY:' in resource, profile + ': packaged email secret is ignored'
        assert '${EMAIL_SENDGRID_ENDPOINT:' in resource, profile + ': email endpoint override is ignored'
        if profile == 'prod':
            assert '${EMAIL_BASE_URL:https://localhost}' in resource, 'production email URL lost its HTTPS default'
    for mode in ('prod', 'e2e'):
        dockerfile = (ROOT / f'server/docker/images/profilemanagement/{mode}/Dockerfile').read_text()
        assert 'ARG MYSCOUTEE_VERSION=' in dockerfile, mode
        if mode == 'prod':
            assert re.search(r'^COPY (?:--chown=\S+ )?profile-\$\{MYSCOUTEE_VERSION\}\.jar ', dockerfile, re.M), 'production selects an ambiguous JAR'
        else:
            assert 'ENV MYSCOUTEE_VERSION=${MYSCOUTEE_VERSION}' in dockerfile, 'E2E Gradle build ignores version'
    print('PASS: DEV/PROD email credentials and exact production/E2E build version')


def print_mongo_audit():
    """Emit read-only mongosh inventory; differences require ownership review."""
    cases = json.loads((ROOT / 'config/packaging/tests/deployment-inputs.json').read_text())
    catalog = None
    for selected in cases['indexManifests']:
        incoming = json.loads((ROOT / selected['path']).read_text())
        if catalog is None:
            catalog = incoming
        else:
            replaced = selected.get('replaceCollections', [])
            catalog['indexes'] = [row for row in catalog['indexes'] if row['collection'] not in replaced] + incoming['indexes']
    print('const catalog=' + json.dumps(catalog) + ';')
    print(r'''
function canonical(value) {
    if (value === undefined) return 'undefined';
    if (value === null || typeof value !== 'object') return JSON.stringify(value);
    if (value._bsontype || value instanceof Date) return JSON.stringify(value);
    if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
    return '{' + Object.keys(value).sort()
        .map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}';
}
function record(value) {
    return value && typeof value === 'object' && !Array.isArray(value)
        && !value._bsontype && !(value instanceof Date);
}
function differences(expected, actual, path = '', result = []) {
    if (canonical(expected) === canonical(actual)) return result;
    if (record(expected) && record(actual)) {
        for (const key of Object.keys(expected))
            differences(expected[key], actual[key], path ? path + '.' + key : key, result);
    } else result.push(path);
    return result;
}
try {
    const fs = require('fs');
    const realDatabase = process.env.MONGO_APP_DATABASE || process.env.MONGO_INITDB_DATABASE;
    if (!realDatabase || realDatabase === 'demo_db')
        throw Error('Run this audit in the installed Mongo container with an isolated REAL database.');
    const databases = [['demo_db', 'demo_db'], [realDatabase, 'myscoutee_db']];
    for (const [name, seed] of databases) {
        const target = db.getSiblingDB(name);
        const directory = '/docker-entrypoint-initdb.d/' + seed;
        const inventory = [];
        for (const file of fs.readdirSync(directory).filter(n => n.endsWith('.json')).sort()) {
            const source = EJSON.parse(fs.readFileSync(directory + '/' + file, 'utf8'));
            const collection = target.getCollection(file === 'adminUsers.json' ? 'users' : file.slice(0, -5));
            // One batch read per collection; never a database query per seed row.
            const documents = new Map(collection.find({_id: {$in: source.map(row => row._id)}})
                .toArray().map(row => [canonical(row._id), row]));
            let missing = 0, changed = 0;
            const fields = {};
            for (const row of source) {
                const actual = documents.get(canonical(row._id));
                if (!actual) { missing++; continue; }
                const paths = differences(row, actual);
                if (paths.length) changed++;
                for (const path of paths) fields[path] = (fields[path] || 0) + 1;
            }
            inventory.push({file, seed: source.length, count: collection.countDocuments({}),
                missing, changed, fields});
        }
        print(JSON.stringify({database: name, inventory}));
        const existing = new Map(target.getCollectionNames()
            .map(name => [name, target.getCollection(name).getIndexes()]));
        const missingIndexes = [], differentIndexes = [];
        for (const row of catalog.indexes) {
            const identity = row.collection + '/' + row.options.name;
            const actual = (existing.get(row.collection) || [])
                .find(index => index.name === row.options.name);
            if (!actual) { missingIndexes.push(identity); continue; }
            const changedOptions = ['unique', 'sparse', 'expireAfterSeconds', 'partialFilterExpression']
                .some(key => canonical(actual[key]) !== canonical(row.options[key]));
            // Mongo expands collation defaults. Compare the declared fields and
            // reject an unexpected collation where simple comparison was required.
            const changedCollation = row.options.collation
                ? Object.entries(row.options.collation).some(([key, value]) => actual.collation?.[key] !== value)
                : Boolean(actual.collation);
            if (JSON.stringify(actual.key) !== JSON.stringify(row.key) || changedOptions || changedCollation)
                differentIndexes.push(identity);
        }
        print(JSON.stringify({database: name, missingIndexes, differentIndexes}));
    }
} catch (error) { print(error.stack); quit(1); }
''')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', type=Path, nargs='?')
    parser.add_argument('--environments-only', action='store_true')
    parser.add_argument('--print-mongo-audit', action='store_true',
                        help='emit read-only inventory for the installed Mongo container; review retained/runtime differences')
    parser.add_argument('--deb', type=Path)
    parser.add_argument('--images', action='store_true')
    args = parser.parse_args()
    if args.print_mongo_audit:
        print_mongo_audit()
        return
    if args.environments_only:
        audit_environments()
        return
    if args.stage is None:
        parser.error('stage is required unless --environments-only or --print-mongo-audit is selected')
    project = json.loads((ROOT / 'config/packaging/release-project.json').read_text())
    package = project['packageName']
    installed = args.stage / 'opt' / package
    cases = json.loads((ROOT / 'config/packaging/tests/deployment-inputs.json').read_text())
    for name in cases['preflightTests']:
        subprocess.run(['node', str(Path(__file__).resolve().parents[3] / 'bin/packaging.mjs'), '--project-root', str(ROOT), 'test', name], check=True)
    subprocess.run(['python3', str(Path(__file__).resolve().parents[3] / 'release/audit/check-seed-parity.py'), '--project-root', str(ROOT), '--packaged-root', str(installed)], check=True)
    for directory in ['packaging/scripts', 'packaging/migrations', 'packaging/templates']:
        expected = host_files('templates') if directory == 'packaging/templates' else files(ROOT / ('config/packaging/migrations' if directory == 'packaging/migrations' else 'build/scripts' if directory == 'packaging/scripts' else directory))
        if directory.endswith('/scripts'):
            expected = {name: body for name, body in expected.items() if '/' not in name and Path(name).suffix in ('.sh', '.py', '.js', '.jq', '.json', '.html')}
            expected['release-project.json'] = (ROOT / 'config/packaging/release-project.json').read_bytes()
        if directory.endswith('/templates'):
            name = package + '.env'
            version = (installed / 'packaging/VERSION').read_text().strip()
            text = re.sub(r'^MYSCOUTEE_VERSION=.*$', lambda _: 'MYSCOUTEE_VERSION=' + version, expected[name].decode(), flags=re.M)
            for image in project['images']:
                if subprocess.run(['dpkg', '--compare-versions', version.replace('-', '~', 1), 'ge',
                                   image['sinceVersion'].replace('-', '~', 1)]).returncode != 0:
                    continue
                value = image['repository'] + ':' + version + '-' + image['tagSuffix']
                text = re.sub(r'^' + image['environment'] + '=.*$', lambda _: image['environment'] + '=' + value, text, flags=re.M)
            expected[name] = text.encode()
        equal_files(expected, files(installed / directory), directory)
    expected = {}
    for name in json.loads((ROOT / 'config/packaging/release/runtime-scripts.json').read_text()):
        path = ROOT / 'server/docker/scripts' / name
        expected.update({name + '/' + key: value for key, value in files(path).items()} if path.is_dir() else {name: path.read_bytes()})
    equal_files(expected, files(installed / 'server/docker/scripts'), 'selected host runtime scripts')
    equal_files(host_files('systemd'), files(args.stage / 'lib/systemd/system'), 'systemd units')
    equal_files(host_files('sysusers'), files(args.stage / 'usr/lib/sysusers.d'), 'system users')
    pairs = [('server/docker-compose-stun.yml', 'server/docker-compose-stun.yml'),
             ('config/packaging/compose/docker-compose.production-replicaset.yml', 'server/docker-compose.replicaset.yml'),
             ('server/projects/profile/secrets/README.md', 'server/projects/profile/secrets/README.md'),
             ('server/projects/profile/secrets/firebase-service-account.json.example', 'server/projects/profile/secrets/firebase-service-account.json.example')]
    for source, target in pairs:
        assert (ROOT / source).read_bytes() == (installed / target).read_bytes(), target
    compose = (ROOT / 'config/packaging/compose/docker-compose.production.yml').read_text().replace('docker-compose.production-replicaset.yml', 'docker-compose.replicaset.yml')
    assert (installed / 'server/docker-compose-prod.yml').read_text() == compose
    for name in ['preinst', 'postinst', 'prerm', 'postrm']:
        expected = subprocess.check_output(['python3', str(ROOT / 'config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/render-debian.py'), str(ROOT / 'packaging'), '-', '--hook', name])
        assert (args.stage / 'DEBIAN' / name).read_bytes() == expected, name
    print('PASS: installed Compose, replica set, STUN, secret provisioning instructions and package lifecycle scripts')
    if args.images:
        audit_images(installed)
    if args.deb:
        audit_deb(args.deb, args.stage)


if __name__ == '__main__':
    main()
