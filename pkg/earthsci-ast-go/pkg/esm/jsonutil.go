package esm

import "fmt"

// jsonutil.go provides the single generic raw-JSON tree walker that the
// bespoke recursive walkers in lower_expression_templates.go
// (validateGeometryManifolds, assertNoNestedApply, validateMakearrayRegions,
// findApplyPaths) each re-implement by hand today. Consolidating them here
// removes four near-identical traversals that had already drifted in their
// path formatting and their expression_templates-skip behavior.

// walkJSONTree recursively walks a decoded-JSON tree (map[string]interface{} /
// []interface{} / scalar leaves) rooted at tree, invoking visit for EVERY
// object (map) node with its JSON-pointer-ish path.
//
// Path convention mirrors the existing walkers exactly: an object's child under
// key k extends the path with "/"+k, and an array's element i extends it with
// fmt.Sprintf("/%d", i). Call the root with path == "" (or "#", as a caller
// prefers). visit is called on the object node itself BEFORE its children are
// visited (pre-order), so a caller can inspect a node's "op"/"manifold"/… and
// still have its descendants walked afterward. Arrays and scalars are not
// passed to visit; only object nodes are.
//
// Object children are descended in sorted-key order (via sortedKeys), so that
// when visit returns an error the surfaced error is deterministic across runs —
// matching assertNoNestedApply / findApplyPaths (Go map iteration is
// randomized). The first error from visit (or from a deeper node) is returned
// and halts the walk.
//
// This base form visits the whole tree, matching assertNoNestedApply and
// findApplyPaths. To replicate the validateGeometryManifolds /
// validateMakearrayRegions convention of NOT descending into
// `expression_templates` blocks (pre-substitution template bodies may legally
// carry parameter names in scalar slots), use walkJSONTreeSkipping with a skip
// set — the skip is a parameter, so the base form stays skip-free.
func walkJSONTree(tree any, path string, visit func(path string, obj map[string]any) error) error {
	return walkJSONTreeSkipping(tree, path, nil, visit)
}

// walkJSONTreeSkipping is walkJSONTree with a set of object keys whose values
// are NOT descended into. When a map node has a child under a key present in
// skipKeys, that child subtree is skipped (the node itself is still visited).
// Passing skipKeys == nil is equivalent to walkJSONTree.
//
// Pass e.g. map[string]struct{}{"expression_templates": {}} to reproduce the
// validateGeometryManifolds / validateMakearrayRegions convention.
func walkJSONTreeSkipping(tree any, path string, skipKeys map[string]struct{}, visit func(path string, obj map[string]any) error) error {
	switch t := tree.(type) {
	case map[string]any:
		if err := visit(path, t); err != nil {
			return err
		}
		for _, k := range sortedKeys(t) {
			if _, skip := skipKeys[k]; skip {
				continue
			}
			if err := walkJSONTreeSkipping(t[k], path+"/"+k, skipKeys, visit); err != nil {
				return err
			}
		}
	case []any:
		for i, child := range t {
			if err := walkJSONTreeSkipping(child, fmt.Sprintf("%s/%d", path, i), skipKeys, visit); err != nil {
				return err
			}
		}
	}
	return nil
}
