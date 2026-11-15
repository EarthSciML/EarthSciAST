#!/usr/bin/env node
// The TypeScript batch driver of the document-format gate
// (scripts/run-document-format-gate.py). Needs the built package
// (`npm run build` in pkg/earthsci-ast-ts).
//
//     node typescript_driver.mjs print MANIFEST OUT   canonical form and both printed texts
//     node typescript_driver.mjs parse MANIFEST OUT   read each text back
//
// The gate compares numbers by their canonical kind (an integral value in Int64
// is an integer), which follows from the value, so a plain number is enough. A
// canonical document holds an Int64 value past 2^53 as a bigint, written as its
// digits. An integral number is written with all its digits too (`BigInt`):
// `JSON.stringify` writes the shortest decimal that rounds to the same double,
// which above 2^53 reads back as a different integer (-19999999999999992 as
// -19999999999999990).

import * as fs from 'node:fs'
import * as path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const pkg = path.resolve(here, '../../pkg/earthsci-ast-ts/dist/esm/index.js')
const { canonicalizeDocument, parseDocument, printDocument } = await import(pathToFileURL(pkg).href)

const EXT = { markdown: 'md', typst: 'typ' }
const [mode, manifestPath, out] = process.argv.slice(2)
const items = JSON.parse(fs.readFileSync(manifestPath, 'utf-8'))

function exact(v) {
  if (typeof v === 'bigint') return v.toString()
  if (typeof v === 'number' && Number.isInteger(v)) return BigInt(v).toString()
  if (Array.isArray(v)) return `[${v.map(exact).join(',')}]`
  if (v !== null && typeof v === 'object') {
    const parts = Object.entries(v)
      .filter(([, x]) => x !== undefined)
      .map(([k, x]) => `${JSON.stringify(k)}:${exact(x)}`)
    return `{${parts.join(',')}}`
  }
  return JSON.stringify(v)
}

const message = (e) => (e && e.code ? `${e.code}: ${e.message}` : String(e))

if (mode === 'print') {
  for (const item of items) {
    const stem = path.join(out, item.id)
    let canon
    try {
      canon = canonicalizeDocument(JSON.parse(fs.readFileSync(item.path, 'utf-8')))
      fs.writeFileSync(`${stem}.canon.json`, exact(canon))
    } catch (e) {
      fs.writeFileSync(`${stem}.canon.error`, message(e))
      continue
    }
    for (const [format, ext] of Object.entries(EXT)) {
      try {
        fs.writeFileSync(`${stem}.${ext}`, printDocument(canon, format))
      } catch (e) {
        fs.writeFileSync(`${stem}.${ext}.error`, message(e))
      }
    }
  }
} else if (mode === 'parse') {
  for (const item of items) {
    const stem = path.join(out, item.id)
    try {
      const doc = parseDocument(fs.readFileSync(item.path, 'utf-8'), item.format)
      fs.writeFileSync(`${stem}.json`, exact(doc))
    } catch (e) {
      fs.writeFileSync(`${stem}.error`, message(e))
    }
  }
} else {
  console.error(`unknown mode ${mode}`)
  process.exit(2)
}
