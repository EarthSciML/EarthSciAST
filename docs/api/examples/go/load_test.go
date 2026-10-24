package examples

import (
	"fmt"
	"log"
	"os"

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm"
)

// Read a document from a path, and the same document from a JSON string.
func Example_load() {
	// region: load ops=load_path,load_string
	doc, err := esm.LoadPath(fixture("decay.esm"))
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(sortedKeys(doc.Models))

	text, err := os.ReadFile(fixture("decay.esm"))
	if err != nil {
		log.Fatal(err)
	}
	fromText, err := esm.LoadString(string(text))
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(fromText.Metadata.Name, len(fromText.Models["Decay"].Equations))
	// endregion

	// Output:
	// [Decay]
	// Decay 2
}
