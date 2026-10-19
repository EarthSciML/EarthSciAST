#!/usr/bin/env node
// Extracts the TypeScript binding's API documentation into the normalized
// docstring file described in docs/api/README.md §2.
//
// Uses the TypeScript compiler API from the package's own pinned `typescript`
// devDependency, so the extractor version is whatever package-lock.json pins.
// Each spelling listed for `typescript` in api-surface.json is looked up among
// the named exports of pkg/earthsci-ast-ts/src/index.ts; its JSDoc/TSDoc is
// converted to CommonMark and its signatures are printed by the type checker.
//
// Usage: node typescript_extract.mjs <repo-root> <output.json>

import { createRequire } from 'node:module'
import fs from 'node:fs'
import path from 'node:path'

const [repoRoot, outPath] = process.argv.slice(2).map((p) => path.resolve(p))
if (!repoRoot || !outPath) {
  console.error('usage: typescript_extract.mjs <repo-root> <output.json>')
  process.exit(2)
}

const pkgDir = path.join(repoRoot, 'pkg', 'earthsci-ast-ts')
const require = createRequire(path.join(pkgDir, 'package.json'))
const ts = require('typescript')

const manifest = JSON.parse(fs.readFileSync(path.join(repoRoot, 'api-surface.json'), 'utf8'))
const pkgJson = JSON.parse(fs.readFileSync(path.join(pkgDir, 'package.json'), 'utf8'))

// spelling -> manifest kind (one entry per spelling, alias pairs included)
const wanted = new Map()
for (const sym of manifest.symbols) {
  const sp = sym.bindings?.typescript
  if (sp === undefined) continue
  for (const s of Array.isArray(sp) ? sp : [sp]) {
    if (wanted.has(s) && wanted.get(s) !== sym.kind) {
      console.error(`warning: ${s} listed with kinds ${wanted.get(s)} and ${sym.kind}`)
    }
    if (!wanted.has(s)) wanted.set(s, sym.kind)
  }
}

// --- program -----------------------------------------------------------------

const configPath = path.join(pkgDir, 'tsconfig.json')
const cfg = ts.readConfigFile(configPath, ts.sys.readFile)
const parsed = ts.parseJsonConfigFileContent(cfg.config, ts.sys, pkgDir)
const entry = path.join(pkgDir, 'src', 'index.ts')
const program = ts.createProgram([entry], { ...parsed.options, noEmit: true })
const checker = program.getTypeChecker()
const entrySf = program.getSourceFile(entry)
const moduleSym = checker.getSymbolAtLocation(entrySf)
const exportsByName = new Map(checker.getExportsOfModule(moduleSym).map((s) => [s.getName(), s]))

const printer = ts.createPrinter({ removeComments: true, newLine: ts.NewLineKind.LineFeed })
const SIG_FLAGS =
  ts.TypeFormatFlags.NoTruncation |
  ts.TypeFormatFlags.UseAliasDefinedOutsideCurrentScope |
  ts.TypeFormatFlags.WriteTypeArgumentsOfSignature
const TYPE_FLAGS = ts.TypeFormatFlags.UseAliasDefinedOutsideCurrentScope

// --- TSDoc -> CommonMark -----------------------------------------------------

/** Raw `/** ... *\/` blocks immediately preceding `node`. */
function jsdocBlocks(node) {
  const sf = node.getSourceFile()
  const text = sf.getFullText()
  const ranges = ts.getLeadingCommentRanges(text, node.getFullStart()) ?? []
  return ranges
    .filter((r) => r.kind === ts.SyntaxKind.MultiLineCommentTrivia)
    .map((r) => text.slice(r.pos, r.end))
    .filter((c) => c.startsWith('/**') && !c.startsWith('/***'))
}

function stripCommentMarkers(block) {
  const body = block.replace(/^\/\*\*/, '').replace(/\*\/$/, '')
  const lines = body.split('\n').map((l) => l.replace(/^\s*\* ?/, '').replace(/\s+$/, ''))
  if (lines.length && lines[0].trim() === '') lines.shift()
  if (lines.length && lines[lines.length - 1].trim() === '') lines.pop()
  // single-line block: `/** text */`
  if (lines.length === 1) lines[0] = lines[0].trim()
  return lines.join('\n')
}

function linkTarget(target, label) {
  if (/^https?:\/\//.test(target)) return label ? `[${label}](${target})` : `<${target}>`
  if (label && label !== target) return `[${label}](api:${target})`
  return `[\`${target}\`](api:${target})`
}

/** Convert inline tags in prose, leaving fenced code and code spans alone. */
function convertInline(text) {
  text = text.replace(/\{@link(code|plain)?\s*\n\s*/g, '{@link$1 ').replace(/\{@link(code|plain)?([^}\n]*)\n\s*([^}]*\})/g, '{@link$1$2 $3')
  const out = []
  let inFence = false
  for (const line of text.split('\n')) {
    if (/^\s*(```|~~~)/.test(line)) {
      inFence = !inFence
      out.push(line)
      continue
    }
    if (inFence) {
      out.push(line)
      continue
    }
    // split on code spans so `{@link}` inside backticks stays literal
    const parts = line.split(/(`+[^`]*`+)/)
    out.push(
      parts
        .map((p, i) =>
          i % 2 === 1
            ? p
            : p.replace(/\{@link(?:code|plain)?\s+([^}\s|]+)(?:\s*\|\s*|\s+)?([^}]*)\}/g, (_, t, l) =>
                linkTarget(t.trim(), l.trim()),
              ),
        )
        .join(''),
    )
  }
  return out.join('\n')
}

const DROPPED_TAGS = new Set([
  'internal', 'public', 'beta', 'alpha', 'experimental', 'packageDocumentation',
  'module', 'category', 'group', 'override', 'virtual', 'sealed', 'readonly',
  'eventProperty', 'privateRemarks', 'inheritDoc', 'type', 'typedef', 'template',
  'typeParam', 'hidden', 'ignore', 'since', 'author', 'license', 'file', 'fileoverview',
])

/** Parse one comment's text into description + block tags. */
function parseTsdoc(text) {
  const lines = text.split('\n')
  const desc = []
  const tags = []
  let cur = null
  let inFence = false
  for (const line of lines) {
    if (/^\s*(```|~~~)/.test(line)) inFence = !inFence
    const m = !inFence && line.match(/^\s*@([A-Za-z]+)\b ?(.*)$/)
    if (m) {
      cur = { tag: m[1], text: m[2] }
      tags.push(cur)
    } else if (cur) {
      cur.text += '\n' + line
    } else {
      desc.push(line)
    }
  }
  for (const t of tags) t.text = t.text.replace(/\s+$/, '')
  return { desc: desc.join('\n').trim(), tags }
}

function dedent(s) {
  const ls = s.split('\n')
  const ind = Math.min(...ls.filter((l) => l.trim()).map((l) => l.match(/^ */)[0].length))
  return Number.isFinite(ind) ? ls.map((l) => l.slice(ind)).join('\n') : s
}

function oneLine(s) {
  // bullet continuation lines get indented so the list item stays one item
  return s.trim().replace(/\n/g, '\n  ')
}

function tsdocToMarkdown(text) {
  const { desc, tags } = parseTsdoc(text)
  const sections = []
  const deprecated = tags.filter((t) => t.tag === 'deprecated')
  for (const t of deprecated) {
    sections.push(`**Deprecated.**${t.text.trim() ? ' ' + t.text.trim() : ''}`)
  }
  if (desc) sections.push(desc)

  const params = tags.filter((t) => t.tag === 'param')
  if (params.length) {
    const items = params.map((t) => {
      // @param {type} name - desc   |   @param name desc   |   @param [name=x] desc
      const m = t.text.match(/^\s*(?:\{[^}]*\}\s*)?(\[[^\]]+\]|[\w$.[\]]+)\s*(?:-\s*)?([\s\S]*)$/)
      if (!m) return `- ${oneLine(t.text)}`
      const name = m[1].replace(/^\[([^=\]]+).*\]$/, '$1')
      return `- \`${name}\`${m[2].trim() ? ' — ' + oneLine(m[2]) : ''}`
    })
    sections.push('**Parameters**\n\n' + items.join('\n'))
  }
  const returns = tags.filter((t) => t.tag === 'returns' || t.tag === 'return')
  if (returns.length) {
    sections.push(
      '**Returns**\n\n' + returns.map((t) => t.text.replace(/^\s*\{[^}]*\}\s*/, '').trim()).join('\n\n'),
    )
  }
  const throws = tags.filter((t) => t.tag === 'throws' || t.tag === 'throw' || t.tag === 'exception')
  if (throws.length) {
    const items = throws.map((t) => {
      const m = t.text.match(/^\s*\{(?:@link\s+)?([^}|\s]+)[^}]*\}\s*(?:-\s*)?([\s\S]*)$/)
      if (m) return `- ${linkTarget(m[1])}${m[2].trim() ? ' — ' + oneLine(m[2]) : ''}`
      return `- ${oneLine(t.text)}`
    })
    sections.push('**Throws**\n\n' + items.join('\n'))
  }
  for (const t of tags.filter((x) => x.tag === 'remarks')) {
    if (t.text.trim()) sections.push(t.text.trim())
  }
  const examples = tags.filter((t) => t.tag === 'example')
  for (const t of examples) {
    let body = t.text.replace(/^\n+/, '')
    const firstLine = body.split('\n')[0]
    let caption = ''
    if (firstLine.trim() && !/^\s*(```|~~~)/.test(firstLine) && /^\s*(```|~~~)/m.test(body)) {
      caption = firstLine.trim()
      body = body.split('\n').slice(1).join('\n')
    }
    body = dedent(body).trim()
    if (!/^(```|~~~)/.test(body)) body = '```typescript\n' + body + '\n```'
    else body = body.replace(/^(```|~~~)(ts|tsx|js|javascript)?\s*$/m, '$1typescript')
    sections.push('**Example**' + (caption ? ` — ${caption}` : '') + '\n\n' + body)
  }
  const sees = tags.filter((t) => t.tag === 'see')
  if (sees.length) {
    sections.push(
      '**See also**\n\n' +
        sees
          .map((t) => {
            const s = t.text.trim()
            return `- ${/^[A-Za-z_$][\w$.]*$/.test(s) ? linkTarget(s) : oneLine(s)}`
          })
          .join('\n'),
    )
  }
  const handled = new Set([
    'deprecated', 'param', 'returns', 'return', 'throws', 'throw', 'exception',
    'remarks', 'example', 'see',
  ])
  for (const t of tags) {
    if (handled.has(t.tag) || DROPPED_TAGS.has(t.tag)) continue
    const head = t.tag[0].toUpperCase() + t.tag.slice(1)
    sections.push(`**${head}**${t.text.trim() ? '\n\n' + t.text.trim() : ''}`)
  }
  return convertInline(sections.join('\n\n')).trim()
}

/** The CommonMark doc for one declaration node, or null. */
function docOf(node) {
  // A JSDoc for `export const X = ...` sits on the VariableStatement.
  let host = node
  if (ts.isVariableDeclaration(host)) host = host.parent.parent
  const blocks = jsdocBlocks(host)
  if (!blocks.length) return null
  const md = tsdocToMarkdown(stripCommentMarkers(blocks[blocks.length - 1]))
  return md || null
}

/** Short member description: the comment's description, up to the first block tag. */
function memberSummary(node) {
  const blocks = jsdocBlocks(node)
  if (!blocks.length) return null
  const { desc, tags } = parseTsdoc(stripCommentMarkers(blocks[blocks.length - 1]))
  const dep = tags.find((t) => t.tag === 'deprecated')
  const s = [dep ? `**Deprecated.**${dep.text.trim() ? ' ' + dep.text.trim() : ''}` : '', desc]
    .filter(Boolean)
    .join(' ')
  return s ? convertInline(oneLine(s)) : null
}

// --- signatures --------------------------------------------------------------

const isPublicMember = (m) => {
  const mods = ts.getCombinedModifierFlags(m)
  if (mods & (ts.ModifierFlags.Private | ts.ModifierFlags.Protected)) return false
  if (m.name && ts.isPrivateIdentifier(m.name)) return false
  const n = m.name?.getText?.()
  return !(n && n.startsWith('_'))
}

function printNode(node) {
  return printer.printNode(ts.EmitHint.Unspecified, node, node.getSourceFile()).trim()
}

/** Strip `export`/`declare` modifiers from a printed declaration. */
function stripExport(s) {
  return s.replace(/^(export\s+)?(declare\s+)?/, '')
}


const squash = (s) => s.replace(/\s*\n\s*/g, ' ')
const typeText = (node) => squash(printNode(node)).replace(/;\s*\}/g, ' }')

/**
 * `(params): Ret` for one signature, using the declaration's own annotations
 * where they exist so the author's spelling survives (the checker would
 * widen `x?: T` to `x?: T | undefined`).
 */
function sigString(sig) {
  const decl = sig.getDeclaration()
  if (!decl || !decl.parameters) return checker.signatureToString(sig, undefined, SIG_FLAGS)
  const tps = decl.typeParameters ? `<${decl.typeParameters.map((t) => squash(t.getText())).join(', ')}>` : ''
  const params = decl.parameters.map((p, i) => {
    const sym = sig.parameters[i]
    const rest = p.dotDotDotToken ? '...' : ''
    const opt = p.questionToken || p.initializer ? '?' : ''
    const type = p.type
      ? typeText(p.type)
      : checker.typeToString(checker.getTypeOfSymbolAtLocation(sym ?? p.symbol, p), p, TYPE_FLAGS)
    return `${rest}${squash(p.name.getText())}${opt}: ${type}`
  })
  const ret = decl.type
    ? typeText(decl.type)
    : checker.typeToString(checker.getReturnTypeOfSignature(sig), decl, TYPE_FLAGS | ts.TypeFormatFlags.NoTruncation)
  return `${tps}(${params.join(', ')}): ${ret}`
}

function callSignatures(name, type, prefix = 'function ') {
  return checker
    .getSignaturesOfType(type, ts.SignatureKind.Call)
    .map((sig) => `${prefix}${name}${sigString(sig)}`)
}

function classSignatures(spelling, decl, members) {
  const sigs = []
  const heritage = (decl.heritageClauses ?? []).map((h) => ' ' + h.getText()).join('')
  const tparams = decl.typeParameters ? `<${decl.typeParameters.map((p) => p.getText()).join(', ')}>` : ''
  const abs = ts.getCombinedModifierFlags(decl) & ts.ModifierFlags.Abstract ? 'abstract ' : ''
  sigs.push(`${abs}class ${spelling}${tparams}${heritage}`)
  const classSym = checker.getSymbolAtLocation(decl.name)
  const ctorType = checker.getTypeOfSymbolAtLocation(classSym, decl)
  for (const sig of checker.getSignaturesOfType(ctorType, ts.SignatureKind.Construct)) {
    const d = sig.getDeclaration()
    if (d && ts.isConstructorDeclaration(d) && !isPublicMember(d)) continue
    sigs.push(`new ${spelling}${sigString(sig)}`)
  }
  for (const m of decl.members) {
    if (ts.isConstructorDeclaration(m) || !m.name || !isPublicMember(m)) continue
    if (ts.isClassStaticBlockDeclaration?.(m) || ts.isIndexSignatureDeclaration(m)) continue
    const isStatic = ts.getCombinedModifierFlags(m) & ts.ModifierFlags.Static
    const owner = isStatic ? spelling : `${spelling}.prototype`
    const mname = m.name.getText()
    const msym = checker.getSymbolAtLocation(m.name)
    if (!msym) continue
    if (ts.isMethodDeclaration(m)) {
      // overload implementations duplicate the overloads; list each signature once
      if (!m.body || !decl.members.some((o) => o !== m && ts.isMethodDeclaration(o) && o.name.getText() === mname)) {
        const sig = checker.getSignatureFromDeclaration(m)
        sigs.push(`${owner}.${mname}${sigString(sig)}`)
      }
    } else if (ts.isGetAccessorDeclaration(m)) {
      const t = checker.getTypeOfSymbolAtLocation(msym, m)
      sigs.push(`get ${owner}.${mname}: ${checker.typeToString(t, m, TYPE_FLAGS)}`)
    } else if (ts.isPropertyDeclaration(m)) {
      if (m.modifiers?.some((x) => x.kind === ts.SyntaxKind.DeclareKeyword) && !memberSummary(m)) continue
      const ro = ts.getCombinedModifierFlags(m) & ts.ModifierFlags.Readonly ? 'readonly ' : ''
      const t = checker.getTypeOfSymbolAtLocation(msym, m)
      sigs.push(`${ro}${owner}.${mname}${m.questionToken ? '?' : ''}: ${checker.typeToString(t, m, TYPE_FLAGS)}`)
    } else {
      continue
    }
    const summ = memberSummary(m)
    if (summ && !members.some((x) => x.name === mname)) members.push({ name: mname, summary: summ })
  }
  return sigs
}

function interfaceMembers(decl, members) {
  for (const m of decl.members ?? []) {
    if (!m.name) continue
    const summ = memberSummary(m)
    if (summ) members.push({ name: m.name.getText(), summary: summ })
  }
}

function describeDeclaration(spelling, decl, members) {
  if (ts.isFunctionDeclaration(decl)) {
    return null // handled per symbol so overloads are listed once
  }
  if (ts.isClassDeclaration(decl)) return classSignatures(spelling, decl, members)
  if (ts.isInterfaceDeclaration(decl)) {
    interfaceMembers(decl, members)
    return [stripExport(printNode(decl))]
  }
  if (ts.isTypeAliasDeclaration(decl)) {
    if (ts.isTypeLiteralNode(decl.type)) interfaceMembers(decl.type, members)
    return [stripExport(printNode(decl))]
  }
  if (ts.isEnumDeclaration(decl)) {
    for (const m of decl.members) {
      const summ = memberSummary(m)
      if (summ) members.push({ name: m.name.getText(), summary: summ })
    }
    return [stripExport(printNode(decl))]
  }
  if (ts.isVariableDeclaration(decl)) {
    const sym = checker.getSymbolAtLocation(decl.name)
    const type = checker.getTypeOfSymbolAtLocation(sym, decl)
    const calls = checker.getSignaturesOfType(type, ts.SignatureKind.Call)
    const ctors = checker.getSignaturesOfType(type, ts.SignatureKind.Construct)
    if (calls.length && !ctors.length) return callSignatures(spelling, type, 'function ')
    const isConst = decl.parent.flags & ts.NodeFlags.Const
    const annotated = decl.type ? decl.type.getText() : checker.typeToString(type, decl, TYPE_FLAGS)
    if (decl.initializer && ts.isObjectLiteralExpression(skipAsConst(decl.initializer))) {
      for (const p of skipAsConst(decl.initializer).properties) {
        const summ = p.name ? memberSummary(p) : null
        if (summ) members.push({ name: p.name.getText(), summary: summ })
      }
    }
    return [`${isConst ? 'const' : 'let'} ${spelling}: ${annotated}`]
  }
  return [stripExport(printNode(decl))]
}

function skipAsConst(e) {
  while (ts.isAsExpression(e) || ts.isSatisfiesExpression?.(e) || ts.isParenthesizedExpression(e)) e = e.expression
  return e
}

// --- per-spelling ------------------------------------------------------------

function rel(p) {
  return path.relative(repoRoot, p).split(path.sep).join('/')
}

/** JSDoc written on the `export { X }` specifier chain in the barrel(s). */
function specifierDocs(sym) {
  const docs = []
  let s = sym
  const seen = new Set()
  while (s && s.flags & ts.SymbolFlags.Alias && !seen.has(s)) {
    seen.add(s)
    for (const d of s.declarations ?? []) {
      if (ts.isExportSpecifier(d)) {
        let blocks = jsdocBlocks(d)
        const decl = d.parent.parent
        if (!blocks.length && decl.exportClause.elements.length === 1) blocks = jsdocBlocks(decl)
        if (blocks.length) docs.push(tsdocToMarkdown(stripCommentMarkers(blocks[blocks.length - 1])))
      }
    }
    s = checker.getImmediateAliasedSymbol(s)
  }
  return docs.filter(Boolean)
}

function extract(spelling, kind) {
  const exp = exportsByName.get(spelling)
  if (!exp) {
    return { spelling, kind, signatures: [], doc: null, source: null, native_url: null, missing: true }
  }
  const target = exp.flags & ts.SymbolFlags.Alias ? checker.getAliasedSymbol(exp) : exp
  const decls = (target.declarations ?? []).filter((d) => !ts.isSourceFile(d))
  const signatures = []
  const docs = []
  const members = []
  const fnDecls = decls.filter(ts.isFunctionDeclaration)
  if (fnDecls.length) {
    const type = checker.getTypeOfSymbolAtLocation(target, fnDecls[0])
    signatures.push(...callSignatures(spelling, type))
    // overloads: each documented overload contributes its doc, in order
    for (const d of fnDecls) {
      const doc = docOf(d)
      if (doc && !docs.includes(doc)) docs.push(doc)
    }
  }
  // value declarations first, then types (e.g. `const VertexKind` + `type VertexKind`)
  for (const d of decls) {
    if (ts.isFunctionDeclaration(d)) continue
    const sigs = describeDeclaration(spelling, d, members) ?? []
    for (const s of sigs) if (!signatures.includes(s)) signatures.push(s)
    const doc = docOf(d)
    if (doc && !docs.includes(doc)) docs.push(doc)
  }
  for (const d of specifierDocs(exp)) if (!docs.includes(d)) docs.unshift(d)

  let doc = docs.length ? docs.join('\n\n---\n\n') : null
  if (members.length) {
    const head = decls.some((d) => ts.isClassDeclaration(d)) ? '**Members**' : '**Properties**'
    const list = members.map((m) => `- \`${m.name}\` — ${m.summary}`).join('\n')
    doc = (doc ? doc + '\n\n' : '') + `${head}\n\n${list}`
  }
  const primary = decls[0]
  const sf = primary?.getSourceFile()
  const nameNode = primary?.name ?? primary
  const source = primary
    ? {
        path: rel(sf.fileName),
        line: sf.getLineAndCharacterOfPosition(nameNode.getStart(sf)).line + 1,
      }
    : null
  return { spelling, kind, signatures, doc, source, native_url: null }
}

const symbols = [...wanted.entries()]
  .map(([spelling, kind]) => extract(spelling, kind))
  .sort((a, b) => a.spelling.localeCompare(b.spelling))

const out = {
  binding: 'typescript',
  package_version: pkgJson.version,
  extractor: `typescript ${ts.version} compiler API`,
  symbols,
}
fs.mkdirSync(path.dirname(outPath), { recursive: true })
fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + '\n')

const missing = symbols.filter((s) => s.missing).map((s) => s.spelling)
const undocumented = symbols.filter((s) => s.doc === null).map((s) => s.spelling)
console.log(
  `typescript: ${symbols.length} spellings, ${symbols.length - undocumented.length} documented, ` +
    `${undocumented.length} without docs, ${missing.length} not found -> ${rel(outPath)}`,
)
if (missing.length) {
  console.error(`warning: not found among index.ts exports: ${missing.join(', ')}`)
}
