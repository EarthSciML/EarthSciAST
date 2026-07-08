package esm

// Enum lowering — esm-spec §9.3.
//
// Walks every expression tree in an EsmFile and replaces each `enum`-op
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
	return fmt.Sprintf("LowerEnumsError(%s): %s", e.Code, e.Message)
}

func newLowerEnumsError(code, msg string) *LowerEnumsError {
	return &LowerEnumsError{Code: code, Message: msg}
}

// LowerEnums walks every expression tree in the file and resolves each
// `enum` op to a `{op: "const", value: <int>}` node per esm-spec §9.3.
// Returns LowerEnumsError if any enum op references an undeclared enum
// or symbol; otherwise mutates the file in place and returns nil.
func LowerEnums(file *EsmFile) error {
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
		if err := lowerCouplingEntryEnums(&file.Coupling[i], enums); err != nil {
			return err
		}
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
	return nil
}

func lowerCouplingEntryEnums(ce *interface{}, enums map[string]map[string]int) error {
	cc, ok := (*ce).(CouplingCouple)
	if !ok {
		return nil
	}
	if cc.Connector.Equations != nil {
		for i := range cc.Connector.Equations {
			if cc.Connector.Equations[i].Expression != nil {
				lowered, err := lowerExprEnums(cc.Connector.Equations[i].Expression, enums)
				if err != nil {
					return err
				}
				cc.Connector.Equations[i].Expression = lowered
			}
		}
		*ce = cc
	}
	return nil
}

// lowerExprEnums recursively lowers `enum` ops to `const` integer nodes.
func lowerExprEnums(expr Expression, enums map[string]map[string]int) (Expression, error) {
	switch e := expr.(type) {
	case ExprNode:
		return lowerExprNodeEnums(e, enums)
	case *ExprNode:
		if e == nil {
			return nil, nil
		}
		out, err := lowerExprNodeEnums(*e, enums)
		return out, err
	default:
		return expr, nil
	}
}

func lowerExprNodeEnums(node ExprNode, enums map[string]map[string]int) (Expression, error) {
	if node.Op == "enum" {
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
		return ExprNode{Op: "const", Args: []interface{}{}, Value: int64(v)}, nil
	}
	// Recurse — lower children and rebuild.
	newArgs := make([]interface{}, len(node.Args))
	for i, a := range node.Args {
		la, err := lowerExprEnums(a, enums)
		if err != nil {
			return nil, err
		}
		newArgs[i] = la
	}
	// Recurse into table_lookup axes (per-axis input expressions).
	var newTableAxes map[string]Expression
	if node.TableAxes != nil {
		newTableAxes = make(map[string]Expression, len(node.TableAxes))
		for k, v := range node.TableAxes {
			lv, err := lowerExprEnums(v, enums)
			if err != nil {
				return nil, err
			}
			newTableAxes[k] = lv
		}
	}
	out := ExprNode{
		Op:        node.Op,
		Args:      newArgs,
		Wrt:       node.Wrt,
		Dim:       node.Dim,
		Name:      node.Name,
		Value:     node.Value,
		Table:     node.Table,
		TableAxes: newTableAxes,
		Output:    node.Output,
	}
	return out, nil
}

// stringFromArg accepts either a bare string (a `VarExpr`-equivalent in
// Go's looser AST) or a `const`-op node carrying a string `Value`.
func stringFromArg(a interface{}) (string, bool) {
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
