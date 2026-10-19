package examples

import (
	"path/filepath"
	"sort"
)

// fixture locates a shared example document. `go test` runs in the package
// directory, so the path is relative to this file.
func fixture(name string) string {
	return filepath.Join("..", "fixtures", name)
}

// sortedKeys returns a map's keys in order, so printed output is stable.
func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
