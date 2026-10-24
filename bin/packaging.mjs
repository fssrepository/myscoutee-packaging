#!/usr/bin/env node
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';

const source = fileURLToPath(new URL('../', import.meta.url));
const scripts = new Set([
  'install', 'purge', 'forward-localhost', 'verify-release',
  'prepare-debian13-minimal', 'install-temporary-image', 'install-temporary-frontend',
]);
const releaseScripts = new Map([
  ...['apply-partial-release-data', 'audit-package-credentials', 'build-debian-release',
    'build-production', 'package-partial-release-data', 'package-production',
    'publish-images', 'qualify-release-artifacts', 'rebuild-production-services']
    .map(name => [name, `${["audit-package-credentials", "qualify-release-artifacts"].includes(name) ? "audit" : name === "apply-partial-release-data" ? "." : "build"}/${name}.sh`]),
  ['render-nginx-routes', 'build/render-nginx-routes.py'],
]);
const args = process.argv.slice(2);
let project;
if (args[0] === '--project-root') {
  args.shift();
  const selected = args.shift();
  if (!selected) throw new Error('--project-root requires a path');
  project = resolve(selected);
} else {
  project = process.cwd();
  while (!existsSync(resolve(project, 'config/packaging/package.json'))) {
    const parent = dirname(project);
    if (parent === project) throw new Error('Select a project with --project-root.');
    project = parent;
  }
}
const selection = JSON.parse(readFileSync(resolve(project, 'config/packaging/package.json'), 'utf8'));
if (!selection.devDependencies?.['@fssrepository/myscoutee-packaging']) {
  throw new Error('The selected project does not declare the packaging dependency.');
}
const containerStack = selection.myscouteePackaging?.profile === 'container-stack';
const prepare = () => {
  const command = containerStack ? 'render-container-stack.py' : 'stage-runtime.py';
  const paths = [resolve(source, 'release/build', command), project];
  if (!containerStack) paths.push(resolve(project, 'build/scripts'));
  const prepared = spawnSync('python3', paths, { stdio: 'inherit' });
  if (prepared.error) throw prepared.error;
  if (prepared.status !== 0) process.exit(prepared.status ?? 1);
};
if (containerStack) prepare();
let script;
switch (args.shift()) {
  case 'client': {
    const name = args.shift()?.replace(/\.sh$/, '');
    if (!scripts.has(name)) throw new Error('Select a supported client script.');
    script = containerStack ? resolve(project, 'build/client-tools', `${name}.sh`) : resolve(source, 'client-tools', `${name}.sh`);
    break;
  }
  case 'client-tools':
    if (containerStack) throw new Error('The standalone container package builds its client archive together with release package-production.');
    script = resolve(source, 'release/build/package-client-tools.sh');
    break;
  case 'development':
    if (args.shift() !== 'purge-local-datastores') throw new Error('Select purge-local-datastores.');
    script = resolve(source, 'runtime/development/purge-local-datastores.sh');
    break;
  case 'qa-release': {
    const name = args.shift()?.replace(/\.py$/, '');
    if (!['reversion-qa-artifacts', 'reversion-registry-qa-artifacts', 'sign-qa-release'].includes(name)) throw new Error('Select a QA release tool.');
    script = resolve(source, 'release/qa', name + '.py');
    break;
  }
  case 'qualification': {
    const name = args.shift()?.replace(/\.(py|sh)$/, '');
    if (!['inspect-memory', 'measure-idle-heap', 'measure-minio-seed', 'measure-runtime', 'retained-data-fingerprint', 'security-probes', 'renew-qa-registry-certificate'].includes(name)) throw new Error('Select a qualification tool.');
    script = resolve(source, 'verification/qualification', name + (name === 'renew-qa-registry-certificate' ? '.sh' : '.py'));
    args.unshift('--config', resolve(project, 'config/packaging/qualification.json'));
    break;
  }
  case 'seeds': {
    const name = args.shift()?.replace(/\.mjs$/, '');
    if (!['assign-seed-user-emails', 'backfill-seed-distances', 'synchronize-seed-profile-details'].includes(name)) throw new Error('Select a supported shared seed command.');
    script = resolve(source, 'release/seeds', name + '.mjs');
    break;
  }
  case 'seed-image-variants':
    script = resolve(source, 'release/seeds/prepare-seed-image-variants.mjs');
    break;
  case 'seed-parity':
    script = resolve(source, 'release/audit/check-seed-parity.py');
    args.unshift('--project-root', project);
    break;
  case 'verify':
    script = containerStack ? resolve(project, 'build/verify-deployment/run.mjs') : resolve(source, 'verification/public/run.mjs');
    break;
  case 'verify-browser':
    script = resolve(source, 'verification/public/browser-smoke.mjs');
    break;
  case 'release': {
    const name = args.shift()?.replace(/\.(sh|py)$/, '');
    if (!releaseScripts.has(name)) throw new Error('Select a supported release script.');
    if (containerStack) {
      if (!['build-production', 'package-production'].includes(name)) throw new Error('Select the configured container-stack build or package command.');
      script = resolve(project, 'build/scripts', `${name}.sh`);
    } else script = resolve(source, 'release', releaseScripts.get(name));
    break;
  }
  case 'prepare-runtime': {
    if (containerStack) process.exit(0);
    script = 'python3';
    args.unshift(resolve(source, 'release/build/stage-runtime.py'), project, resolve(project, 'build/scripts'));
    break;
  }
  case 'test': {
    const selection = JSON.parse(readFileSync(resolve(project, 'config/packaging/tests/selection.json'), 'utf8'));
    const name = args.shift();
    if (name === '--list') {
      process.stdout.write(Object.keys(selection.tests).sort().join('\n') + '\n');
      process.exit(0);
    }
    const test = selection.tests[name];
    if (!test || !['package', 'project'].includes(test.owner)
        || !/^[A-Za-z0-9_./-]+\.(sh|py|mjs)$/.test(test.path)
        || test.path.split('/').includes('..') || test.path.startsWith('/')) {
      throw new Error('Select a configured packaging test.');
    }
    if (!containerStack) prepare();
    script = resolve(test.owner === 'package' ? source : project, test.path);
    if (containerStack && test.owner === 'package' && test.path.startsWith('tests/consumer/')) {
      script = resolve(project, 'build/packaging-tests', test.path.slice('tests/consumer/'.length));
    }
    break;
  }
  case 'runtime': {
    const name = args.shift();
    if (containerStack) {
      if (!['registry-compose.sh', 'qualify-deployment.sh'].includes(name)) throw new Error('Select a configured container-stack host command.');
      script = resolve(project, 'build/scripts', name);
      break;
    }
    const selection = JSON.parse(readFileSync(resolve(project, 'config/packaging/runtime-inputs.json'), 'utf8'));
    if (!selection.files.includes(name) || !/\.(sh|py)$/.test(name)) throw new Error('Select a supported runtime script.');
    const prepared = spawnSync('python3', [resolve(source, 'release/build/stage-runtime.py'), project, resolve(project, 'build/scripts')], { stdio: 'inherit' });
    if (prepared.error) throw prepared.error;
    if (prepared.status !== 0) process.exit(prepared.status ?? 1);
    script = resolve(project, 'build/scripts', name);
    break;
  }
  default:
    throw new Error('Usage: myscoutee-packaging [--project-root ROOT] client SCRIPT [ARGS] | client-tools | release SCRIPT [ARGS] | prepare-runtime | runtime SCRIPT [ARGS] | test NAME|--list | development SCRIPT [ARGS] | qa-release SCRIPT [ARGS] | qualification SCRIPT [ARGS] | seed-parity [ARGS] | verify [ARGS] | verify-browser [ARGS]');
}
const interpreter = script.endsWith('.py') ? 'python3' : script.endsWith('.mjs') ? process.execPath : script.endsWith('.sh') ? 'bash' : script;
const child = spawn(interpreter, interpreter === script ? args : [script, ...args], {
  stdio: 'inherit',
  env: { ...process.env, MYSCOUTEE_PACKAGING_PROJECT_ROOT: project },
});
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => child.kill(signal));
child.on('error', error => { console.error(error.message); process.exitCode = 1; });
child.on('exit', (code, signal) => { process.exitCode = code ?? (signal === 'SIGINT' ? 130 : 1); });
