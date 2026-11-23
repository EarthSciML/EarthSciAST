package esm

import (
	"fmt"
	"slices"
	"strings"
)

// PrecisionSource returns the declared element type or "unspecified" (§11.3.3).
// A nil variable queries the document default, including for reaction species
// and parameters.
func PrecisionSource(document *ESMFile, variable *ModelVariable) string {
	if variable != nil && variable.ElementType != nil {
		return *variable.ElementType
	}
	if document.Domain != nil && document.Domain.ElementType != nil {
		return *document.Domain.ElementType
	}
	return omittedPrecision(document.ESM)
}

// unspecifiedPrecisionSince is the first esm version at which a root that
// declares no `domain.element_type` leaves its precision unspecified
// (esm-spec §11.3.3). An older root that omits it declares binary64.
var unspecifiedPrecisionSince = semVer{Major: 2, Minor: 4, Patch: 0}

func omittedPrecision(version string) string {
	if parsed, ok := parseSemVer(version); ok && compareSemVer(parsed, unspecifiedPrecisionSince) >= 0 {
		return "unspecified"
	}
	return "Float64"
}

// keySite is one unspecified variable used directly as a key (esm-spec
// §11.3.3 P8): the JSON pointer of the equation side or reaction rate.
type keySite struct {
	Path    string
	Message string
}

type keyExpression struct {
	scope, pointer string
	expr           Expression
}

// unspecifiedKeys lists every unspecified variable used directly as an operand
// of `==` / `!=` or as a `join.on` key (esm-spec §11.3.3 P8). It is empty
// unless the document's own precision is unspecified. An indexed read is its
// array; a loop or binder symbol is not a variable.
func unspecifiedKeys(file *ESMFile) []keySite {
	if file == nil || PrecisionSource(file, nil) != "unspecified" {
		return nil
	}
	unspecified := map[string]bool{}
	var exprs []keyExpression
	equations := func(scope, pointer, block string, eqs []Equation) {
		for i, eq := range eqs {
			exprs = append(exprs,
				keyExpression{scope, fmt.Sprintf("%s/%s/%d/lhs", pointer, block, i), eq.LHS},
				keyExpression{scope, fmt.Sprintf("%s/%s/%d/rhs", pointer, block, i), eq.RHS})
		}
	}
	var model func(scope, pointer string, m *Model)
	model = func(scope, pointer string, m *Model) {
		for _, name := range sortedKeys(m.Variables) {
			unspecified[scope+"."+name] = m.Variables[name].ElementType == nil
		}
		equations(scope, pointer, "equations", m.Equations)
		equations(scope, pointer, "initialization_equations", m.InitializationEquations)
		for _, key := range sortedKeys(m.Subsystems) {
			raw, ok := subsystemAsMap(m.Subsystems[key])
			if !ok || isReactionSystemMap(raw) {
				continue
			}
			if sub, ok := decodeSubsystemAs[Model](raw); ok {
				model(scope+"."+key, pointer+"/subsystems/"+key, &sub)
			}
		}
	}
	var reactionSystem func(scope, pointer string, rs *ReactionSystem)
	reactionSystem = func(scope, pointer string, rs *ReactionSystem) {
		for name := range rs.Species {
			unspecified[scope+"."+name] = true
		}
		for name := range rs.Parameters {
			unspecified[scope+"."+name] = true
		}
		for i, r := range rs.Reactions {
			exprs = append(exprs, keyExpression{scope, fmt.Sprintf("%s/reactions/%d/rate", pointer, i), r.Rate})
		}
		equations(scope, pointer, "constraint_equations", rs.ConstraintEquations)
		for _, key := range sortedKeys(rs.Subsystems) {
			raw, ok := subsystemAsMap(rs.Subsystems[key])
			if !ok || !isReactionSystemMap(raw) {
				continue
			}
			if sub, ok := decodeSubsystemAs[ReactionSystem](raw); ok {
				reactionSystem(scope+"."+key, pointer+"/subsystems/"+key, &sub)
			}
		}
	}
	token := strings.NewReplacer("~", "~0", "/", "~1")
	for _, name := range sortedKeys(file.Models) {
		m := file.Models[name]
		model(name, "/models/"+token.Replace(name), &m)
	}
	for _, name := range sortedKeys(file.ReactionSystems) {
		rs := file.ReactionSystems[name]
		reactionSystem(name, "/reaction_systems/"+token.Replace(name), &rs)
	}
	var sites []keySite
	for _, e := range exprs {
		visitKeys(e.expr, nil, func(key, op string) {
			for _, variable := range []string{e.scope + "." + key, key} {
				isUnspecified, declared := unspecified[variable]
				if !declared {
					continue
				}
				if isUnspecified {
					sites = append(sites, keySite{
						Path:    e.pointer,
						Message: fmt.Sprintf("%s has unspecified precision in %s at %s", variable, op, e.pointer),
					})
				}
				return
			}
		})
	}
	return sites
}

// isReactionSystemMap reports whether a raw component is a reaction system.
func isReactionSystemMap(raw map[string]any) bool {
	_, species := raw["species"]
	_, reactions := raw["reactions"]
	return species || reactions
}

func visitKeys(expr Expression, bound []string, found func(key, op string)) {
	node, ok := asExprNode(expr)
	if !ok {
		return
	}
	for name := range node.Ranges {
		bound = append(bound, name)
	}
	for _, i := range node.OutputIdx {
		if s, ok := i.(string); ok {
			bound = append(bound, s)
		}
	}
	if node.Var != nil {
		bound = append(bound, *node.Var)
	}
	if node.Op == "==" || node.Op == "!=" {
		for _, arg := range node.Args {
			for {
				inner, ok := asExprNode(arg)
				if !ok || inner.Op != "index" || len(inner.Args) == 0 {
					break
				}
				arg = inner.Args[0]
			}
			if name, ok := arg.(string); ok && !slices.Contains(bound, name) {
				found(name, node.Op)
			}
		}
	}
	for _, raw := range node.Join {
		clause, _ := raw.(map[string]any)
		pairs, _ := clause["on"].([]any)
		for _, rawPair := range pairs {
			pair, _ := rawPair.([]any)
			for _, name := range pair {
				if s, ok := name.(string); ok {
					found(s, "join.on")
				}
			}
		}
	}
	for _, child := range exprRefChildren(node) {
		// A fresh slice per child so siblings never see each other's binders.
		visitKeys(child.Child, slices.Clip(bound), found)
	}
}
