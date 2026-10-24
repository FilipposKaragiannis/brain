import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseYaml, yamlList, yamlMap, yamlString } from '../src/yaml.ts';

const SOURCE = `# comment
base: main   # trailing comment
adapters:
  default: github
github:
  repo: "FJ2K/foosbrawl"
  priority_order: [P0, P1, P2]
pool:
  - ../wt-2
  - ../wt-3
pool_max: 9
notify:
  slack_webhook: ""
jobs:
  schedule:
    next: every 30m --workers 2 --max-steps 15
`;

test('TopLevelScalar_ReadWithoutTrailingComment', () => {
  assert.equal(yamlString(parseYaml(SOURCE), 'base'), 'main', 'because a trailing comment is not part of the value');
});

test('NestedQuotedScalar_QuotesStripped', () => {
  assert.equal(yamlString(parseYaml(SOURCE), 'github.repo'), 'FJ2K/foosbrawl', 'because yaml_get strips quotes the same way');
});

test('BlockList_ReadInOrder', () => {
  assert.deepEqual(yamlList(parseYaml(SOURCE), 'pool'), ['../wt-2', '../wt-3'], 'because pool order is the claim order');
});

test('InlineList_SplitOnCommas', () => {
  assert.deepEqual(yamlList(parseYaml(SOURCE), 'github.priority_order'), ['P0', 'P1', 'P2'], 'because inline lists are the second list shape the config allows');
});

test('EmptyQuotedScalar_IsEmptyString', () => {
  assert.equal(yamlString(parseYaml(SOURCE), 'notify.slack_webhook'), '', 'because an empty webhook disables Slack and must not read as missing');
});

test('ValueWithColons_KeptWhole', () => {
  assert.equal(yamlMap(parseYaml(SOURCE), 'jobs.schedule')['next'], 'every 30m --workers 2 --max-steps 15', 'because only the first colon separates the key');
});

test('MissingPath_IsNullAndEmptyList', () => {
  const map = parseYaml(SOURCE);
  assert.equal(yamlString(map, 'nothing.here'), null, 'because absence is null, not an empty string');
  assert.deepEqual(yamlList(map, 'nothing.here'), [], 'because a missing list reads as empty');
});
