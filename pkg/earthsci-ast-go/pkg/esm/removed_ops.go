package esm

// The `removed_op` boundary (esm-spec §4.2; MIGRATION.md, "format 2.0.0").
//
// esm 2.0.0 removed the closed-function call `fn`, the `function_tables` block
// with its `table_lookup` op, `skolem`, `rank`, the geometry leaves
// `intersect_polygon` / `polygon_intersection_area` and the `argmin` /
// `argmax` op forms; the standard-library templates (`esm:std/...`) replace
// them. A removed op's name is still a well-formed identifier, which esm-spec
// §4.2 would admit as an OPEN rewrite-target op, so a document using one is
// refused BY NAME at the wire boundary (prepareDocumentOps), before schema
// validation and before the rewrite-target tier can see it. `arrayop`, removed
// at 0.8.0, goes through the same check.

import (
	"encoding/json"
	"fmt"
	"strings"
)

// codeRemovedOp: a document uses an op or a top-level / component-level field
// the format has removed (esm-spec §4.2). Hard error at load.
const codeRemovedOp = "removed_op"

// migrateCommand is the codemod that rewrites a 1.x document to 2.0.0.
const migrateCommand = "python -m earthsci_ast.migrate"

// removedOps maps each removed expression op to the esm version that removed it.
var removedOps = map[string]string{
	"arrayop":                   "0.8.0",
	"fn":                        "2.0.0",
	"table_lookup":              "2.0.0",
	"skolem":                    "2.0.0",
	"rank":                      "2.0.0",
	"intersect_polygon":         "2.0.0",
	"polygon_intersection_area": "2.0.0",
	"argmin":                    "2.0.0",
	"argmax":                    "2.0.0",
}

// removedFunctionTables is the removed document block; it is refused at the
// top level and inside a model or reaction system.
const removedFunctionTables = "function_tables"

// removedOpError is the `removed_op` diagnostic: Name is the removed op or
// field, Path the JSON Pointer of the node or block that uses it.
type removedOpError struct {
	Name    string
	Path    string
	Message string
}

func (e *removedOpError) Error() string { return fmt.Sprintf("[%s] %s", codeRemovedOp, e.Message) }

// DiagnosticCode returns the stable diagnostic code (DiagnosticError).
func (e *removedOpError) DiagnosticCode() string { return codeRemovedOp }

// newRemovedOpError builds the diagnostic for a removed op (isField false) or
// the removed `function_tables` block (isField true) found at path.
func newRemovedOpError(name, path string, isField bool) *removedOpError {
	where := path
	if where == "" {
		where = "/"
	}
	var msg string
	switch {
	case isField:
		msg = fmt.Sprintf("the `%s` block at %s was removed at esm 2.0.0; a table is now "+
			"`const` data read by the `linear` / `bilinear` templates of esm:std/interp.esm. "+
			"Convert the document with `%s` (MIGRATION.md)", name, where, migrateCommand)
	case name == "arrayop":
		msg = fmt.Sprintf("`\"op\": \"arrayop\"` at %s was removed at esm 0.8.0 and is not a "+
			"deprecated alias; use `\"op\": \"faq\"` (the Functional Aggregate Query node). "+
			"See docs/content/rfcs/faq-node-rename.md", where)
	default:
		msg = fmt.Sprintf("`\"op\": \"%s\"` at %s was removed at esm %s; the esm:std expression "+
			"templates replace it. Convert the document with `%s` (MIGRATION.md)",
			name, where, removedOps[name], migrateCommand)
	}
	return &removedOpError{Name: name, Path: path, Message: msg}
}

// checkRemovedConstructs is the wire-boundary check of one document's JSON
// text. removedOp is the first removed op scanOpAliases saw in the text ("" for
// none). The document is decoded only when there is something to locate.
func checkRemovedConstructs(jsonStr, removedOp string) error {
	if removedOp == "" && !strings.Contains(jsonStr, `"`+removedFunctionTables+`"`) {
		return nil
	}
	var doc any
	if err := json.Unmarshal([]byte(jsonStr), &doc); err != nil {
		// Not JSON: schema validation reports it.
		return nil
	}
	if err := findRemovedConstruct(doc); err != nil {
		return err
	}
	return nil
}

// findRemovedConstruct reports the first removed construct of a decoded
// document: a `function_tables` block (top level, then each model and reaction
// system in name order), then the first node whose `op` is removed, in
// sorted-key depth-first order. It returns nil when the document uses none.
func findRemovedConstruct(doc any) *removedOpError {
	root, ok := doc.(map[string]any)
	if !ok {
		return nil
	}
	if _, has := root[removedFunctionTables]; has {
		return newRemovedOpError(removedFunctionTables, "/"+removedFunctionTables, true)
	}
	for _, kind := range []string{"models", "reaction_systems"} {
		comps, _ := root[kind].(map[string]any)
		for _, name := range sortedKeys(comps) {
			comp, _ := comps[name].(map[string]any)
			if _, has := comp[removedFunctionTables]; has {
				return newRemovedOpError(removedFunctionTables,
					"/"+kind+"/"+escapeJSONPointerSegment(name)+"/"+removedFunctionTables, true)
			}
		}
	}
	return findRemovedOp(doc, "")
}

// findRemovedOp walks a decoded JSON tree for an object whose `op` is a removed
// op name.
func findRemovedOp(node any, path string) *removedOpError {
	switch v := node.(type) {
	case map[string]any:
		if op, ok := v["op"].(string); ok {
			if _, gone := removedOps[op]; gone {
				return newRemovedOpError(op, path, false)
			}
		}
		for _, k := range sortedKeys(v) {
			if err := findRemovedOp(v[k], path+"/"+escapeJSONPointerSegment(k)); err != nil {
				return err
			}
		}
	case []any:
		for i, el := range v {
			if err := findRemovedOp(el, fmt.Sprintf("%s/%d", path, i)); err != nil {
				return err
			}
		}
	}
	return nil
}
