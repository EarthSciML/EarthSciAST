package esm

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/xeipuuv/gojsonschema"
)

// DeprecationWarningCode identifies a specific deprecation warning emitted at load time.
type DeprecationWarningCode string

// DeprecationWarningLogger is invoked once per deprecation the loader detects.
// Default is to log via the standard `log` package; set to nil to silence.
var DeprecationWarningLogger = func(code DeprecationWarningCode, message string) {
	log.Printf("[%s] %s", code, message)
}

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
func Load(path string, opts ...LoadOption) (*EsmFile, error) {
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

	// Resolve subsystem references relative to the file's directory
	if err := ResolveSubsystemRefs(esmFile, basePath); err != nil {
		return nil, fmt.Errorf("failed to resolve subsystem references: %w", err)
	}

	return esmFile, nil
}

// LoadString parses an ESM file from JSON string and validates it against the JSON schema
func LoadString(jsonStr string, opts ...LoadOption) (*EsmFile, error) {
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
		var preCheck map[string]interface{}
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
			errorStrs = append(errorStrs, schemaErr.Message)
		}
		return nil, fmt.Errorf("JSON schema validation failed: %v", errorStrs)
	}

	// Resolve esm-spec §9.7 machinery — template-library imports (depth-first
	// post-order, per-edge metaparameter instantiation), index_sets merge,
	// metaparameter close+fold — then expand `apply_expression_template` ops
	// / fire `match` rules to the §9.6.3 fixpoint (esm-spec §9.6 /
	// docs/rfcs/ast-expression-templates.md). After both passes the JSON has
	// no apply_expression_template nodes, no expression_templates blocks, no
	// imports, and no metaparameters — the typed struct sees only normal
	// Expression ASTs (Option A round-trip).
	expanded, err := resolveAndLowerJSON(jsonStr, o.basePath, o.metaparameters)
	if err != nil {
		return nil, err
	}
	jsonStr = expanded

	// Parse JSON into our struct. Use UseNumber so that JSON numbers in
	// Expression (interface{}) slots retain their wire form — otherwise
	// json.Unmarshal coerces every number to float64, destroying the
	// integer/float node distinction required by discretization RFC §5.4.1.
	var esmFile EsmFile
	dec := json.NewDecoder(bytes.NewReader([]byte(jsonStr)))
	dec.UseNumber()
	if err := dec.Decode(&esmFile); err != nil {
		return nil, fmt.Errorf("failed to unmarshal JSON: %w", err)
	}

	// Convert residual json.Number tokens (only appear inside Expression
	// slots and other interface{} fields) to int64 or float64 per RFC §5.4.6
	// round-trip parse rule: a token containing '.', 'e', or 'E' is a float;
	// otherwise it is an integer.
	normalizeNumericLiterals(&esmFile)

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
func normalizeJSONNumber(n json.Number) interface{} {
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

// normalizeExpression walks an Expression tree and replaces json.Number
// tokens with int64 or float64 per RFC §5.4.6.
func normalizeExpression(expr Expression) Expression {
	switch e := expr.(type) {
	case json.Number:
		return normalizeJSONNumber(e)
	case ExprNode:
		for i, a := range e.Args {
			e.Args[i] = normalizeExpression(a)
		}
		for k, v := range e.TableAxes {
			e.TableAxes[k] = normalizeExpression(v)
		}
		for k, v := range e.Attrs {
			e.Attrs[k] = normalizeExpression(v)
		}
		if n, ok := e.Output.(json.Number); ok {
			e.Output = normalizeJSONNumber(n)
		}
		return e
	case *ExprNode:
		for i, a := range e.Args {
			e.Args[i] = normalizeExpression(a)
		}
		for k, v := range e.TableAxes {
			e.TableAxes[k] = normalizeExpression(v)
		}
		for k, v := range e.Attrs {
			e.Attrs[k] = normalizeExpression(v)
		}
		if n, ok := e.Output.(json.Number); ok {
			e.Output = normalizeJSONNumber(n)
		}
		return e
	case []interface{}:
		for i, a := range e {
			e[i] = normalizeExpression(a)
		}
		return e
	case map[string]interface{}:
		for k, v := range e {
			e[k] = normalizeExpression(v)
		}
		return e
	default:
		return expr
	}
}

// normalizeNumericLiterals walks the parsed EsmFile and normalizes json.Number
// tokens to int64 or float64 in every Expression-bearing field.
func normalizeNumericLiterals(ef *EsmFile) {
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
	for i := range m.DiscreteEvents {
		for j := range m.DiscreteEvents[i].Affects {
			m.DiscreteEvents[i].Affects[j].RHS = normalizeExpression(m.DiscreteEvents[i].Affects[j].RHS)
		}
		if m.DiscreteEvents[i].Trigger.Expression != nil {
			m.DiscreteEvents[i].Trigger.Expression = normalizeExpression(m.DiscreteEvents[i].Trigger.Expression)
		}
	}
	for i := range m.ContinuousEvents {
		for j := range m.ContinuousEvents[i].Conditions {
			m.ContinuousEvents[i].Conditions[j] = normalizeExpression(m.ContinuousEvents[i].Conditions[j])
		}
		for j := range m.ContinuousEvents[i].Affects {
			m.ContinuousEvents[i].Affects[j].RHS = normalizeExpression(m.ContinuousEvents[i].Affects[j].RHS)
		}
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

// rejectCallOps walks every expression tree and fails LoadString if any
// node carries `op: "call"`. The `call` op was removed in v0.3.0 in favor
// of the closed-registry `fn` op (esm-spec §4.4 / §9.2).
func rejectCallOps(file *EsmFile) error {
	var visit func(expr Expression) error
	visit = func(expr Expression) error {
		switch e := expr.(type) {
		case ExprNode:
			if e.Op == "call" {
				return fmt.Errorf("deprecated_call_op: `call` op was removed in v0.3.0; " +
					"use `fn` with a closed-registry name (esm-spec §4.4 / §9.2)")
			}
			for _, a := range e.Args {
				if err := visit(a); err != nil {
					return err
				}
			}
			for _, v := range e.TableAxes {
				if err := visit(v); err != nil {
					return err
				}
			}
		case *ExprNode:
			if e == nil {
				return nil
			}
			return visit(*e)
		}
		return nil
	}
	if file.Models != nil {
		for _, m := range file.Models {
			for _, v := range m.Variables {
				if v.Expression != nil {
					if err := visit(v.Expression); err != nil {
						return err
					}
				}
			}
			for _, eq := range m.Equations {
				if err := visit(eq.LHS); err != nil {
					return err
				}
				if err := visit(eq.RHS); err != nil {
					return err
				}
			}
			for _, eq := range m.InitializationEquations {
				if err := visit(eq.LHS); err != nil {
					return err
				}
				if err := visit(eq.RHS); err != nil {
					return err
				}
			}
		}
	}
	if file.ReactionSystems != nil {
		for _, rs := range file.ReactionSystems {
			for _, r := range rs.Reactions {
				if err := visit(r.Rate); err != nil {
					return err
				}
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
		for _, desc := range result.Errors() {
			schemaError := SchemaError{
				Path:    desc.Context().String(),
				Message: desc.Description(),
				Keyword: desc.Type(),
			}
			validationResult.SchemaErrors = append(validationResult.SchemaErrors, schemaError)
		}
	}

	return validationResult, nil
}
