/**
 * Unit tests for the shared POSIX path helpers (path-utils.ts). These pin the
 * canonical behavior extracted from the byte-identical
 * `template-imports.ts` / `ref-loading.ts` helpers.
 */

import { describe, it, expect } from 'vitest'
import {
  isRemoteRef,
  joinPath,
  canonicalizePath,
  normalizeRef,
  readFileSyncNode,
} from './path-utils.js'

describe('isRemoteRef', () => {
  it('detects http/https refs', () => {
    expect(isRemoteRef('http://example.com/a.esm')).toBe(true)
    expect(isRemoteRef('https://example.com/a.esm')).toBe(true)
  })

  it('rejects local and other-scheme refs', () => {
    expect(isRemoteRef('a/b.esm')).toBe(false)
    expect(isRemoteRef('/abs/a.esm')).toBe(false)
    expect(isRemoteRef('./rel.esm')).toBe(false)
    expect(isRemoteRef('ftp://example.com/a.esm')).toBe(false)
    expect(isRemoteRef('file:///a.esm')).toBe(false)
  })
})

describe('joinPath', () => {
  it('returns an absolute ref outright', () => {
    expect(joinPath('/base/dir', '/abs/ref.esm')).toBe('/abs/ref.esm')
  })

  it('joins with exactly one separator when base has no trailing slash', () => {
    expect(joinPath('/base/dir', 'ref.esm')).toBe('/base/dir/ref.esm')
    expect(joinPath('base', 'ref.esm')).toBe('base/ref.esm')
  })

  it('does not double the separator when base ends with a slash', () => {
    expect(joinPath('/base/dir/', 'ref.esm')).toBe('/base/dir/ref.esm')
  })

  it('leaves ".." un-collapsed (collapse is canonicalizePath’s job)', () => {
    expect(joinPath('/base/dir', '../sibling/ref.esm')).toBe('/base/dir/../sibling/ref.esm')
  })
})

describe('canonicalizePath', () => {
  it('collapses "." and ".." for absolute paths and keeps the root', () => {
    expect(canonicalizePath('/base/dir/../sibling/./ref.esm')).toBe('/base/sibling/ref.esm')
    expect(canonicalizePath('/a/b/../../c')).toBe('/c')
  })

  it('never escapes the root for absolute paths', () => {
    expect(canonicalizePath('/../../x')).toBe('/x')
  })

  it('retains leading ".." for relative paths', () => {
    expect(canonicalizePath('../a/b')).toBe('../a/b')
    expect(canonicalizePath('a/../../b')).toBe('../b')
  })

  it('reduces an emptied relative path to "."', () => {
    expect(canonicalizePath('a/..')).toBe('.')
    expect(canonicalizePath('./')).toBe('.')
  })

  it('is idempotent', () => {
    for (const p of ['/base/dir/../sibling/ref.esm', '../a/b', 'a/../../b', '/a/b/c']) {
      const once = canonicalizePath(p)
      expect(canonicalizePath(once)).toBe(once)
    }
  })
})

describe('normalizeRef (cycle-detection key)', () => {
  it('returns remote refs verbatim, ignoring the base', () => {
    expect(normalizeRef('https://x/a.esm', '/base')).toBe('https://x/a.esm')
  })

  it('joins + collapses local refs against the base', () => {
    expect(normalizeRef('../lib/b.esm', '/base/dir')).toBe('/base/lib/b.esm')
    expect(normalizeRef('./b.esm', '/base/dir')).toBe('/base/dir/b.esm')
  })

  it('keys different spellings of the same file identically', () => {
    const a = normalizeRef('a/../lib/b.esm', '/base')
    const b = normalizeRef('./lib/b.esm', '/base')
    expect(a).toBe(b)
    expect(a).toBe('/base/lib/b.esm')
  })

  it('normalizes backslash bases to POSIX (superset of canonicalRef)', () => {
    expect(normalizeRef('b.esm', 'C:\\base\\dir')).toBe(normalizeRef('b.esm', 'C:/base/dir'))
  })

  it('canonicalizes the bare ref when the base is omitted or empty', () => {
    expect(normalizeRef('a/../b.esm')).toBe('b.esm')
    expect(normalizeRef('a/../b.esm', '')).toBe('b.esm')
  })
})

describe('readFileSyncNode', () => {
  it('reads a real file synchronously under Node', () => {
    // This test file itself is guaranteed to exist and be readable.
    const contents = readFileSyncNode(__filename)
    expect(contents).toContain('readFileSyncNode')
  })

  it('throws for a missing path', () => {
    expect(() => readFileSyncNode('/no/such/file/really.esm')).toThrow()
  })
})
