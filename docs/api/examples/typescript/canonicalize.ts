// Put expressions in canonical form so equal expressions compare equal.
import assert from 'node:assert/strict'
import { parseMath, printMath, canonicalize, canonicalJson } from '@earthsciml/ast'
import type { Expr } from '@earthsciml/ast'

// region: canonicalize ops=canonicalize,canonical_json
const names = ['a', 'b']
const a = parseMath('b + a dot 2 + 0', names, 'typst') as Expr
const b = parseMath('0 + 2 a + b', names, 'typst') as Expr

// Operands are ordered and identities dropped.
assert.equal(printMath(canonicalize(a), names, 'typst'), 'b + 2 a')
assert.deepEqual(canonicalize(a), canonicalize(b))

// The canonical JSON text is a stable key for hashing or comparison.
assert.equal(canonicalJson(a), canonicalJson(b))
// endregion
