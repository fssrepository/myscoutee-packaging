import { verification } from './configuration.mjs';
const selected = await import(`./contracts/${verification.publicContent}.mjs`);
export const PROJECT_CHECK_CATALOG = selected.PROJECT_CHECK_CATALOG;
export const buildProjectChecks = selected.buildProjectChecks;
