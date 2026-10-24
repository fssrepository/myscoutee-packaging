// Product-owned public content contract; shared deployment checks stay in checks.mjs.
import { assert, expectArray, expectContentType, expectInteger, expectJson,
  expectObject, expectStatus, expectString } from '../lib/assertions.mjs';

export const PROJECT_CHECK_CATALOG = [['backend/landing', 'seeded public landing content']];
export function buildProjectChecks(ctx) {
  return [
    { id: 'backend/landing', name: 'seeded public landing content', run: async () => {
      const result = await ctx.get('/api/landing/content?lang=en', {
        maxBodyBytes: 4 * 1024 * 1024
      });
      expectStatus(result, 200, 'English landing content');
      expectContentType(result, 'json', 'English landing content');
      const landing = expectObject(expectJson(result, 'English landing content'), 'English landing content');
      assertActiveDocument(landing.privacy, 'privacy');
      assertActiveDocument(landing.terms, 'terms');
      const ideas = expectArray(landing.ideas, 'English landing content.ideas');
      assert(ideas.length > 0, 'fresh package landing content should include featured ideas');
      const ideasTotal = expectInteger(
        landing.ideasTotal,
        'English landing content.ideasTotal',
        { min: 0 }
      );
      assert(
        ideasTotal >= ideas.length,
        'landing ideasTotal should cover the returned preview',
        { ideasTotal, returned: ideas.length }
      );
      for (const [index, ideaValue] of ideas.entries()) {
        const idea = expectObject(ideaValue, `English landing content.ideas[${index}]`);
        assert(idea.featured === true, `landing idea ${index} should be featured`);
        assert(idea.published === true, `landing idea ${index} should be published`);
      }
      assert(
        landing.loginAvailability === null || landing.loginAvailability === undefined,
        'landing request without coordinates should not calculate login availability'
      );
    }}
  ];
}

function assertActiveDocument(value, kind) {
  const state = expectObject(value, `English landing content.${kind}`);
  const revision = expectObject(
    state.activeRevision,
    `English landing content.${kind}.activeRevision`
  );
  assert(
    revision.documentKind === kind,
    `English landing ${kind} revision should identify documentKind=${kind}`,
    { documentKind: revision.documentKind }
  );
  assert(revision.lang === 'en', `English landing ${kind} revision should use lang=en`, {
    lang: revision.lang
  });
  expectInteger(revision.version, `English landing ${kind} revision.version`, { min: 1 });
  expectString(revision.title, `English landing ${kind} revision.title`);
  const sections = expectArray(revision.sections, `English landing ${kind} revision.sections`);
  assert(sections.length > 0, `English landing ${kind} revision should contain sections`);
}

