package examples

import (
	"encoding/json"
	"fmt"
	"log"
	"reflect"

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm"
)

// Read an expression from LaTeX math, build one from nodes, list its free
// variables, and substitute into it.
func Example_expressions() {
	// region: expressions ops=parse_math,free_variables,substitute,print_math,evaluate
	read, err := esm.ParseMath(`k \left(T_{\mathrm{wall}} - T_{\mathrm{air}}\right)`,
		[]string{"k", "T_wall", "T_air"}, esm.DocumentMarkdown)
	if err != nil {
		log.Fatal(err)
	}
	// ParseMath returns the decoded JSON tree; UnmarshalExpression makes it
	// this package's Expression.
	blob, err := json.Marshal(read)
	if err != nil {
		log.Fatal(err)
	}
	parsed, err := esm.UnmarshalExpression(blob)
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
	fmt.Println(reflect.DeepEqual(built, parsed))

	substituted, err := esm.Substitute(parsed, map[string]esm.Expression{
		"T_wall": 290.0,
		"k":      esm.ExprNode{Op: "/", Args: []any{1.0, "tau"}},
	})
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(esm.PrintMath(substituted, esm.ExpressionNames(substituted), esm.DocumentTypst))
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
	// 1/tau (290 - T_(upright("air")))
	// [T_air tau]
	// 0.5
}
