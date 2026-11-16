package examples

import (
	"fmt"
	"log"

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm"
)

// Derive the mass-action ODEs of a reaction system.
func Example_reactions() {
	// region: reactions ops=load_path,derive_odes,stoichiometric_matrix,print_math
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
		fmt.Println(esm.PrintMath(eq, esm.ExpressionNames(eq), esm.DocumentTypst))
	}

	// One row per species, one column per reaction.
	fmt.Println(esm.StoichiometricMatrix(&system))
	// endregion

	// Output:
	// (dif upright("O")_3)/(dif t) = -1 (italic("k1") upright("NO") upright("O")_3) + italic("jNO2") upright("NO")_2
	// (dif upright("NO"))/(dif t) = -1 (italic("k1") upright("NO") upright("O")_3) + italic("jNO2") upright("NO")_2
	// (dif upright("NO")_2)/(dif t) = italic("k1") upright("NO") upright("O")_3 + -1 (italic("jNO2") upright("NO")_2)
	// [[-1 1] [-1 1] [1 -1]]
}
