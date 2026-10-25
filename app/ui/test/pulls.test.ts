import { expect, test } from 'vitest';
import { pullLabel, pullUrl } from '../src/pulls.ts';

test('PullNumberWithRepo_LinksToGitHub', () => {
  expect(pullUrl('#560', 'FJ2K/foosbrawl'), 'because the board stores a bare number and the repo gives it a home').toBe('https://github.com/FJ2K/foosbrawl/pull/560');
});

test('PullThatIsAlreadyAUrl_KeptAsIs', () => {
  expect(pullUrl('https://example.test/pr/9', null), 'because a full link needs no rebuilding').toBe('https://example.test/pr/9');
});

test('PullNumberWithoutRepo_HasNoLink', () => {
  expect(pullUrl('560', null), 'because a link without a repo would point nowhere').toBeNull();
});

test('PullUrl_LabelledByItsNumber', () => {
  expect(pullLabel('https://github.com/FJ2K/foosbrawl/pull/560'), 'because a table cell reads better as #560 than as a full link').toBe('#560');
});
