// The minimal landing has public documents, without MyScoutee ideas or slides.
import { assert, expectArray, expectContentType, expectInteger, expectJson,
  expectObject, expectStatus, expectString } from '../lib/assertions.mjs';

export const PROJECT_CHECK_CATALOG = [['backend/documents', 'seeded public help, privacy, terms and guide']];

export function buildProjectChecks(ctx) {
  return [{ id: PROJECT_CHECK_CATALOG[0][0], name: PROJECT_CHECK_CATALOG[0][1], run: async () => {
    for (const kind of ['help', 'privacy', 'terms', 'explanation']) {
      const result = await ctx.get(`/api/${kind}/active?lang=en${kind === 'explanation' ? '&contextKey=home' : ''}`, {
        maxBodyBytes: 4 * 1024 * 1024
      });
      expectStatus(result, 200, `${kind} document`);
      expectContentType(result, 'json', `${kind} document`);
      const document = expectObject(expectJson(result, kind), kind);
      const revision = expectObject(document.activeRevision, `${kind}.activeRevision`);
      assert(revision.documentKind === kind && revision.lang === 'en' && revision.active === true,
        `${kind} should have an active English revision`);
      expectInteger(revision.version, `${kind}.version`, { min: 1 });
      expectString(revision.title, `${kind}.title`);
      assert(expectArray(revision.sections, `${kind}.sections`).length > 0,
        `${kind} should contain seeded sections`);
    }
  }}];
}
