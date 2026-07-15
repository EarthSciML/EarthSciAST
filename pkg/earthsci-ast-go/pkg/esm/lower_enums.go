package esm

// Enum lowering — esm-spec §9.3.
//
// Walks every expression tree in an ESMFile and replaces each `enum`-op
// node with an equivalent `const`-op integer per the file's `enums` block.
// After this pass runs, no `enum`-op nodes remain in the in-memory
// representation.

import (
	"fmt"
)

// LowerEnumsError carries the spec-defined diagnostic codes for the
// load-time lowering pass:
//
//   - unknown_enum         — `enum` op names an undeclared enum.
//   - unknown_enum_symbol  — `enum` op names a symbol not declared under
//     that enum.
type LowerEnumsError struct {
	Code    string
	Message string
}

func (e *LowerEnumsError) Error() string {
	return fmt.Sprintf("[%s] %s", e.Code, e.Message)
}

// DiagnosticCode returns the stable diagnostic code (DiagnosticError).
func (e *LowerEnumsError) DiagnosticCode() string { return e.Code }

func newLowerEnumsError(code, msg string) *LowerEnumsError {
	return &LowerEnumsError{Code: code, Message: msg}
}

// LowerEnums walks every expression tree in the file and resolves each
// `enum` op to a `{op: "const", value: <int>}` node per esm-spec §9.3.
// Returns LowerEnumsError if any enum op references an undeclared enum
// or symbol; otherwise mutates the file in place and returns nil.
func LowerEnums(file *ESMFile) error {
	enums := file.Enums
	if enums == nil {
		enums = map[string]map[string]int{}
	}
	if file.Models != nil {
		for name, m := range file.Models {
			if err := lowerModelEnums(&m, enums); err != nil {
				return err
			}
			file.Models[name] = m
		}
	}
	if file.ReactionSystems != nil {
		for name, rs := range file.ReactionSystems {
			if err := lowerReactionSystemEnums(&rs, enums); err != nil {
				return err
			}
			file.ReactionSystems[name] = rs
		}
	}
	for i := range file.Coupling {
		lowered, err := lowerCouplingEntryEnums(file.Coupling[i], enums)
		if err != nil {
			return err
		}
		file.Coupling[i] = lowered
	}
	return nil
}

func lowerModelEnums(m *Model, enums map[string]map[string]int) error {
	for name, v := range m.Variables {
		if v.Expression != nil {
			lowered, err := lowerExprEnums(v.Expression, enums)
			if err != nil {
				return err
			}
			v.Expression = lowered
			m.Variables[name] = v
		}
	}
	for i := range m.Equations {
		l, err := lowerExprEnums(m.Equations[i].LHS, enums)
		if err != nil {
			return err
		}
		r, err := lowerExprEnums(m.Equations[i].RHS, enums)
		if err != nil {
			return err
		}
		m.Equations[i].LHS = l
		m.Equations[i].RHS = r
	}
	for i := range m.InitializationEquations {
		l, err := lowerExprEnums(m.InitializationEquations[i].LHS, enums)
		if err != nil {
			return err
		}
		r, err := lowerExprEnums(m.InitializationEquations[i].RHS, enums)
		if err != nil {
			return err
		}
		m.InitializationEquations[i].LHS = l
		m.InitializationEquations[i].RHS = r
	}
	if err := lowerDiscreteEventEnums(m.DiscreteEvents, enums); err != nil {
		return err
	}
	return lowerContinuousEventEnums(m.ContinuousEvents, enums)
}

// lowerDiscreteEventEnums lowers `enum` ops in a discrete event's trigger
// condition and affect right-hand sides. Events were skipped entirely by the
// enum-lowering walk, so an `enum` in an event survived the pass — violating the
// post-condition that no `enum` node remains after LowerEnums, and leaving the
// `unknown_enum` / `unknown_enum_symbol` diagnostics dead in those positions
// (audit G15).
func lowerDiscreteEventEnums(events []DiscreteEvent, enums map[string]map[string]int) error {
	for i := range events {
		if events[i].Trigger.Expression != nil {
			lowered, err := lowerExprEnums(events[i].Trigger.Expression, enums)
			if err != nil {
				return err
			}
			events[i].Trigger.Expression = lowered
		}
		if err := lowerAffectEnums(events[i].Affects, enums); err != nil {
			return err
		}
	}
	return nil
}

// lowerContinuousEventEnums lowers `enum` ops in a continuous event's root-find
// conditions and both affect lists.
func lowerContinuousEventEnums(events []ContinuousEvent, enums map[string]map[string]int) error {
	for i := range events {
		for j := range events[i].Conditions {
			lowered, err := lowerExprEnums(events[i].Conditions[j], enums)
			if err != nil {
				return err
			}
			events[i].Conditions[j] = lowered
		}
		if err := lowerAffectEnums(events[i].Affects, enums); err != nil {
			return err
		}
		if err := lowerAffectEnums(events[i].AffectNeg, enums); err != nil {
			return err
		}
	}
	return nil
}

// lowerAffectEnums lowers `enum` ops in the RHS of each affect equation. The LHS
// is a variable NAME, not an expression, so it is left alone.
func lowerAffectEnums(affects []AffectEquation, enums map[string]map[string]int) error {
	for i := range affects {
		lowered, err := lowerExprEnums(affects[i].RHS, enums)
		if err != nil {
			return err
		}
		affects[i].RHS = lowered
	}
	return nil
}

func lowerReactionSystemEnums(rs *ReactionSystem, enums map[string]map[string]int) error {
	for i := range rs.Reactions {
		r, err := lowerExprEnums(rs.Reactions[i].Rate, enums)
		if err != nil {
			return err
		}
		rs.Reactions[i].Rate = r
	}
	for i := range rs.ConstraintEquations {
		l, err := lowerExprEnums(rs.ConstraintEquations[i].LHS, enums)
		if err != nil {
			return err
		}
		r, err := lowerExprEnums(rs.ConstraintEquations[i].RHS, enums)
		if err != nil {
			return err
		}
		rs.ConstraintEquations[i].LHS = l
		rs.ConstraintEquations[i].RHS = r
	}
	if err := lowerDiscreteEventEnums(rs.DiscreteEvents, enums); err != nil {
		return err
	}
	return lowerContinuousEventEnums(rs.ContinuousEvents, enums)
}

// lowerCouplingEntryEnums lowers enum ops inside a coupling entry's connector
// equations, returning the (possibly updated) entry. Only CouplingCouple
// entries carry connector equations; any other entry is returned unchanged.
func lowerCouplingEntryEnums(ce CouplingEntry, enums map[string]map[string]int) (CouplingEntry, error) {
	cc, ok := ce.(CouplingCouple)
	if !ok {
		return ce, nil
	}
	for i := range cc.Connector.Equations {
		if cc.Connector.Equations[i].Expression != nil {
			lowered, err := lowerExprEnums(cc.Connector.Equations[i].Expression, enums)
			if err != nil {
				return ce, err
			}
			cc.Connector.Equations[i].Expression = lowered
		}
	}
	return cc, nil
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
			return nil, newLowerEnumsError("invalid_enum_arity",
				fmt.Sprintf("`enum` op expects 2 args (enum_name, symbol_name), got %d", len(node.Args)))
		}
		enumName, ok := stringFromArg(node.Args[0])
		if !ok {
			return nil, newLowerEnumsError("invalid_enum_arg",
				"`enum` op: first arg must be a string (enum name)")
		}
		symName, ok := stringFromArg(node.Args[1])
		if !ok {
			return nil, newLowerEnumsError("invalid_enum_arg",
				"`enum` op: second arg must be a string (symbol name)")
		}
		mapping, ok := enums[enumName]
		if !ok {
			return nil, newLowerEnumsError("unknown_enum",
				fmt.Sprintf("enum %q is not declared in the file's `enums` block", enumName))
		}
		v, ok := mapping[symName]
		if !ok {
			return nil, newLowerEnumsError("unknown_enum_symbol",
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
