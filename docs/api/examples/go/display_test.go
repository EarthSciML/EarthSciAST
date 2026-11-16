package examples

import (
	"fmt"
	"log"

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm"
)

// Show an equation as math, LaTeX or Typst, under the names it uses.
func Example_display() {
	// region: display ops=print_math,expression_names
	doc, err := esm.LoadPath(fixture("decay.esm"))
	if err != nil {
		log.Fatal(err)
	}
	model := doc.Models["Decay"]
	decay := model.Equations[0]
	names := esm.ExpressionNames(decay)
	fmt.Println(names)
	fmt.Println(esm.PrintMath(decay, names, esm.DocumentMarkdown))
	fmt.Println(esm.PrintMath(decay, names, esm.DocumentTypst))

	// A single expression prints the same way.
	rhs := model.Equations[1].RHS
	fmt.Println(esm.PrintMath(rhs, esm.ExpressionNames(rhs), esm.DocumentTypst))
	// endregion

	// Output:
	// [N lambda]
	// \frac{\mathrm{d} N}{\mathrm{d} t} = \left(-\lambda\right) N
	// (dif N)/(dif t) = (-lambda) N
	// ln(2)/lambda
}
