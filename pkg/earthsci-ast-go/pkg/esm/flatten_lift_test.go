package esm

import (
	"errors"
	"reflect"
	"strings"
	"testing"
)

// liftShaped is one shaped variable handed to lift2D: its name and declared
// index sets.
type liftShaped struct {
	name  string
	shape []string
}

// lift2D lifts `D(C) = wrap(<2-D operator makearray over x × y>)`, with the
// declared index sets x (2), y (3) and z (4) and the given shaped parameters,
// and returns the lifted right-hand side's `faq` body.
func lift2D(t *testing.T, wrap func(Expression) Expression, shapes []liftShaped) (Expression, error) {
	t.Helper()
	makearray := ExprNode{
		Op:      "makearray",
		Regions: [][][]any{{{1, 2}, {1, 3}}},
		Values:  []any{ExprNode{Op: "index", Args: []any{"C", "i", "j"}}},
	}
	wrt := DefaultIndepVar
	flat := &FlattenedSystem{
		StateVariables: []FlattenedVariable{{Name: "C", Role: "state"}},
		Equations: []FlattenedEquation{{
			LHS:          ExprNode{Op: OpDerivative, Args: []any{"C"}, Wrt: &wrt},
			RHS:          wrap(makearray),
			SourceSystem: "M",
		}},
	}
	for _, s := range shapes {
		flat.Parameters = append(flat.Parameters,
			FlattenedVariable{Name: s.name, Role: "parameter", Shape: s.shape})
	}
	for _, is := range []struct {
		name string
		size int
	}{{"x", 2}, {"y", 3}, {"z", 4}} {
		size := is.size
		flat.IndexSets = append(flat.IndexSets,
			FlattenedIndexSet{Name: is.name, Set: IndexSet{Kind: "interval", Size: &size}})
	}
	pointwise := "pointwise"
	coupling := []CouplingEntry{OperatorComposeCoupling{
		Type: "operator_compose", Systems: [2]string{"M", "Adv"}, Lifting: &pointwise,
	}}
	if err := applyPointwiseLift(flat, coupling); err != nil {
		return nil, err
	}
	if len(flat.LiftedShapes) != 1 || !reflect.DeepEqual(flat.LiftedShapes[0].Shape, []int{2, 3}) {
		t.Fatalf("lifted shapes = %+v, want C: [2 3]", flat.LiftedShapes)
	}
	if got := flat.StateVariables[0].Shape; !reflect.DeepEqual(got, []string{"x", "y"}) {
		t.Fatalf("C shape = %v, want [x y]", got)
	}
	rhs, ok := flat.Equations[0].RHS.(ExprNode)
	if !ok || rhs.Op != "faq" {
		t.Fatalf("lifted RHS is not an faq: %#v", flat.Equations[0].RHS)
	}
	return rhs.Expr, nil
}

// liftOver is `makearray / <operand>`.
func liftOver(operand Expression) func(Expression) Expression {
	return func(ma Expression) Expression {
		return ExprNode{Op: "/", Args: []any{ma, operand}}
	}
}

// liftOperand is the divisor of a lifted `makearray / <operand>` body.
func liftOperand(t *testing.T, body Expression) Expression {
	t.Helper()
	node, ok := body.(ExprNode)
	if !ok || node.Op != "/" || len(node.Args) != 2 {
		t.Fatalf("lifted body is not a binary '/': %#v", body)
	}
	return node.Args[1]
}

func assertGather(t *testing.T, got Expression, want ...any) {
	t.Helper()
	if !reflect.DeepEqual(got, ExprNode{Op: "index", Args: want}) {
		t.Fatalf("got %#v, want index%v", got, want)
	}
}

func liftErrorMessage(t *testing.T, err error) string {
	t.Helper()
	var dpe *DimensionPromotionError
	if !errors.As(err, &dpe) {
		t.Fatalf("expected *DimensionPromotionError, got %T: %v", err, err)
	}
	return dpe.Message
}

// A variable that already lives on the lift grid (here an air mass `m` the
// merged right-hand side divides by) is read per cell inside the lifted body.
func TestPointwiseLiftIndexesAShapedOperand(t *testing.T) {
	body, err := lift2D(t, liftOver("m"), []liftShaped{{"m", []string{"x", "y"}}})
	if err != nil {
		t.Fatal(err)
	}
	assertGather(t, liftOperand(t, body), "m", "i", "j")
}

// Operands align by index-set NAME (esm-spec §4.3.4): a lower-rank operand is
// read at the loops of the index sets it declares and replicates along the
// rest, rather than taking every loop positionally.
func TestPointwiseLiftGathersALowerRankOperandByName(t *testing.T) {
	body, err := lift2D(t, liftOver("p"), []liftShaped{{"p", []string{"y"}}})
	if err != nil {
		t.Fatal(err)
	}
	assertGather(t, liftOperand(t, body), "p", "j")
}

// A permuted shape transposes: `[y, x]` is read at `(j, i)`, not `(i, j)`.
func TestPointwiseLiftGathersAPermutedOperandByName(t *testing.T) {
	body, err := lift2D(t, liftOver("m"), []liftShaped{{"m", []string{"y", "x"}}})
	if err != nil {
		t.Fatal(err)
	}
	assertGather(t, liftOperand(t, body), "m", "j", "i")
}

// An axis the grid is not shaped over (a staggered or differently sized index
// set) has no loop to read it at, so the lift refuses rather than reading the
// wrong cell.
func TestPointwiseLiftRefusesAnOperandOnAForeignIndexSet(t *testing.T) {
	for _, shape := range [][]string{{"x", "z"}, {"z"}} {
		_, err := lift2D(t, liftOver("f"), []liftShaped{{"f", shape}})
		msg := liftErrorMessage(t, err)
		if !strings.Contains(msg, `"f"`) || !strings.Contains(msg, `index set "z"`) {
			t.Fatalf("shape %v: message %q", shape, msg)
		}
	}
}

// A whole-array shape op has no per-cell reading of its operand, so the lift
// refuses instead of gathering one cell into it.
func TestPointwiseLiftRefusesAnOperandOfAWholeArrayOp(t *testing.T) {
	reshaped := ExprNode{Op: "reshape", Args: []any{"m"}, Shape: []any{6}}
	_, err := lift2D(t, liftOver(reshaped), []liftShaped{{"m", []string{"x", "y"}}})
	msg := liftErrorMessage(t, err)
	if !strings.Contains(msg, `"m"`) || !strings.Contains(msg, `"reshape"`) {
		t.Fatalf("message %q", msg)
	}
}
