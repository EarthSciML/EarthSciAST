// dae.go implements the Go binding's trivial-DAE strategy (discretization RFC
// §12). See ApplyDAEContract for the full contract. The package-level
// documentation lives in doc.go.

package esm

import (
	"fmt"
	"sort"
	"strings"
)

// codeNontrivialDAE is the RFC §12 stable error code raised when residual
// algebraic equations survive trivial factoring.
const codeNontrivialDAE = "E_NONTRIVIAL_DAE"

// RuleEngineError is a stable-coded error raised by the DAE contract.
// Code is one of the RFC §12 codes (e.g. E_NONTRIVIAL_DAE).
type RuleEngineError struct {
	Code    string
	Message string
}

func (e *RuleEngineError) Error() string {
	return fmt.Sprintf("[%s] %s", e.Code, e.Message)
}

// DiagnosticCode returns the stable diagnostic code (DiagnosticError).
func (e *RuleEngineError) DiagnosticCode() string { return e.Code }

func newRuleErr(code, msg string) *RuleEngineError {
	return &RuleEngineError{Code: code, Message: msg}
}

// DAEInfo records the outcome of ApplyDAEContract on an ESMFile.
type DAEInfo struct {
	// SystemClass is "ode" if ApplyDAEContract succeeded with no
	// residual algebraic equations, else "dae".
	SystemClass string
	// AlgebraicEquationCount is the number of algebraic equations
	// remaining after trivial factoring, summed across models.
	AlgebraicEquationCount int
	// TrivialFactoredCount is the number of algebraic equations
	// substituted out and removed during factoring.
	TrivialFactoredCount int
	// PerModel maps model name to residual algebraic equation count.
	PerModel map[string]int
	// PerModelFactored maps model name to equations factored out.
	PerModelFactored map[string]int
}

// ApplyDAEContract applies the Go binding's trivial-DAE strategy to every
// applicable model in file (mutating each in place) and classifies the result.
//
// Per docs/rfcs/dae-binding-strategies.md, when an ESM model contains algebraic
// equations alongside differential ones, ApplyDAEContract factors out equations
// of the form
//
//	y ~ f(...)
//
// where `y` is a plain variable that does not appear in `f` (acyclic). Such
// equations are symbolically substituted into every other equation (and into
// observed-variable expressions) and then removed from the model. The factoring
// runs to a fixed point so that chains like
//
//	z ~ g(y); y ~ h(x); D(x) ~ F(y, z)
//
// reduce to a pure ODE in `x`.
//
// It returns a populated DAEInfo and, if any non-trivial algebraic equations
// remain after factoring, a *RuleEngineError with code E_NONTRIVIAL_DAE whose
// message lists the residual equation paths and points the author at the Julia
// binding (full DAE via ModelingToolkit.jl) and RFC §12.
//
// ApplyDAEContract does not run the RFC §11 discretization pipeline: it is
// intended to be composed with discretize() when that lands in Go, or called
// standalone by tools that need DAE factoring on an already discretized model.
// Models carrying an explicit non-ODE SystemKind ("nonlinear", "sde", "pde")
// are skipped — the DAE contract only applies to would-be ODE systems.
func ApplyDAEContract(file *ESMFile) (DAEInfo, error) {
	info := DAEInfo{
		SystemClass:      SystemKindODE,
		PerModel:         map[string]int{},
		PerModelFactored: map[string]int{},
	}
	if file == nil || len(file.Models) == 0 {
		return info, nil
	}

	indep := fileIndepVar(file)

	names := make([]string, 0, len(file.Models))
	for name := range file.Models {
		names = append(names, name)
	}
	sort.Strings(names)

	var residualPaths []string
	for _, mname := range names {
		m := file.Models[mname]
		if !isDAETargetSystem(&m) {
			info.PerModel[mname] = 0
			info.PerModelFactored[mname] = 0
			continue
		}
		factored, err := factorTrivialDAE(&m, indep)
		if err != nil {
			return info, err
		}
		info.TrivialFactoredCount += factored
		info.PerModelFactored[mname] = factored

		residual := 0
		for i, eq := range m.Equations {
			if isDifferentialEquation(eq, indep) {
				continue
			}
			residual++
			residualPaths = append(residualPaths,
				fmt.Sprintf("/models/%s/equations/%d", mname, i))
		}
		info.AlgebraicEquationCount += residual
		info.PerModel[mname] = residual
		file.Models[mname] = m
	}

	if info.AlgebraicEquationCount == 0 {
		return info, nil
	}

	info.SystemClass = SystemKindDAE
	msg := fmt.Sprintf(
		"model contains %d non-trivial algebraic equation(s) that could not be "+
			"factored symbolically (at %s). The Go binding implements trivial-DAE "+
			"support only: observed-style equations `y ~ f(...)` where y does not "+
			"appear in f are substituted and removed, but cyclic observed equations "+
			"and genuine algebraic constraints (e.g., x^2 + y^2 = 1) require a full "+
			"DAE assembler. Use the Julia binding (EarthSciAST.jl), which hands "+
			"mixed DAEs to ModelingToolkit.jl. See RFC §12 and "+
			"docs/rfcs/dae-binding-strategies.md.",
		info.AlgebraicEquationCount,
		strings.Join(residualPaths, ", "),
	)
	return info, newRuleErr(codeNontrivialDAE, msg)
}

// factorTrivialDAE runs trivial-algebraic factoring on a single model
// until fixed point. Returns the number of equations factored out.
//
// The `y` of a candidate equation `y ~ f(...)` is eliminated only when `y` does
// not occur anywhere in `f` — and "anywhere" now genuinely means anywhere,
// because Contains walks EVERY expression-bearing field (audit G1). Before that
// fix, an occurrence hidden in a sidecar field (`aggregate.expr`, an integral
// bound, a `table_lookup` axis, …) was invisible: the guard passed, the
// defining equation was DELETED, and the surviving equations went on referencing
// an now-undefined variable — a silently corrupted model returned with err=nil
// (audit G2).
//
// Substitution errors are propagated rather than discarded. The acyclicity of a
// single binding makes a SubstitutionError unreachable in principle, but
// swallowing it with `_ =` would have hidden exactly the class of corruption
// above, so the error path is real.
func factorTrivialDAE(model *Model, indep string) (int, error) {
	factored := 0
	for {
		idx := -1
		var lhsName string
		var rhsExpr Expression
		for i, eq := range model.Equations {
			if isDifferentialEquation(eq, indep) {
				continue
			}
			name, ok := eq.LHS.(string)
			if !ok {
				continue
			}
			if Contains(eq.RHS, name) {
				continue
			}
			idx = i
			lhsName = name
			rhsExpr = eq.RHS
			break
		}
		if idx < 0 {
			return factored, nil
		}
		bindings := map[string]Expression{lhsName: rhsExpr}
		for j := range model.Equations {
			if j == idx {
				continue
			}
			out, err := SubstituteInEquation(model.Equations[j], bindings)
			if err != nil {
				return factored, err
			}
			model.Equations[j] = out
		}
		for vname, v := range model.Variables {
			if v.Expression == nil {
				continue
			}
			out, err := Substitute(v.Expression, bindings)
			if err != nil {
				return factored, err
			}
			v.Expression = out
			model.Variables[vname] = v
		}
		model.Equations = append(model.Equations[:idx], model.Equations[idx+1:]...)
		factored++
	}
}

// isDifferentialEquation reports whether eq's LHS is D(<var>, wrt=indep).
// An LHS of D without an explicit wrt is treated as the model's
// independent variable (matches the Julia reference semantics).
func isDifferentialEquation(eq Equation, indep string) bool {
	var node ExprNode
	switch lhs := eq.LHS.(type) {
	case ExprNode:
		node = lhs
	case *ExprNode:
		if lhs == nil {
			return false
		}
		node = *lhs
	default:
		return false
	}
	if node.Op != OpDerivative {
		return false
	}
	if node.Wrt == nil {
		return true
	}
	return *node.Wrt == indep
}

// isDAETargetSystem reports whether the DAE contract applies to model.
// Models declared with a non-ODE SystemKind are handed off to other
// solver stacks (nonlinear, SDE, PDE) and are outside the DAE/ODE
// classification contract.
func isDAETargetSystem(model *Model) bool {
	if model.SystemKind == nil {
		return true
	}
	return *model.SystemKind == SystemKindODE
}

// fileIndepVar returns the independent (time) variable for the document. Every
// component shares the single top-level domain; when it declares an explicit
// independent_variable that name is used, otherwise it defaults to "t".
func fileIndepVar(file *ESMFile) string {
	if file.Domain != nil && file.Domain.IndependentVariable != nil {
		return *file.Domain.IndependentVariable
	}
	return DefaultIndepVar
}
