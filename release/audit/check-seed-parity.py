#!/usr/bin/env python3
"""Audit all seed inventories, shared definitions and environment boundaries."""
import argparse
import copy
import json
import re
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


def load_project(root):
    return json.loads((Path(root) / 'config/packaging/tests/release-seeds.json').read_text())


def identity(value):
    return value.get('$oid') if isinstance(value, dict) else value

def import_collections(rule, database):
    return {name for item in rule.split(';') if item.partition(':')[0] == database
            for name in item.partition(':')[2].split(',') if name}


def audit_delivery(data, errors, root, seeds, project, packaged_root=None):
    """Compare delivery with the classified DEV/production baseline, not itself."""
    production = data['myscoutee_db']
    required = set(tuple(project['inventory']['shared']) + tuple(project['inventory']['configured'])) | {name for name, rows in production.items() if rows}
    package = json.loads((root / 'config/packaging/release-project.json').read_text())['packageName']
    policy = json.loads((root / 'config/packaging/templates/install-policy.json').read_text())
    env_path = Path('config/packaging/templates') / (package + '.env')
    source_env = (root / 'server/.env').read_text()
    packaged_env = (root / env_path).read_text()
    importer = (seeds / 'mongo-seed-policy.inc').read_text()
    env_rule = lambda text: re.search(r'^MONGO_IMPORT_ALLOWED_COLLECTIONS_BY_DB=(.*)$', text, re.M).group(1)
    fallback = re.search(r'allowed_collections_by_db="\$\{MONGO_IMPORT_ALLOWED_COLLECTIONS_BY_DB:-(.*)\}"', importer).group(1)
    rules = [('source environment', env_rule(source_env)), ('importer default', fallback),
             ('installed environment', env_rule(packaged_env)), ('install fallback', policy['mongoSeedFallback'])]
    for label, rule in rules:
        for database in ('production_db', 'myscoutee_db') if label in ('source environment', 'importer default') else ('production_db',):
            actual = import_collections(rule, database)
            if '*' in actual or not required.issubset(actual):
                errors.append(f'{label}/{database}: missing production inputs {sorted(required - actual)}; wildcard={"*" in actual}')
    missing_upgrade = required - set(policy['requiredMongoCollections'])
    if missing_upgrade:
        errors.append(f'install upgrade policy: missing production inputs {sorted(missing_upgrade)}')
    if packaged_root is None:
        return
    installed = Path(packaged_root) / 'server/docker/conf/mongodb'
    if (installed / 'e2e_db').exists():
        errors.append('installed Mongo inputs contain E2E fixtures')
    for path in seeds.iterdir():
        if path.is_file() and (not (installed / path.name).is_file()
                               or path.read_bytes() != (installed / path.name).read_bytes()):
            errors.append(f'installed Mongo initializer differs or is missing: {path.name}')
    for mode in ('demo_db', 'myscoutee_db'):
        expected = set(data[mode]) if mode == 'demo_db' else required
        actual = {p.stem for p in (installed / mode).glob('*.json')}
        if actual != expected:
            errors.append(f'installed {mode}: missing={sorted(expected - actual)}, unexpected={sorted(actual - expected)}')
        for name in expected & actual:
            reference = copy.deepcopy(data[mode][name])
            if name == 'appSettings':
                admins = sorted({row['email'] for row in data['demo_db']['users']
                                 if row.get('hostTier') == 'Admin' and re.search(r'@[^@]+\.(local|invalid)$', row.get('email', ''), re.I)})
                for row in reference:
                    if row.get('settingsKey') == 'global':
                        row['adminEmails'] = admins if mode == 'demo_db' else []
            if json.loads((installed / mode / (name + '.json')).read_text()) != reference:
                errors.append(f'installed {mode}/{name}: differs from canonical environment input')


def audit_chat_fixture(data, label, errors, root, settings):
    """Check selected references against the native message/counter contracts."""
    users = {row.get('userId', row.get('id')): row for row in data['users']}
    chats = data['chats']
    messages = data['chatMessages']
    notifications = data['userNotifications']

    def require(condition, detail):
        if not condition:
            errors.append(f'{label}: {detail}')

    channels = {chat['id']: set(chat['memberIds']) for chat in chats}
    for chat in chats:
        owner, channel = chat['ownerUserId'], chat['id']
        require(chat['channelType'] == settings['channelType'], 'omitted chat domain in fixture')
        require(owner in channels[channel] <= users.keys(), 'invalid chat member/owner reference')
        thread = [message for message in messages if message['chatId'] == channel]
        unread = sum(message['senderAvatar']['id'] != owner
                     and owner not in message['messageReadByUserIds']
                     and not message.get('deletedAtIso') for message in thread)
        require(chat['unread'] == unread, f'{owner}: chat unread counter differs')
        if thread:
            latest = max(thread, key=lambda message: message['sentAtIso'])
            require((chat['lastMessage'], chat['lastSenderId'], chat['dateIso']) ==
                    (latest['text'], latest['senderAvatar']['id'], latest['sentAtIso']),
                    f'{owner}: chat summary differs from latest message')
    for message in messages:
        members = channels.get(message['chatId'], set())
        sender = message['senderAvatar']['id']
        readers = {reader['id'] for reader in message['readBy']}
        require(sender in members and readers <= members, 'invalid message member reference')
        require(set(message['messageSenderUserIds']) == {sender}
                and set(message['messageReadByUserIds']) == readers, 'message lookup IDs differ')
    for access in data['contactChatAccess']:
        pair = {access['leftUserId'], access['rightUserId']}
        require(pair <= users.keys() and access['requestedBy'] in pair,
                'invalid contact access reference')
    for notification in notifications:
        require(notification['recipientUserId'] in users and notification['sourceType'] == 'user'
                and notification['sourceId'] in users, 'invalid notification reference/domain')
    for owner, user in users.items():
        unread = sum(chat['unread'] for chat in chats if chat['ownerUserId'] == owner)
        activity = user['activities']
        require(activity['chats'] == activity['chat']['all'] == activity['chat']['contacts'] == unread
                and activity['chat']['appSupport'] == 0, f'{owner}: user chat counters differ')
        require(activity['notifications'] == sum(n['recipientUserId'] == owner and not n['readAtIso']
                                                for n in notifications),
                f'{owner}: notification counter differs')

    def media(value):
        if isinstance(value, dict):
            for child in value.values():
                media(child)
        elif isinstance(value, list):
            for child in value:
                media(child)
        elif isinstance(value, str):
            if value.startswith(settings['media']['publicPrefix']):
                key = parse_qs(urlsplit(value).query).get(settings['media']['queryKey'], [''])[0]
                require(bool(key) and (root / settings['media']['directory'] / key).is_file(),
                        f'missing packaged media: {key}')
            elif value.startswith(settings['media']['assetPrefix']):
                require((root / settings['media']['assetDirectory'] / value).is_file(), f'missing browser asset: {value}')
    media(data)


MISSING = object()


def field(document, path):
    value = document
    for name in path.split('.'):
        if not isinstance(value, dict) or name not in value:
            return MISSING
        value = value[name]
    return value


def set_field(document, path, value):
    names = path.split('.')
    for name in names[:-1]:
        document = document[name]
    document[names[-1]] = copy.deepcopy(value)


def audit_rules(data, errors, root, rules):
    for rule in rules.get('expectedCollections', []):
        if data[rule['mode']][rule['collection']] != rule['documents']:
            errors.append(f"{rule['mode']}/{rule['collection']}: unexpected bootstrap documents")
    for rule in rules.get('comparisons', []):
        for name in rule['collections']:
            source, target = data[rule['source']][name], data[rule['target']][name]
            if rule.get('byId'):
                source = {identity(row['_id']): row for row in source}
                target = {identity(row['_id']): row for row in target}
            if source != target:
                errors.append(f"{rule['target']}/{name}: differs from {rule['source']}")
    for rule in rules.get('configurations', []):
        name, mode = rule['collection'], rule['target']
        reference = copy.deepcopy(data[rule['source']][name])
        actual = copy.deepcopy(data[mode][name])
        for path in rule.get('copyFromTarget', []):
            value = field(actual[0], path)
            if value is MISSING:
                errors.append(f'{mode}/{name}: missing field {path}')
            else:
                set_field(reference[0], path, value)
        for path, value in rule.get('set', {}).items():
            set_field(reference[0], path, value)
        for requirement in rule.get('requirements', []):
            value = field(actual[0], requirement['path'])
            if value is MISSING and requirement.get('missingEqualsNull'):
                value = None
            if value != requirement['value']:
                errors.append(f"{mode}/{name}: unexpected {requirement['path']}")
        for override in rule.get('rowSets', []):
            for row in reference:
                if all(field(row, path) == value for path, value in override['where'].items()):
                    for path, value in override['set'].items():
                        set_field(row, path, value)
        if rule.get('sortBy'):
            actual.sort(key=lambda row: row[rule['sortBy']])
            reference.sort(key=lambda row: row[rule['sortBy']])
        if actual != reference:
            errors.append(f'{mode}/{name}: unexpected configuration difference')
    for rule in rules.get('fieldsContain', []):
        name = rule['collection']
        if not set(data[rule['source']][name][0]).issubset(data[rule['target']][name][0]):
            errors.append(f"{rule['target']}/{name}: missing top-level fields")
    for mode, collections in rules.get('emptyCollections', {}).items():
        for name in collections:
            if data[mode].get(name, []) != []:
                errors.append(f'{mode}/{name}: must remain empty')
    for rule in rules.get('recordSets', []):
        rows = data[rule['mode']][rule['collection']]
        if ({identity(row['_id']) for row in rows} != set(rule['identities'])
                or any(field(row, path) != value for row in rows for path, value in rule['fields'].items())):
            errors.append(f"{rule['mode']}/{rule['collection']}: unexpected identities or fields")
    for rule in rules.get('references', []):
        rows = data[rule['mode']]
        owners = {identity(field(row, rule['targetField'])) for row in rows[rule['targetCollection']]}
        for row in rows[rule['collection']]:
            value = field(row, rule['prefixField'])
            if (identity(field(row, rule['field'])) not in owners
                    or not isinstance(value, str) or not value.startswith(rule['prefix'])):
                errors.append(f"{rule['mode']}/{rule['collection']}: invalid owner or reference")
    for rule in rules.get('schemaVersions', []):
        if any(field(row, rule['field']) != rule['value']
               for mode in data.values() for row in mode[rule['collection']]):
            errors.append(f"{rule['collection']}: unexpected {rule['field']}")
    if 'chatFixtures' in rules:
        settings = rules['chatFixtures']
        for mode in settings['environments']:
            audit_chat_fixture(data[mode], mode, errors, root, settings)
        local = root / settings['localDirectory']
        fixture = {name: json.loads((local / (filename + '.json')).read_text())
                   for name, filename in settings['localCollections'].items()}
        audit_chat_fixture(fixture, 'frontend-local', errors, root, settings)
    if 'localBranding' in rules:
        selection = rules['localBranding']
        local = json.loads((root / selection['path']).read_text())
        branding = field(data['demo_db'][selection['collection']][0], selection['field'])
        for key in selection['keys']:
            if branding[key] != local[key]:
                errors.append(f'frontend-local branding differs: {key}')


def audit(project_root, seeds=None, packaged_root=None, project=None):
    root = Path(project_root).resolve()
    seeds = Path(seeds) if seeds is not None else root / 'server/docker/conf/mongodb'
    if project is None:
        project = load_project(root)
    errors = []
    data = {}
    known = set(tuple(project['inventory']['shared']) + tuple(project['inventory']['configured']) + tuple(project['inventory']['runtime']) + tuple(project['inventory']['demoOnlyRuntime'])) | {'adminUsers'}
    for mode in ('demo_db', 'myscoutee_db', 'e2e_db'):
        data[mode] = {}
        for path in (seeds / mode).glob('*.json'):
            rows = json.loads(path.read_text())
            if path.stem not in known:
                errors.append(f'{mode}/{path.stem}: unclassified seed; review its ownership')
            if not isinstance(rows, list) or any(not isinstance(r, dict) or '_id' not in r for r in rows):
                errors.append(f'{mode}/{path.stem}: expected document array with identities')
                continue
            ids = [identity(r['_id']) for r in rows]
            if len(set(ids)) != len(ids):
                errors.append(f'{mode}/{path.stem}: duplicate identity')
            data[mode][path.stem] = rows
        required = tuple(project['inventory']['shared']) + tuple(project['inventory']['configured']) + tuple(project['inventory']['runtime']) + (() if mode == 'myscoutee_db' else tuple(project['inventory']['demoOnlyRuntime']))
        for name in required:
            if name not in data[mode]:
                errors.append(f'{mode}/{name}: missing JSON baseline')
    if errors:
        return errors
    audit_rules(data, errors, root, project['parity'])
    audit_delivery(data, errors, root, seeds, project, packaged_root)
    return errors

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-root', type=Path, required=True, help='Application source checkout')
    parser.add_argument('--packaged-root', type=Path, help='Extracted /opt/<package> directory to compare with DEV/source inputs')
    args = parser.parse_args()
    project = load_project(args.project_root.resolve())
    errors = audit(args.project_root, packaged_root=args.packaged_root, project=project)
    if errors:
        raise SystemExit('\n'.join(errors))
    count = sum(len(project['inventory'][key]) for key in ('shared', 'configured', 'runtime', 'demoOnlyRuntime'))
    print(f'PASS: all {count} dev/prod/e2e seed baselines classified and project parity verified.')


if __name__ == '__main__':
    main()
