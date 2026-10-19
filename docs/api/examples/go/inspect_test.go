package examples

import (
	"fmt"
	"log"

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm"
)

// List a document's models and variables, then classify the variables
// (esm-spec §6.3.1): ODE states, observed and algebraic unknowns, parameters.
func Example_inspect() {
	// region: inspect ops=load_path,ode_states,observed_unknowns,algebraic_unknowns,constant_parameters,is_ode_state,observed_definition,to_ascii
	doc, err := esm.LoadPath(fixture("decay.esm"))
	if err != nil {
		log.Fatal(err)
	}
	for _, name := range sortedKeys(doc.Models) {
		model := doc.Models[name]
		fmt.Println(name, sortedKeys(model.Variables))

		fmt.Println("ODE states:", esm.ODEStates(&model))
		fmt.Println("observed:", esm.ObservedUnknowns(&model))
		fmt.Println("algebraic:", esm.AlgebraicUnknowns(&model))
		fmt.Println("constant parameters:", esm.ConstantParameters(&model))

		fmt.Println(esm.IsODEState(&model, "N"), esm.IsODEState(&model, "half_life"))
		if def, ok := esm.ObservedDefinition(&model, "half_life"); ok {
			fmt.Println("half_life =", esm.ToASCII(def))
		}
	}
	// endregion

	// Output:
	// Decay [N half_life lambda]
	// ODE states: [N]
	// observed: [half_life]
	// algebraic: []
	// constant parameters: [lambda]
	// true false
	// half_life = log(2) / lambda
}
