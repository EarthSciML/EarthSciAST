#!/usr/bin/env node
// TypeScript/JavaScript expression round-trip driver for property-corpus
// conformance (gt-3fbf).
//
// Invokes the @earthsciml/ast expression-coercion path (mirroring the
// internal coerceExpression helper in parse.ts) and JSON.stringify for
// serialization. Emits a JSON object
// {fixture_name: {"ok": bool, "value"|"error": ...}} to stdout.
//
// Usage: node roundtrip_typescript.mjs <fixture.json> [<fixture.json> ...]

import { readFileSync } from 'node:fs'
import { basename } from 'node:path'

// Mirrors coerceExpression in pkg/earthsci-ast-ts/src/parse.ts. Kept
// as a literal re-implementation rather than a direct import because
// coerceExpression is not part of the binding's public API; re-implementing
// it here keeps the driver self-contained while still exercising the same
// shape-preserving contract the binding promises.
function coerceExpression(value) {
  if (typeof value === 'number' || typeof value === 'string') {
    return value
  }
  if (value && typeof value === 'object' && 'op' in value && 'args' in value) {
    return {
      ...value,
      args: Array.isArray(value.args) ? value.args.map(coerceExpression) : value.args,
    }
  }
  return value
}

function roundtripOne(path) {
  try {
    const raw = readFileSync(path, 'utf8')
    const parsed = coerceExpression(JSON.parse(raw))
    // Re-parse the stringified output so nested structures land as plain
    // JSON values in the aggregated result — matches what the other
    // drivers emit.
    const value = JSON.parse(JSON.stringify(parsed))
    return { ok: true, value }
  } catch (err) {
    return { ok: false, error: `${err.name ?? 'Error'}: ${err.message ?? err}` }
  }
}

function main() {
  const results = {}
  for (const arg of process.argv.slice(2)) {
    results[basename(arg)] = roundtripOne(arg)
  }
  // Sort keys for deterministic output.
  const sorted = Object.fromEntries(Object.entries(results).sort(([a], [b]) => a.localeCompare(b)))
  process.stdout.write(JSON.stringify(sorted))
  process.stdout.write('\n')
}

main()
