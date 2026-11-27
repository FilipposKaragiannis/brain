import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { FLOW_CONFIG_SCHEMA } from '../src/plugins/flow/schema.ts';

// The mirror is how tools/lib/migration_steps.py sees the schema: CI's lint job has no Node.
const MIRROR = path.resolve(import.meta.dirname, '..', '..', '..', '..', '..', 'tools', 'config-keys', 'flow-schema.txt');
const DEPRECATED_MARK = ' deprecated';

function schemaLines(): string[] {
  return FLOW_CONFIG_SCHEMA.flatMap((field) => {
    const names = [...(field.keys ?? []).map((key) => key.name), ...(field.counts?.keys ?? [])];
    const paths = [field.path, ...names.map((name) => `${field.path}.${name}`)];
    return paths.map((keyPath) => (field.deprecated === undefined ? keyPath : `${keyPath}${DEPRECATED_MARK}`));
  }).sort();
}

function mirrorLines(): string[] {
  return readFileSync(MIRROR, 'utf8').split('\n').filter((line) => line !== '');
}

test('SchemaKey_NotInTheMirror_ListedAsMissing', () => {
  const schema = schemaLines();
  const mirror = new Set(mirrorLines());
  assert.ok(schema.length > 0, 'because the schema lists keys to mirror');
  const missing = schema.filter((line) => !mirror.has(line));
  assert.deepEqual(missing, [], `because ${MIRROR} lists every schema key; add these lines, sorted`);
});

test('MirrorLine_NotInTheSchema_ListedAsExtra', () => {
  const schema = new Set(schemaLines());
  const mirror = mirrorLines();
  assert.ok(mirror.length > 0, 'because the mirror lists keys to compare');
  const extra = mirror.filter((line) => !schema.has(line));
  assert.deepEqual(extra, [], `because ${MIRROR} lists only schema keys; take these lines out`);
});
