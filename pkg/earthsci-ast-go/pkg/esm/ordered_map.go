package esm

import "sort"

// ---------------------------------------------------------------------------
// Ordered-map helper (Go maps are unordered; declaration order is normative)
// ---------------------------------------------------------------------------

type orderedMap struct {
	keys []string
	m    map[string]any
}

func newOrderedMap() *orderedMap {
	return &orderedMap{m: map[string]any{}}
}

func (o *orderedMap) has(k string) bool { _, ok := o.m[k]; return ok }

func (o *orderedMap) get(k string) any { return o.m[k] }

func (o *orderedMap) set(k string, v any) {
	if _, ok := o.m[k]; !ok {
		o.keys = append(o.keys, k)
	}
	o.m[k] = v
}

func (o *orderedMap) delete(k string) {
	if _, ok := o.m[k]; !ok {
		return
	}
	delete(o.m, k)
	for i, key := range o.keys {
		if key == k {
			o.keys = append(o.keys[:i], o.keys[i+1:]...)
			break
		}
	}
}

func (o *orderedMap) len() int { return len(o.m) }

// orderedKeysOf returns m's keys, honouring `order` first and appending any
// keys absent from `order` in sorted-name order.
func orderedKeysOf(m map[string]any, order []string) []string {
	return orderedKeys(m, order)
}

// orderedKeys is orderedKeysOf over a map of any value type. Declaration order
// is normative for every map a FlattenedSystem carries (esm-libraries-spec
// §4.7.5 step 4), and the typed document holds those maps as
// map[string]ModelVariable, map[string]Species, ... rather than map[string]any.
func orderedKeys[V any](m map[string]V, order []string) []string {
	seen := make(map[string]bool, len(m))
	keys := make([]string, 0, len(m))
	for _, k := range order {
		if _, ok := m[k]; ok && !seen[k] {
			keys = append(keys, k)
			seen[k] = true
		}
	}
	rest := make([]string, 0, len(m))
	for k := range m {
		if !seen[k] {
			rest = append(rest, k)
		}
	}
	sort.Strings(rest)
	return append(keys, rest...)
}

// sortedKeys returns the sorted keys of a map. Use it for a DETERMINISTIC walk
// of a map whose order is not itself meaningful; where declaration order IS
// meaningful (esm-libraries-spec §4.7.5 step 4), use orderedKeys instead.
func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// attachSpeciesOrders copies each reaction system's authored `species` key
// order out of ESMFile.keyOrders and onto the system itself, so DeriveODEs and
// StoichiometricMatrix — which take a bare *ReactionSystem and have no route
// back to the file — can iterate species in declaration order (API_SPEC.md
// §5.10).
//
// Only top-level `/reaction_systems/<name>` systems are reached. A system
// mounted as a SUBSYSTEM is held as `any` and decoded on demand by
// decodeSubsystemAs, so there is no persistent struct to attach an order to;
// those fall back to sorted-name order, exactly as ESMFile.declarationOrder
// already documents for a `{"ref": ...}` mount. Flatten is unaffected either
// way: it walks subsystems with the file in hand and reads keyOrders directly.
func attachSpeciesOrders(file *ESMFile) {
	if file == nil || file.keyOrders == nil {
		return
	}
	for name, rs := range file.ReactionSystems {
		order := file.declarationOrder("/reaction_systems/" + name + "/species")
		if order == nil {
			continue
		}
		rs.speciesOrder = order
		file.ReactionSystems[name] = rs
	}
}
