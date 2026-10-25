// Materialize the configured builder's profile details into the selected Mongo fixtures.
// No production seed or running database is modified by this command.
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import path from 'node:path';
const root = process.env.MYSCOUTEE_PACKAGING_PROJECT_ROOT || process.cwd();
const config = JSON.parse(await readFile(path.join(root, 'config/packaging/seeds/data/profile-details.json'), 'utf8'));
const frontendRequire = createRequire(path.join(root, 'frontend/package.json'));
const { build } = frontendRequire('esbuild');
const mode = process.argv[2];
if (!['--check', '--write'].includes(mode)) throw Error('Use --check or --write');
// Keep lazy ESM dependencies separate. A single-file bundle can omit the
// initialization of values re-exported through a side-effect-free barrel.
const output = await mkdtemp(path.join(tmpdir(), 'myscoutee-seed-profile-'));
let seeds;
try {
  await build({
    entryPoints: { builder: path.join(root, config.builder) },
    inject: (config.preloadModules ?? []).map(name => frontendRequire.resolve(name)),
    bundle: true, splitting: true, outdir: output,
    outExtension: { '.js': '.mjs' }, platform: 'node', format: 'esm', logLevel: 'silent'
  });
  const builders = await import(pathToFileURL(path.join(output, 'builder.mjs')));
  seeds = builders[config.exportName][config.method](config.count);
} finally {
  await rm(output, { recursive: true, force: true });
}
const byName = new Map(seeds.map(user => [user.name, user]));
if (byName.size !== seeds.length) throw Error('Ambiguous local seed name mapping');
let mismatch = false;
for (const db of config.databases) {
  const file = path.join(root, config.seedRoot, db, config.collection);
  const users = JSON.parse(await readFile(file, 'utf8'));
  let matched = 0, changed = 0;
  for (const user of users) {
    if (user.accountUserId || user.workspaceGroupId) continue;
    const seed = byName.get(user.name);
    if (!seed) continue;
    matched++;
    const expected = seed.profileDetails;
    if (JSON.stringify(user.profileDetails) === JSON.stringify(expected)) continue;
    // Existing curated seed values require explicit reconciliation, never silent overwrite.
    if (user.profileDetails != null) throw Error(`${db}: existing profile details differ for ${user.name}`);
    user.profileDetails = expected;
    changed++;
  }
  if (matched !== seeds.length) throw Error(`${db}: expected ${seeds.length} mapped base profiles, found ${matched}`);
  if (changed) {
    mismatch = true;
    if (mode === '--write') await writeFile(file, JSON.stringify(users, null, 2) + '\n');
  }
  console.log(`${db}: ${matched} matched seed profiles; ${changed} ${mode === '--write' ? 'updated' : 'missing'}`);
}
if (mode === '--check' && mismatch) process.exitCode = 1;
