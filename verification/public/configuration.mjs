import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

// A client archive carries its selected policy beside the verifier. Source
// invocations bind the existing application configuration through the CLI.
const file = process.env.MYSCOUTEE_PACKAGING_PROJECT_ROOT
  ? resolve(process.env.MYSCOUTEE_PACKAGING_PROJECT_ROOT, 'config/packaging/verification.json')
  : new URL('./project.json', import.meta.url);
export const verification = JSON.parse(readFileSync(file, 'utf8'));
if (verification.schemaVersion !== 1
    || !['hashed', 'immutable'].includes(verification.assetCache)
    || !['landing', 'documents'].includes(verification.publicContent)) {
  throw new Error('Invalid deployment verification configuration.');
}
