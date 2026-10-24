import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const engines = fileURLToPath(new URL('../../release/seeds/', import.meta.url));

async function write(root, name, data) {
  const target = path.join(root, name);
  await mkdir(path.dirname(target), { recursive: true });
  await writeFile(target, JSON.stringify(data));
}

async function read(root, name) {
  return JSON.parse(await readFile(path.join(root, name), 'utf8'));
}

function run(root, name, ...args) {
  return spawnSync(process.execPath, [path.join(engines, name + '.mjs'), ...args], {
    encoding: 'utf8', env: { ...process.env, MYSCOUTEE_PACKAGING_PROJECT_ROOT: root },
  });
}

test('email maintenance uses each project selection and refuses invalid role counts before writing', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'seed-emails-'));
  try {
    for (const [domain, admins] of [['first.invalid', 2], ['second.invalid', 1]]) {
      const rows = [{ hostTier: 'Operator' }, ...Array.from({ length: admins }, () => ({ hostTier: 'Admin' })), {}];
      const workspaceProfiles = [
        { hostTier: 'Admin', accountUserId: 'admin', workspaceGroupId: 'workspace' },
        { accountUserId: 'member', workspaceGroupId: 'workspace', email: 'retained.invalid' },
      ];
      const file = 'selected/accounts.json';
      await write(root, file, [...rows, ...workspaceProfiles]);
      await write(root, 'config/packaging/seeds/data/emails.json', {
        files: [file], domain, adminCount: admins, operatorCount: 1, minimumMemberCount: 1,
      });
      const result = run(root, 'assign-seed-user-emails');
      assert.equal(result.status, 0, result.stderr);
      const assigned = await read(root, file);
      assert.deepEqual(assigned.slice(0, rows.length).map(row => row.email), [
        `operator1@${domain}`, ...Array.from({ length: admins }, (_, i) => `admin${i + 1}@${domain}`), `member1@${domain}`,
      ]);
      assert.deepEqual(assigned.slice(rows.length), workspaceProfiles);
      await write(root, file, [{}]);
      const before = await readFile(path.join(root, file), 'utf8');
      assert.equal(run(root, 'assign-seed-user-emails').status, 1);
      assert.equal(await readFile(path.join(root, file), 'utf8'), before);
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('distance generation supports another record schema and preserves other fields', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'seed-distances-'));
  try {
    await write(root, 'config/packaging/seeds/data/seed-distances.json', {
      files: ['selected/records.json'], hashModulus: 104729, salt: '',
      minimumKilometers: 2, kilometerRange: 33, meterRange: 1000,
      identity: { preferred: 'key', fallback: ['identity.part'] }, targetField: 'computedDistance',
    });
    await write(root, 'selected/records.json', [
      { key: 'a', unchanged: true }, { identity: { part: 'b' }, unchanged: true },
    ]);
    const result = run(root, 'backfill-seed-distances');
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(await read(root, 'selected/records.json'), [
      { key: 'a', unchanged: true, computedDistance: 33097 },
      { identity: { part: 'b' }, unchanged: true, computedDistance: 34098 },
    ]);
    const before = await readFile(path.join(root, 'selected/records.json'), 'utf8');
    assert.equal(run(root, 'backfill-seed-distances').status, 0);
    assert.equal(await readFile(path.join(root, 'selected/records.json'), 'utf8'), before);
  } finally { await rm(root, { recursive: true, force: true }); }
});

