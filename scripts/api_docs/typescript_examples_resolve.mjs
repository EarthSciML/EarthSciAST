// Node `--import` hook for the TypeScript examples: resolves the package name
// `@earthsciml/ast` to the in-repo build (pkg/earthsci-ast-ts/dist), so the
// examples import the package exactly as a user would but run against this
// checkout rather than a published release.
import module from 'node:module'

const entry = new URL('../../pkg/earthsci-ast-ts/dist/esm/index.js', import.meta.url).href
const NAME = '@earthsciml/ast'

if (typeof module.registerHooks === 'function') {
  module.registerHooks({
    resolve: (specifier, context, next) =>
      specifier === NAME ? { url: entry, shortCircuit: true } : next(specifier, context),
  })
} else {
  const src =
    `export async function resolve(s, c, n) {` +
    ` return s === ${JSON.stringify(NAME)} ? { url: ${JSON.stringify(entry)}, shortCircuit: true } : n(s, c) }`
  module.register('data:text/javascript,' + encodeURIComponent(src))
}
