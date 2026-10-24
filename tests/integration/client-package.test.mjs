import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, copyFileSync, cpSync, chmodSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const source = fileURLToPath(new URL('../../', import.meta.url));
const workspace = resolve(source, '..');
const run = (command, args, options = {}) => execFileSync(command, args, { encoding: 'utf8', ...options });

test('release settings and configured audit exceptions', () => {
  run('python3', [resolve(source, 'tests/unit/release-config-test.py')]);
});

test('the packed dependency builds both products outside the workspace', () => {
  const temporary = mkdtempSync(resolve(tmpdir(), 'myscoutee-client-package-'));
  try {
    const [packed] = JSON.parse(run('npm', ['pack', '--json', '--pack-destination', temporary], { cwd: source }));
    const names = packed.files.map(file => file.path);
    for (const name of ['client-tools/install.sh', 'client-tools/client-project.sh', 'client-tools/README.md', 'release/build/package-client-tools.sh', 'debian/postinst', 'debian/defaults.json', 'release/build/render-debian.py', 'release/build/package-production.sh', 'release/build/build-production.sh', 'release/audit/audit-package-credentials.sh', 'release/apply-partial-release-data.sh', 'release/audit/check-seed-parity.py']) {
      assert.ok(names.includes(name), name);
    }
    assert.ok(!names.some(name => name.startsWith('config/') || name.endsWith('.env')
      || (name.includes('credentials') && name !== 'release/audit/audit-package-credentials.sh') || name.endsWith('.pyc')));
    for (const product of ['myscoutee-backend', 'myscoutee-template']) {
      const original = resolve(workspace, product);
      const project = resolve(temporary, product);
      const copy = relative => {
        const target = resolve(project, relative);
        mkdirSync(dirname(target), { recursive: true });
        copyFileSync(resolve(original, relative), target);
        chmodSync(target, 0o644);
      };
      for (const relative of ['config/packaging/release-project.json', 'config/packaging/release/settings.json', 'config/packaging/client-tools/manifest.json', 'config/packaging/client-tools/install.env.example']) copy(relative);
      for (const name of ['control.json', 'purge-policy.json']) copy(`config/packaging/debian/${name}`);
      copy('config/packaging/systemd.json');
      copy('config/packaging/tests/selection.json');
      copy('config/packaging/tests/release-project.json');
      const templateHashes = JSON.parse(readFileSync(resolve(source, 'tests/fixtures/deployment-templates.json')))[product];
      for (const name of Object.keys(templateHashes)) copy(`config/packaging/templates/${name}`);
      copy('config/packaging/runtime-inputs.json');
      const runtime = JSON.parse(readFileSync(resolve(original, 'config/packaging/runtime-inputs.json')));
      for (const relative of Object.values(runtime.projectSources)) copy(relative);
      copy('config/packaging/verification.json');
      const config = resolve(project, 'config/packaging');
      writeFileSync(resolve(config, 'package.json'), JSON.stringify({
        private: true,
        devDependencies: { '@fssrepository/myscoutee-packaging': `file:${resolve(temporary, packed.filename)}` },
      }));
      run('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund'], { cwd: config });
      const installed = resolve(config, 'node_modules/@fssrepository/myscoutee-packaging');
      const baseline = JSON.parse(readFileSync(resolve(source, 'tests/fixtures/debian-products.json')))[product];
      for (const [hook, expected] of Object.entries(baseline.files)) {
        const rendered = run('python3', [resolve(installed, 'release/build/render-debian.py'), resolve(project, 'packaging'), '-', '--hook', hook]);
        assert.equal(createHash('sha256').update(rendered).digest('hex'), expected, `${product}/${hook}`);
      }
      const cli = resolve(installed, 'bin/packaging.mjs');
      assert.match(run('node', [cli, '--project-root', project, 'verify', '--list']), product === 'myscoutee-backend' ? /backend\/landing/ : /backend\/documents/);
      assert.match(run('node', [cli, '--project-root', project, 'test', '--list']), /install-policy-test.py/);
      run('node', [cli, '--project-root', project, 'test', 'install-policy-test.py']);
      const deploymentTemplates = JSON.parse(run('python3', [resolve(installed, 'release/build/render-debian.py'), resolve(project, 'packaging'), '-', '--component', 'templates']));
      assert.deepEqual(Object.keys(deploymentTemplates).sort(), Object.keys(templateHashes).sort());
      for (const [name, content] of Object.entries(deploymentTemplates)) {
        assert.equal(createHash('sha256').update(content).digest('hex'), templateHashes[name]);
      }
      const manager = JSON.parse(readFileSync(resolve(source, 'tests/fixtures/service-manager-products.json')))[product];
      for (const component of ['systemd', 'sysusers']) {
        const files = JSON.parse(run('python3', [resolve(installed, 'release/build/render-debian.py'), resolve(project, 'packaging'), '-', '--component', component]));
        assert.deepEqual(Object.keys(files).sort(), Object.keys(manager.files[component]).sort());
        for (const [name, content] of Object.entries(files)) {
          assert.equal(createHash('sha256').update(content).digest('hex'), manager.files[component][name]);
        }
      }
      run('node', [cli, '--project-root', project, 'prepare-runtime']);
      const runtimeSources = JSON.parse(readFileSync(resolve(installed, 'runtime/sources.json'))).files;
      for (const name of runtime.files) {
        const originalSource = runtime.projectSources[name]
          ? resolve(project, runtime.projectSources[name])
          : resolve(installed, runtime.packageSources[name] ?? runtimeSources[name]);
        assert.deepEqual(readFileSync(resolve(project, 'build/scripts', name)), readFileSync(originalSource));
      }
      const built = run('node', [cli, '--project-root', project, 'release', 'build-production'], {
        env: { ...process.env, MYSCOUTEE_VERSION: '1.0.0', BUILD_FRONTEND: 'false', BUILD_BACKEND: 'false', BUILD_IMAGES: 'false' },
      });
      assert.match(built, /production artifacts for version 1\.0\.0/);
      run('node', [cli, '--project-root', project, 'client', 'install', '--help']);
      const help = run('node', [cli, '--project-root', project, 'client', 'install-temporary-image', '--help']);
      if (product === 'myscoutee-template') assert.ok(!help.includes('Services: nginx, profilemanagement, mongodb, redis, minio, registry'));
      const output = resolve(project, 'dist');
      run('node', [cli, '--project-root', project, 'client-tools'], {
        env: { ...process.env, MYSCOUTEE_VERSION: '1.0.0', MYSCOUTEE_DIST_DIR: output },
      });
      const policy = JSON.parse(readFileSync(resolve(config, 'release-project.json')));
      const archive = resolve(output, `${policy.packageName}-client-tools_1.0.0.tar.gz`);
      const archivedPolicy = JSON.parse(run('tar', ['-xOzf', archive, './release-project.json']));
      assert.deepEqual(archivedPolicy, policy);
      const members = run('tar', ['-tzf', archive]).trim().split('\n');
      const unpacked = resolve(temporary, `${product}-client-tools`);
      mkdirSync(unpacked);
      run('tar', ['-xzf', archive, '-C', unpacked]);
      assert.match(run('node', [resolve(unpacked, 'verify-deployment/run.mjs'), '--list'], { cwd: temporary }), product === 'myscoutee-backend' ? /backend\/landing/ : /backend\/documents/);
      assert.ok(!members.some(name => name.endsWith('.env') || name.includes('credentials')));
      assert.ok(members.includes('./client-project.sh'));
      assert.equal(members.includes('./install-temporary-image.sh'), product === 'myscoutee-backend');
      assert.equal(run('tar', ['-xOzf', archive, './install.sh']), readFileSync(resolve(installed, 'client-tools/install.sh'), 'utf8'));
    }
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});

test('the packed dependency assembles a standalone container stack outside the workspace', () => {
  const temporary = mkdtempSync(resolve(tmpdir(), 'container-stack-package-'));
  try {
    const [packed] = JSON.parse(run('npm', ['pack', '--json', '--pack-destination', temporary], { cwd: source }));
    const original = resolve(workspace, 'myscoutee-registry');
    const project = resolve(temporary, 'standalone-project');
    const config = resolve(project, 'config/packaging');
    mkdirSync(config, { recursive: true });
    for (const relative of ['Dockerfile', 'Dockerfile.dockerignore']) {
      copyFileSync(resolve(original, relative), resolve(project, relative));
    }
    for (const relative of ['container-stack.json', 'build-contexts.json', 'VERSION', 'debian', 'templates', 'compose', 'tests', 'client-tools']) {
      cpSync(resolve(original, 'config/packaging', relative), resolve(config, relative), { recursive: true,
        filter: path => !path.endsWith('/install.env') && !path.endsWith('/deployment.env') && !path.includes('/tls/') });
    }
    const metadata = JSON.parse(readFileSync(resolve(config, 'container-stack.json')));
    for (const relative of [metadata.verifierSource, metadata.documentationSource]) {
      const target = resolve(project, relative);
      mkdirSync(dirname(target), { recursive: true });
      cpSync(resolve(original, relative), target, { recursive: true });
    }
    writeFileSync(resolve(config, 'package.json'), JSON.stringify({ private: true,
      myscouteePackaging: { profile: 'container-stack' },
      devDependencies: { '@fssrepository/myscoutee-packaging': `file:${resolve(temporary, packed.filename)}` } }));
    run('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund'], { cwd: config });
    const installed = resolve(config, 'node_modules/@fssrepository/myscoutee-packaging');
    const cli = resolve(installed, 'bin/packaging.mjs');
    run('node', [cli, '--project-root', project, 'prepare-runtime']);
    const golden = JSON.parse(readFileSync(resolve(source, 'tests/fixtures/container-stack-products.json')));
    for (const [name, expected] of Object.entries(golden)) {
      assert.equal(createHash('sha256').update(readFileSync(resolve(project, 'build', name))).digest('hex'), expected, name);
    }
    assert.match(run('node', [cli, '--project-root', project, 'verify', '--list']), /identity/);
    run('node', [cli, '--project-root', project, 'test', 'docker-build-context-test.sh']);
    run('node', [cli, '--project-root', project, 'test', 'debian-removal-contract-test.sh']);
    const output = resolve(project, 'release-output');
    run('node', [cli, '--project-root', project, 'release', 'package-production', '9.8.7'], {
      env: { ...process.env, BUILD_ARTIFACTS: 'false', PACKAGE_IMAGES: 'false',
        ALLOW_UNBUNDLED_IMAGES_FOR_TESTS: 'true', SOURCE_DATE_EPOCH: '1700000000', MYSCOUTEE_DIST_DIR: output } });
    const deb = resolve(output, 'myscoutee-registry_9.8.7_amd64.deb');
    assert.equal(run('dpkg-deb', ['-f', deb, 'Package']).trim(), 'myscoutee-registry');
    const unpacked = resolve(temporary, 'client'); mkdirSync(unpacked);
    run('tar', ['-xzf', resolve(output, 'myscoutee-registry-client-tools_9.8.7.tar.gz'), '-C', unpacked]);
    assert.match(run('node', [resolve(unpacked, 'verify-deployment/run.mjs'), '--list'], { cwd: temporary }), /identity/);
    assert.equal(JSON.parse(readFileSync(resolve(unpacked, 'forward.json'))).minimumLocalPort, 1024);
  } finally { rmSync(temporary, { recursive: true, force: true }); }
});
