package esm

// Enum lowering — esm-spec §9.3.
//
// Walks every expression tree in an ESMFile and replaces each `enum`-op
// node with an equivalent `const`-op integer per the file's `enums` block.
// After this pass runs, no `enum`-op nodes remain in the in-memory
// representation.

import (
	"encoding/json"
	"fmt"
)

// EnumLoweringError carries the spec-defined diagnostic codes for the
// load-time lowering pass:
//
//   - unknown_enum         — `enum` op names an undeclared enum.
//   - unknown_enum_symbol  — `enum` op names a symbol not declared under
//     that enum.
type EnumLoweringError struct {
	Code    string
	Message string
}

func (e *EnumLoweringError) Error() string {
	return fmt.Sprintf("[%s] %s", e.Code, e.Message)
}

// DiagnosticCode returns the stable diagnostic code (DiagnosticError).
func (e *EnumLoweringError) DiagnosticCode() string { return e.Code }

func newEnumLoweringError(code, msg string) *EnumLoweringError {
	return &EnumLoweringError{Code: code, Message: msg}
}

// lowerEnumOpsForFile returns raw-JSON target with its `enum` ops lowered
// against the `enums` block of document, the file that wrote target. target is
// not modified.
//
// An `enum` op is file-local (esm-spec §9.3): it resolves against the block of
// the file it is written in. LowerEnums runs once over the root document, so a
// tree that crosses a file boundary before that pass (a template-library body
// reaching an importer, §9.7.5) is lowered here, at the edge, while its own
// file's block is still at hand.
//
// An op with an argument spelled by a name in openNames is left in place: a
// template parameter substitutes position-blind (§9.6.3 constraint 5), so the
// call site decides what it spells and the op resolves there. An op whose
// arguments are not two strings is left for LowerEnums, which owns the
// malformed-op diagnostic.
func lowerEnumOpsForFile(document map[string]any, target any, openNames map[string]bool) (any, error) {
	return lowerRawEnumOps(target, rawEnumsBlock(document), openNames)
}

// rawEnumsBlock reads a raw document's `enums` block into its typed form.
func rawEnumsBlock(document map[string]any) map[string]map[string]int {
	enums := map[string]map[string]int{}
	block, _ := document["enums"].(map[string]any)
	for name, rawMembers := range block {
		members, ok := rawMembers.(map[string]any)
		if !ok {
			continue
		}
		m := map[string]int{}
		for sym, v := range members {
			if n, ok := rawEnumValue(v); ok {
				m[sym] = n
			}
		}
		enums[name] = m
	}
	return enums
}

// lowerMountedDocumentEnums lowers, IN PLACE, the `enum` ops of a document
// mounted at a §4.7 edge against that document's own `enums` block (esm-spec
// §9.3), once it has resolved in its own scope and before its component is
// spliced into the mounting document, whose block is a different one. `enums`
// do not merge across a mount, so this is the only block those ops can name.
//
// A template declaration's body is lowered with that template's `params` left
// open, as at the import edge: an op spelled with a parameter resolves at the
// call site. Everything else is lowered with no open names.
func lowerMountedDocumentEnums(document map[string]any) error {
	enums := rawEnumsBlock(document)
	for k, v := range document {
		lowered, err := lowerMountedEnumOps(k, v, enums)
		if err != nil {
			return err
		}
		document[k] = lowered
	}
	return nil
}

func lowerMountedEnumOps(key string, node any, enums map[string]map[string]int) (any, error) {
	if tpl, ok := node.(map[string]any); ok && key == "expression_templates" {
		for name, rawDecl := range tpl {
			decl, ok := rawDecl.(map[string]any)
			if !ok {
				continue
			}
			body, has := decl["body"]
			if !has {
				continue
			}
			open := map[string]bool{}
			if params, ok := decl["params"].([]any); ok {
				for _, p := range params {
					if s, ok := p.(string); ok {
						open[s] = true
					}
				}
			}
			lowered, err := lowerRawEnumOps(body, enums, open)
			if err != nil {
				return nil, err
			}
			decl["body"] = lowered
			tpl[name] = decl
		}
		return tpl, nil
	}
	switch v := node.(type) {
	case []any:
		for i, el := range v {
			lowered, err := lowerMountedEnumOps("", el, enums)
			if err != nil {
				return nil, err
			}
			v[i] = lowered
		}
		return v, nil
	case map[string]any:
		if op, _ := v["op"].(string); op == OpEnum {
			return lowerRawEnumOps(v, enums, nil)
		}
		for k, el := range v {
			lowered, err := lowerMountedEnumOps(k, el, enums)
			if err != nil {
				return nil, err
			}
			v[k] = lowered
		}
		return v, nil
	}
	return node, nil
}

func rawEnumValue(v any) (int, bool) {
	switch n := v.(type) {
	case json.Number:
		i, err := n.Int64()
		return int(i), err == nil
	case float64:
		return int(n), n == float64(int(n))
	case int:
		return n, true
	case int64:
		return int(n), true
	}
	return 0, false
}

func lowerRawEnumOps(node any, enums map[string]map[string]int, openNames map[string]bool) (any, error) {
	switch v := node.(type) {
	case []any:
		out := make([]any, len(v))
		for i, el := range v {
			lowered, err := lowerRawEnumOps(el, enums, openNames)
			if err != nil {
				return nil, err
			}
			out[i] = lowered
		}
		return out, nil
	case map[string]any:
		if op, _ := v["op"].(string); op == OpEnum {
			args, _ := v["args"].([]any)
			if len(args) != 2 {
				return v, nil
			}
			name, okName := args[0].(string)
			sym, okSym := args[1].(string)
			if !okName || !okSym || openNames[name] || openNames[sym] {
				return v, nil
			}
			lowered, err := lowerExprNodeEnums(ExprNode{Op: OpEnum, Args: []any{name, sym}}, enums)
			if err != nil {
				return nil, err
			}
			return map[string]any{"op": OpConst, "args": []any{}, "value": lowered.(ExprNode).Value}, nil
		}
		out := make(map[string]any, len(v))
		for k, el := range v {
			lowered, err := lowerRawEnumOps(el, enums, openNames)
			if err != nil {
				return nil, err
			}
			out[k] = lowered
		}
		return out, nil
	}
	return node, nil
}

// LowerEnums resolves every `enum` op in the file to a
// `{op: "const", value: <int>}` node per esm-spec §9.3, and returns the
// lowered document. The argument is NOT modified.
//
// Canonical `lower_enums` (API_SPEC.md §8 item 15): the canonical name is the
// PURE form in every binding, and the mutating twin takes a suffix (`Mut` here,
// `!` in Julia). Go's LowerEnums used to be the mutating one.
//
// Returns an *EnumLoweringError if any `enum` op names an undeclared enum or an
// undeclared symbol; the returned document is nil in that case, so a caller
// cannot mistake a partially-lowered value for a lowered one — which is the
// concrete reason the pure form is canonical. LowerEnumsMut, having written
// into the caller's document as it went, cannot make that promise.
func LowerEnums(file *ESMFile) (*ESMFile, error) {
	if file == nil {
		return nil, nil
	}
	out := cloneForExprLowering(file)
	if err := LowerEnumsMut(out); err != nil {
		return nil, err
	}
	return out, nil
}

// cloneForExprLowering copies exactly the containers a mapFileExprs pass writes
// into — the models and reaction-systems maps, the equation / event / reaction
// slices inside them, and the coupling slice — so that lowering the copy cannot
// be observed through the original. It backs the PURE form of both lowering
// passes (LowerEnums and lowerTableLookups).
//
// It is deliberately NOT a deep copy of the whole document: expression trees
// are rewritten functionally (mapExprChildren allocates rather than mutating),
// and every other field is only read, so sharing them is safe and copying them
// would be waste. A new mutation site in mapFileExprs needs a new clone site
// here.
func cloneForExprLowering(file *ESMFile) *ESMFile {
	out := *file
	if file.Models != nil {
		out.Models = make(map[string]Model, len(file.Models))
		for name, m := range file.Models {
			m.Variables = cloneMap(m.Variables)
			m.Equations = cloneSlice(m.Equations)
			m.InitializationEquations = cloneSlice(m.InitializationEquations)
			m.DiscreteEvents = cloneDiscreteEvents(m.DiscreteEvents)
			m.ContinuousEvents = cloneContinuousEvents(m.ContinuousEvents)
			out.Models[name] = m
		}
	}
	if file.ReactionSystems != nil {
		out.ReactionSystems = make(map[string]ReactionSystem, len(file.ReactionSystems))
		for name, rs := range file.ReactionSystems {
			rs.Reactions = cloneSlice(rs.Reactions)
			rs.ConstraintEquations = cloneSlice(rs.ConstraintEquations)
			rs.DiscreteEvents = cloneDiscreteEvents(rs.DiscreteEvents)
			rs.ContinuousEvents = cloneContinuousEvents(rs.ContinuousEvents)
			out.ReactionSystems[name] = rs
		}
	}
	out.Coupling = cloneSlice(file.Coupling)
	for i, ce := range out.Coupling {
		if cc, ok := ce.(CouplingCouple); ok {
			cc.Connector.Equations = cloneSlice(cc.Connector.Equations)
			out.Coupling[i] = cc
		}
	}
	return &out
}

// cloneSlice returns a copy of s with its own backing array (nil stays nil, so
// an absent optional block re-emits as absent rather than as an empty array).
func cloneSlice[T any](s []T) []T {
	if s == nil {
		return nil
	}
	out := make([]T, len(s))
	copy(out, s)
	return out
}

// cloneMap returns a shallow copy of m (nil stays nil).
func cloneMap[K comparable, V any](m map[K]V) map[K]V {
	if m == nil {
		return nil
	}
	out := make(map[K]V, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

// cloneDiscreteEvents copies the event slice and, inside each event, the affect
// slice — the two levels LowerEnumsMut writes through.
func cloneDiscreteEvents(events []DiscreteEvent) []DiscreteEvent {
	out := cloneSlice(events)
	for i := range out {
		out[i].Affects = cloneSlice(out[i].Affects)
	}
	return out
}

// cloneContinuousEvents copies the event slice and, inside each event, the
// condition and both affect slices.
func cloneContinuousEvents(events []ContinuousEvent) []ContinuousEvent {
	out := cloneSlice(events)
	for i := range out {
		out[i].Conditions = cloneSlice(out[i].Conditions)
		out[i].Affects = cloneSlice(out[i].Affects)
		out[i].AffectNeg = cloneSlice(out[i].AffectNeg)
	}
	return out
}

// LowerEnumsMut is LowerEnums applied IN PLACE: it walks every expression tree
// in the file and resolves each `enum` op to a `{op: "const", value: <int>}`
// node per esm-spec §9.3, mutating the file and returning nil, or returning an
// *EnumLoweringError if any enum op references an undeclared enum or symbol.
//
// On error the file is left PARTIALLY LOWERED — the pass writes as it walks and
// does not roll back. A caller that cannot tolerate that wants LowerEnums.
func LowerEnumsMut(file *ESMFile) error {
	enums := file.Enums
	if enums == nil {
		enums = map[string]map[string]int{}
	}
	// mapFileExprs enumerates the document's Expression-bearing positions once,
	// for every lowering pass. Spelling that walk here is how an `enum` inside
	// an EVENT came to survive the pass (audit G15).
	return mapFileExprs(file, func(expr Expression) (Expression, error) {
		return lowerExprEnums(expr, enums)
	})
}

// lowerExprEnums recursively lowers `enum` ops to `const` integer nodes.
//
// Operator nodes are recognized in EVERY on-heap spelling (asExprNode), raw
// decoded map included, so an `enum` in a hand-built or un-normalized subtree is
// lowered rather than passed through untouched by a `default:` arm (audit G15).
// Raw lists are descended for the same reason.
func lowerExprEnums(expr Expression, enums map[string]map[string]int) (Expression, error) {
	if node, ok := asExprNode(expr); ok {
		return lowerExprNodeEnums(node, enums)
	}
	if list, ok := expr.([]any); ok {
		out := make([]any, len(list))
		for i, el := range list {
			lowered, err := lowerExprEnums(el, enums)
			if err != nil {
				return nil, err
			}
			out[i] = lowered
		}
		return out, nil
	}
	return expr, nil
}

func lowerExprNodeEnums(node ExprNode, enums map[string]map[string]int) (Expression, error) {
	if node.Op == OpEnum {
		// esm-spec §4.5: args are exactly two strings — the enum name and
		// the symbolic key.
		if len(node.Args) != 2 {
			return nil, newEnumLoweringError("invalid_enum_arity",
				fmt.Sprintf("`enum` op expects 2 args (enum_name, symbol_name), got %d", len(node.Args)))
		}
		enumName, ok := stringFromArg(node.Args[0])
		if !ok {
			return nil, newEnumLoweringError("invalid_enum_arg",
				"`enum` op: first arg must be a string (enum name)")
		}
		symName, ok := stringFromArg(node.Args[1])
		if !ok {
			return nil, newEnumLoweringError("invalid_enum_arg",
				"`enum` op: second arg must be a string (symbol name)")
		}
		mapping, ok := enums[enumName]
		if !ok {
			return nil, newEnumLoweringError("unknown_enum",
				fmt.Sprintf("enum %q is not declared in the file's `enums` block", enumName))
		}
		v, ok := mapping[symName]
		if !ok {
			return nil, newEnumLoweringError("unknown_enum_symbol",
				fmt.Sprintf("symbol %q is not declared under enum %q", symName, enumName))
		}
		return ExprNode{Op: OpConst, Args: []any{}, Value: int64(v)}, nil
	}
	// Recurse — lower every child through the shared field-preserving walker.
	// The old rebuild covered only Args + TableAxes, so an `enum` op nested in
	// an aggregate body, integral bound, join/filter clause, makearray region,
	// etc. survived to evaluation ("should have been lowered at load"); routing
	// through mapExprChildren lowers those positions too and preserves every
	// other field.
	return mapExprChildren(node, func(child Expression) (Expression, error) {
		return lowerExprEnums(child, enums)
	})
}

// stringFromArg accepts either a bare string (a `VarExpr`-equivalent in
// Go's looser AST) or a `const`-op node carrying a string `Value`.
func stringFromArg(a any) (string, bool) {
	switch v := a.(type) {
	case string:
		return v, true
	case ExprNode:
		if v.Op == "const" {
			if s, ok := v.Value.(string); ok {
				return s, true
			}
		}
	case *ExprNode:
		if v != nil && v.Op == "const" {
			if s, ok := v.Value.(string); ok {
				return s, true
			}
		}
	}
	return "", false
}
