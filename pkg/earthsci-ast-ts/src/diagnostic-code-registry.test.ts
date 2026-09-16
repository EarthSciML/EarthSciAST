/**
 * Every diagnostic code this binding raises is a registered one.
 *
 * The code strings are a cross-binding wire contract (esm-spec §9.6.6 calls
 * the table "cross-language uniform"), and a code that reaches a raise site
 * without going through `ERROR_CODES` is exactly how one binding silently
 * drifts from the others. This test parses `src/` with the TypeScript compiler
 * API and enforces three things:
 *
 *  1. A raise site never spells its code as a string literal. A raise site is
 *     the argument bound to a parameter named `code` (of a constructor —
 *     including through `super(...)` — a function, or a method), that
 *     parameter's default value, a `code:` property in an object literal, a
 *     class property named `code`, or an assignment to `.code`.
 *  2. An `ERROR_CODES.<KEY>` reference at a raise site names a key the registry
 *     has.
 *  3. Every code in the esm-spec §9.6.6 table is in `ERROR_CODES`.
 *
 * A registry entry nothing references is reported with `console.warn`, not
 * failed.
 */

import * as fs from 'node:fs'
import * as path from 'node:path'
import { fileURLToPath } from 'node:url'
import ts from 'typescript'
import { describe, expect, it } from 'vitest'
import { ERROR_CODES } from './errors.js'

const SRC = path.dirname(fileURLToPath(import.meta.url))
const SPEC = path.resolve(SRC, '../../../esm-spec.md')

function sourceFiles(dir: string): string[] {
  const out: string[] = []
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) out.push(...sourceFiles(full))
    else if (full.endsWith('.ts') && !full.endsWith('.test.ts') && !full.endsWith('.d.ts'))
      out.push(full)
  }
  return out.sort()
}

function specDiagnosticCodes(): string[] {
  const text = fs.readFileSync(SPEC, 'utf8')
  const start = text.indexOf('\n#### 9.6.6 ')
  expect(start, 'esm-spec.md has no §9.6.6 heading').toBeGreaterThanOrEqual(0)
  let section = text.slice(start + 1)
  const end = section.indexOf('\n#### ')
  if (end >= 0) section = section.slice(0, end)
  return [...section.matchAll(/^\| `([a-z][a-z0-9_]*)` \|/gm)].map((m) => m[1]!)
}

interface Scan {
  violations: string[]
  checked: number
  referencedKeys: Set<string>
}

function scan(): Scan {
  const parsed = sourceFiles(SRC).map((file) =>
    ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true),
  )

  // Pass 1: which parameter position carries the code, per callable name, and
  // each class's superclass (so a subclass without its own constructor, and a
  // `super(...)` call, resolve to the constructor that declares `code`).
  const ctorCodeIndex = new Map<string, number>()
  // Functions resolve within their own file: two files may each declare a local
  // helper of the same name, and only one of them may take a `code`.
  const fnCodeIndex = new Map<string, number>() // `${file}\0${name}`
  const superclass = new Map<string, string>()
  const codeParamIndex = (params: ts.NodeArray<ts.ParameterDeclaration>) =>
    params.findIndex((p) => ts.isIdentifier(p.name) && p.name.text === 'code')
  for (const sf of parsed) {
    const visit = (node: ts.Node): void => {
      if (ts.isClassDeclaration(node) && node.name) {
        const ext = node.heritageClauses?.find((h) => h.token === ts.SyntaxKind.ExtendsKeyword)
        const base = ext?.types[0]?.expression
        if (base && ts.isIdentifier(base)) superclass.set(node.name.text, base.text)
      }
      if (
        ts.isConstructorDeclaration(node) &&
        ts.isClassDeclaration(node.parent) &&
        node.parent.name
      ) {
        const i = codeParamIndex(node.parameters)
        if (i >= 0) ctorCodeIndex.set(node.parent.name.text, i)
      }
      if (
        (ts.isFunctionDeclaration(node) || ts.isMethodDeclaration(node)) &&
        node.name &&
        ts.isIdentifier(node.name)
      ) {
        const i = codeParamIndex(node.parameters)
        if (i >= 0) fnCodeIndex.set(`${sf.fileName}\0${node.name.text}`, i)
      }
      // A local helper bound to a name (`const warn = (message, code) => ...`)
      // is a raise site exactly like a declared function.
      if (
        ts.isVariableDeclaration(node) &&
        ts.isIdentifier(node.name) &&
        node.initializer &&
        (ts.isArrowFunction(node.initializer) || ts.isFunctionExpression(node.initializer))
      ) {
        const i = codeParamIndex(node.initializer.parameters)
        if (i >= 0) fnCodeIndex.set(`${sf.fileName}\0${node.name.text}`, i)
      }
      ts.forEachChild(node, visit)
    }
    visit(sf)
  }
  const classesWithCtor = new Set<string>()
  for (const sf of parsed) {
    const visit = (node: ts.Node): void => {
      if (
        ts.isConstructorDeclaration(node) &&
        ts.isClassDeclaration(node.parent) &&
        node.parent.name
      ) {
        classesWithCtor.add(node.parent.name.text)
      }
      ts.forEachChild(node, visit)
    }
    visit(sf)
  }
  const resolveCtor = (cls: string | undefined): number | undefined => {
    for (let c = cls, guard = 0; c && guard < 32; c = superclass.get(c), guard++) {
      if (classesWithCtor.has(c)) return ctorCodeIndex.get(c)
    }
    return undefined
  }

  const result: Scan = { violations: [], checked: 0, referencedKeys: new Set() }

  // Pass 2: check every raise site.
  for (const sf of parsed) {
    const rel = path.relative(SRC, sf.fileName)
    const fileStringConsts = new Map<string, string>()
    for (const stmt of sf.statements) {
      if (!ts.isVariableStatement(stmt)) continue
      for (const decl of stmt.declarationList.declarations) {
        if (
          ts.isIdentifier(decl.name) &&
          decl.initializer &&
          ts.isStringLiteralLike(decl.initializer)
        ) {
          fileStringConsts.set(decl.name.text, decl.initializer.text)
        }
      }
    }

    const check = (expr: ts.Expression | undefined, context: string): void => {
      if (!expr) return
      while (
        ts.isParenthesizedExpression(expr) ||
        ts.isAsExpression(expr) ||
        ts.isSatisfiesExpression(expr)
      ) {
        expr = expr.expression
      }
      const literal = ts.isStringLiteralLike(expr)
        ? expr.text
        : ts.isIdentifier(expr)
          ? fileStringConsts.get(expr.text)
          : undefined
      // The uppercase `E_*` names (E_REF_*, E_CANONICAL_*) are a separate
      // stable error-NAME vocabulary, excluded from the snake_case code
      // registry by the same convention Julia (`E_TREEWALK_*`) and Rust (the DAE
      // lowering's `E_*`) follow; they are not diagnostic codes.
      if (literal !== undefined && /^E_[A-Z0-9_]+$/.test(literal)) return
      const line = sf.getLineAndCharacterOfPosition(expr.getStart(sf)).line + 1
      const where = `${rel}:${line}: ${context}`
      if (ts.isStringLiteralLike(expr)) {
        result.checked++
        result.violations.push(
          `${where} raises the literal code '${expr.text}'; use ERROR_CODES instead`,
        )
      } else if (
        ts.isPropertyAccessExpression(expr) &&
        ts.isIdentifier(expr.expression) &&
        expr.expression.text === 'ERROR_CODES'
      ) {
        result.checked++
        if (!Object.prototype.hasOwnProperty.call(ERROR_CODES, expr.name.text)) {
          result.violations.push(
            `${where} raises ERROR_CODES.${expr.name.text}, which the registry does not define`,
          )
        }
      } else if (ts.isIdentifier(expr) && fileStringConsts.has(expr.text)) {
        result.checked++
        result.violations.push(
          `${where} raises the module constant ${expr.text} = '${fileStringConsts.get(expr.text)}'; use ERROR_CODES instead`,
        )
      }
    }

    const enclosingClass = (node: ts.Node): ts.ClassLikeDeclaration | undefined => {
      for (let n = node.parent; n; n = n.parent) if (ts.isClassLike(n)) return n
      return undefined
    }

    const visit = (node: ts.Node): void => {
      if (
        ts.isPropertyAccessExpression(node) &&
        ts.isIdentifier(node.expression) &&
        node.expression.text === 'ERROR_CODES'
      ) {
        result.referencedKeys.add(node.name.text)
      }
      if (ts.isNewExpression(node) && ts.isIdentifier(node.expression)) {
        const i = resolveCtor(node.expression.text)
        if (i !== undefined) check(node.arguments?.[i], `new ${node.expression.text}()`)
      } else if (ts.isCallExpression(node)) {
        if (node.expression.kind === ts.SyntaxKind.SuperKeyword) {
          const cls = enclosingClass(node)
          const i = resolveCtor(cls?.name ? superclass.get(cls.name.text) : undefined)
          if (i !== undefined) check(node.arguments[i], 'super()')
        } else {
          const callee = ts.isIdentifier(node.expression)
            ? node.expression.text
            : ts.isPropertyAccessExpression(node.expression)
              ? node.expression.name.text
              : undefined
          const i = callee === undefined ? undefined : fnCodeIndex.get(`${sf.fileName}\0${callee}`)
          if (i !== undefined) check(node.arguments[i], `${callee}()`)
        }
      } else if (ts.isParameter(node) && ts.isIdentifier(node.name) && node.name.text === 'code') {
        check(node.initializer, 'default value of a `code` parameter')
      } else if (ts.isPropertyAssignment(node) && node.name.getText(sf) === 'code') {
        check(node.initializer, '`code:` property')
      } else if (ts.isPropertyDeclaration(node) && node.name.getText(sf) === 'code') {
        check(node.initializer, 'class property `code`')
      } else if (
        ts.isBinaryExpression(node) &&
        node.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
        ts.isPropertyAccessExpression(node.left) &&
        node.left.name.text === 'code'
      ) {
        check(node.right, '`.code` assignment')
      }
      ts.forEachChild(node, visit)
    }
    visit(sf)
  }
  return result
}

describe('diagnostic code registry coverage', () => {
  const result = scan()

  it('every raise site names its code through ERROR_CODES', () => {
    // Guard the scan: a layout drift that matched no raise site would pass
    // vacuously.
    expect(result.checked).toBeGreaterThanOrEqual(100)
    expect(result.violations).toEqual([])
  })

  it('registers every code in the esm-spec §9.6.6 table', () => {
    const codes = specDiagnosticCodes()
    // Guard the extraction: a heading or table-layout change that matched
    // nothing would pass the membership check vacuously.
    expect(codes.length).toBeGreaterThanOrEqual(30)
    const registered = new Set<string>(Object.values(ERROR_CODES))
    expect(codes.filter((c) => !registered.has(c))).toEqual([])
  })

  it('reports registry entries nothing raises (advisory)', () => {
    const unused = Object.keys(ERROR_CODES).filter((k) => !result.referencedKeys.has(k))
    if (unused.length > 0) {
      console.warn(`ERROR_CODES entries never referenced from src/: ${unused.join(', ')}`)
    }
  })
})
