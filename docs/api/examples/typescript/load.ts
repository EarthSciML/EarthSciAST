// Read an .esm document from a path, and from a JSON string.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { loadPath, loadString } from '@earthsciml/ast'

const fixture = (name: string): string => fileURLToPath(new URL(`../fixtures/${name}`, import.meta.url))
const decayPath = fixture('decay.esm')

// region: load ops=load_path,load_string
// From a file on disk:
const doc = loadPath(decayPath)
assert.deepEqual(Object.keys(doc.models ?? {}), ['Decay'])
assert.equal(doc.metadata.name, 'Decay')

// From JSON text you already hold (a fetch response, a database row, ...):
const text = readFileSync(decayPath, 'utf8')
const same = loadString(text)
const model = same.models!.Decay
// A `models` entry is a Model or, before `resolveSubsystemRefs`, a `{ ref }` mount.
assert.ok(!('ref' in model))
assert.deepEqual(Object.keys(model.variables), ['N', 'lambda', 'half_life'])
// endregion
