#!/usr/bin/env node

import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

const repositoryRoot = process.env.MYSCOUTEE_PACKAGING_PROJECT_ROOT || process.cwd();
const config = JSON.parse(await readFile(path.join(repositoryRoot, 'config/packaging/seeds/data/seed-distances.json'), 'utf8'));
const seedFiles = config.files.map(file => path.join(repositoryRoot, file));

function hashText(value) {
  let hash = 0;
  for (let index = 0; index < value.length; index += 1) {
    hash = (hash * 31 + value.charCodeAt(index)) % config.hashModulus;
  }
  return Math.abs(hash);
}

function field(record, name) {
  return name.split('.').reduce((value, key) => value?.[key], record);
}

function seedIdentity(record) {
  return field(record, config.identity.preferred)
    ?? config.identity.fallback.map(name => field(record, name)).join(':');
}

function seedDistanceMeters(record) {
  const seed = hashText(`${config.salt}${seedIdentity(record)}`);
  return ((config.minimumKilometers + (seed % config.kilometerRange)) * 1000) + (seed % config.meterRange);
}

for (const seedFile of seedFiles) {
  const records = JSON.parse(await readFile(seedFile, 'utf8'));
  for (const record of records) {
    record[config.targetField] = seedDistanceMeters(record);
  }
  await writeFile(seedFile, `${JSON.stringify(records, null, 2)}\n`);
  process.stdout.write(`${path.relative(repositoryRoot, seedFile)}: ${records.length} records updated\n`);
}
