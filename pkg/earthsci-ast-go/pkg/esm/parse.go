package esm

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/xeipuuv/gojsonschema"
)

//go:embed esm-schema.json
var embeddedSchema []byte

// LoadOption configures a Load / LoadString call.
type LoadOption func(*loadOptions)

type loadOptions struct {
	basePath       string
	metaparameters map[string]int64
}

// WithMetaparameters binds the ROOT document's open metaparameters at the
// loader API (esm-spec §9.7.6 binding site 4): already-closed edge bindings
// win, API bindings beat `default`s. Binding a name the document does not
// declare fails with `template_import_unknown_name`.
func WithMetaparameters(m map[string]int64) LoadOption {
	return func(o *loadOptions) { o.metaparameters = m }
}

// WithBasePath anchors relative `expression_template_imports` refs (esm-spec
// §9.7.2) for LoadString input. Load derives it from the file's directory
// automatically; an explicit WithBasePath overrides that.
func WithBasePath(dir string) LoadOption {
	return func(o *loadOptions) { o.basePath = dir }
}

func applyLoadOptions(opts []LoadOption) loadOptions {
	o := loadOptions{basePath: "."}
	for _, opt := range opts {
		opt(&o)
	}
	return o
}

// Load loads an ESM file from the specified path and validates it against the JSON schema.
// After parsing, it resolves any subsystem references relative to the file's directory.
func Load(path string, opts ...LoadOption) (*ESMFile, error) {
	// Read the file
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read file %s: %w", path, err)
	}

	basePath := filepath.Dir(path)
	esmFile, err := LoadString(string(data),
		append([]LoadOption{WithBasePath(basePath)}, opts...)...)
	if err != nil {
		return nil, err
	}

	// Capture the ROOT document's closed metaparameter environment (declared
	// integer defaults overlaid with the loader-API bindings) from the raw JSON
	// BEFORE LoadString's template-machinery pass has consumed the
	// `metaparameters` block — the resolved esmFile no longer carries it. This
	// is the scope against which a §4.7 subsystem mount edge's binding
	// EXPRESSIONS fold (e.g. `NTGT = NX*NY`, esm-spec §9.7.6 binding site 3).
	var rootMetaEnv map[string]int64
	if rootView, verr := decodeJSONView(data); verr == nil {
		rootMetaEnv = metaEnvFromDecls(rootView["metaparameters"], applyLoadOptions(opts).metaparameters)
	}

	// Resolve subsystem references relative to the file's directory
	if err := resolveSubsystemRefsWithMeta(esmFile, basePath, rootMetaEnv); err != nil {
		return nil, fmt.Errorf("failed to resolve subsystem references: %w", err)
	}

	return esmFile, nil
}

// LoadString parses an ESM file from JSON string and validates it against the JSON schema
func LoadString(jsonStr string, opts ...LoadOption) (*ESMFile, error) {
	o := applyLoadOptions(opts)

	// v0.4.0 expression_templates / apply_expression_template are rejected
	// when the file declares esm < 0.4.0 (RFC §5.4 spec-version gate), and
	// the v0.8.0 §9.7 constructs (expression_template_imports, top-level
	// expression_templates, metaparameters) when the file declares
	// esm < 0.8.0 (esm-spec §9.6.5). Surfaced before schema validation so
	// the user sees the version hint instead of a generic "extra property"
	// schema error. Operates on a generic map view of the JSON (UseNumber to
	// preserve int/float).
	{
		var preCheck map[string]any
		predec := json.NewDecoder(bytes.NewReader([]byte(jsonStr)))
		predec.UseNumber()
		if err := predec.Decode(&preCheck); err == nil {
			if err := RejectExpressionTemplatesPreV04(preCheck); err != nil {
				return nil, err
			}
			if err := RejectTemplateImportsPreV08(preCheck); err != nil {
				return nil, err
			}
		}
	}

	// First, validate against JSON schema
	result, err := validateJSONSchema(jsonStr)
	if err != nil {
		return nil, fmt.Errorf("schema validation failed: %w", err)
	}

	if !result.IsValid {
		var errorStrs []string
		for _, schemaErr := range result.SchemaErrors {
			errorStrs = append(errorStrs,
				fmt.Sprintf("%s: %s (%s)", schemaErr.Path, schemaErr.Message, schemaErr.Keyword))
		}
		return nil, fmt.Errorf("JSON schema validation failed: %s", strings.Join(errorStrs, "; "))
	}

	// Resolve esm-spec §9.7 machinery — template-library imports (depth-first
	// post-order, per-edge metaparameter instantiation), index_sets merge,
	// metaparameter close+fold — then expand `apply_expression_template` ops
	// / fire `match` rules to the §9.6.3 fixpoint (esm-spec §9.6 /
	// docs/rfcs/ast-expression-templates.md). After both passes the JSON has
	// no apply_expression_template nodes, no expression_templates blocks, no
	// imports, and no metaparameters — the typed struct sees only normal
	// Expression ASTs (Option A round-trip).
	//
	// EXCEPT for the two DECLARATION blocks. §9.6.4 rule 5: Option A expands CALL
	// SITES; it does not delete DECLARATIONS. The top-level `expression_templates`
	// registry and `metaparameters` block are peers of `index_sets`, and they
	// survive parse → emit VERBATIM — a template-library file must round-trip to
	// itself. The resolver strips them from its working view (it has consumed
	// them), so they are captured from the AUTHORED document here and reattached to
	// the typed struct below, which makes "verbatim" literal: whatever the passes
	// did to their working copy cannot perturb what is re-emitted.
	authoredTemplates, authoredMetaparams := authoredDeclarationBlocks(jsonStr)

	expanded, err := resolveAndLowerJSON(jsonStr, o.basePath, o.metaparameters)
	if err != nil {
		return nil, err
	}
	jsonStr = expanded

	// Parse JSON into our struct. ESMFile implements json.Unmarshaler, so a
	// top-level decoder's UseNumber setting would NOT reach the nested
	// Expression slots — the int/float wire distinction (discretization RFC
	// §5.4.1) is instead preserved deeper down, by UnmarshalExpression's own
	// UseNumber decoder for every Expression-bearing field, with the residual
	// json.Number tokens cleaned up by normalizeNumericLiterals below.
	var esmFile ESMFile
	if err := json.Unmarshal([]byte(jsonStr), &esmFile); err != nil {
		return nil, fmt.Errorf("failed to unmarshal JSON: %w", err)
	}

	// Convert residual json.Number tokens (only appear inside Expression
	// slots and other interface{} fields) to int64 or float64 per RFC §5.4.6
	// round-trip parse rule: a token containing '.', 'e', or 'E' is a float;
	// otherwise it is an integer.
	normalizeNumericLiterals(&esmFile)

	// Reattach the authored declaration blocks (see authoredDeclarationBlocks).
	esmFile.ExpressionTemplates = authoredTemplates
	esmFile.Metaparameters = authoredMetaparams

	// v0.3.0 closes the function registry (closed-function-registry RFC).
	// Reject any v0.2.x file that still carries the removed top-level
	// `operators` / `registered_functions` blocks or an explicit `call`
	// op anywhere in an expression tree. The schema also rejects these,
	// but we add structural checks at the file boundary so callers that
	// bypass schema validation still see a clear error.
	if err := rejectDeprecatedV02Blocks(jsonStr); err != nil {
		return nil, err
	}
	if err := rejectCallOps(&esmFile); err != nil {
		return nil, err
	}

	// Lower `enum` ops to `const` integer nodes per esm-spec §9.3. After
	// this pass, no `enum` op remains in the in-memory representation.
	if err := LowerEnums(&esmFile); err != nil {
		return nil, err
	}

	// According to spec Section 2.1a: load() should succeed for valid JSON that
	// passes schema validation but fails structural validation. Structural issues
	// should only be reported by the separate validate() function.
	// Therefore, we skip the structural validation here.

	return &esmFile, nil
}

// normalizeJSONNumber converts a json.Number to int64 (no '.', no 'e'/'E') or
// float64 per discretization RFC §5.4.6 round-trip parse rule. Values outside
// int64 range fall back to float64.
func normalizeJSONNumber(n json.Number) any {
	s := string(n)
	if strings.ContainsAny(s, ".eE") {
		f, err := n.Float64()
		if err != nil {
			return s
		}
		return f
	}
	i, err := n.Int64()
	if err == nil {
		return i
	}
	// Integer grammar but outside int64 range — fall back to float.
	f, err := n.Float64()
	if err != nil {
		return s
	}
	return f
}

// normalizeExpression walks an Expression tree and replaces json.Number tokens
// with int64 or float64 per RFC §5.4.6. It is TOTAL over the Expression union:
// every value it does not recognize is returned unchanged, which is required so
// it can be handed to mapExprChildren as the child-normalizer (mapExprChildren
// applies it to raw-JSON slots — Attrs/Bindings/Ranges/Regions/aggregate
// scalars — that carry non-node leaves).
func normalizeExpression(expr Expression) Expression {
	switch e := expr.(type) {
	case json.Number:
		return normalizeJSONNumber(e)
	case ExprNode:
		// Route the child recursion through the shared field-preserving walker
		// so a newly added Expression-bearing field can never be missed here.
		// f never errors, so the returned error is always nil.
		out, _ := mapExprChildren(e, func(child Expression) (Expression, error) {
			return normalizeExpression(child), nil
		})
		return out
	case *ExprNode:
		if e == nil {
			return e
		}
		// Delegate to the value case, then write the normalized node back
		// through the pointer so callers that reuse the *ExprNode see it.
		if nv, ok := normalizeExpression(*e).(ExprNode); ok {
			*e = nv
		}
		return e
	case []any:
		for i, a := range e {
			e[i] = normalizeExpression(a)
		}
		return e
	case map[string]any:
		for k, v := range e {
			e[k] = normalizeExpression(v)
		}
		return e
	default:
		return expr
	}
}

// normalizeNumericLiterals walks the parsed ESMFile and normalizes json.Number
// tokens to int64 or float64 in every Expression-bearing field.
func normalizeNumericLiterals(ef *ESMFile) {
	if ef.Models != nil {
		for name, model := range ef.Models {
			normalizeModelLiterals(&model)
			ef.Models[name] = model
		}
	}
	if ef.ReactionSystems != nil {
		for name, rs := range ef.ReactionSystems {
			normalizeReactionSystemLiterals(&rs)
			ef.ReactionSystems[name] = rs
		}
	}
}

// normalizeDiscreteEventLiterals normalizes the Expression-bearing slots of a
// discrete event (its condition-trigger expression and each affect RHS).
func normalizeDiscreteEventLiterals(de *DiscreteEvent) {
	for j := range de.Affects {
		de.Affects[j].RHS = normalizeExpression(de.Affects[j].RHS)
	}
	if de.Trigger.Expression != nil {
		de.Trigger.Expression = normalizeExpression(de.Trigger.Expression)
	}
}

// normalizeContinuousEventLiterals normalizes the Expression-bearing slots of a
// continuous event (each condition, each affect RHS, and each affect_neg RHS).
func normalizeContinuousEventLiterals(ce *ContinuousEvent) {
	for j := range ce.Conditions {
		ce.Conditions[j] = normalizeExpression(ce.Conditions[j])
	}
	for j := range ce.Affects {
		ce.Affects[j].RHS = normalizeExpression(ce.Affects[j].RHS)
	}
	for j := range ce.AffectNeg {
		ce.AffectNeg[j].RHS = normalizeExpression(ce.AffectNeg[j].RHS)
	}
}

func normalizeModelLiterals(m *Model) {
	if m == nil {
		return
	}
	for name, v := range m.Variables {
		if v.Expression != nil {
			v.Expression = normalizeExpression(v.Expression)
		}
		if v.Default != nil {
			v.Default = normalizeExpression(v.Default)
		}
		m.Variables[name] = v
	}
	for i := range m.Equations {
		m.Equations[i].LHS = normalizeExpression(m.Equations[i].LHS)
		m.Equations[i].RHS = normalizeExpression(m.Equations[i].RHS)
	}
	for i := range m.InitializationEquations {
		m.InitializationEquations[i].LHS = normalizeExpression(m.InitializationEquations[i].LHS)
		m.InitializationEquations[i].RHS = normalizeExpression(m.InitializationEquations[i].RHS)
	}
	for name, g := range m.Guesses {
		m.Guesses[name] = normalizeExpression(g)
	}
	for i := range m.DiscreteEvents {
		normalizeDiscreteEventLiterals(&m.DiscreteEvents[i])
	}
	for i := range m.ContinuousEvents {
		normalizeContinuousEventLiterals(&m.ContinuousEvents[i])
	}
}

func normalizeReactionSystemLiterals(rs *ReactionSystem) {
	if rs == nil {
		return
	}
	for i := range rs.Reactions {
		rs.Reactions[i].Rate = normalizeExpression(rs.Reactions[i].Rate)
	}
	for i := range rs.ConstraintEquations {
		rs.ConstraintEquations[i].LHS = normalizeExpression(rs.ConstraintEquations[i].LHS)
		rs.ConstraintEquations[i].RHS = normalizeExpression(rs.ConstraintEquations[i].RHS)
	}
	for i := range rs.DiscreteEvents {
		normalizeDiscreteEventLiterals(&rs.DiscreteEvents[i])
	}
	for i := range rs.ContinuousEvents {
		normalizeContinuousEventLiterals(&rs.ContinuousEvents[i])
	}
}

// rejectDeprecatedV02Blocks fails LoadString with a structural error when
// the input still declares the v0.2.x `operators` or `registered_functions`
// top-level blocks removed by the closed-function-registry RFC. The schema
// already rejects these for v0.3.0 inputs; this is a redundant boundary
// check that survives bypassed schema validation.
func rejectDeprecatedV02Blocks(jsonStr string) error {
	var top map[string]json.RawMessage
	if err := json.Unmarshal([]byte(jsonStr), &top); err != nil {
		// Non-object root would have failed schema validation upstream.
		return nil
	}
	if _, ok := top["operators"]; ok {
		return fmt.Errorf("deprecated_v02_block: top-level `operators` was removed in v0.3.0 " +
			"(closed-function-registry RFC §6); migrate to discretization schemes or AST equations")
	}
	if _, ok := top["registered_functions"]; ok {
		return fmt.Errorf("deprecated_v02_block: top-level `registered_functions` was removed in v0.3.0 " +
			"(closed-function-registry RFC §6); rewrite call ops as AST or use the closed registry (esm-spec §9.2)")
	}
	return nil
}

// rejectCallOps walks every expression tree and fails LoadString if any node
// carries `op: "call"`. The `call` op was removed in v0.3.0 in favor of the
// closed-registry `fn` op (esm-spec §4.4 / §9.2).
//
// Node recursion routes through mapExprChildren so every Expression-bearing
// field is covered (not just Args/TableAxes), and the carrier walk reaches
// every top-level expression slot: observed-variable expressions, equations,
// initialization equations, guesses, event triggers/conditions/affects, and —
// on reaction systems — reaction rates and constraint equations.
func rejectCallOps(file *ESMFile) error {
	var visit func(expr Expression) error
	visit = func(expr Expression) error {
		if node, ok := asExprNode(expr); ok {
			if node.Op == "call" {
				return fmt.Errorf("deprecated_call_op: `call` op was removed in v0.3.0; " +
					"use `fn` with a closed-registry name (esm-spec §4.4 / §9.2)")
			}
			_, err := mapExprChildren(node, func(child Expression) (Expression, error) {
				return child, visit(child)
			})
			return err
		}
		// Raw containers (e.g. a decoded Attrs/Bindings value) may still hold
		// operator objects; descend deterministically.
		switch v := expr.(type) {
		case []any:
			for _, a := range v {
				if err := visit(a); err != nil {
					return err
				}
			}
		case map[string]any:
			for _, k := range sortedKeys(v) {
				if err := visit(v[k]); err != nil {
					return err
				}
			}
		}
		return nil
	}

	visitEquations := func(eqs []Equation) error {
		for _, eq := range eqs {
			if err := visit(eq.LHS); err != nil {
				return err
			}
			if err := visit(eq.RHS); err != nil {
				return err
			}
		}
		return nil
	}
	visitDiscreteEvent := func(de *DiscreteEvent) error {
		if de.Trigger.Expression != nil {
			if err := visit(de.Trigger.Expression); err != nil {
				return err
			}
		}
		for _, aff := range de.Affects {
			if err := visit(aff.RHS); err != nil {
				return err
			}
		}
		return nil
	}
	visitContinuousEvent := func(ce *ContinuousEvent) error {
		for _, cond := range ce.Conditions {
			if err := visit(cond); err != nil {
				return err
			}
		}
		for _, aff := range ce.Affects {
			if err := visit(aff.RHS); err != nil {
				return err
			}
		}
		for _, aff := range ce.AffectNeg {
			if err := visit(aff.RHS); err != nil {
				return err
			}
		}
		return nil
	}

	for _, m := range file.Models {
		for _, v := range m.Variables {
			if v.Expression != nil {
				if err := visit(v.Expression); err != nil {
					return err
				}
			}
		}
		if err := visitEquations(m.Equations); err != nil {
			return err
		}
		if err := visitEquations(m.InitializationEquations); err != nil {
			return err
		}
		for _, g := range m.Guesses {
			if err := visit(g); err != nil {
				return err
			}
		}
		for i := range m.DiscreteEvents {
			if err := visitDiscreteEvent(&m.DiscreteEvents[i]); err != nil {
				return err
			}
		}
		for i := range m.ContinuousEvents {
			if err := visitContinuousEvent(&m.ContinuousEvents[i]); err != nil {
				return err
			}
		}
	}
	for _, rs := range file.ReactionSystems {
		for _, r := range rs.Reactions {
			if err := visit(r.Rate); err != nil {
				return err
			}
		}
		if err := visitEquations(rs.ConstraintEquations); err != nil {
			return err
		}
		for i := range rs.DiscreteEvents {
			if err := visitDiscreteEvent(&rs.DiscreteEvents[i]); err != nil {
				return err
			}
		}
		for i := range rs.ContinuousEvents {
			if err := visitContinuousEvent(&rs.ContinuousEvents[i]); err != nil {
				return err
			}
		}
	}
	return nil
}

// validateJSONSchema validates the JSON string against the ESM JSON schema
func validateJSONSchema(jsonStr string) (*ValidationResult, error) {
	// Load the embedded schema
	schemaLoader := gojsonschema.NewBytesLoader(embeddedSchema)

	// Load the document
	documentLoader := gojsonschema.NewStringLoader(jsonStr)

	// Validate
	result, err := gojsonschema.Validate(schemaLoader, documentLoader)
	if err != nil {
		return nil, fmt.Errorf("validation error: %w", err)
	}

	// Convert result to new ValidationResult format
	validationResult := &ValidationResult{
		IsValid:          result.Valid(),
		SchemaErrors:     []SchemaError{},
		StructuralErrors: []StructuralError{},
		UnitWarnings:     []UnitWarning{},
	}

	if !result.Valid() {
		// gojsonschema reports a failed `oneOf`/`anyOf` only as a SHALLOW
		// composition error at the branch point — it does not surface the
		// sub-schema errors (a missing `required`, a mismatched `const`) that
		// explain WHY each branch failed, which AJV (the reference producer) does.
		// The ESM schema wraps every component in a `oneOf` (a coupling entry, a
		// model-vs-subsystem-ref, an event trigger), so most pinned sub-branch
		// errors would otherwise hide behind a bare `oneOf`. descendSchemaErrors
		// recovers them by compiling each failing branch standalone and
		// re-validating the offending subtree — see schema_descent.go.
		validationResult.SchemaErrors = collectSchemaErrorsWithDescent(jsonStr, result.Errors())
	}

	return validationResult, nil
}

// gojsonschemaKeywordMap translates gojsonschema's library-specific error
// "type" strings (errors.go) into the standard JSON-Schema keyword vocabulary
// the cross-language conformance harness pins on (CONFORMANCE_SPEC.md §7.1.2).
// gojsonschema names, e.g., a failed `type` check `invalid_type` and a failed
// `minItems` check `array_min_items`; the harness (and AJV, the reference
// producer) speak the schema keywords themselves. Any type absent from this map
// passes through unchanged, so genuine keywords gojsonschema already names
// correctly (`pattern`, `enum`, `const`, `format`, `required`, `not`) still
// emit, and a future gojsonschema type never silently becomes empty.
var gojsonschemaKeywordMap = map[string]string{
	"additional_property_not_allowed": "additionalProperties",
	"array_max_items":                 "maxItems",
	"array_max_properties":            "maxProperties",
	"array_min_items":                 "minItems",
	"array_min_properties":            "minProperties",
	"array_no_additional_items":       "additionalItems",
	"condition_else":                  "else",
	"condition_then":                  "then",
	"invalid_property_name":           "propertyNames",
	"invalid_property_pattern":        "patternProperties",
	"invalid_type":                    "type",
	"missing_dependency":              "dependencies",
	"multiple_of":                     "multipleOf",
	"number_all_of":                   "allOf",
	"number_any_of":                   "anyOf",
	"number_gt":                       "exclusiveMinimum",
	"number_gte":                      "minimum",
	"number_lt":                       "exclusiveMaximum",
	"number_lte":                      "maximum",
	"number_not":                      "not",
	"number_one_of":                   "oneOf",
	"string_gte":                      "minLength",
	"string_lte":                      "maxLength",
	"unique":                          "uniqueItems",
}

// schemaKeyword maps a gojsonschema error type to the standard JSON-Schema
// keyword, falling back to the raw type for keywords gojsonschema already names
// canonically (or any type not yet mapped).
func schemaKeyword(t string) string {
	if k, ok := gojsonschemaKeywordMap[t]; ok {
		return k
	}
	return t
}

// jsonPointerFromContext converts a gojsonschema validation context
// ("(root).models.BadDiscrete.variables.wind", array indices as ".0") into an
// RFC-6901 JSON Pointer with the document root as the empty string ""
// ("/models/BadDiscrete/variables/wind"). A context of just "(root)" yields "".
//
// The context is split on a NUL delimiter rather than "." so a property name
// that itself contains "." is not mis-segmented, and each segment is
// JSON-Pointer escaped (~ → ~0, / → ~1).
func jsonPointerFromContext(ctx *gojsonschema.JsonContext) string {
	if ctx == nil {
		return ""
	}
	segments := strings.Split(ctx.String("\x00"), "\x00")
	// segments[0] is the root sentinel "(root)"; drop it.
	if len(segments) > 0 {
		segments = segments[1:]
	}
	var b strings.Builder
	for _, seg := range segments {
		b.WriteByte('/')
		b.WriteString(escapeJSONPointerSegment(seg))
	}
	return b.String()
}

// escapeJSONPointerSegment applies RFC-6901 reference-token escaping: "~" must
// be encoded before "/" so a literal "/" does not become "~1" and then get
// re-read as an escape.
func escapeJSONPointerSegment(s string) string {
	if !strings.ContainsAny(s, "~/") {
		return s
	}
	s = strings.ReplaceAll(s, "~", "~0")
	s = strings.ReplaceAll(s, "/", "~1")
	return s
}

// authoredDeclarationBlocks extracts the top-level `expression_templates` and
// `metaparameters` blocks from a document AS AUTHORED, verbatim.
//
// They are declarations, not call sites (esm-spec §9.6.4 rule 5), so they survive
// parse → emit unchanged. Returning the raw bytes — rather than re-encoding a
// decoded view — is what makes that survival exact: key order, number spelling and
// all. A document carrying neither block yields two nils, and both fields are
// `omitempty`, so nothing is added to a document that never had them.
func authoredDeclarationBlocks(jsonStr string) (templates, metaparams json.RawMessage) {
	var top map[string]json.RawMessage
	if err := json.Unmarshal([]byte(jsonStr), &top); err != nil {
		return nil, nil
	}
	return top["expression_templates"], top["metaparameters"]
}
