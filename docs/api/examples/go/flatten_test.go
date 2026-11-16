package examples

import (
	"fmt"
	"log"

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm"
)

// Flatten a coupled document into one system with dot-namespaced names, and
// list its variables and equations.
func Example_flatten() {
	// region: flatten ops=load_path,flatten,print_math
	doc, err := esm.LoadPath(fixture("coupled.esm"))
	if err != nil {
		log.Fatal(err)
	}
	flat, err := esm.Flatten(doc)
	if err != nil {
		log.Fatal(err)
	}
	for _, v := range flat.StateVariables {
		fmt.Println("state:", v.Name)
	}
	for _, v := range flat.Parameters {
		fmt.Println("parameter:", v.Name)
	}
	for _, eq := range flat.Equations {
		fmt.Println(eq.LHSString(), "=", eq.RHSString())
	}
	// endregion

	// Output:
	// state: Heater.T
	// state: Box.T_air
	// parameter: Heater.rate
	// parameter: Box.k
	// (dif italic("Heater")"."T)/(dif t) = italic("Heater")"."italic("rate")
	// (dif italic("Box")"."T_(upright("air")))/(dif t) = italic("Box")"."k (italic("Heater")"."T - italic("Box")"."T_(upright("air")))
}
