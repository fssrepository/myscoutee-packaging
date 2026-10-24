#!/usr/bin/env python3
"""Exercise selected host scripts with disposable files and command doubles.

No service, real database, system account or installed package is modified.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd()))
CONTRACT = json.loads((Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())) / 'config/packaging/tests/contract-inputs.json').read_text())['contracts']['host-lifecycle-test']
CONTRACT_INPUTS = CONTRACT['inputs']
CONTRACT_EXPECTATIONS = CONTRACT.get('expectations', {})
POLICY = json.loads((ROOT / 'config/packaging/tests/host-lifecycle.json').read_text())
PACKAGE_NAME = POLICY['packageName']


def run(args, env, *, success=True):
    result = subprocess.run(args, env=env, text=True, capture_output=True)
    if success and result.returncode:
        raise AssertionError((args, result.returncode, result.stderr))
    if not success:
        assert result.returncode, args
    return result


def executable(path, source):
    path.write_text(source)
    path.chmod(0o755)


with tempfile.TemporaryDirectory(prefix='template-host-lifecycle-') as directory:
    temp = Path(directory)
    bin_dir = temp / 'bin'
    bin_dir.mkdir()
    trace = temp / 'trace'
    purge_env = temp / 'purge.env'
    purge_env.write_text('')
    env = dict(os.environ, PATH=str(bin_dir)+':'+os.environ['PATH'], HOST_TRACE=str(trace),
               DPKG_MAINTSCRIPT_PACKAGE=f'{PACKAGE_NAME}', MYSCOUTEE_POSTRM_ENV_FILE=str(purge_env))
    executable(bin_dir/'systemctl', '#!/bin/sh\nprintf "systemctl %s\\n" "$*" >> "$HOST_TRACE"\n')
    executable(bin_dir/'rm', '#!/bin/sh\nprintf "rm %s\\n" "$*" >> "$HOST_TRACE"\n')
    executable(bin_dir/'docker', f'#!/bin/sh\nprintf \'docker %s\n\' "$*" >> "$HOST_TRACE"\nif [ "$1" = images ]; then\n  printf \'%s\n\' {PACKAGE_NAME}-api:1.0.0-prod myscoutee-api:1.0.0-prod mongo:8.0.4 unrelated:1\nfi\n')
    postrm = temp / 'postrm'
    run(['python3',str(ROOT/'config/packaging/node_modules/@fssrepository/myscoutee-packaging/release/build/render-debian.py'),str(ROOT/'packaging'),str(postrm)],env)
    run(['bash',str(postrm),'remove'],env)
    assert 'rm ' not in trace.read_text() and 'docker ' not in trace.read_text()
    trace.write_text('')
    run(['bash',str(postrm),'purge'],env)
    calls = trace.read_text().splitlines()
    assert [line for line in calls if line.startswith('docker image rm')] == [f'docker image rm -f {PACKAGE_NAME}-api:1.0.0-prod']
    assert [line for line in calls if line.startswith('docker volume')] == [
        f'docker volume inspect {PACKAGE_NAME}-nginx-state-v1',
        f'docker volume rm -f {PACKAGE_NAME}-nginx-state-v1']
    assert [line for line in calls if line.startswith('rm ')] == [
        f'rm -rf /etc/{PACKAGE_NAME}',f'rm -rf /opt/{PACKAGE_NAME}',
        f'rm -rf /var/lib/{PACKAGE_NAME}',f'rm -rf /var/log/{PACKAGE_NAME}',
        f'rm -rf /var/cache/{PACKAGE_NAME}-update']
    purge_env.write_text('MYSCOUTEE_NGINX_STATE_VOLUME=custom-template-nginx\n')
    trace.write_text('')
    run(['bash',str(postrm),'purge'],env)
    assert [line for line in trace.read_text().splitlines() if line.startswith('docker volume')] == [
        'docker volume inspect custom-template-nginx',
        'docker volume rm -f custom-template-nginx']
    (bin_dir/'rm').unlink()  # Remaining cleanup is confined to the temporary tree.

    # Actual selected Compose model, without resolving deployment secret files.
    model = run(['docker','compose','-f',str(ROOT/'config/packaging/compose/docker-compose.production.yml'),
                 '--env-file',str(ROOT/CONTRACT_INPUTS['packaging_templates__PACKAGE_NAME_env'].format(PACKAGE_NAME=PACKAGE_NAME)),
                 'config','--no-env-resolution','--format','json'],dict(os.environ)).stdout
    model_path = temp/'compose.json'
    model_path.write_text(model)
    assert set(json.loads(model)['services']) == set(POLICY['composeServices'])
    scripts = temp/'scripts'
    scripts.mkdir()
    for name in ['release-project.sh','restart-update-stack.sh']:
        shutil.copy2(ROOT/'build/scripts'/name, scripts/name)
    shutil.copy2(ROOT/'config/packaging/release-project.json', scripts/'release-project.json')
    for name in ['reset-demo-state.sh','sync-i18n-seeds.sh','migrate-production-data.sh']:
        executable(scripts/name,'#!/bin/sh\nprintf "%s %s\\n" "$(basename "$0")" "$*" >> "$HOST_TRACE"\n')
    executable(temp/'compose','''#!/bin/sh
if [ "$1" = config ]; then cat "$HOST_MODEL"; exit; fi
printf 'compose %s\n' "$*" >> "$HOST_TRACE"
''')
    executable(bin_dir/'docker','''#!/bin/sh
printf '%s\n' "${HOST_HEALTH:-healthy}"
''')
    env.update(MYSCOUTEE_COMPOSE_SCRIPT=str(temp/'compose'),HOST_MODEL=str(model_path))
    trace.write_text('')
    run(['bash',str(scripts/'restart-update-stack.sh')],env)
    calls=trace.read_text().splitlines()
    assert calls[0:2] == [f'systemctl is-active --quiet {PACKAGE_NAME}.service',
                         f'systemctl is-active --quiet {PACKAGE_NAME}-update-status.socket']
    assert POLICY['restartInfrastructureCommand'] in calls
    assert calls[-1] == 'compose up -d --no-deps nginx'
    trace.write_text('')
    run(['bash',str(scripts/'restart-update-stack.sh')],dict(env,HOST_HEALTH='unhealthy'),success=False)
    assert not any('nginx' in line for line in trace.read_text().splitlines())

    # Complete common backup and guarded Mongo/master-key restore. Docker is a
    # command double here; database semantics are covered by runtime qualification.
    server=temp/'server'
    (server/'data/minio').mkdir(parents=True)
    (server/'data/minio/kept').write_text('media')
    (server/'.env').write_text('FIREBASE_ENABLED=false\nMONGO_REPLICA_SET_ENABLED=false\n')
    (server/'.env.secrets').write_text('MONGO_APP_PASSWORD=test-only\n')
    (server/'docker-compose-prod.yml').write_text('services: {}\n')
    key=temp/'configuration';key.mkdir()
    (key/'deployment-master-key').write_text('5'*64+'\n')
    executable(bin_dir/'docker',f'#!/bin/sh\ncase "$1" in\n  ps) printf \'%s\n\' mongodb {PACKAGE_NAME};;\n  exec)\n    if [ "$2" = -i ]; then\n      cat >/dev/null\n      printf \'restore\n\' >> "$HOST_TRACE"\n      exit "${{HOST_RESTORE_EXIT:-0}}"\n    fi\n    printf \'disposable Mongo dump\n\';;\n  compose) printf \'compose %s\n\' "$*" >> "$HOST_TRACE";;\nesac\n')
    env.update(MYSCOUTEE_SERVER_DIR=str(server),MYSCOUTEE_CONFIGURATION_KEY_DIR=str(key),
               MYSCOUTEE_BACKUP_DIR=str(temp/'backups'),MYSCOUTEE_BACKUP_REQUIRE_COMPLETE='true')
    result=run(['bash',str(ROOT/'build/scripts/backup-production.sh')],env)
    archive=Path(result.stdout.strip())
    assert archive.name.startswith(f'{PACKAGE_NAME}-backup-')
    assert archive.stat().st_mode & 0o777 == 0o600
    with tarfile.open(archive) as stream:
        names=stream.getnames()
        assert not any('registry' in name for name in names)
        manifest=json.load(stream.extractfile('./backup-manifest.json'))
        assert manifest['complete'] is True
        assert set(manifest['components']) == set(POLICY['backupComponents'])
    (key/'deployment-master-key').write_text('7'*64+'\n')
    trace.write_text('')
    run(['bash',str(ROOT/'build/scripts/restore-production.sh'),str(archive)],dict(env,CONFIRM_RESTORE='true',HOST_RESTORE_EXIT='1'),success=False)
    assert (key/'deployment-master-key').read_text() == '7'*64+'\n'
    assert 'stop profilemanagement' in trace.read_text()
    assert 'up -d' not in trace.read_text()
    trace.write_text('')
    run(['bash',str(ROOT/'build/scripts/restore-production.sh'),str(archive)],dict(env,CONFIRM_RESTORE='true'))
    assert (key/'deployment-master-key').read_text() == '5'*64+'\n'
    assert 'up -d --force-recreate profilemanagement' in trace.read_text()
    (key/'deployment-master-key').unlink()
    run(['bash',str(ROOT/'build/scripts/backup-production.sh')],env,success=False)
print('PASS: template purge isolation, all seven selected services, ingress preservation, complete backup and failed/successful Mongo/key restore orchestration.')
