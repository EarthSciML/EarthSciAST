// Put expressions in canonical form so equal expressions compare equal.
import assert from 'node:assert/strict'
import { parseExpression, canonicalize, canonicalJson, toAscii } from '@earthsciml/ast'

// region: canonicalize ops=canonicalize,canonical_json
const a = parseExpression('b + a*2 + 0')
const b = parseExpression('0 + 2*a + b')

// Operands are ordered and identities dropped.
assert.equal(toAscii(canonicalize(a)), 'b + 2 * a')
assert.deepEqual(canonicalize(a), canonicalize(b))

// The canonical JSON text is a stable key for hashing or comparison.
assert.equal(canonicalJson(a), canonicalJson(b))
// endregion
