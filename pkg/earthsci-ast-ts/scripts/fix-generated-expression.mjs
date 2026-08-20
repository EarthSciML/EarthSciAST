#!/usr/bin/env node
/**
 * fix-generated-expression.mjs — repair the one thing `json2ts` gets wrong
 * about `src/generated.ts`, immediately after it is generated.
 *
 * The schema's `Expression` is `oneOf: [number, string, ExpressionNode]`, and
 * `ExpressionNode` carries an `allOf` of conditional arity rules. json2ts
 * handles that composition by splitting the node into
 * `ExpressionNode = ExpressionNode1 & { … }`, where `ExpressionNode1` is the
 * bare index signature `{ [k: string]: unknown }`. It then inlines EVERY
 * `$ref: Expression` as `number | string | ExpressionNode1` — dropping the
 * half of the node type that carries `op` and `args`.
 *
 * The result is a supertype of the truth: `node.expr`, `affect.rhs`,
 * `reaction.rate`, `template.body` and friends read as "a string, a number, or
 * literally any object". Until esm 1.0.0 that looseness was invisible because
 * `Expression` ITSELF resolved to the same degenerate union, so the two agreed.
 * 1.0.0's schema restructure made `Expression` resolve correctly while the
 * inlined copies stayed degenerate, and the disagreement surfaced at ~120 call
 * sites at once.
 *
 * Rewriting the inlined copies back to `Expression` is a faithful repair, not a
 * loosening: it restores exactly what the schema says. The alternative — a
 * hand-written override per containing type in `types.ts` — has to be extended
 * every time the schema grows another Expression-valued field, and silently
 * under-covers until someone notices, which is how this drifted in the first
 * place.
 *
 * Runs as part of `npm run generate-types`. Fails loudly if the patterns it
 * expects are absent, so a json2ts upgrade that fixes this upstream (or changes
 * the spelling) is a build error rather than a silent no-op.
 */
import { readFileSync, writeFileSync } from 'node:fs'

const target = new URL('../src/generated.ts', import.meta.url)
const original = readFileSync(target, 'utf-8')

// The declaration of ExpressionNode itself is the ONE legitimate use of
// `ExpressionNode1` and must survive untouched.
const NODE_DECL = 'export type ExpressionNode = ExpressionNode1 & {'
if (!original.includes(NODE_DECL)) {
  throw new Error(
    'fix-generated-expression: `export type ExpressionNode = ExpressionNode1 & {` not found. ' +
      'json2ts output shape changed; re-check whether this repair is still needed.',
  )
}

let patched = original

// 1. The inlined Expression union, wherever a field was `$ref: Expression`.
const inlined = /number \| string \| ExpressionNode1/g
const inlinedCount = (patched.match(inlined) || []).length
patched = patched.replace(inlined, 'Expression')

// 2. The `CouplingVariableMap.transform` union, whose Expression branch is a
//    node specifically (a bare reference or literal is not admissible there).
const transformBranch = /\) \| ExpressionNode1;/g
const transformCount = (patched.match(transformBranch) || []).length
patched = patched.replace(transformBranch, ') | ExpressionNode;')

if (inlinedCount === 0 && transformCount === 0) {
  throw new Error(
    'fix-generated-expression: found no `number | string | ExpressionNode1` and no ' +
      '`) | ExpressionNode1;` to repair. Either json2ts now emits `Expression` directly ' +
      '(in which case delete this script and its npm-script step) or the spelling changed.',
  )
}

// `Expression` is declared AFTER some of its uses in json2ts output; TypeScript
// type aliases hoist, so ordering is immaterial. Guard that it exists at all.
if (!/^export type Expression = /m.test(patched)) {
  throw new Error('fix-generated-expression: no `export type Expression =` declaration found.')
}

writeFileSync(target, patched)
console.log(
  `fix-generated-expression: rewrote ${inlinedCount} inlined Expression union(s) and ` +
    `${transformCount} transform branch(es) in src/generated.ts`,
)
