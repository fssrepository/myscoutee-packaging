import { mkdir, stat, readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import path from 'node:path';

const ROOT = process.env.MYSCOUTEE_PACKAGING_PROJECT_ROOT || process.cwd();
const configuration = JSON.parse(await readFile(path.join(ROOT, 'config/packaging/seed-images.json'), 'utf8'));
const options = parseArgs(process.argv.slice(2));
if (!options.source || !options.kind || !options.key) {
  throw new Error('Usage: npm --prefix config/packaging run seed-image-variants -- --source FILE --kind KIND --key KEY');
}

const selected = configuration.kinds[options.kind];
if (!selected) throw new Error(`Unsupported configured image kind: ${options.kind}`);
options.source = path.resolve(ROOT, options.source);
await stat(options.source);
const targetDirectory = path.join(ROOT, selected.directory.replace('{key}', options.key));
await mkdir(targetDirectory, { recursive: true });
const variants = selected.variants;

for (const variant of variants) {
  const target = path.join(targetDirectory, `${variant.name}.webp`);
  try {
    await stat(target);
    if (!options.force) throw new Error(`Refusing to overwrite ${path.relative(ROOT, target)}; pass --force intentionally.`);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  const result = spawnSync('convert', [
    options.source,
    '-auto-orient',
    '-resize', `${variant.width}x${variant.height}^`,
    '-gravity', 'center',
    '-extent', `${variant.width}x${variant.height}`,
    '-strip',
    '-define', 'webp:method=6',
    '-quality', `${variant.quality}`,
    target
  ], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(result.stderr || `ImageMagick failed with ${result.status}`);
}

console.log(JSON.stringify({ kind: options.kind, key: options.key, targetDirectory: path.relative(ROOT, targetDirectory) }));

function parseArgs(args) {
  const result = { force: false };
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] === '--force') result.force = true;
    else if (args[index]?.startsWith('--')) result[args[index].slice(2)] = args[index + 1], index += 1;
  }
  return result;
}
