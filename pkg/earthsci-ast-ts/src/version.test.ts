import { describe, it, expect } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { LIBRARY_VERSION } from './version.js'
import { SCHEMA_VERSION } from './parse.js'
import { schema } from './embedded-schema.js'

const here = path.dirname(fileURLToPath(import.meta.url))

describe('version constants', () => {
  it('LIBRARY_VERSION mirrors package.json', () => {
    const pkg = JSON.parse(fs.readFileSync(path.join(here, '..', 'package.json'), 'utf-8')) as {
      version: string
    }
    expect(LIBRARY_VERSION).toBe(pkg.version)
  })

  it('SCHEMA_VERSION is the bundled schema $id version', () => {
    const id = (schema as { $id?: string }).$id ?? ''
    expect(id).toContain(`/esm/${SCHEMA_VERSION}/`)
  })

  it('the two constants are separate concepts, not an alias pair', () => {
    // Guards the regression this split exists to prevent: re-exporting one
    // under the other's name (`SCHEMA_VERSION as VERSION`) made the package
    // version unobservable from TypeScript entirely.
    expect(typeof LIBRARY_VERSION).toBe('string')
    expect(typeof SCHEMA_VERSION).toBe('string')
  })
})
