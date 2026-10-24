#!/usr/bin/env python3
"""Default Compose contracts; --runtime also tests one isolated cached Mongo at a time.

No image builds/pulls, published ports, application fixtures or existing volumes.
"""
import os
import argparse
import json
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd()))


def run(*args, check=True):
    return subprocess.run(args, text=True, capture_output=True, check=check, timeout=120)


def config_contracts():
    files = ('server/docker-compose.yml', 'server/docker-compose-dev.yml',
             'server/docker-compose-prod.yml', 'server/docker-compose.e2e.yml',
             'config/packaging/compose/docker-compose.production.yml')
    for file in files:
        config = json.loads(run('docker', 'compose', '--env-file', str(ROOT / 'server/.env'),
            '-f', str(ROOT / file), 'config', '--no-env-resolution', '--format', 'json').stdout)
        mongo, app = (config['services'][name] for name in ('mongodb', 'profilemanagement'))
        assert '--replSet' in mongo['command'], file
        assert mongo['entrypoint'] == ['bash', '/docker-entrypoint-initdb.d/replica-entrypoint'], file
        assert mongo['healthcheck']['test'] == ['CMD', 'bash', '/docker-entrypoint-initdb.d/replica-health'], file
        assert app['environment']['AFFINITY_RECOMPUTE_CHANGE_STREAM_ENABLED'] == 'true', file
        assert app['environment']['AFFINITY_RECOMPUTE_CHANGE_STREAM_FALLBACK_POLL_ENABLED'] == 'false', file
        assert app['environment']['MONGODB_REPLICA_SET'] == mongo['environment']['MONGO_REPLICA_SET_NAME'], file
    print('PASS: five default Compose entry points inherit the retained replica override')


def runtime_contract(image):
    run('docker', 'image', 'inspect', image)  # Fail rather than download.
    label = 'com.myscoutee.test=mongo-replica-default'
    fixture = 'myscoutee-mongo-replica-test-' + uuid.uuid4().hex
    auth = "const a=db.getSiblingDB('admin');a.auth(process.env.MONGO_INITDB_ROOT_USERNAME,process.env.MONGO_INITDB_ROOT_PASSWORD);"
    source = ROOT / 'server/docker/conf/mongodb'
    volume = fixture + '-data'
    run('docker', 'volume', 'create', '--label', label, volume)

    def start(replica):
        command = ['docker', 'run', '-d', '--pull=never', '--name', fixture, '--label', label,
            '--network=none', '--memory=512m', '--cpus=1', '--mount', 'type=volume,src=' + volume + ',dst=/data/db',
            '-e', 'MONGO_INITDB_ROOT_USERNAME=fixture', '-e', 'MONGO_INITDB_ROOT_PASSWORD=disposable-fixture-only']
        if replica:
            for name in ('replica-entrypoint', 'replica-health', '00_replica_set.js'):
                command += ['--mount', 'type=bind,src=' + str(source / name) + ',dst=/docker-entrypoint-initdb.d/' + name + ',readonly']
            command += ['-e', 'MONGO_REPLICA_SET_NAME=fixture-rs', '-e', 'MONGO_REPLICA_SET_HOST=localhost:27017',
                '--entrypoint=bash', image, '/docker-entrypoint-initdb.d/replica-entrypoint',
                'mongod', '--bind_ip_all', '--replSet', 'fixture-rs', '--wiredTigerCacheSizeGB', '0.25']
        else:
            command += [image, 'mongod', '--bind_ip_all', '--wiredTigerCacheSizeGB', '0.25']
        run(*command)
        ready(replica)

    def mongo(script, check=True):
        return run('docker', 'exec', fixture, 'mongosh', 'mongodb://127.0.0.1:27017/?directConnection=true',
                   '--quiet', '--eval', auth + script, check=check)

    def ready(replica):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if replica:
                result = run('docker', 'exec', fixture, 'bash', '/docker-entrypoint-initdb.d/replica-health', check=False)
            else:
                # Authenticated access distinguishes final daemon from pre-user bootstrap.
                result = mongo('quit(a.runCommand({connectionStatus:1}).authInfo.authenticatedUsers.length ? 0 : 1);', check=False)
            if result.returncode == 0:
                return
            state = json.loads(run('docker', 'inspect', fixture).stdout)[0]['State']
            if not state['Running']:
                raise RuntimeError('Fixture exited: ' + run('docker', 'logs', fixture).stdout[-3000:])
            time.sleep(1)
        raise RuntimeError('Fixture did not become ready: ' + run('docker', 'logs', fixture).stdout[-3000:])

    def remove_container():
        result = run('docker', 'inspect', fixture, check=False)
        if result.returncode == 0:
            assert json.loads(result.stdout)[0]['Config']['Labels'].get('com.myscoutee.test') == 'mongo-replica-default'
            run('docker', 'stop', '-t', '20', fixture)
            run('docker', 'rm', fixture)

    try:
        start(False)
        mongo("db.getSiblingDB('fixture').retained.insertOne({_id:'original',value:42});")
        remove_container()
        start(True)
        mongo("const d=db.getSiblingDB('fixture');if(d.retained.findOne({_id:'original'}).value!==42)throw Error('data lost');const c=d.retained.watch([],{maxAwaitTimeMS:1000});d.retained.insertOne({_id:'stream-probe'});const e=c.next();c.close();if(e.documentKey._id!=='stream-probe')throw Error('stream missing');")
        before = run('docker', 'exec', fixture, 'sha256sum', '/data/db/.myscoutee-replica-key').stdout
        run('docker', 'restart', '-t', '20', fixture)
        ready(True)
        assert run('docker', 'exec', fixture, 'sha256sum', '/data/db/.myscoutee-replica-key').stdout == before
        mongo("if(db.getSiblingDB('fixture').retained.countDocuments({})!==2)throw Error('restart lost data');")
        remove_container()
        run('docker', 'volume', 'rm', volume)
        run('docker', 'volume', 'create', '--label', label, volume)
        start(True)
        mongo("if(rs.conf()._id!=='fixture-rs'||!a.runCommand({hello:1}).isWritablePrimary)throw Error('fresh replica failed');")
        print('PASS: existing standalone data retained; live change event; key/data survive restart; fresh replica bootstrap')
    finally:
        remove_container()
        inspected = json.loads(run('docker', 'volume', 'inspect', volume).stdout)[0]
        assert inspected['Labels'].get('com.myscoutee.test') == 'mongo-replica-default'
        run('docker', 'volume', 'rm', volume)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', action='store_true')
    parser.add_argument('--image', default='mongo:8.0.4')
    args = parser.parse_args()
    config_contracts()
    if args.runtime:
        runtime_contract(args.image)
