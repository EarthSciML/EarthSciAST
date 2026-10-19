// Validate a good document, then read the errors reported for a bad one.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { loadPath, loadString, validate, validateText, ParseError } from '@earthsciml/ast'
import type { UnitWarning } from '@earthsciml/ast'

const fixture = (name: string): string => fileURLToPath(new URL(`../fixtures/${name}`, import.meta.url))

// region: validate ops=validate,validate_text,validation_result,validation_error,parse_error
// A good document validates cleanly.
const good = validate(loadPath(fixture('decay.esm')))
assert.equal(good.is_valid, true)
assert.deepEqual(good.structural_errors, [])

// `validate` reports problems in its result; it does not throw. invalid.esm
// uses a variable `k` that its model never declares.
const bad = validateText(readFileSync(fixture('invalid.esm'), 'utf8'))
assert.equal(bad.is_valid, false)
assert.equal(bad.schema_errors.length, 0)
const [err] = bad.structural_errors
assert.equal(err.code, 'undefined_variable')
assert.equal(err.path, '/models/Broken/equations/0/rhs')
assert.match(err.message, /Variable "k" referenced in equation is not declared/)

// Loading a structurally invalid document still succeeds. Unit warnings found
// while loading go to `console.warn` unless you collect them yourself.
const warnings: UnitWarning[] = []
const broken = loadPath(fixture('invalid.esm'), { onUnitWarning: (w) => warnings.push(w) })
assert.equal(validate(broken).is_valid, false)
assert.match(warnings[0].message, /Unknown variable: k/)

// Text that is not JSON at all is a `ParseError`, thrown at load time.
assert.throws(() => loadString('{ not json'), ParseError)
// endregion
