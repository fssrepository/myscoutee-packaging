"""Run focused Mongo tests on the one already-running deployment.

Set MYSCOUTEE_TEST_MONGO_TARGET=kvm for the existing owned lab. This helper
never starts a container, VM or database and never reads credentials on the host.
MYSCOUTEE_TEST_MONGO_CONTAINER selects an existing monolith Mongo container.
"""
import os
from pathlib import Path
import subprocess
import sys


def run_mongo(script, *, demo=False, capture=False, node_heap_mib=None):
    if node_heap_mib is not None and (type(node_heap_mib) is not int or node_heap_mib < 1):
        raise ValueError('node_heap_mib must be a positive integer')
    node_environment = ['NODE_OPTIONS=--max-old-space-size=' + str(node_heap_mib)] if node_heap_mib else []
    prefix = (
        'db = db.getSiblingDB(process.env.MONGO_DEMO_DATABASE || "demo_db");\n'
        'if (!db.auth(process.env.MONGO_APP_USERNAME, process.env.MONGO_APP_PASSWORD)) '
        'throw new Error("Demo Mongo authentication failed");\n'
        if demo else
        'if (!db.getSiblingDB("admin").auth(process.env.MONGO_INITDB_ROOT_USERNAME, '
        'process.env.MONGO_INITDB_ROOT_PASSWORD)) throw new Error("Mongo authentication failed");\n'
    )
    target = os.environ.get('MYSCOUTEE_TEST_MONGO_TARGET', 'monolith')
    if target == 'monolith':
        container = os.environ.get('MYSCOUTEE_TEST_MONGO_CONTAINER', 'mongodb')
        environment_args = [arg for value in node_environment for arg in ['-e', value]]
        result = subprocess.run(['docker', 'exec', '-i', *environment_args, container, 'mongosh', '--quiet',
                                 '--file', '/dev/stdin'], input=prefix + script, text=True,
                                 capture_output=capture, check=True)
        if capture:
            return result.stdout
    elif target == 'kvm':
        import os as _runtime_context_os
        _runtime_context_os.environ.setdefault('MYSCOUTEE_BACKEND_SOURCE', str(Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())).resolve()))
        sys.path.insert(0, str(Path(_runtime_context_os.environ.get('MYSCOUTEE_MICROSERVICES_SOURCE', (Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd())).resolve()).parent / 'myscoutee-microservices')) / 'tools'))
        import mongo_replica
        import workloads
        workloads.namespace_owned()
        host = ['--host', workloads.CONFIG['databases']['replicaSet']
                + '/mongodb:27017,mongodb-secondary:27017'] \
            if workloads.CONFIG.get('mongoReplicaSet') else []
        result = workloads.kube('-n', workloads.NAMESPACE, 'exec', '-i',
                                mongo_replica.member_target(), '--', *(['env', *node_environment] if node_environment else []), 'mongosh',
                                *host, '--quiet', '--file', '/dev/stdin', data=prefix + script,
                                check=False)
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or 'KVM Mongo test failed')
        if capture:
            return result.stdout
        print(result.stdout, end='')
    else:
        raise ValueError('MYSCOUTEE_TEST_MONGO_TARGET must be monolith or kvm')
