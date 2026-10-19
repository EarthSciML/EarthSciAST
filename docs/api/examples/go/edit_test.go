package examples

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm"
)

// Add a variable and an equation to a model, serialize the document to JSON,
// and write it to a file. The edit functions return a changed copy.
func Example_edit() {
	dir, err := os.MkdirTemp("", "esm-edit-example")
	if err != nil {
		log.Fatal(err)
	}
	defer os.RemoveAll(dir)

	// region: edit ops=load_path,add_variable,add_equation,parse_equation,validate,to_json,write_path
	doc, err := esm.LoadPath(fixture("decay.esm"))
	if err != nil {
		log.Fatal(err)
	}

	units, desc := "mol", "Amount decayed so far"
	model := esm.AddVariable(doc.Models["Decay"], "decayed", esm.ModelVariable{
		Type: "unknown", Units: &units, Description: &desc,
	})
	eq, err := esm.ParseEquation("decayed = 100 - N")
	if err != nil {
		log.Fatal(err)
	}
	model = esm.AddEquation(model, *eq)
	doc.Models["Decay"] = model
	fmt.Println(len(model.Equations), esm.Validate(doc).IsValid)

	text, err := esm.ToJSON(doc)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(strings.Contains(text, `"decayed"`))

	path := filepath.Join(dir, "decay-edited.esm")
	if err := esm.WritePath(doc, path); err != nil {
		log.Fatal(err)
	}
	reread, err := esm.LoadPath(path)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(sortedKeys(reread.Models["Decay"].Variables))
	// endregion

	// Output:
	// 3 true
	// true
	// [N decayed half_life lambda]
}
