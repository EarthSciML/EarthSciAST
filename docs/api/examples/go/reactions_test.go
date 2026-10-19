package examples

import (
	"fmt"
	"log"

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm"
)

// Derive the mass-action ODEs of a reaction system.
func Example_reactions() {
	// region: reactions ops=load_path,derive_odes,stoichiometric_matrix,to_ascii
	doc, err := esm.LoadPath(fixture("ozone.esm"))
	if err != nil {
		log.Fatal(err)
	}
	system := doc.ReactionSystems["Ozone"]
	odes, err := esm.DeriveODEs(&system)
	if err != nil {
		log.Fatal(err)
	}
	for _, eq := range odes.Equations {
		fmt.Println(esm.ToASCII(eq.LHS), "=", esm.ToASCII(eq.RHS))
	}

	// One row per species, one column per reaction.
	fmt.Println(esm.StoichiometricMatrix(&system))
	// endregion

	// Output:
	// D(O3)/Dt = -1 * k1 * NO * O3 + jNO2 * NO2
	// D(NO)/Dt = -1 * k1 * NO * O3 + jNO2 * NO2
	// D(NO2)/Dt = k1 * NO * O3 + -1 * jNO2 * NO2
	// [[-1 1] [-1 1] [1 -1]]
}
