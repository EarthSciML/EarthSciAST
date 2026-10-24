package examples

import (
	"fmt"
	"log"
	"os"

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm"
)

// Validate a good document, then read the errors a bad one reports. Go
// returns a result value rather than an error for an invalid document.
func Example_validate() {
	// region: validate ops=validate,validate_text
	doc, err := esm.LoadPath(fixture("decay.esm"))
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(esm.Validate(doc).IsValid)

	// invalid.esm is schema-clean but its equation reads an undeclared `k`.
	text, err := os.ReadFile(fixture("invalid.esm"))
	if err != nil {
		log.Fatal(err)
	}
	result := esm.ValidateText(string(text))
	fmt.Println(result.IsValid)
	for _, e := range result.StructuralErrors {
		fmt.Println(e.Code, e.Path)
		fmt.Println(e.Message)
	}
	// endregion

	// Output:
	// true
	// false
	// undefined_variable /models/Broken/equations/0/rhs
	// Undefined variable 'k'
}
