#!/usr/bin/env python3
"""Render self-contained dpkg control files from shared code and product data."""
import argparse
import copy
import json
import re
import sys
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[2] / 'debian'
HOOKS = ('control', 'preinst', 'postinst', 'prerm', 'postrm')


def read(path):
    return json.loads(path.read_text())


def match(pattern, value):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def merge(defaults, overrides):
    """Only existing fields can be overridden; arrays are complete selections."""
    if not isinstance(overrides, dict) or overrides.keys() - defaults.keys():
        raise ValueError('Unknown configuration field')
    result = copy.deepcopy(defaults)
    for key, value in overrides.items():
        if isinstance(defaults[key], dict):
            result[key] = merge(defaults[key], value)
        elif type(value) is not type(defaults[key]):
            raise ValueError(f'Invalid configuration type: {key}')
        else:
            result[key] = value
    return result


def selected(config, name, defaults):
    path = config / (name + '.json')
    if not path.exists():
        return copy.deepcopy(defaults)
    data = read(path)
    if not isinstance(data, dict) or data.get('schemaVersion') != 1:
        raise ValueError(f'Invalid {name} configuration')
    return merge(defaults, {key: value for key, value in data.items() if key != 'schemaVersion'})


def purge_values(release, policy):
    if (not isinstance(policy, dict) or set(policy) != {'schemaVersion', 'volumes'}
            or policy['schemaVersion'] != 1 or not isinstance(policy['volumes'], list)
            or len(policy['volumes']) > 32):
        raise ValueError('Invalid purge policy')
    rows = []
    for volume in policy['volumes']:
        if (not isinstance(volume, dict) or set(volume) != {'environment', 'default'}
                or not match(r'[A-Z][A-Z0-9_]{1,63}', volume['environment'])
                or not match(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}', volume['default'])):
            raise ValueError('Invalid purge volume')
        rows.append(volume['environment'] + '\t' + volume['default'])
    if len({item['environment'] for item in policy['volumes']}) != len(rows):
        raise ValueError('Duplicate purge volume')
    repositories = sorted({image['repository'] for image in release['images']})
    if not repositories or not all(match(r'[a-z][a-z0-9-]{1,63}', value) for value in repositories):
        raise ValueError('Invalid managed repositories')
    return {'PACKAGE_VOLUME_RULES': '\n'.join(rows),
            'PACKAGE_IMAGE_REPOSITORIES': ','.join(repositories)}


def lifecycle_values(data):
    tls = data['bootstrapTls']
    if (type(tls['days']) is not int or not 1 <= tls['days'] <= 36500
            or not match(r'[A-Za-z0-9][A-Za-z0-9:._-]*', tls['key'])
            or not match(r'\.[A-Za-z0-9_-]+\.', tls['temporaryPrefix'])
            or not match(r'[A-Za-z][A-Za-z0-9_.-]*', tls['certificate'])
            or not match(r'[A-Za-z][A-Za-z0-9_.-]*', tls['privateKey'])
            or tls['certificate'] == tls['privateKey']
            or not match(r'/[A-Za-z0-9_./:=,+ -]+', tls['subject'])
            or not match(r'subjectAltName=[A-Za-z0-9_.:,=-]+', tls['alternativeNames'])
            or not match(r'[A-Za-z][A-Za-z0-9_]*', data['mongoDatabase'])
            or type(data['firebaseEnabled']) is not bool):
        raise ValueError('Invalid lifecycle configuration')
    images = data['requiredImages']
    if not isinstance(images, list) or len(images) > 32:
        raise ValueError('Invalid required images')
    lines = []
    for image in images:
        if (not isinstance(image, dict) or set(image) != {'environment', 'default', 'label'}
                or not match(r'[A-Z][A-Z0-9_]{1,63}', image['environment'])
                or not match(r'[a-z0-9][a-zA-Z0-9_./:@-]*', image['default'])
                or not match(r'[A-Za-z0-9][A-Za-z0-9 ._-]*', image['label'])):
            raise ValueError('Invalid required image')
        lines.append('  ensure_docker_image "$(config_value ' + image['environment']
                     + ' ' + image['default'] + ')" "' + image['label'] + '"')
    if len({image['environment'] for image in images}) != len(images):
        raise ValueError('Duplicate required image')
    return {'TLS_DAYS': str(tls['days']), 'TLS_KEY': tls['key'],
            'TLS_TEMPORARY_PREFIX': tls['temporaryPrefix'], 'TLS_CERTIFICATE': tls['certificate'],
            'TLS_PRIVATE_KEY': tls['privateKey'], 'TLS_SUBJECT': tls['subject'],
            'TLS_ALT_NAMES': tls['alternativeNames'], 'MONGO_DATABASE': data['mongoDatabase'],
            'FIREBASE_ENABLED': str(data['firebaseEnabled']).lower(),
            'REQUIRED_IMAGES': '\n'.join(lines)}


def render(packaging, hook='postrm', version='1.0.0', architecture='amd64'):
    if hook not in HOOKS:
        raise ValueError('Unknown Debian control file')
    config = Path(packaging).parent / 'config/packaging'
    release = read(config / 'release-project.json')
    if not match(r'[a-z][a-z0-9-]{1,63}', release['packageName']):
        raise ValueError('Invalid package identity')
    values = {'PACKAGE_NAME': release['packageName']}
    defaults = read(SOURCE / 'defaults.json')
    if hook == 'control':
        if (not match(r'[0-9][A-Za-z0-9.+:~\-]*', version)
                or not match(r'[a-z0-9][a-z0-9-]{0,31}', architecture)):
            raise ValueError('Invalid package version or architecture')
        metadata = selected(config / 'debian', 'control', {**defaults['control'], 'Description': ''})
        for key, value in metadata.items():
            if not isinstance(value, str) or not value or any(ord(char) < 32 and char != '\n' for char in value):
                raise ValueError(f'Invalid control field: {key}')
            if '\n' in value and (key != 'Description' or any(not line.startswith(' ') for line in value.split('\n')[1:])):
                raise ValueError(f'Invalid multiline control field: {key}')
            values['CONTROL_' + key.upper()] = value
        values.update(VERSION=version, ARCHITECTURE=architecture)
    elif hook == 'preinst':
        for key in ('uid', 'gid'):
            number = release['runtimeIdentity'][key]
            if type(number) is not int or not 10000 <= number <= 60000:
                raise ValueError('Invalid runtime identity')
            values['RUNTIME_' + key.upper()] = str(number)
    elif hook == 'postinst':
        values.update(lifecycle_values(selected(config / 'debian', 'lifecycle', defaults['lifecycle'])))
    elif hook == 'postrm':
        values.update(purge_values(release, read(config / 'debian/purge-policy.json')))
    source = (SOURCE / hook).read_text()
    # Substitute in one pass: configuration values cannot become new tokens.
    return re.sub(r'@([A-Z_]+)@', lambda found: values[found[1]], source)


def render_host_files(packaging, component):
    if component not in ('systemd', 'sysusers', 'templates'):
        raise ValueError('Unknown host component')
    config = Path(packaging).parent / 'config/packaging'
    release = read(config / 'release-project.json')
    name = release['packageName']
    if not match(r'[a-z][a-z0-9-]{1,63}', name):
        raise ValueError('Invalid package identity')
    if component == 'templates':
        files = {}
        for filename in (name + '.env', name + '.secrets.env', 'install-policy.json', 'update-release-key.README'):
            source = config / 'templates' / filename
            if source.is_symlink() or not source.is_file():
                raise ValueError('Missing or symbolic deployment template')
            files[filename] = source.read_bytes().decode('utf-8')
        return files
    settings = read(config / 'systemd.json')
    if (settings.keys() != {'schemaVersion', 'displayName'} or settings['schemaVersion'] != 1
            or not match(r'[A-Za-z][A-Za-z0-9 ._-]{0,63}', settings['displayName'])):
        raise ValueError('Invalid service-manager settings')
    identity = release['runtimeIdentity']
    if (any(type(identity[k]) is not int or not 10000 <= identity[k] <= 60000 for k in ('uid', 'gid'))
            or identity['uid'] != identity['gid']):
        raise ValueError('System account requires the existing matching numeric UID/GID')
    values = {'PACKAGE_NAME': name, 'DISPLAY_NAME': settings['displayName'],
              'RUNTIME_UID': str(identity['uid'])}
    result = {}
    for source in sorted((SOURCE.parent / component).iterdir()):
        if not source.is_file():
            continue
        filename = (name + '.conf' if component == 'sysusers' else
                    name + '.service' if source.name == 'stack.service' else name + '-' + source.name)
        result[filename] = re.sub(r'@([A-Z_]+)@', lambda found: values[found[1]], source.read_text())
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('packaging', type=Path)
    parser.add_argument('output', help='File, directory for --hook all, or - for stdout')
    parser.add_argument('--hook', choices=(*HOOKS, 'all'), default='postrm')
    parser.add_argument('--version', default='1.0.0')
    parser.add_argument('--architecture', default='amd64')
    parser.add_argument('--component', choices=('debian', 'systemd', 'sysusers', 'templates'), default='debian')
    args = parser.parse_args()
    if args.component == 'debian' and args.hook == 'all' and args.output == '-':
        parser.error('--hook all requires an output directory')
    # Validate/render the complete selection before writing any output.
    files = ({hook: render(args.packaging, hook, args.version, args.architecture)
              for hook in (HOOKS if args.hook == 'all' else [args.hook])}
             if args.component == 'debian' else render_host_files(args.packaging, args.component))
    if args.component != 'debian' and args.output == '-':
        print(json.dumps(files))
        return
    for hook, source in files.items():
        if args.output == '-':
            sys.stdout.write(source)
        else:
            target = Path(args.output) / hook if args.hook == 'all' or args.component != 'debian' else Path(args.output)
            if args.component != 'debian':
                target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(source)
            target.chmod(0o644 if hook == 'control' or args.component != 'debian' else 0o755)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, AttributeError) as error:
        sys.exit(f'Cannot render Debian control data: {error}')
