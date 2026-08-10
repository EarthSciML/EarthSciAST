#!/usr/bin/env node
/**
 * generate-standalone-validator.mjs — precompile the ESM schema into a
 * validator module, so no JavaScript is generated at runtime.
 *
 * ## Why this exists
 *
 * Ajv is a code generator: `ajv.compile(schema)` builds JavaScript source for
 * the schema and evaluates it with `new Function`. That is why it is fast, and
 * it is also why it cannot run under a Content-Security-Policy without
 * `'unsafe-eval'`.
 *
 * `parse.ts` compiled at MODULE LOAD time and threw on failure, so a consuming
 * app with a strict `script-src` did not lose validation — it lost everything.
 * The module threw before anything rendered, and the page was blank. Granting
 * `'unsafe-eval'` to get it back is the wrong trade for an app that renders
 * untrusted documents: it re-permits exactly the string-to-code execution a CSP
 * is bought to prevent.
 *
 * Precompiling is Ajv's own documented answer (`ajv/dist/standalone`). The
 * generated module contains the same validation logic as plain source, so the
 * browser only ever loads code, never builds it.
 *
 * ## Keeping it honest
 *
 * A precompiled artifact is a copy, and copies drift. This mirrors
 * `generate-embedded-schema.mjs` exactly:
 *
 *   npm run generate-validator                                 # rewrite
 *   node scripts/generate-standalone-validator.mjs --check     # drift guard
 *
 * and `scripts/sync-schema.sh --check` runs both, so a schema change that is
 * not accompanied by a regenerated validator fails CI rather than shipping a
 * validator for last week's schema.
 *
 * The Ajv options here MUST match `parse.ts`'s former runtime options exactly,
 * or the generated validator reports different errors than the one it replaces.
 * They are defined once in `src/ajv-options.mjs` and imported by both.
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

import Ajv from 'ajv'
import addFormats from 'ajv-formats'
import standaloneCode from 'ajv/dist/standalone/index.js'

import { AJV_OPTIONS } from '../src/ajv-options.mjs'

const here = dirname(fileURLToPath(import.meta.url))
// scripts/ -> package root -> pkg/ -> repo root
const CANONICAL = resolve(here, '..', '..', '..', 'esm-schema.json')
const OUTPUT = resolve(here, '..', 'src', 'generated-validator.js')

const BANNER = `/* eslint-disable */
// @ts-nocheck
/**
 * generated-validator.js — GENERATED FILE. DO NOT EDIT BY HAND.
 *
 * The canonical repo-root \`esm-schema.json\`, precompiled by Ajv into a
 * standalone validator (\`scripts/generate-standalone-validator.mjs\`).
 *
 * This exists so that validating an .esm document requires no runtime code
 * generation. \`ajv.compile()\` builds JavaScript and evaluates it, which a
 * Content-Security-Policy without 'unsafe-eval' forbids — and because the
 * compile happened at module load, a strict CSP did not degrade validation, it
 * blanked the whole application.
 *
 * To change the schema, edit \`esm-schema.json\` and run:
 *   npm run generate-schema && npm run generate-validator
 * The drift guard \`scripts/sync-schema.sh --check\` fails CI if this file falls
 * out of sync.
 */
`

/**
 * Turn the `require()` calls Ajv leaves behind into ES imports.
 *
 * `code.esm` only rewrites the EXPORT statements — see `funcExportCode` in
 * `ajv/dist/standalone`. Anything the schema pulls in from Ajv's scope is
 * emitted verbatim as `require("…")`, because that is how `ajv-formats` and
 * Ajv's own runtime register their helpers. In a `"type": "module"` package
 * that is an immediate `ReferenceError: require is not defined`.
 *
 * ## The interop, measured rather than assumed
 *
 * Node and bundlers disagree about what a CommonJS module's `default` is, and
 * the disagreement is silent — each spelling below works in exactly one of the
 * two, so a validator that passes `npm test` can still be broken in the app (or
 * the reverse). Measured against `ajv/dist/runtime/ucs2length.js`, which is
 * TypeScript-compiled CJS (`exports.default = fn`, `__esModule: true`):
 *
 *   import form                | Node                  | Vite / Vitest
 *   ---------------------------|-----------------------|---------------
 *   default / {default as x}   | module.exports        | the function
 *   namespace .default         | module.exports        | the function
 *   any other named import     | that export           | that export
 *
 * So a plain named import is unambiguous for every name EXCEPT `default`, and
 * that one case gets the standard `__esModule` normalization — which is correct
 * in both because it asks the module what it is rather than guessing:
 *
 *   Node   `m.__esModule` is true  -> take `m.default`  (m is module.exports)
 *   Vite   `m.__esModule` absent   -> take `m`          (m is already the value)
 *
 * Getting this wrong does not fail at import. It fails as "func5 is not a
 * function" the first time a document is validated, which is how each wrong
 * spelling was found.
 *
 * The transform is deliberately narrow: `require` applied to a double-quoted
 * literal AND immediately followed by a property access. Anything surviving is
 * an error, because the failure mode of guessing is a validator that imports
 * the wrong shape and dies on first use.
 */
function requiresToImports(code) {
  // specifier -> (property -> alias)
  const specs = new Map()
  const CALL = /require\("((?:[^"\\]|\\.)*)"\)\.([A-Za-z_$][\w$]*)/g

  const body = code.replace(CALL, (_, spec, prop) => {
    if (!specs.has(spec)) specs.set(spec, new Map())
    const props = specs.get(spec)
    if (!props.has(prop)) props.set(prop, `__dep${specs.size - 1}_${prop}`)
    return props.get(prop)
  })

  // Nothing may survive. A bare `require("x")` with no property access, or a
  // dynamic one, means Ajv emitted a shape this does not understand.
  if (/\brequire\s*\(/.test(body)) {
    const at = body.search(/\brequire\s*\(/)
    throw new Error(
      `generated validator has a require() this rewrite does not handle: ` +
        `${body.slice(at, at + 80)}`,
    )
  }

  // Ajv writes CJS specifiers, which may omit the file extension
  // (`ajv-formats/dist/formats`). Node's ESM resolver does not add one, so the
  // import fails with ERR_MODULE_NOT_FOUND — in this package's own tests, which
  // import from `src/`, even though a bundler would have resolved it happily.
  // Add the extension, then PROVE both the module and every name resolve: if a
  // future Ajv emits something this does not handle, generation must fail here
  // rather than ship a module that throws on first use.
  const require_ = createRequire(import.meta.url)
  const lines = []
  for (const [spec, props] of [...specs].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) {
    const withExt = /\.[cm]?js$/.test(spec) ? spec : `${spec}.js`
    let mod
    try {
      mod = require_(require_.resolve(withExt))
    } catch (e) {
      throw new Error(`generated validator imports ${withExt}, which does not resolve: ${e}`)
    }

    const named = []
    for (const [prop, alias] of [...props].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) {
      if (!(prop in mod)) {
        throw new Error(`generated validator wants ${prop} from ${withExt}, which lacks it`)
      }
      if (prop === 'default') {
        // The one ambiguous name — see the interop table above.
        const ns = `${alias}__mod`
        lines.push(`import ${ns} from ${JSON.stringify(withExt)}`)
        lines.push(`const ${alias} = ${ns} && ${ns}.__esModule ? ${ns}.default : ${ns}`)
      } else {
        named.push(`${prop} as ${alias}`)
      }
    }
    if (named.length) {
      lines.unshift(`import { ${named.join(', ')} } from ${JSON.stringify(withExt)}`)
    }
  }

  // After `"use strict";`, which standaloneCode always emits first.
  const marker = '"use strict";'
  if (body.indexOf(marker) !== 0) {
    throw new Error('generated validator did not start with "use strict";')
  }
  return marker + '\n' + lines.join('\n') + '\n' + body.slice(marker.length)
}

/** Render the full text of the generated module. Pure in the schema's bytes. */
function render() {
  const schema = JSON.parse(readFileSync(CANONICAL, 'utf8'))

  // `code.source` is what makes the compiled function serializable; `code.esm`
  // gets the exports right (the imports are this script's job — see above).
  const ajv = new Ajv({ ...AJV_OPTIONS, code: { source: true, esm: true } })
  addFormats(ajv)

  const validate = ajv.compile(schema)
  return BANNER + requiresToImports(standaloneCode(ajv, validate))
}

const expected = render()

if (process.argv.includes('--check')) {
  let actual = ''
  try {
    actual = readFileSync(OUTPUT, 'utf8')
  } catch {
    console.error(`DRIFT: ${OUTPUT} is missing. Run: npm run generate-validator`)
    process.exit(1)
  }
  if (actual !== expected) {
    console.error(
      `DRIFT: src/generated-validator.js is out of sync with esm-schema.json.\n` +
        `       Run: npm run generate-validator`,
    )
    process.exit(1)
  }
  console.log('OK: src/generated-validator.js matches esm-schema.json')
} else {
  writeFileSync(OUTPUT, expected)
  console.log(`Wrote ${OUTPUT}`)
}
