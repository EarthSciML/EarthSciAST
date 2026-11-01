---
title: "expression_template_error"
description: "Stable error · Load-time lowering and templates"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** error · **Topic:** [Load-time lowering and templates](/generated/api/topics/lowering)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `ExpressionTemplateError` | `ExpressionTemplateError` | `ExpressionTemplateError` | not exported | `ExpressionTemplateError` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct ExpressionTemplateError <: EarthSciASTError
ExpressionTemplateError(code::String, message::String)
ExpressionTemplateError(code, message)
```

```julia
ExpressionTemplateError <: EarthSciASTError
```

Exception raised when a load-time lowering pass fails: expression-template
expansion (esm-spec §9.6), template-library imports (§9.7), coupling-library
imports (§10.9–§10.11), and the subsystem-reference / index-set checks in
`parse.jl`. Carries a stable diagnostic `code` drawn from
[`ERROR_CODES`](/generated/api/ref/error_codes) — `_KNOWN_DIAGNOSTIC_CODES` names the subset of
that registry this exception is raised with. Codes (and their message texts)
are conformance-relevant, so a new raise site MUST use a code registered there
— and a genuinely new code MUST be added to `ERROR_CODES` (and coordinated
across every binding) alongside its first raise site.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/lower_expression_templates.jl#L60)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
class ExpressionTemplateError extends EsmDiagnosticError
new ExpressionTemplateError(code: string, message: string): EsmMachineryError
```

**Deprecated.** Alias of [`EsmMachineryError`](/generated/api/extension/typescript#x-esmmachineryerror) — the SAME class object, so
`instanceof ExpressionTemplateError` and `instanceof EsmMachineryError` are
identical. Prefer [`EsmMachineryError`](/generated/api/extension/typescript#x-esmmachineryerror), which names the class's role as
the shared load-time template/coupling/import/ref machinery diagnostic.

---

Shared load-time diagnostic for the §9.x machinery: expression-template
lowering (§9.6), template-library imports (§9.7), coupling-library imports
(§10.10), subsystem-ref loading, and the §9.6.4 expanded-form validators all
raise it as their common coded-diagnostic class — `validate` maps it (by
`instanceof`) to the `expression_template_error` load-error kind. A subclass
of [`EsmDiagnosticError`](/generated/api/extension/typescript#x-esmdiagnosticerror): `code` is the specific diagnostic and the
message text is `[code] message`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/lower-expression-templates.ts#L113)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class ExpressionTemplateError(EarthSciAstError)
ExpressionTemplateError(code: str, message: str)
```

Raised when expression-template expansion fails.

The `code` attribute carries one of the stable diagnostic codes:
`apply_expression_template_unknown_template`,
`apply_expression_template_bindings_mismatch`,
`apply_expression_template_recursive_body`,
`apply_expression_template_invalid_declaration`,
`apply_expression_template_version_too_old`,
`rewrite_rule_nonterminating`,
`template_constraint_unknown_index_set` (§9.6.1 `where` scoping),
`makearray_region_inverted` (§4.3.2 empty/inverted bounds),

or one of the esm-spec §9.7 template-library / metaparameter codes
(§9.6.6, raised from `earthsci_ast.template_imports` and
`earthsci_ast.parse`):

`template_import_version_too_old`, `template_import_unresolved`,
`template_import_not_library`, `template_library_illegal_payload`,
`subsystem_ref_is_template_library`,
`template_import_cycle`, `template_import_name_conflict`,
`template_import_unknown_name`, `template_import_index_set_conflict`,
`template_body_expansion_too_deep`, `metaparameter_unbound`,
`metaparameter_type_error`, `metaparameter_name_conflict`,

or one of the esm-spec §9.7.7 import-renaming codes (raised from
`earthsci_ast.template_imports`):

`template_import_rename_unknown_name`,
`template_import_rebind_unknown_name`,
`template_import_rename_collision`, `template_import_rename_invalid`,

or one of the esm-spec §10.9–§10.11 coupling-library / `coupling_import`
role-binding codes (raised from `earthsci_ast.coupling_imports`, with
`subsystem_ref_is_coupling_library` / `template_import_is_coupling_library`
raised from `earthsci_ast.parse` / `earthsci_ast.template_imports`):

`coupling_import_unresolved`, `coupling_import_not_library`,
`coupling_library_illegal_payload`, `coupling_library_nested_import`,
`coupling_edge_unknown_role`, `coupling_role_unused`,
`coupling_import_unknown_role`, `coupling_import_role_unbound`,
`coupling_import_bind_not_a_component`,
`subsystem_ref_is_coupling_library`,
`template_import_is_coupling_library`.

The code constants themselves are defined in
`earthsci_ast.error_handling`; their string values are part of the
cross-binding contract and must never change.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/json_walk.py#L37)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this error.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ExpressionTemplateError struct {
	Code    string
	Message string
	// Path is an RFC 6901 JSON Pointer to the document node that carries the
	// defect, when one can be attributed. It is populated for LOAD-phase
	// rejections that a conformance producer must surface as a structured
	// (code, path) structural finding — e.g. a §4.7 subsystem ref that does not
	// resolve (`/models/<M>/subsystems/<name>`). Most template/metaparameter
	// errors leave it empty; a caller that needs a pointer sets it via
	// withETPath as the error unwinds past the frame that knows the location.
	Path string
}

func (e *ExpressionTemplateError) DiagnosticCode() string

func (e *ExpressionTemplateError) DiagnosticPath() string

func (e *ExpressionTemplateError) Error() string
```

ExpressionTemplateError is the error type raised by the expression-template expansion pass. The Code field carries one of the stable diagnostic codes:

- apply\_expression\_template\_unknown\_template
- apply\_expression\_template\_bindings\_mismatch
- apply\_expression\_template\_recursive\_body
- apply\_expression\_template\_invalid\_declaration
- apply\_expression\_template\_version\_too\_old
- rewrite\_rule\_nonterminating

or one of the esm-spec §9.7 template-library / metaparameter codes (§9.6.6, raised from template\_imports.go and subsystem\_ref.go):

- template\_import\_version\_too\_old
- template\_import\_unresolved
- template\_import\_not\_library
- template\_library\_illegal\_payload
- subsystem\_ref\_is\_template\_library
- template\_import\_cycle
- template\_import\_name\_conflict
- template\_import\_unknown\_name
- template\_import\_index\_set\_conflict
- template\_body\_expansion\_too\_deep
- metaparameter\_unbound
- metaparameter\_type\_error
- metaparameter\_name\_conflict

or one of the esm-spec §10.11 coupling-library / coupling\_import codes (raised from coupling\_imports.go, subsystem\_ref.go, template\_imports.go):

- coupling\_import\_unresolved
- coupling\_import\_not\_library
- subsystem\_ref\_is\_coupling\_library
- template\_import\_is\_coupling\_library
- coupling\_library\_illegal\_payload
- coupling\_library\_nested\_import
- coupling\_edge\_unknown\_role
- coupling\_role\_unused
- coupling\_import\_unknown\_role
- coupling\_import\_role\_unbound
- coupling\_import\_bind\_not\_a\_component

**Methods**

```go
func (e *ExpressionTemplateError) DiagnosticCode() string
```

DiagnosticCode returns the stable diagnostic code (DiagnosticError).

```go
func (e *ExpressionTemplateError) DiagnosticPath() string
```

DiagnosticPath returns the JSON Pointer the error is attributed to, or "" if none was set.

```go
func (e *ExpressionTemplateError) Error() string
```

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/lower_expression_templates.go#L163) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ExpressionTemplateError)

</div>

</div>
