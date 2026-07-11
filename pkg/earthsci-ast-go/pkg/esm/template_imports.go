package esm

// Load-time resolution for esm-spec §9.7: template-library files, cross-file
// `expression_template_imports`, and load-time `metaparameters`
// (docs/content/rfcs/template-library-imports.md; esm-libraries-spec §2.1c).
//
// Everything here resolves BEFORE the §9.6.3 rewrite fixpoint
// (lower_expression_templates.go) and before the typed struct sees the tree.
// Per document the order is innermost-first (esm-spec §9.7.6):
//
//  1. resolve imports (recursively, depth-first post-order, instantiating the
//     imported subtree with the edge's metaparameter `bindings` at each edge);
//  2. merge imported `index_sets` into the document registry;
//  3. close and fold this document's metaparameters (loader-API bindings, then
//     defaults; `metaparameter_unbound` if still open);
//  4. §9.7.3 registration-time body composition (composeTemplateBodies,
//     invoked per component from lowerExpressionTemplatesOrdered);
//  5. the §9.6.3 fixpoint on fully-concrete trees.
//
// Round-trip is Option A: `expression_template_imports`, `metaparameters`, and
// top-level `expression_templates` do not survive parse → emit; the emitted
// form is the expanded, folded document.
//
// Because a decoded map[string]interface{} loses key order — and the §9.7.4
// effective declaration order is normative for the §9.6.3 tie-break — the
// resolver tracks explicit ordered key lists (recovered from the raw JSON via
// extractTemplateOrders) and publishes each component's effective template
// sequence back into the `orders` map consumed by
// lowerExpressionTemplatesOrdered.
//
// All diagnostics are raised as *ExpressionTemplateError with the stable
// §9.6.6 codes. Mirrors the Julia reference implementation
// EarthSciAST.jl/src/template_imports.jl.

// MaxTemplateExpansionDepth is the maximum template-body reference-chain depth
// (counted in TEMPLATES along the longest chain, so a 33-template chain is
// rejected and a 32-template chain is accepted) before a file is rejected with
// `template_body_expansion_too_deep` (esm-spec §9.7.3). Pinned identically
// across all bindings.
const MaxTemplateExpansionDepth = 32

var templateComponentKinds = []string{"models", "reaction_systems"}

// A template-library file MUST NOT declare any of these (esm-spec §9.7.1).
var libraryForbiddenKeys = []string{
	"models", "reaction_systems", "data_loaders", "coupling", "domain",
}
