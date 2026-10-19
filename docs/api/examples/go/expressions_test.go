package examples

import (
	"fmt"
	"log"

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm"
)

// Parse an expression from text, build one from nodes, list its free
// variables, and substitute into it.
func Example_expressions() {
	// region: expressions ops=parse_expression,free_variables,substitute,to_ascii,evaluate
	parsed, err := esm.ParseExpression("k * (T_wall - T_air)")
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(sortedKeys(esm.FreeVariables(parsed)))

	// The same tree, built directly: an operator node is an ExprNode, a
	// variable is a string and a number is a float64.
	built := esm.ExprNode{Op: "*", Args: []any{
		"k",
		esm.ExprNode{Op: "-", Args: []any{"T_wall", "T_air"}},
	}}
	fmt.Println(esm.ToASCII(built) == esm.ToASCII(parsed))

	substituted, err := esm.Substitute(parsed, map[string]esm.Expression{
		"T_wall": 290.0,
		"k":      esm.ExprNode{Op: "/", Args: []any{1.0, "tau"}},
	})
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(esm.ToASCII(substituted))
	fmt.Println(sortedKeys(esm.FreeVariables(substituted)))

	value, err := esm.Evaluate(substituted, map[string]float64{"tau": 20, "T_air": 280})
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(value)
	// endregion

	// Output:
	// [T_air T_wall k]
	// true
	// 1 / tau * (290 - T_air)
	// [T_air tau]
	// 0.5
}
