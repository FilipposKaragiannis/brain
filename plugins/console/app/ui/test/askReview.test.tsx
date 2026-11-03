import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import { AskReview } from '../src/askReview.tsx';
import { FakeDaemon } from './fakeDaemon.tsx';

afterEach(cleanup);

function offered(reviewers: string[]): string[] {
  const Wrapper = new FakeDaemon().screenWrapper();
  render(<Wrapper><AskReview pr={20} reviewers={reviewers} /></Wrapper>);
  return [...(screen.getByLabelText('Ask for review from') as HTMLSelectElement).options].map((option) => option.textContent ?? '');
}

test('ProjectReviewers_FirstThenTheOtherSupportedReviewersThenOther', () => {
  expect(offered(['codex', 'claude']), 'because the project\'s reviewers lead, copilot follows as the one supported reviewer left, and any login comes last').toEqual(['codex', 'claude', 'copilot', 'other…']);
});

test('ProjectReviewerALogin_EverySupportedReviewerStillOffered', () => {
  expect(offered(['octo-cat']), 'because a project that names only a person can still ask any reviewer the flow supports').toEqual(['octo-cat', 'codex', 'claude', 'copilot', 'other…']);
});

test('SupportedReviewerNamedInOtherCase_OfferedOnce', () => {
  expect(offered(['Copilot']), 'because a name GitHub reads without case is one reviewer, listed where the project put it').toEqual(['Copilot', 'codex', 'claude', 'other…']);
});
