package esm

import "sort"

// ---------------------------------------------------------------------------
// Ordered-map helper (Go maps are unordered; declaration order is normative)
// ---------------------------------------------------------------------------

type orderedMap struct {
	keys []string
	m    map[string]interface{}
}

func newOrderedMap() *orderedMap {
	return &orderedMap{m: map[string]interface{}{}}
}

func (o *orderedMap) has(k string) bool { _, ok := o.m[k]; return ok }

func (o *orderedMap) get(k string) interface{} { return o.m[k] }

func (o *orderedMap) set(k string, v interface{}) {
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
func orderedKeysOf(m map[string]interface{}, order []string) []string {
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
