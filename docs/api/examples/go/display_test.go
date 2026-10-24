package examples

import (
	"fmt"
	"log"

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm"
)

// Render an equation for people: Unicode, LaTeX and plain ASCII.
func Example_display() {
	// region: display ops=to_unicode,to_latex,to_ascii
	doc, err := esm.LoadPath(fixture("decay.esm"))
	if err != nil {
		log.Fatal(err)
	}
	model := doc.Models["Decay"]
	decay := model.Equations[0]
	fmt.Println(esm.ToUnicode(decay))
	fmt.Println(esm.ToLatex(decay))
	fmt.Println(esm.ToASCII(decay))

	// A single expression renders the same way.
	fmt.Println(esm.ToUnicode(model.Equations[1].RHS))
	// endregion

	// Output:
	// ∂N/∂t = (−λ)·N
	// \frac{\partial N}{\partial t} = (-\lambda) \cdot N
	// D(N)/Dt = (-lambda) * N
	// ln(2)/λ
}
